//! Paystack Ghana client — plan §2.2.
//!
//! MTN MoMo, Telecel Cash, AT Money, Visa/MC charge initialization via
//! the Paystack API. Dynamic GHS pricing flows through from config.

use serde::{Deserialize, Serialize};
use waec_common::{DomainError, ErrorCode};

/// Static pricing table until the pricing config table lands (2.7).
/// Values are pesewas (GHS × 100). Served by GetPricing.
pub fn base_price_pesewas(exam: &str) -> i64 {
    match exam {
        "BECE" => 1500,      // GHS 15.00
        "WASSCE_SC" => 2000, // GHS 20.00
        "WASSCE_PRIVATE" => 2000,
        _ => 0,
    }
}

#[derive(Debug, Serialize)]
pub struct ChargeRequest<'a> {
    pub email: &'a str,
    pub amount: i64, // pesewas
    pub currency: &'a str,
    pub reference: &'a str, // = idempotency key
    pub channel_hint: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mobile_money: Option<MobileMoney<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<ChargeMetadata>,
}

#[derive(Debug, Serialize)]
pub struct MobileMoney<'a> {
    pub phone: &'a str,
    pub provider: &'a str, // mtn | telecel_cash | atm
}

#[derive(Debug, Serialize)]
pub struct ChargeMetadata {
    pub index_number: String,
    pub exam_type: String,
    pub exam_year: String,
}

#[derive(Debug, Deserialize)]
pub struct ChargeResponse {
    pub status: bool,
    pub message: String,
    pub data: Option<ChargeData>,
}

#[derive(Debug, Deserialize)]
pub struct ChargeData {
    pub status: String, // pending | success | failed
    #[serde(default)]
    pub display_text: Option<String>,
    #[serde(default)]
    pub authorization_url: Option<String>,
}

/// Transport used by the engine — mockable for tests.
#[async_trait::async_trait]
pub trait PaystackTransport: Send + Sync {
    async fn initialize_transaction(
        &self,
        req: &ChargeRequest<'_>,
    ) -> Result<ChargeData, DomainError>;
}

/// Live HTTP transport (Paystack API).
pub struct PaystackHttp {
    pub secret: String,
    pub base_url: String,
    pub http: reqwest::Client,
}

#[async_trait::async_trait]
impl PaystackTransport for PaystackHttp {
    async fn initialize_transaction(
        &self,
        req: &ChargeRequest<'_>,
    ) -> Result<ChargeData, DomainError> {
        let url = format!("{}/transaction/initialize", self.base_url);
        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.secret)
            .json(req)
            .send()
            .await
            .map_err(|e| DomainError::new(ErrorCode::WaecPortalUnavailable, e.to_string()))?;

        let parsed: ChargeResponse = resp
            .json()
            .await
            .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;

        if !parsed.status {
            // Paystack-level rejection (bad channel, amount, etc.)
            return Err(DomainError::new(ErrorCode::PaymentDeclined, parsed.message));
        }
        parsed
            .data
            .ok_or_else(|| DomainError::new(ErrorCode::Internal, "empty paystack data"))
    }
}
