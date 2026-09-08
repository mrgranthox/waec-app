//! HandlerService gRPC — streams the result and forgets it (plan §2.4:
//! "explicit no-persistence guarantee"). The gRPC response carries the
//! payload; nothing is written to disk, DB, or logs.

// tonic::Status is large but canonical at gRPC boundaries.
#![allow(clippy::result_large_err)]

use std::sync::Arc;

use tonic::{Request, Response, Status};

use waec_common::pb::waec::common::v1::ResultPayload;
use waec_common::pb::waec::handler::v1::handler_service_server::HandlerService;
use waec_common::pb::waec::handler::v1::FetchResultRequest;
use waec_common::{DomainError, ErrorCode};

use crate::{fetch_and_parse, HandlerState};

pub struct HandlerServiceImpl {
    state: Arc<HandlerState>,
}

impl HandlerServiceImpl {
    pub fn new(state: Arc<HandlerState>) -> Self {
        Self { state }
    }
}

#[tonic::async_trait]
impl HandlerService for HandlerServiceImpl {
    async fn fetch_result(
        &self,
        request: Request<FetchResultRequest>,
    ) -> Result<Response<ResultPayload>, Status> {
        let req = request.into_inner();

        if !waec_common::is_valid_index_number(&req.index_number) {
            return Err(DomainError::new(
                ErrorCode::InvalidIndexNumber,
                "index number must be exactly 10 digits",
            )
            .into());
        }
        if req.voucher_pin.is_empty() {
            return Err(
                DomainError::new(ErrorCode::InvalidExamParams, "voucher PIN required").into(),
            );
        }
        let exam = waec_common::pb::waec::common::v1::ExamType::try_from(req.exam_type)
            .map_err(|_| DomainError::new(ErrorCode::UnsupportedExamType, "unknown exam_type"))?;
        let exam = match exam {
            waec_common::pb::waec::common::v1::ExamType::Bece => waec_common::ExamType::Bece,
            waec_common::pb::waec::common::v1::ExamType::WassceSchool => {
                waec_common::ExamType::WassceSchool
            }
            waec_common::pb::waec::common::v1::ExamType::WasscePrivate => {
                waec_common::ExamType::WasscePrivate
            }
            waec_common::pb::waec::common::v1::ExamType::Unspecified => {
                return Err(
                    DomainError::new(ErrorCode::UnsupportedExamType, "exam_type required").into(),
                );
            }
        };

        let (payload, _drift_alert) = fetch_and_parse(
            &self.state,
            &req.index_number,
            exam,
            &req.exam_year,
            &req.voucher_pin,
        )
        .await?;

        // Log metadata only — never grades, never PIN (hard rule 1).
        tracing::info!(
            transaction_id = %req.transaction_id,
            subjects = payload.grades.len(),
            "result fetched and streamed"
        );

        Ok(Response::new(payload))
    }
}

/// Serve with standard health checks.
pub async fn serve(state: Arc<HandlerState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::handler::v1::handler_service_server::HandlerServiceServer<HandlerServiceImpl>>()
        .await;

    let svc = waec_common::pb::waec::handler::v1::handler_service_server::HandlerServiceServer::new(
        HandlerServiceImpl::new(state),
    );

    tracing::info!(%port, "handler service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}
