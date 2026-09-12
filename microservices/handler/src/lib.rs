//! Handler service — plan §2.4.
//!
//! TLS clients to eresults.waecgh.org (BECE / WASSCE SC) and
//! ghana.waecdirect.org (WASSCE Private). Egress via the residential
//! proxy pool (hard rule 4 — never Hetzner DC IPs). Schema-validated
//! parsing with clean abort + DomDrift alert. Explicit no-persistence:
//! results stream through and are forgotten.

pub mod parser;
pub mod portal;
pub mod proxy;
pub mod svc;

use std::sync::{Arc, Mutex};

pub use portal::{HttpPortal, PortalClient, PortalResponse};
pub use proxy::{ProxyExit, ProxyRotator, TLS_PROFILES};

use waec_common::pb::waec::common::v1::ResultPayload;
use waec_common::ExamType;
use waec_data::events::EventPublisher;
use waec_data::grace::{FetchFailureKind, GraceIssuer, MemoryGraceLease};

/// Shared state.
pub struct HandlerState {
    pub portal: Arc<dyn PortalClient>,
    /// Residential exit + TLS fingerprint rotation (plan §4.7).
    pub rotator: Arc<Mutex<ProxyRotator>>,
    /// Pipeline publisher for fetch.result / fetch.failed / audit.events
    /// (plan §4.1 / §4.8).
    pub events: Arc<dyn EventPublisher>,
    /// Auto-issue 24 h grace tokens on mid-fetch failure (plan §4.1).
    /// `None` only in validation-only test configurations.
    pub grace: Option<Arc<GraceIssuer>>,
    /// Atomic transaction journal: the journey row is durable **before**
    /// portal egress (plan §4.1), so a process killed mid-scrape leaves an
    /// auditable in-flight transaction instead of a vanished one.
    pub journal: Arc<dyn waec_data::txlog::TxJournal>,
}

impl HandlerState {
    pub fn new(portal: Arc<dyn PortalClient>) -> Self {
        Self {
            portal,
            rotator: Arc::new(Mutex::new(ProxyRotator::default())),
            events: Arc::new(waec_data::events::InMemoryEventBus::new()),
            grace: None,
            journal: Arc::new(waec_data::txlog::MemoryTxJournal::default()),
        }
    }

    /// Full pipeline wiring (production + integration tests).
    pub fn with_pipeline(
        portal: Arc<dyn PortalClient>,
        events: Arc<dyn EventPublisher>,
        grace: Option<Arc<GraceIssuer>>,
        journal: Arc<dyn waec_data::txlog::TxJournal>,
    ) -> Self {
        Self {
            portal,
            rotator: Arc::new(Mutex::new(ProxyRotator::default())),
            events,
            grace,
            journal,
        }
    }

    /// Hermetic test state: memory lease + in-memory bus + given portal.
    /// Returns the handles so tests can assert without trait downcasts.
    pub fn for_test(
        portal: Arc<dyn PortalClient>,
    ) -> (
        Self,
        Arc<MemoryGraceLease>,
        Arc<waec_data::events::InMemoryEventBus>,
    ) {
        let lease = Arc::new(MemoryGraceLease::default());
        let bus = Arc::new(waec_data::events::InMemoryEventBus::new());
        let state = Self {
            portal,
            rotator: Arc::new(Mutex::new(ProxyRotator::default())),
            events: bus.clone(),
            grace: Some(Arc::new(GraceIssuer::new(lease.clone()))),
            journal: Arc::new(waec_data::txlog::MemoryTxJournal::default()),
        };
        (state, lease, bus)
    }
}

