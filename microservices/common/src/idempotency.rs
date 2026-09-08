//! Idempotency key store trait + in-memory implementation (plan §4.9).
//!
//! Contract: the FIRST outcome for a key is cached and replayed verbatim.
//! Duplicate requests never re-execute the operation — no double charge,
//! no second voucher. The Redis adapter lives in the payment service;
//! this trait is the source of truth and the in-memory impl serves tests.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Cached outcome for an idempotency key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdempotentOutcome {
    /// Serialized response payload (service-specific encoding).
    pub response: String,
    /// Unix timestamp when first recorded.
    pub recorded_at: i64,
}

/// Async idempotency store.
#[async_trait::async_trait]
pub trait IdempotencyStore: Send + Sync {
    /// Look up a prior outcome; None when key unseen.
    async fn get(&self, key: &str) -> Option<IdempotentOutcome>;

    /// Record an outcome for a key. Returns Err when the key was already
    /// recorded (callers should re-read via `get`) — prevents races where
    /// two concurrent requests both claim to be first.
    async fn put(&self, key: &str, outcome: IdempotentOutcome) -> Result<(), ()>;
}

/// In-memory store for tests and local dev.
#[derive(Default, Clone)]
pub struct InMemoryIdempotencyStore {
    map: Arc<RwLock<HashMap<String, IdempotentOutcome>>>,
}

#[async_trait::async_trait]
impl IdempotencyStore for InMemoryIdempotencyStore {
    async fn get(&self, key: &str) -> Option<IdempotentOutcome> {
        self.map.read().await.get(key).cloned()
    }

    async fn put(&self, key: &str, outcome: IdempotentOutcome) -> Result<(), ()> {
        let mut w = self.map.write().await;
        if w.contains_key(key) {
            return Err(());
        }
        w.insert(key.to_string(), outcome);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn first_put_wins_duplicate_put_fails() {
        let store = InMemoryIdempotencyStore::default();
        assert!(store
            .put(
                "k1",
                IdempotentOutcome {
                    response: "A".into(),
                    recorded_at: 1
                }
            )
            .await
            .is_ok());
        assert!(store
            .put(
                "k1",
                IdempotentOutcome {
                    response: "B".into(),
                    recorded_at: 2
                }
            )
            .await
            .is_err());
        assert_eq!(store.get("k1").await.unwrap().response, "A");
    }

    #[tokio::test]
    async fn unknown_key_returns_none() {
        let store = InMemoryIdempotencyStore::default();
        assert!(store.get("missing").await.is_none());
    }
}
