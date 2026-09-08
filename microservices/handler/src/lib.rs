//! Handler service — plan §2.4.
//!
//! TLS clients to eresults.waecgh.org (BECE / WASSCE SC) and
//! ghana.waecdirect.org (WASSCE Private). Egress via the residential
//! proxy pool (hard rule 4 — never Hetzner DC IPs). Schema-validated
//! parsing with clean abort + DomDrift alert. Explicit no-persistence:
//! results stream through and are forgotten.

pub mod parser;
pub mod portal;
pub mod svc;

use std::sync::Arc;

pub use portal::{HttpPortal, PortalClient, PortalResponse};

use waec_common::pb::waec::common::v1::ResultPayload;
use waec_common::ExamType;

/// Shared state.
pub struct HandlerState {
    pub portal: Arc<dyn PortalClient>,
}

impl HandlerState {
    pub fn new(portal: Arc<dyn PortalClient>) -> Self {
        Self { portal }
    }
}

/// Full fetch+parse pipeline for one candidate.
pub async fn fetch_and_parse(
    state: &HandlerState,
    index_number: &str,
    exam: ExamType,
    exam_year: &str,
    voucher_pin: &str,
) -> Result<(ResultPayload, Option<parser::DomDriftAlert>), waec_common::errors::DomainError> {
    // Pin/serial go only into the form body — never logs (hard rule 1).
    let PortalResponse { html } = state
        .portal
        .fetch(exam, index_number, exam_year, voucher_pin)
        .await?;

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
            Ok((payload, None))
        }
        Err((err, alert)) => {
            // DOM drift: clean abort, no partial parse. Alert payload
            // carries selectors only — zero candidate data.
            if let Some(a) = &alert {
                tracing::error!(portal = a.portal_host, selector = %a.missing_selector, "DOM drift detected");
            }
            Err(err)
        }
    }
}

/// Binary entry point.
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("handler", "info", false);
        let portal = HttpPortal::from_env();
        let state = Arc::new(HandlerState::new(Arc::new(portal)));
        svc::serve(state, 50054).await.expect("handler server");
    });
}
