//! Paystack Ghana client — plan §2.2.
//!
//! MTN MoMo, Telecel Cash, AT Money, Visa/MC charge initialization via
//! the Paystack API. Dynamic GHS pricing flows through from config.

use serde::{Deserialize, Serialize};
use waec_common::{DomainError, ErrorCode};

/// Static pricing table used when no Postgres pool is wired (unit tests, bare
/// local dev) or when the database is unreachable — pricing must never take the
/// whole payment service down (plan §2.2 degradation).
///
/// Values are pesewas (GHS × 100) and mirror the seeded `pricing_config` rows,
/// including the two-part checker pricing from ADR-002:
/// - `check_now == false` — a checker bought on its own, to keep or share.
/// - `check_now == true`  — a checker spent immediately, retrieval included.
///
/// An unknown exam type resolves to 0, which the client renders as its own
/// documented fallback rather than as "free".
pub fn base_price_pesewas(exam: &str, check_now: bool) -> i64 {
    match (exam, check_now) {
        ("BECE" | "WASSCE_SC" | "WASSCE_PRIVATE", false) => 2600, // GHS 26.00
        ("BECE" | "WASSCE_SC" | "WASSCE_PRIVATE", true) => 3600,  // GHS 36.00
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

#[cfg(test)]
mod tests {
    use super::base_price_pesewas;

    #[test]
    fn static_table_matches_the_seeded_config() {
        // The fallback must mirror `pricing_config` exactly, or a database
        // outage would silently change what a candidate is charged.
        for exam in ["BECE", "WASSCE_SC", "WASSCE_PRIVATE"] {
            assert_eq!(base_price_pesewas(exam, false), 2600, "{exam} checker only");
            assert_eq!(
                base_price_pesewas(exam, true),
                3600,
                "{exam} checker + result"
            );
        }
    }

    #[test]
    fn check_now_is_dearer_than_checker_only() {
        // ADR-002: spending the checker in the same pass also buys the
        // retrieval, so the combined rate must be strictly higher.
        assert!(base_price_pesewas("BECE", true) > base_price_pesewas("BECE", false));
    }

    #[test]
    fn unknown_exam_type_prices_at_zero() {
        // Nothing is invented for an unmapped exam type — the client renders its
        // own documented fallback instead of treating 0 as a real price.
        assert_eq!(base_price_pesewas("NOPE", false), 0);
        assert_eq!(base_price_pesewas("NOPE", true), 0);
    }
}
