//! PaymentService gRPC implementation (plan §2.2).
//!
//! Acceptance criteria:
//! - Replay of duplicate idempotency key returns cached result (no
//!   second Paystack call — zero double-charge path).
//! - Invalid webhook signature rejected (401-equivalent).
//! - Dynamic GHS pricing served from config.

// tonic::Status is large but canonical at gRPC boundaries.
#![allow(clippy::result_large_err)]

use std::sync::Arc;

use tonic::{Request, Response, Status};
use waec_common::idempotency::IdempotentOutcome;

use waec_common::pb::waec::common::v1::ExamType as PbExamType;
use waec_common::pb::waec::payment::v1::payment_service_server::PaymentService;
use waec_common::pb::waec::payment::v1::{
    GetPricingRequest, GetPricingResponse, InitChargeRequest, InitChargeResponse, PaymentStatus,
};
use waec_common::{DomainError, ErrorCode};

use crate::paystack::{base_price_pesewas, ChargeMetadata, ChargeRequest, MobileMoney};
use crate::PaymentState;

pub struct PaymentServiceImpl {
    state: Arc<PaymentState>,
}

impl PaymentServiceImpl {
    pub fn new(state: Arc<PaymentState>) -> Self {
        Self { state }
    }

    fn pb_to_exam(t: PbExamType) -> Result<waec_common::ExamType, DomainError> {
        match t {
            PbExamType::Bece => Ok(waec_common::ExamType::Bece),
            PbExamType::WassceSchool => Ok(waec_common::ExamType::WassceSchool),
            PbExamType::WasscePrivate => Ok(waec_common::ExamType::WasscePrivate),
            PbExamType::Unspecified => Err(DomainError::new(
                ErrorCode::UnsupportedExamType,
                "exam_type required",
            )),
        }
    }

    /// Map proto channel → Paystack channel hint + MoMo provider.
    fn channel_parts(
        ch: waec_common::pb::waec::common::v1::PaymentChannel,
    ) -> (&'static str, Option<&'static str>) {
        use waec_common::pb::waec::common::v1::PaymentChannel as P;
        match ch {
            P::MtnMomo => ("mobile_money", Some("mtn")),
            P::TelecelCash => ("mobile_money", Some("telecel_cash")),
            P::AtMoney => ("mobile_money", Some("at")),
            P::Card | P::Unspecified => ("card", None),
        }
    }
}

#[tonic::async_trait]
impl PaymentService for PaymentServiceImpl {
    async fn init_charge(
        &self,
        request: Request<InitChargeRequest>,
    ) -> Result<Response<InitChargeResponse>, Status> {
        let req = request.into_inner();

        // Hard rule 3: idempotency key mandatory.
        if req.idempotency_key.is_empty() {
            return Err(DomainError::new(
                ErrorCode::InvalidExamParams,
                "X-Idempotency-Key required",
            )
            .into());
        }
        if !waec_common::is_valid_index_number(&req.index_number) {
            return Err(DomainError::new(
                ErrorCode::InvalidIndexNumber,
                "index number must be exactly 10 digits",
            )
            .into());
        }
        let exam =
            Self::pb_to_exam(PbExamType::try_from(req.exam_type).map_err(|_| {
                DomainError::new(ErrorCode::UnsupportedExamType, "unknown exam_type")
            })?)?;

        // ── Idempotency check: duplicate key → original outcome ─────────
        if let Some(cached) = self.state.idempotency.get(&req.idempotency_key).await {
            let v: serde_json::Value = serde_json::from_str(&cached.response)
                .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;
            tracing::info!(key = %req.idempotency_key, "idempotent replay");
            return Ok(Response::new(InitChargeResponse {
                transaction_id: v["transaction_id"].as_str().unwrap_or_default().into(),
                status: v["status"].as_i64().unwrap_or(0) as i32,
                amount_pesewas: v["amount_pesewas"].as_i64().unwrap_or(0),
                checkout_url: v["checkout_url"].as_str().unwrap_or_default().into(),
                display_message: v["display_message"].as_str().unwrap_or_default().into(),
            }));
        }

        // ── Dynamic GHS price (table until pricing config lands in 2.7) ─
        let amount = base_price_pesewas(exam.as_str());
        let (channel_hint, momo_provider) = Self::channel_parts(
            waec_common::pb::waec::common::v1::PaymentChannel::try_from(req.channel)
                .unwrap_or_default(),
        );

        let charge = ChargeRequest {
            email: "candidate@waecplatform.gh", // Paystack requires an email
            amount,
            currency: "GHS",
            reference: &req.idempotency_key,
            channel_hint,
            mobile_money: momo_provider.map(|provider| MobileMoney {
                phone: &req.phone,
                provider,
            }),
            metadata: Some(ChargeMetadata {
                index_number: req.index_number.clone(),
                exam_type: exam.as_str().to_string(),
                exam_year: req.exam_year.clone(),
            }),
        };

        let data = self.state.transport.initialize_transaction(&charge).await?;

        let response = InitChargeResponse {
            transaction_id: req.idempotency_key.clone(),
            status: match data.status.as_str() {
                "success" => PaymentStatus::Success as i32,
                "failed" => PaymentStatus::Failed as i32,
                _ => PaymentStatus::Pending as i32,
            },
            amount_pesewas: amount,
            checkout_url: data.authorization_url.unwrap_or_default(),
            display_message: data.display_text.unwrap_or_default(),
        };

        // Record outcome BEFORE returning: a crash between record and
        // respond can only cause a retry that hits the cached outcome —
        // never a second charge.
        let serialized = serde_json::json!({
            "transaction_id": response.transaction_id,
            "status": response.status,
            "amount_pesewas": response.amount_pesewas,
            "checkout_url": response.checkout_url,
            "display_message": response.display_message,
        })
        .to_string();
        let _ = self
            .state
            .idempotency
            .put(
                &req.idempotency_key,
                IdempotentOutcome {
                    response: serialized,
                    recorded_at: chrono::Utc::now().timestamp(),
                },
            )
            .await;

        tracing::info!(key = %req.idempotency_key, channel = channel_hint, "charge initialized");
        Ok(Response::new(response))
    }

    async fn get_pricing(
        &self,
        request: Request<GetPricingRequest>,
    ) -> Result<Response<GetPricingResponse>, Status> {
        let req = request.into_inner();
        let exam =
            Self::pb_to_exam(PbExamType::try_from(req.exam_type).map_err(|_| {
                DomainError::new(ErrorCode::UnsupportedExamType, "unknown exam_type")
            })?)?;
        Ok(Response::new(GetPricingResponse {
            amount_pesewas: base_price_pesewas(exam.as_str()),
            currency: "GHS".into(),
            effective_from_unix: 0,
        }))
    }
}

/// Webhook HMAC verification (used by the axum webhook facade).
pub fn verify_webhook(
    state: &PaymentState,
    raw_body: &[u8],
    signature: &str,
) -> Result<(), DomainError> {
    waec_common::webhook::verify_paystack_signature(&state.webhook_secret, raw_body, signature)
        .map_err(|_| {
            DomainError::new(
                ErrorCode::WebhookSignatureInvalid,
                "webhook signature invalid",
            )
        })
}

/// Serve with standard health checks.
pub async fn serve(state: Arc<PaymentState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer<PaymentServiceImpl>>()
        .await;

    let svc = waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer::new(
        PaymentServiceImpl::new(state),
    );

    tracing::info!(%port, "payment service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}
