//! User store trait + in-memory implementation.
//!
//! Postgres adapter arrives with integration wiring (task 2.7); the
//! trait keeps services testable without a database.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Persisted user record. `password_hash` is Argon2id PHC format.
#[derive(Debug, Clone)]
pub struct UserRecord {
    pub user_id: String,
    pub index_number: String,
    pub password_hash: String,
    /// Platform biometric public key when bound (plan §2.1).
    pub biometric_public_key: Option<String>,
    /// Consecutive failed logins (for lockout).
    pub failed_attempts: u32,
    /// Unix secs until which the account is locked (0 = unlocked).
    pub locked_until: i64,
}

/// Errors from the store layer.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("index number already registered")]
    DuplicateIndex,
    #[error("user not found")]
    NotFound,
}

#[async_trait::async_trait]
pub trait UserStore: Send + Sync {
    async fn create(
        &self,
        index_number: &str,
        password_hash: &str,
    ) -> Result<UserRecord, StoreError>;
    async fn find_by_index(&self, index_number: &str) -> Result<UserRecord, StoreError>;
    /// Resolve by JWT subject (user_id). In-memory store scans; the
    /// Postgres adapter uses an indexed column.
    async fn find_by_user_id(&self, user_id: &str) -> Result<UserRecord, StoreError>;
    async fn update(&self, record: UserRecord) -> Result<(), StoreError>;
}

/// Thread-safe in-memory store (tests + dev).
#[derive(Default)]
pub struct InMemoryUserStore {
    users: RwLock<HashMap<String, UserRecord>>, // keyed by index
}

impl InMemoryUserStore {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait::async_trait]
impl UserStore for InMemoryUserStore {
    async fn create(
        &self,
        index_number: &str,
        password_hash: &str,
    ) -> Result<UserRecord, StoreError> {
        let mut w = self.users.write().await;
        if w.contains_key(index_number) {
            return Err(StoreError::DuplicateIndex);
        }
        let rec = UserRecord {
            user_id: uuid::Uuid::new_v4().to_string(),
            index_number: index_number.to_string(),
            password_hash: password_hash.to_string(),
            biometric_public_key: None,
            failed_attempts: 0,
            locked_until: 0,
        };
        w.insert(index_number.to_string(), rec.clone());
        Ok(rec)
    }

    async fn find_by_index(&self, index_number: &str) -> Result<UserRecord, StoreError> {
        self.users
            .read()
            .await
            .get(index_number)
            .cloned()
            .ok_or(StoreError::NotFound)
    }

    async fn find_by_user_id(&self, user_id: &str) -> Result<UserRecord, StoreError> {
        self.users
            .read()
            .await
            .values()
            .find(|u| u.user_id == user_id)
            .cloned()
            .ok_or(StoreError::NotFound)
    }

    async fn update(&self, record: UserRecord) -> Result<(), StoreError> {
        let mut w = self.users.write().await;
        if !w.contains_key(&record.index_number) {
            return Err(StoreError::NotFound);
        }
        w.insert(record.index_number.clone(), record);
        Ok(())
    }
}

/// Shared alias used by the service.
pub type SharedUserStore = Arc<dyn UserStore>;
