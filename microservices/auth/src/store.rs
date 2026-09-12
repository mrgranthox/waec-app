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

    /// Record a failed login **atomically** (plan §4.6).
    ///
    /// The increment and the lockout decision must happen in one critical
    /// section: a read-modify-write from the caller lets concurrent
    /// credential-stuffing attempts lose increments, so an account hammered
    /// from many parallel requests never reaches the threshold and never
    /// locks. Implementations take their write lock for the whole
    /// increment → threshold → arm-lock sequence.
    ///
    /// Returns `true` when this failure armed a lockout.
    async fn record_failure(
        &self,
        index_number: &str,
        now: i64,
        max_attempts: u32,
        lockout_secs: i64,
    ) -> Result<bool, StoreError>;

    /// Record a **successful credential verification** atomically (plan §4.6).
    ///
    /// Clears the failure counters, but only when the account is not locked at
    /// `now`. This closes the last race: a request that read the row *before*
    /// another request armed the lock must not be allowed to log in merely
    /// because its password happened to be correct.
    ///
    /// Returns `false` when the account is locked (state left untouched).
    async fn succeed_login(&self, index_number: &str, now: i64) -> Result<bool, StoreError>;
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

    async fn record_failure(
        &self,
        index_number: &str,
        now: i64,
        max_attempts: u32,
        lockout_secs: i64,
    ) -> Result<bool, StoreError> {
        // Held across read + increment + arm-lock: no await point may sit
        // between them, which is what makes the counter race-free.
        let mut w = self.users.write().await;
        let u = w.get_mut(index_number).ok_or(StoreError::NotFound)?;
        u.failed_attempts = u.failed_attempts.saturating_add(1);
        if u.failed_attempts >= max_attempts {
            u.locked_until = now + lockout_secs;
            u.failed_attempts = 0;
            return Ok(true);
        }
        Ok(false)
    }

    async fn succeed_login(&self, index_number: &str, now: i64) -> Result<bool, StoreError> {
        let mut w = self.users.write().await;
        let u = w.get_mut(index_number).ok_or(StoreError::NotFound)?;
        if u.locked_until > now {
            return Ok(false);
        }
        u.failed_attempts = 0;
        u.locked_until = 0;
        Ok(true)
    }
}

/// Shared alias used by the service.
pub type SharedUserStore = Arc<dyn UserStore>;
