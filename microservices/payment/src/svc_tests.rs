//! Payment service tests — plan §2.2 acceptance criteria.

use std::sync::Arc;

use tonic::Request;
use waec_common::idempotency::{IdempotencyStore, InMemoryIdempotencyStore};

use crate::svc::{verify_webhook, verify_webhook_at, webhook_event_time, PaymentServiceImpl};
use crate::{MockTransport, PaymentState};
use waec_common::pb::waec::common::v1::{ExamType, PaymentChannel};
use waec_common::pb::waec::payment::v1::payment_service_server::PaymentService;
use waec_common::pb::waec::payment::v1::{
    GetPricingRequest, InitChargeRequest, InitChargeResponse,
};

fn svc(transport_fail: bool) -> PaymentServiceImpl {
    let state = Arc::new(PaymentState::new(
        Arc::new(MockTransport {
            fail: transport_fail,
            ..Default::default()
        }),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    ));
    PaymentServiceImpl::new(state)
}

fn charge_req(key: &str) -> InitChargeRequest {
    InitChargeRequest {
        idempotency_key: key.into(),
        index_number: "1002330440".into(),
        exam_type: ExamType::WassceSchool as i32,
        exam_year: "2025".into(),
        channel: PaymentChannel::MtnMomo as i32,
        phone: "0244000000".into(),
    }
}

#[tokio::test]
async fn charge_initializes_pending() {
    let s = svc(false);
    let resp = s
        .init_charge(Request::new(charge_req("key-1")))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        resp.status,
        waec_common::pb::waec::payment::v1::PaymentStatus::Pending as i32
    );
    assert_eq!(resp.amount_pesewas, 2000); // WASSCE_SC = GHS 20
    assert!(resp.checkout_url.contains("key-1"));
}

#[tokio::test]
async fn idempotent_replay_returns_original_no_double_charge() {
    let s = svc(false);
    let first = s
        .init_charge(Request::new(charge_req("same-key")))
        .await
        .unwrap()
        .into_inner();

    // Replay with the SAME key → cached response, transport not re-called.
    let second = s
        .init_charge(Request::new(charge_req("same-key")))
        .await
        .unwrap()
        .into_inner();

    assert_eq!(first, second);
    assert_eq!(first.transaction_id, "same-key");
}

#[tokio::test]
async fn missing_idempotency_key_rejected() {
    let s = svc(false);
    let mut req = charge_req("");
    req.idempotency_key = String::new();
    let err = s.init_charge(Request::new(req)).await.unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn declined_charge_is_error() {
    let s = svc(true);
    let err = s
        .init_charge(Request::new(charge_req("key-decline")))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::FailedPrecondition);
}

#[tokio::test]
async fn dynamic_pricing_per_exam() {
    let s = svc(false);
    let bece = s
        .get_pricing(Request::new(GetPricingRequest {
            exam_type: ExamType::Bece as i32,
        }))
        .await
        .unwrap()
        .into_inner();
    let wassce = s
        .get_pricing(Request::new(GetPricingRequest {
            exam_type: ExamType::WassceSchool as i32,
        }))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(bece.amount_pesewas, 1500);
    assert_eq!(wassce.amount_pesewas, 2000);
    assert_eq!(bece.currency, "GHS");
}

#[test]
fn webhook_signature_enforced() {
    let state = PaymentState::new(
        Arc::new(MockTransport {
            fail: false,
            ..Default::default()
        }),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    );
    let body = br#"{"event":"charge.success","createdAt":1800000000}"#;
    let good = waec_common::webhook::compute_paystack_signature("whsec_test", body);
    assert!(verify_webhook_at(&state, body, &good, 1800000000).is_ok());

    let bad = waec_common::webhook::compute_paystack_signature("wrong", body);
    let err = verify_webhook_at(&state, body, &bad, 1800000000).unwrap_err();
    assert_eq!(err.code, waec_common::ErrorCode::WebhookSignatureInvalid);
}

// ── §4.5: replay window on the payment-side entry point ─────────────────

