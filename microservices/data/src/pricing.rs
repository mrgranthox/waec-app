//! Dynamic GHS pricing from PostgreSQL (plan §2.2 / §2.7):
//! "fee changes without app releases".

use waec_common::{DomainError, ErrorCode};

pub struct Price {
    pub amount_pesewas: i64,
    pub currency: String,
}

pub struct PgPricingStore {
    pool: sqlx::PgPool,
}

impl PgPricingStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }

    /// Current price for a purchase of [exam_type] (BECE | WASSCE_SC |
    /// WASSCE_PRIVATE).
    ///
    /// [check_now] selects which of the two configured amounts applies (ADR-002):
    /// - `false` — a checker bought on its own, to keep or share.
    /// - `true`  — a checker spent immediately, which also pays for the
    ///   retrieval (`check_now_pesewas`).
    ///
    /// Both amounts come from the same row so a fee change is one `UPDATE`.
    /// A `check_now` row whose combined amount was never priced (0) resolves to
    /// the checker-only amount rather than to a free retrieval, so a half-seeded
    /// config can never undercharge.
    pub async fn price_for(&self, exam_type: &str, check_now: bool) -> Result<Price, DomainError> {
        let row: (i64, i64, String) = sqlx::query_as(
            "SELECT amount_pesewas, check_now_pesewas, currency \
             FROM pricing_config WHERE exam_type = $1",
        )
        .bind(exam_type)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?
        .ok_or_else(|| DomainError::new(ErrorCode::UnsupportedExamType, "no pricing configured"))?;
        let (checker_only, check_now_amount, currency) = row;
        let amount_pesewas = if check_now && check_now_amount > 0 {
            check_now_amount
        } else {
            checker_only
        };
        Ok(Price {
            amount_pesewas,
            currency,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn live_pricing_read() {
        let Ok(url) = std::env::var("WAEC_PG_TEST_URL") else {
            eprintln!("WAEC_PG_TEST_URL unset — skipping live pg test");
            return;
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(3)
            .connect(&url)
            .await
            .unwrap();
        let store = PgPricingStore::new(pool);
        // Checker-only (ADR-002): the amount in `amount_pesewas`.
        let bece = store.price_for("BECE", false).await.unwrap();
        assert_eq!(bece.amount_pesewas, 2600);
        assert_eq!(bece.currency, "GHS");
        // Checker + immediate retrieval resolves the combined amount.
        let bece_now = store.price_for("BECE", true).await.unwrap();
        assert_eq!(bece_now.amount_pesewas, 3600);
        // The flag must actually change the answer, not just be accepted.
        assert!(bece_now.amount_pesewas > bece.amount_pesewas);
        assert!(store.price_for("NOPE", false).await.is_err());
    }
}
