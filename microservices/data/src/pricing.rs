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

    /// Current price for an exam type (BECE | WASSCE_SC | WASSCE_PRIVATE).
    pub async fn price_for(&self, exam_type: &str) -> Result<Price, DomainError> {
        let row: (i64, String) = sqlx::query_as(
            "SELECT amount_pesewas, currency FROM pricing_config WHERE exam_type = $1",
        )
        .bind(exam_type)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?
        .ok_or_else(|| DomainError::new(ErrorCode::UnsupportedExamType, "no pricing configured"))?;
        Ok(Price {
            amount_pesewas: row.0,
            currency: row.1,
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
        let bece = store.price_for("BECE").await.unwrap();
        assert_eq!(bece.amount_pesewas, 1500);
        assert_eq!(bece.currency, "GHS");
        assert!(store.price_for("NOPE").await.is_err());
    }
}