/// Full fetch+parse pipeline for one candidate (plan §2.4 + §4.1/§4.8).
///
/// Failure semantics (§4.1): if the fetch began (egress attempted) and
/// then broke — transport drop or DOM drift — the voucher is already
/// consumed upstream, so a 24 h grace token is auto-issued and
/// `fetch.failed` is emitted. Success emits `fetch.result` with outcome
/// metadata only (never grades — hard rule 1).
pub async fn fetch_and_parse(
    state: &HandlerState,
    transaction_id: &str,
    index_number: &str,
    exam: ExamType,
    exam_year: &str,
    voucher_pin: &str,
) -> Result<(ResultPayload, Option<parser::DomDriftAlert>), waec_common::errors::DomainError> {
    // §4.7: every egress rotates residential exit + TLS fingerprint.
    // The directive is chosen here and handed to the portal transport,
    // which forwards it to the pool rotator sidecar.
    let directive = {
        let mut rotator = state.rotator.lock().expect("rotator lock");
        let d = rotator.next_directive();
        proxy::assert_no_dc_leak(&d)?;
        tracing::debug!(
            exit = d.exit.id,
            tls = %d.tls_profile.label(),
            "egress directive selected"
        );
        d
    };

    // §4.1: the journey row is durable BEFORE any portal egress. A replay
    // of the same idempotency key does not own the journey and must not
    // re-enter the portal (one voucher per paid journey).
    let journaled = state
        .journal
        .begin(&waec_data::txlog::TxRecord {
            transaction_id: transaction_id.to_string(),
            index_number: index_number.to_string(),
            exam_type: exam.as_str().to_string(),
            exam_year: exam_year.parse().unwrap_or(0),
            amount_pesewas: 0, // sourced from the durable payment record
            status: waec_data::txlog::TxStatus::Fetching,
        })
        .await?;
    if !journaled {
        return Err(waec_common::errors::DomainError::new(
            waec_common::errors::ErrorCode::PaymentDuplicateIdempotencyKey,
            "journey already journaled for this transaction id",
        ));
    }

    // Pin/serial go only into the form body — never logs (hard rule 1).
    let html = match state
        .portal
        .fetch(exam, index_number, exam_year, voucher_pin, &directive)
        .await
    {
        Ok(r) => r.html,
        Err(err) => {
            // §4.1 transport failure: voucher consumed, candidate paid.
            emit_fetch_failed(
                state,
                transaction_id,
                index_number,
                FetchFailureKind::Transport,
            )
            .await;
            return Err(err);
        }
    };

    let schema = match exam {
        ExamType::Bece | ExamType::WassceSchool => &parser::ERESULTS_SCHEMA,
        ExamType::WasscePrivate => &parser::WAECDIRECT_SCHEMA,
    };

    match parser::parse_result(schema, &html) {
        Ok(parsed) => {
            let payload = ResultPayload {
                index_number: parsed.index_number,
                exam_type: exam as i32,
                exam_year: parsed.exam_year,
                candidate_name: parsed.candidate_name,
                grades: parsed
                    .grades
                    .into_iter()
                    .map(|g| waec_common::pb::waec::common::v1::SubjectGrade {
                        subject: g.subject,
                        grade: g.grade,
                    })
                    .collect(),
                aggregate: parsed.aggregate,
            };
            // Success path: no alert, no persistence — payload is returned
            // to the caller and forgotten here.
            let event = waec_data::events::Event::new(
                waec_data::events::topics::FETCH_RESULT,
                transaction_id,
                serde_json::json!({ "outcome": "success", "subjects": payload.grades.len() }),
            );
            let _ = state.events.publish(event).await;
            Ok((payload, None))
        }
        Err((err, alert)) => {
            // DOM drift: clean abort, no partial parse. Alert payload
            // carries selectors only — zero candidate data.
            if let Some(a) = &alert {
                tracing::error!(portal = a.portal_host, selector = %a.missing_selector, "DOM drift detected");
                // §4.8: engineering alert via the audit topic (Admin
                // routes it; counters drive DOM-drift alerting).
                let audit = waec_data::events::Event::new(
                    waec_data::events::topics::AUDIT_EVENTS,
                    transaction_id,
                    serde_json::json!({
                        "outcome": "dom_drift",
                        "portal_host": a.portal_host,
                        "missing_selector": a.missing_selector,
                    }),
                );
                let _ = state.events.publish(audit).await;
            }
            // §4.1: the voucher was consumed; the failure is ours —
            // auto-issue the free re-fetch token.
            emit_fetch_failed(
                state,
                transaction_id,
                index_number,
                FetchFailureKind::DomDrift,
            )
            .await;
            Err(err)
        }
    }
}

/// §4.1 failure path: auto-issue the grace token, then emit
/// `fetch.failed`. The issuer already orders these so the grace
/// guarantee never depends on the event bus.
async fn emit_fetch_failed(
    state: &HandlerState,
    transaction_id: &str,
    index_number: &str,
    kind: FetchFailureKind,
) {
    match &state.grace {
        Some(grace) => {
            if let Err(e) = grace
                .on_fetch_failed(transaction_id, index_number, kind, state.events.as_ref())
                .await
            {
                tracing::error!(transaction_id = %transaction_id, error = %e, "grace issuance failed");
            }
        }
        None => {
            // Validation-only mode (no lease wired): observability stays
            // on, but no free re-fetch is promised.
            let event = waec_data::events::Event::new(
                waec_data::events::topics::FETCH_FAILED,
                transaction_id,
                serde_json::json!({ "outcome": "failed", "kind": kind.as_str() }),
            );
            let _ = state.events.publish(event).await;
        }
    }
}