/// A genuine delivery replayed after the window must be refused with a
/// code distinct from a signature failure, so ops can tell "attacker
/// forged" apart from "attacker (or a buggy retry) replayed".
#[test]
fn replayed_webhook_outside_window_rejected() {
    let state = PaymentState::new(
        Arc::new(MockTransport {
            fail: false,
            ..Default::default()
        }),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    );
    let event = 1_800_000_000i64;
    let body = format!(r#"{{"event":"charge.success","createdAt":{event}}}"#).into_bytes();
    let sig = waec_common::webhook::compute_paystack_signature("whsec_test", &body);

    // Inside the window: accepted.
    assert!(verify_webhook_at(&state, &body, &sig, event + 60).is_ok());

    // Delivered ten minutes later: same secret, same signature — replay.
    let err = verify_webhook_at(&state, &body, &sig, event + 600).unwrap_err();
    assert_eq!(err.code, waec_common::ErrorCode::WebhookReplayDetected);
    assert!(
        !err.retryable,
        "a replay must never be retried by the client"
    );
}

/// Stripping the timestamp must not downgrade verification to
/// signature-only — strict mode rejects the envelope outright.
#[test]
fn webhook_without_timestamp_is_rejected() {
    let state = PaymentState::new(
        Arc::new(MockTransport {
            fail: false,
            ..Default::default()
        }),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    );
    let body = br#"{"event":"charge.success"}"#;
    let sig = waec_common::webhook::compute_paystack_signature("whsec_test", body);
    let err = verify_webhook(&state, body, &sig).unwrap_err();
    assert_eq!(err.code, waec_common::ErrorCode::WebhookReplayDetected);
}

/// The ISO-8601 fallback on `data.create_time` is honoured when the
/// envelope timestamp is absent.
#[test]
fn webhook_timestamp_parsed_from_data_create_time() {
    let body = br#"{"event":"charge.success","data":{"create_time":"2027-01-01T00:00:00Z"}}"#;
    assert_eq!(webhook_event_time(body), Some(1_798_761_600));
}

// ── §4.9: idempotency replay storm (flaky Ghana networks) ───────────────

#[tokio::test]
async fn replay_storm_produces_exactly_one_charge() {
    // 40 concurrent replays of the SAME idempotency key — the retry
    // storm a congested Ghana tower can produce. Every replay must
    // return the SAME outcome, and the Paystack transport must see at
    // most one successful charge initialization (hard rule 3 / §4.9).
    let transport = Arc::new(MockTransport {
        fail: false,
        ..Default::default()
    });
    let state = Arc::new(PaymentState::new(
        transport.clone(),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    ));

    let key = "5f0f00e7-1111-4111-8111-111111111111"; // valid UUIDv4
    let mut handles = Vec::new();
    for _ in 0..40 {
        let s2 = PaymentServiceImpl::new(state.clone());
        let req = charge_req(key);
        handles.push(tokio::spawn(async move {
            s2.init_charge(Request::new(req)).await
        }));
    }

    let mut first: Option<InitChargeResponse> = None;
    for h in handles {
        let resp = h.await.unwrap().unwrap().into_inner();
        match &first {
            None => first = Some(resp),
            Some(f) => assert_eq!(&resp, f, "replay must return original outcome"),
        }
    }
    assert_eq!(first.unwrap().transaction_id, key);

    // Zero double-charge: at most ONE call may reach the transport.
    let calls = transport.calls.load(std::sync::atomic::Ordering::SeqCst);
    assert!(
        calls <= 1,
        "replay storm must not fan out to Paystack: {calls} calls"
    );
}

#[tokio::test]
async fn sequential_replay_never_recharges() {
    // The common mobile case: client retries after a timeout. Second
    // call with the same key must NOT hit the transport again.
    let transport = Arc::new(MockTransport {
        fail: false,
        ..Default::default()
    });
    let state = Arc::new(PaymentState::new(
        transport.clone(),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    ));
    let s = PaymentServiceImpl::new(state);

    let a = s
        .init_charge(Request::new(charge_req("retry-key")))
        .await
        .unwrap()
        .into_inner();
    let b = s
        .init_charge(Request::new(charge_req("retry-key")))
        .await
        .unwrap()
        .into_inner();
    assert_eq!(a, b);
    assert_eq!(transport.calls.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn distinct_keys_charge_independently() {
    // Idempotency must dedupe replays, not requests: different keys are
    // different purchases and each must reach the transport.
    let transport = Arc::new(MockTransport {
        fail: false,
        ..Default::default()
    });
    let state = Arc::new(PaymentState::new(
        transport.clone(),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    ));
    let s = PaymentServiceImpl::new(state);

    for i in 0..5 {
        let key = format!("5f0f00e7-2222-4222-8222-{:012x}", i);
        s.init_charge(Request::new(charge_req(&key))).await.unwrap();
        // Replay each once: still 5 total transport calls.
        s.init_charge(Request::new(charge_req(&key))).await.unwrap();
    }
    assert_eq!(transport.calls.load(std::sync::atomic::Ordering::SeqCst), 5);
}

#[tokio::test]
async fn concurrent_first_writes_race_to_one_cached_outcome() {
    // Same storm, but proving the store contract: of N concurrent `put`s
    // for one key, exactly one wins; `get` afterwards is stable.
    let store = InMemoryIdempotencyStore::default();
    let mut handles = Vec::new();
    for i in 0..25 {
        let st = store.clone();
        handles.push(tokio::spawn(async move {
            st.put(
                "race-key",
                waec_common::idempotency::IdempotentOutcome {
                    response: format!("winner-{i}"),
                    recorded_at: i as i64,
                },
            )
            .await
        }));
    }
    let wins = futures_lite_count(handles).await;
    assert_eq!(wins, 1, "exactly one concurrent put may win");
    let cached = store.get("race-key").await.unwrap();
    // The winner's identity is scheduling-dependent; consistency is not:
    // every caller that lost must observe the SAME stored outcome on re-
    // read, and it must be one of the candidates.
    assert!(cached.response.starts_with("winner-"));
}

async fn futures_lite_count(handles: Vec<tokio::task::JoinHandle<Result<(), ()>>>) -> usize {
    let mut wins = 0;
    for h in handles {
        if h.await.unwrap().is_ok() {
            wins += 1;
        }
    }
    wins
}
