//! PostgreSQL idempotency store — plan §2.2 / §4.9.
//!
//! Backed by `payment_idempotency` (unique PK = key). First put wins:
//! ON CONFLICT DO NOTHING + re-read guarantees the original outcome is
//! returned under concurrent replays (zero double-charge path).

use async_trait::async_trait;
use waec_common::idempotency::{IdempotencyStore, IdempotentOutcome};

pub struct PgIdempotencyStore {
    pool: sqlx::PgPool,
}

impl PgIdempotencyStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl IdempotencyStore for PgIdempotencyStore {
    async fn get(&self, key: &str) -> Option<IdempotentOutcome> {
        let key = uuid::Uuid::parse_str(key).ok()?;
        let row: (serde_json::Value, chrono::DateTime<chrono::Utc>) = sqlx::query_as(
            "SELECT response_json, recorded_at FROM payment_idempotency WHERE idempotency_key = $1",
        )
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .ok()??;
        Some(IdempotentOutcome {
            response: row.0.to_string(),
            recorded_at: row.1.timestamp(),
        })
    }

    async fn put(&self, key: &str, outcome: IdempotentOutcome) -> Result<(), ()> {
        let key = match uuid::Uuid::parse_str(key) {
            Ok(k) => k,
            Err(_) => return Err(()),
        };
        let value: serde_json::Value = serde_json::from_str(&outcome.response).map_err(|_| ())?;
        let recorded = chrono::DateTime::<chrono::Utc>::from_timestamp(outcome.recorded_at, 0)
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());

        // Insert-if-absent: conflict → the cached original stays intact.
        let result = sqlx::query(
            "INSERT INTO payment_idempotency (idempotency_key, response_json, recorded_at)
             VALUES ($1, $2, $3)
             ON CONFLICT (idempotency_key) DO NOTHING",
        )
        .bind(key)
        .bind(&value)
        .bind(recorded)
        .execute(&self.pool)
        .await
        .map_err(|_| ())?;

        if result.rows_affected() == 0 {
            return Err(()); // already present
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live test against local Postgres. Enabled via WAEC_PG_TEST_URL.
    #[tokio::test]
    async fn pg_idempotency_first_write_wins() {
        let Ok(url) = std::env::var("WAEC_PG_TEST_URL") else {
            eprintln!("WAEC_PG_TEST_URL unset — skipping live pg test");
            return;
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(3)
            .connect(&url)
            .await
            .unwrap();
        let store = PgIdempotencyStore::new(pool);
        let key = uuid::Uuid::new_v4().to_string();

        assert!(store.get(&key).await.is_none());
        store
            .put(
                &key,
                IdempotentOutcome {
                    response: r#"{"amount":2000}"#.into(),
                    recorded_at: 1,
                },
            )
            .await
            .unwrap();
        // Second put is rejected — original preserved.
        assert!(
            store
                .put(
                    &key,
                    IdempotentOutcome {
                        response: r#"{"amount":999}"#.into(),
                        recorded_at: 2
                    },
                )
                .await
                .is_err()
        );
        let got = store.get(&key).await.unwrap();
        assert!(got.response.contains("2000"));
    }
}