/// Binary entry point.
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("handler", "info", false);
        let portal = HttpPortal::from_env();
        // Grace wiring (plan §4.1/§4.3): Redis lease + Postgres durable log
        // when the data stores are configured; in-memory only for local dev.
        let grace = match build_grace_issuer().await {
            Some(g) => g,
            None => Arc::new(GraceIssuer::new(Arc::new(MemoryGraceLease::default()))),
        };
        let events = Arc::new(waec_data::events::InMemoryEventBus::new());
        // §4.1: durable journal so a journey row exists BEFORE portal egress.
        // Production uses Postgres; the journal is memory-only for local dev.
        let journal = build_journal().await;
        let state = HandlerState::with_pipeline(
            Arc::new(portal),
            events,
            Some(grace),
            journal,
        );
        svc::serve(Arc::new(state), 50054)
            .await
            .expect("handler server");
    });
}

/// Production grace issuer: Redis `grace:` lease + `grace_tokens` log.
/// `None` only when neither store is reachable (dev/test stacks).
async fn build_grace_issuer() -> Option<Arc<GraceIssuer>> {
    let redis_url = std::env::var("REDIS_URL").ok()?;
    let lease = waec_data::grace::GraceStore::connect(&redis_url)
        .await
        .map(Arc::new)
        .ok()?;
    let db_url = std::env::var("DATABASE_URL").ok()?;
    let pool = waec_data::connect_pool(&db_url).await.ok()?;
    let log = Arc::new(waec_data::grace::PgGraceLog::new(pool));
    Some(Arc::new(GraceIssuer::with_log(lease, log)))
}

/// Production transaction journal: Postgres `transaction_log` (migration
/// 0002). Memory-only for local dev / when no `DATABASE_URL` is set.
async fn build_journal() -> Arc<dyn waec_data::txlog::TxJournal> {
    match std::env::var("DATABASE_URL") {
        Ok(url) => match waec_data::connect_pool(&url).await {
            Ok(pool) => Arc::new(waec_data::txlog::PgTxJournal::new(pool)),
            Err(e) => {
                tracing::warn!(error = %e, "journal: falling back to in-memory");
                Arc::new(waec_data::txlog::MemoryTxJournal::default())
            }
        },
        Err(_) => Arc::new(waec_data::txlog::MemoryTxJournal::default()),
    }
}

#[cfg(test)]
mod lib_tests {
    use super::*;
    use std::collections::HashMap;
    use waec_data::events::topics;

    fn good_html() -> String {
        r#"<html><body>
            <div class="candidate-name">ADJEI KWAME</div>
            <div class="candidate-index">1002330440</div>
            <div class="exam-year">2025</div>
            <table class="grades"><tbody>
            <tr><td class="subject">MATHEMATICS</td><td class="grade">A1</td></tr>
            </tbody></table>
            <div class="aggregate">6</div>
            </body></html>"#
            .into()
    }

    fn healthy_portal() -> Arc<portal::MockPortal> {
        Arc::new(portal::MockPortal::new(HashMap::from([(
            ExamType::Bece,
            good_html(),
        )])))
    }

