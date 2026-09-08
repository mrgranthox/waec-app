//! Redis grace-token keys — plan §2.7 / §4.1 / §4.3.
//!
//! "Redis (AOF, sessions + 24 h grace TTL keys only)". A grace token
//! authorizes ONE free re-fetch within 24 h after a mid-fetch failure.
//! PostgreSQL holds the durable pointer (grace_tokens table); Redis
//! carries the hot TTL key for O(1) consumption checks.

use redis::AsyncCommands;
use waec_common::{DomainError, ErrorCode};

const GRACE_PREFIX: &str = "grace:";
/// Exactly 24 hours per plan §6 (global DoD: "grace keys expire at 24 h").
pub const GRACE_TTL_SECS: u64 = 24 * 3600;

pub struct GraceStore {
    conn: redis::aio::ConnectionManager,
}

impl GraceStore {
    pub async fn connect(url: &str) -> Result<Self, DomainError> {
        let client = redis::Client::open(url)
            .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;
        let conn = redis::aio::ConnectionManager::new(client)
            .await
            .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;
        Ok(Self { conn })
    }

    fn key(token: &str) -> String {
        format!("{GRACE_PREFIX}{token}")
    }

    fn err(e: redis::RedisError) -> DomainError {
        DomainError::new(ErrorCode::Internal, e.to_string())
    }

    /// Issue a grace token with the fixed 24 h TTL (SET EX).
    pub async fn issue(&self, token: &str, transaction_id: &str) -> Result<(), DomainError> {
        let mut conn = self.conn.clone();
        let _: () = conn
            .set_ex(Self::key(token), transaction_id, GRACE_TTL_SECS)
            .await
            .map_err(Self::err)?;
        Ok(())
    }

    /// Atomically read-and-delete a token (single use). Returns the bound
    /// transaction id when valid and unexpired.
    pub async fn consume(&self, token: &str) -> Result<Option<String>, DomainError> {
        let mut conn = self.conn.clone();
        let v: Option<String> = conn.get_del(Self::key(token)).await.map_err(Self::err)?;
        Ok(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live test against local Redis (enabled via WAEC_REDIS_TEST_URL).
    #[tokio::test]
    async fn live_grace_issue_and_consume() {
        let Ok(url) = std::env::var("WAEC_REDIS_TEST_URL") else {
            eprintln!("WAEC_REDIS_TEST_URL unset — skipping live redis test");
            return;
        };
        let store = GraceStore::connect(&url).await.unwrap();
        let token = uuid::Uuid::new_v4().to_string();

        store.issue(&token, "tx-1").await.unwrap();
        let consumed = store.consume(&token).await.unwrap();
        assert_eq!(consumed.as_deref(), Some("tx-1"));
        // Single use: gone after consume; expired keys behave the same.
        assert!(store.consume(&token).await.unwrap().is_none());
    }
}
