//! Distributor service — plan §2.3.

// tonic::Status is large but canonical at gRPC boundaries.
#![allow(clippy::result_large_err)]

pub mod breaker;
pub mod vendor;

use std::sync::Arc;

use tonic::{Request, Response, Status};

pub use breaker::{CircuitBreaker, CircuitState, FailureKind};
pub use vendor::{MockVendor, VendorClient, VendorOutcome};

use waec_common::pb::waec::common::v1::ExamType as PbExamType;
use waec_common::pb::waec::distributor::v1::distributor_service_server::DistributorService;
use waec_common::pb::waec::distributor::v1::{AcquirePinRequest, AcquirePinResponse};
use waec_common::{DomainError, ErrorCode};

/// Primary + secondary pair, each guarded by its own breaker.
pub struct VendorPair {
    pub primary: Arc<dyn VendorClient>,
    pub secondary: Arc<dyn VendorClient>,
    pub primary_breaker: Arc<CircuitBreaker>,
    pub secondary_breaker: Arc<CircuitBreaker>,
}

pub struct DistributorState {
    pub vendors: VendorPair,
}

impl DistributorState {
    pub fn new(primary: Arc<dyn VendorClient>, secondary: Arc<dyn VendorClient>) -> Self {
        Self {
            vendors: VendorPair {
                primary,
                secondary,
                primary_breaker: Arc::new(CircuitBreaker::new()),
                secondary_breaker: Arc::new(CircuitBreaker::new()),
            },
        }
    }
}

pub struct DistributorServiceImpl {
    state: Arc<DistributorState>,
}

impl DistributorServiceImpl {
    pub fn new(state: Arc<DistributorState>) -> Self {
        Self { state }
    }

    /// Attempt one vendor with timeout classification + breaker updates.
    pub async fn try_vendor(
        &self,
        vendor: &Arc<dyn VendorClient>,
        breaker: &Arc<CircuitBreaker>,
        exam_type: &str,
    ) -> Result<VendorOutcome, DomainError> {
        if !breaker.allow_call().await {
            return Err(DomainError::new(
                ErrorCode::VendorCircuitOpen,
                format!("{} circuit open", vendor.name()),
            ));
        }

        let result = tokio::time::timeout(breaker::CALL_TIMEOUT, vendor.acquire(exam_type)).await;

        match result {
            Ok(Ok(outcome)) => match outcome {
                VendorOutcome::Acquired(_) => {
                    breaker.record_success().await;
                    Ok(outcome)
                }
                VendorOutcome::OutOfStock => {
                    breaker.record_failure(FailureKind::OutOfStock).await;
                    Err(DomainError::new(
                        ErrorCode::VendorsOutOfStock,
                        "out of stock",
                    ))
                }
            },
            Ok(Err(service_err)) => {
                breaker.record_failure(FailureKind::HttpError).await;
                Err(service_err)
            }
            Err(_elapsed) => {
                // Timeout fired at CALL_TIMEOUT; overruns count as Timeout
                // (plan: >3000ms).
                breaker.record_failure(FailureKind::Timeout).await;
                Err(DomainError::new(
                    ErrorCode::VendorCircuitOpen,
                    "vendor timeout",
                ))
            }
        }
    }

    /// Core acquisition with mandatory failover (plan §2.3 acceptance:
    /// "vendor outage simulation triggers failover with zero dropped
    /// transactions").
    pub async fn acquire_pin(
        &self,
        transaction_id: &str,
        exam_type: &str,
    ) -> Result<AcquirePinResponse, DomainError> {
        let v = &self.state.vendors;

        let primary_result = self
            .try_vendor(&v.primary, &v.primary_breaker, exam_type)
            .await;

        let (voucher, vendor_name, failover_used) = match primary_result {
            Ok(VendorOutcome::Acquired(vch)) => (vch, v.primary.name().to_string(), false),
            Ok(VendorOutcome::OutOfStock) | Err(_) => {
                // 100% reroute to secondary — user sees no failure.
                match self
                    .try_vendor(&v.secondary, &v.secondary_breaker, exam_type)
                    .await
                {
                    Ok(VendorOutcome::Acquired(vch)) => (vch, v.secondary.name().to_string(), true),
                    Ok(VendorOutcome::OutOfStock) | Err(_) => {
                        return Err(DomainError::new(
                            ErrorCode::VendorsOutOfStock,
                            "all vendors unavailable",
                        ));
                    }
                }
            }
        };

        // Hard rule 1: PIN/serial returned to caller, NEVER logged.
        tracing::info!(
            transaction_id = %transaction_id,
            vendor = %vendor_name,
            failover_used,
            "voucher acquired"
        );

        Ok(AcquirePinResponse {
            pin: voucher.pin,
            serial: voucher.serial,
            vendor: vendor_name,
            failover_used,
        })
    }
}

#[tonic::async_trait]
impl DistributorService for DistributorServiceImpl {
    async fn acquire_pin(
        &self,
        request: Request<AcquirePinRequest>,
    ) -> Result<Response<AcquirePinResponse>, Status> {
        let req = request.into_inner();
        let exam = match PbExamType::try_from(req.exam_type) {
            Ok(t) if t != PbExamType::Unspecified => pb_to_domain(t),
            _ => {
                return Err(
                    DomainError::new(ErrorCode::UnsupportedExamType, "exam_type required").into(),
                );
            }
        };

        self.acquire_pin(&req.transaction_id, exam.as_str())
            .await
            .map(Response::new)
            .map_err(Into::into)
    }
}

/// Free function (impls on foreign types violate the orphan rule).
fn pb_to_domain(t: PbExamType) -> waec_common::ExamType {
    match t {
        PbExamType::Bece => waec_common::ExamType::Bece,
        PbExamType::WassceSchool => waec_common::ExamType::WassceSchool,
        PbExamType::WasscePrivate => waec_common::ExamType::WasscePrivate,
        PbExamType::Unspecified => unreachable!("filtered by caller"),
    }
}

/// Binary entry point.
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("distributor", "info", false);
        let state = Arc::new(DistributorState::new(
            Arc::new(MockVendor {
                name: "sellepins".into(),
                always_fail: false,
                always_out_of_stock: false,
                latency: std::time::Duration::ZERO,
            }),
            Arc::new(MockVendor {
                name: "ewale".into(),
                always_fail: false,
                always_out_of_stock: false,
                latency: std::time::Duration::ZERO,
            }),
        ));
        serve(state, 50053).await.expect("distributor server");
    });
}

/// Serve with standard health checks.
pub async fn serve(
    state: Arc<DistributorState>,
    port: u16,
) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::distributor::v1::distributor_service_server::DistributorServiceServer<DistributorServiceImpl>>()
        .await;

    let svc = waec_common::pb::waec::distributor::v1::distributor_service_server::DistributorServiceServer::new(
        DistributorServiceImpl::new(state),
    );

    tracing::info!(%port, "distributor service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}

#[cfg(test)]
mod lib_tests;
