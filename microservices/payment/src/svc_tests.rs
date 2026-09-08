//! Payment service tests — plan §2.2 acceptance criteria.

use std::sync::Arc;

use tonic::Request;
use waec_common::idempotency::InMemoryIdempotencyStore;

use crate::svc::{verify_webhook, PaymentServiceImpl};
use crate::{MockTransport, PaymentState};
use waec_common::pb::waec::common::v1::{ExamType, PaymentChannel};
use waec_common::pb::waec::payment::v1::payment_service_server::PaymentService;
use waec_common::pb::waec::payment::v1::{GetPricingRequest, InitChargeRequest};

fn svc(transport_fail: bool) -> PaymentServiceImpl {
    let state = Arc::new(PaymentState::new(
        Arc::new(MockTransport {
            fail: transport_fail,
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
        Arc::new(MockTransport { fail: false }),
        Arc::new(InMemoryIdempotencyStore::default()),
        "whsec_test".into(),
    );
    let body = br#"{"event":"charge.success"}"#;
    let good = waec_common::webhook::compute_paystack_signature("whsec_test", body);
    assert!(verify_webhook(&state, body, &good).is_ok());

    let bad = waec_common::webhook::compute_paystack_signature("wrong", body);
    let err = verify_webhook(&state, body, &bad).unwrap_err();
    assert_eq!(err.code, waec_common::ErrorCode::WebhookSignatureInvalid);
}
