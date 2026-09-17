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

use crate::PaymentState;
use crate::paystack::{ChargeMetadata, ChargeRequest, MobileMoney, base_price_pesewas};

/// PaymentService gRPC implementation.
///
/// Pricing resolution (requirement 4): when a Postgres pool is wired (prod /
/// Neon), every price is read live from `pricing_config` so a fee change
/// never needs an app release. Without a pool (unit tests, bare local dev)
/// it degrades to the static table in `paystack::base_price_pesewas` — the
/// same values the mock gateway serves.
pub struct PaymentServiceImpl {
    pub(crate) state: Arc<PaymentState>,
    pub(crate) pricing: Option<Arc<waec_data::pricing::PgPricingStore>>,
}

impl PaymentServiceImpl {
    pub fn new(state: Arc<PaymentState>) -> Self {
        Self {
            state,
            pricing: None,
        }
    }

    /// Constructor used when a database is available (Neon in prod test
    /// phase, compose Postgres in local dev).
    pub fn with_pricing(
        state: Arc<PaymentState>,
        pricing: Arc<waec_data::pricing::PgPricingStore>,
    ) -> Self {
        Self {
            state,
            pricing: Some(pricing),
        }
    }

    /// Resolve the current price for a purchase: DB first, static table as the
    /// documented fallback.
    ///
    /// [check_now] is forwarded to the store so the resolved amount is the one
    /// that actually applies to the purchase being made (ADR-002): checker-only
    /// or checker-and-retrieve. Pricing is resolved here rather than on the
    /// client precisely so the quoted and charged amounts cannot drift.
    async fn resolve_price(
        &self,
        exam: waec_common::ExamType,
        check_now: bool,
    ) -> Result<(i64, String), DomainError> {
        if let Some(store) = &self.pricing {
            let price = store.price_for(exam.as_str(), check_now).await?;
            return Ok((price.amount_pesewas, price.currency));
        }
        Ok((base_price_pesewas(exam.as_str(), check_now), "GHS".into()))
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

        // ── Dynamic GHS price (requirement 4: DB-backed when wired, static
        // table otherwise) ────────────────────────────────────────────────
        // `check_now` is part of the price lookup, not a client-side surcharge
        // (ADR-002): a checker spent in this pass costs the combined rate, and
        // the amount returned below is what Paystack is asked to charge.
        let (amount, currency) = self.resolve_price(exam, req.check_now).await?;
        let (channel_hint, momo_provider) = Self::channel_parts(
            waec_common::pb::waec::common::v1::PaymentChannel::try_from(req.channel)
                .unwrap_or_default(),
        );

        let charge = ChargeRequest {
            email: "candidate@waecplatform.gh", // Paystack requires an email
            amount,
            currency: &currency,
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
        // Dynamic GHS pricing (plan §4.3): read the fee live from the Neon
        // `pricing_config` store (falling back to the static table when the
        // store is unavailable) so fee changes never require an app release.
        // The request's `check_now` selects which of the two configured rates
        // applies, so this is exactly the amount InitCharge will charge for the
        // same flag (ADR-002).
        let (amount, currency) = self.resolve_price(exam, req.check_now).await?;
        Ok(Response::new(GetPricingResponse {
            amount_pesewas: amount,
            currency,
            effective_from_unix: chrono::Utc::now().timestamp(),
        }))
    }
}

/// Webhook verification (plan §4.5): HMAC SHA-512 **and** timestamp window.
///
/// A signature alone proves authenticity, not freshness — a delivery
/// captured off the wire replays forever. The envelope timestamp
/// (`createdAt`, sometimes mirrored as `data.create_time`) is extracted
/// from the raw body and required to fall inside
/// [`waec_common::webhook::MAX_SKEW_SECS`] of our clock.
///
/// Strict mode is deliberate: a body without a usable timestamp is
/// rejected rather than waved through, so an attacker cannot strip the
/// field to downgrade verification to signature-only.
pub fn verify_webhook(
    state: &PaymentState,
    raw_body: &[u8],
    signature: &str,
) -> Result<(), DomainError> {
    verify_webhook_at(state, raw_body, signature, chrono::Utc::now().timestamp())
}

/// Deterministic seam for tests (and for the facade when it wants to
/// inject its own clock).
pub fn verify_webhook_at(
    state: &PaymentState,
    raw_body: &[u8],
    signature: &str,
    now_unix: i64,
) -> Result<(), DomainError> {
    let event_unix = webhook_event_time(raw_body);
    waec_common::webhook::verify_webhook_fresh(
        &state.webhook_secret,
        raw_body,
        signature,
        event_unix,
        now_unix,
        true,
    )
    .map_err(|e| match e {
        waec_common::webhook::WebhookError::StaleTimestamp
        | waec_common::webhook::WebhookError::MissingTimestamp => DomainError::new(
            ErrorCode::WebhookReplayDetected,
            "webhook outside replay window",
        ),
        _ => DomainError::new(
            ErrorCode::WebhookSignatureInvalid,
            "webhook signature invalid",
        ),
    })
}

/// Lift the event timestamp out of a webhook payload, if one is present.
/// Paystack sends `createdAt` (seconds) on the envelope and a
/// `data.create_time` (ISO-8601 string) on the object; either is enough.
pub fn webhook_event_time(raw_body: &[u8]) -> Option<i64> {
    let value: serde_json::Value = serde_json::from_slice(raw_body).ok()?;
    if let Some(ts) = value.get("createdAt").and_then(|v| v.as_i64()) {
        return Some(ts);
    }
    let iso = value.get("data")?.get("create_time")?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(iso)
        .map(|dt| dt.timestamp())
        .ok()
}

/// Serve with standard health checks.
pub async fn serve(state: Arc<PaymentState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer<PaymentServiceImpl>>()
        .await;

    let svc_impl = PaymentServiceImpl::new(state);
    let svc = waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer::new(
        svc_impl,
    );

    tracing::info!(%port, "payment service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}

/// Serve with a live pricing store (requirement 4): prices read from the
/// Postgres `pricing_config` table, falling back to the static table on a
/// missing row or a DB error.
pub async fn serve_with_pricing(
    state: Arc<PaymentState>,
    pricing: Arc<waec_data::pricing::PgPricingStore>,
    port: u16,
) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer<PaymentServiceImpl>>()
        .await;

    let svc_impl = PaymentServiceImpl::with_pricing(state, pricing);
    let svc = waec_common::pb::waec::payment::v1::payment_service_server::PaymentServiceServer::new(
        svc_impl,
    );

    tracing::info!(%port, "payment service listening (dynamic pricing)");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}