    #[tokio::test]
    async fn success_emits_fetch_result_metadata_only() {
        let (state, lease, bus) = HandlerState::for_test(healthy_portal());
        let (payload, alert) = fetch_and_parse(
            &state,
            "tx-ok",
            "1002330440",
            ExamType::Bece,
            "2025",
            "pin-1",
        )
        .await
        .unwrap();
        assert!(alert.is_none());
        assert_eq!(payload.grades.len(), 1);

        let snap = bus.snapshot().await;
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].topic, topics::FETCH_RESULT);
        assert_eq!(snap[0].payload["outcome"], "success");
        // Hard rule 1: no grades, no PIN in the event payload.
        let raw = serde_json::to_string(&snap[0].payload).unwrap();
        assert!(!raw.contains("A1") && !raw.contains("pin"));
        assert!(lease.is_empty().await, "success must not mint grace tokens");
    }

    #[tokio::test]
    async fn transport_failure_issues_grace_and_emits_fetch_failed() {
        // §4.1 chaos: portal unreachable after the voucher was consumed.
        let empty = Arc::new(portal::MockPortal::new(HashMap::new()));
        let (state, lease, bus) = HandlerState::for_test(empty);

        let err = fetch_and_parse(
            &state,
            "tx-drop",
            "1002330440",
            ExamType::Bece,
            "2025",
            "pin",
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, waec_common::ErrorCode::WaecPortalUnavailable);

        // §4.3: exactly one single-use grace token, bound to "tx-drop".
        let (_token, tx) = lease.consume_any().await.expect("grace auto-issued");
        assert_eq!(tx, "tx-drop");
        assert!(lease.is_empty().await);

        let snap = bus.snapshot().await;
        assert!(snap.iter().any(|e| e.topic == topics::FETCH_FAILED
            && e.correlation_id == "tx-drop"
            && e.payload["kind"] == "transport"));
    }

    #[tokio::test]
    async fn dom_drift_alerts_and_earns_grace_without_partial_results() {
        // §4.8: WAEC "redesigned". Clean abort, engineering alert, grace.
        let drifted = r#"<html><body>
            <p class="studentFullName">ADJEI KWAME</p>
            <div class="candidate-index">1002330440</div>
            <table class="results-grid"><tbody><tr><td>M</td><td>A1</td></tr></tbody></table>
            </body></html>"#;
        let portal = Arc::new(portal::MockPortal::new(HashMap::from([(
            ExamType::Bece,
            drifted.to_string(),
        )])));
        let (state, lease, bus) = HandlerState::for_test(portal);

        let err = fetch_and_parse(
            &state,
            "tx-drift",
            "1002330440",
            ExamType::Bece,
            "2025",
            "pin",
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, waec_common::ErrorCode::WaecDomSchemaDrift);

        let (_token, tx) = lease.consume_any().await.expect("grace auto-issued");
        assert_eq!(tx, "tx-drift");

        let snap = bus.snapshot().await;
        // Alert carries selectors only — zero candidate data (§4.8).
        let alert = snap
            .iter()
            .find(|e| e.topic == topics::AUDIT_EVENTS)
            .expect("dom_drift alert published");
        assert_eq!(alert.payload["portal_host"], "eresults.waecgh.org");
        let raw = serde_json::to_string(&alert.payload).unwrap();
        assert!(!raw.contains("KWAME") && !raw.contains("A1"));
        assert!(snap.iter().any(|e| e.topic == topics::FETCH_FAILED));
    }

    #[tokio::test]
    async fn poisoned_pool_aborts_egress_before_portal_call() {
        // §4.7 guard wired into the fetch path: a datacenter endpoint in
        // the pool aborts BEFORE any egress and without touching the
        // grace/pipeline machinery.
        let (mut state, _lease, bus) = HandlerState::for_test(healthy_portal());
        state.rotator = Arc::new(Mutex::new(ProxyRotator::seeded(
            vec![ProxyExit {
                id: "bad",
                region: "DC",
                endpoint: "10.0.0.9:9000",
                weight: 1,
            }],
            1,
        )));

        let err = fetch_and_parse(
            &state,
            "tx-leak",
            "1002330440",
            ExamType::Bece,
            "2025",
            "pin",
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, waec_common::ErrorCode::WaecPortalUnavailable);
        assert!(
            bus.snapshot().await.is_empty(),
            "pre-egress abort: pipeline untouched"
        );
    }

    #[tokio::test]
    async fn sustained_load_rotates_egress_directives() {
        // §4.7 acceptance: rotation is not just in the rotator — every
        // portal call must carry a fresh directive.
        let portal = healthy_portal();
        let (state, _lease, _bus) = HandlerState::for_test(portal.clone());
        for i in 0..5 {
            let _ = fetch_and_parse(
                &state,
                &format!("tx-{i}"),
                "1002330440",
                ExamType::Bece,
                "2025",
                "pin",
            )
            .await;
        }
        let seen = portal.seen_directives.lock().unwrap();
        assert_eq!(seen.len(), 5);
        let exits: std::collections::HashSet<_> = seen.iter().map(|d| d.exit.id).collect();
        let tls: std::collections::HashSet<_> =
            seen.iter().map(|d| d.tls_profile.label()).collect();
        assert!(exits.len() > 1, "exit never rotated across 5 calls");
        assert!(tls.len() > 1, "fingerprint never rotated across 5 calls");
    }

    #[tokio::test]
    async fn svc_validation_rejection_never_mints_grace() {
        // A bad index fails in the gRPC layer BEFORE egress — the voucher
        // was never consumed, so no grace token may exist and the
        // pipeline stays silent.
        let portal = healthy_portal();
        let (state, lease, bus) = HandlerState::for_test(portal);
        let svc = crate::svc::HandlerServiceImpl::new(Arc::new(state));

        use waec_common::pb::waec::handler::v1::handler_service_server::HandlerService;
        let err = svc
            .fetch_result(tonic::Request::new(
                waec_common::pb::waec::handler::v1::FetchResultRequest {
                    transaction_id: "tx-bad".into(),
                    index_number: "12".into(), // invalid
                    exam_type: ExamType::Bece as i32,
                    exam_year: "2025".into(),
                    voucher_pin: "pin".into(),
                    voucher_serial: String::new(),
                },
            ))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::InvalidArgument);
        assert!(lease.is_empty().await, "validation ≠ disruption: no grace");
        assert!(bus.snapshot().await.is_empty());
    }
}
