//! Checker vault + result snapshots — plan §2.7 / §3.7.
//!
//! ## Security model (hard rules 1 and 2)
//!
//! - Raw serial/PIN pairs are encrypted client-side (AES-256-GCM, key held only
//!   by the mobile device's SQLCipher vault) before they are transmitted to the
//!   backend. The backend persists the ciphertext blob and never sees the
//!   plaintext credential. The mobile app decrypts locally when redeeming.
//! - Result grade payloads are also client-encrypted; the backend stores the
//!   ciphertext blob as a durable snapshot the client can re-fetch within the
//!   24h grace window (§4.1) without re-paying.
//! - No raw grade, serial, or PIN value is logged, included in stack traces, or
//!   returned in API responses. Audit rows carry metadata only (index, exam,
//!   outcome, timestamp).

use async_trait::async_trait;
use chrono::Utc;
use std::sync::Arc;

use sqlx::FromRow;

use waec_common::DomainError;

// ── Wire types ──────────────────────────────────────────────────────────────

/// One row in the checkers vault.
#[derive(Debug, Clone, FromRow)]
pub struct CheckerRow {
    pub id: String,
    pub index_number: String,
    pub exam_type: String,
    pub exam_year: i16,
    /// AES-256-GCM ciphertext of `{"serial":"...","pin":"..."}`.
    /// The backend never decrypts this.
    pub encrypted_blob: Vec<u8>,
    pub status: String,
    pub acquired_at_unix: i64,
    pub expires_at_unix: Option<i64>,
    pub transaction_id: String,
}

/// One persisted result snapshot (client-encrypted grade payload).
#[derive(Debug, Clone, FromRow)]
pub struct SnapshotRow {
    pub id: String,
    pub index_number: String,
    /// Client-encrypted grade payload. Backend does not decrypt.
    pub encrypted_payload: Vec<u8>,
    pub fetched_at_unix: i64,
    pub expires_at_unix: i64,
    pub created_at: chrono::DateTime<Utc>,
}

/// Checkout initiation that flowed through Paystack.
#[derive(Debug, Clone, FromRow)]
pub struct PaystackInitiationRow {
    pub id: String,
    pub index_number: String,
    pub exam_type: String,
    pub exam_year: i16,
    pub paystack_ref: String,
    pub paystack_authorization_url: String,
    pub amount_pesewas: i64,
    pub currency: String,
    pub status: String,
    pub created_at: chrono::DateTime<Utc>,
}

// ── Store trait ─────────────────────────────────────────────────────────────

/// Checker vault persistence. In-memory impl for tests; Postgres impl for prod.
#[async_trait]
pub trait CheckerStore: Send + Sync {
    /// Persist a freshly acquired checker (encrypted blob provided by caller).
    ///
    /// The argument count is deliberate: every value is a distinct column of
    /// `checker_vault` and none of them is defaulted, so grouping them into a
    /// struct would only move the same list one hop away from the SQL.
    #[allow(clippy::too_many_arguments)]
    async fn store_checker(
        &self,
        id: &str,
        index_number: &str,
        exam_type: &str,
        exam_year: i16,
        encrypted_blob: &[u8],
        transaction_id: &str,
        expires_at_unix: Option<i64>,
    ) -> Result<(), DomainError>;

    /// Load a checker by id + index. Returns the encrypted blob (decryption is
    /// the client's job).
    async fn load_checker(
        &self,
        id: &str,
        index_number: &str,
    ) -> Result<Option<CheckerRow>, DomainError>;

    /// Mark a checker as spent after a successful result redemption.
    async fn mark_spent(&self, id: &str, index_number: &str) -> Result<(), DomainError>;

    /// List all non-spent checkers for an index.
    async fn list_available(&self, index_number: &str) -> Result<Vec<CheckerRow>, DomainError>;

    /// List all checkers (spent + available) for an index.
    async fn list_all(&self, index_number: &str) -> Result<Vec<CheckerRow>, DomainError>;

    /// Delete a checker by id + index.
    async fn delete_checker(&self, id: &str, index_number: &str) -> Result<(), DomainError>;
}

/// Result snapshot persistence.
#[async_trait]
pub trait SnapshotStore: Send + Sync {
    /// Persist a client-encrypted grade snapshot.
    async fn store_snapshot(
        &self,
        snapshot_id: &str,
        index_number: &str,
        encrypted_payload: &[u8],
        fetched_at_unix: i64,
        expires_at_unix: i64,
    ) -> Result<(), DomainError>;

    /// Load a snapshot by id.
    async fn load_snapshot(&self, snapshot_id: &str) -> Result<Option<SnapshotRow>, DomainError>;

    /// List snapshots for an index, newest first.
    async fn list_snapshots(&self, index_number: &str) -> Result<Vec<SnapshotRow>, DomainError>;

    /// Delete a snapshot by id.
    async fn delete_snapshot(&self, snapshot_id: &str) -> Result<(), DomainError>;
}

/// Paystack initiation tracking.
#[async_trait]
pub trait InitiationStore: Send + Sync {
    /// Record a Paystack checkout that the client started.
    ///
    /// Same reasoning as [CheckerStore::store_checker]: each argument is a
    /// required `paystack_initiations` column, and [Self::record_initiation] is
    /// called once, at the point where all of them are already in scope.
    #[allow(clippy::too_many_arguments)]
    async fn record_initiation(
        &self,
        id: &str,
        index_number: &str,
        exam_type: &str,
        exam_year: i16,
        paystack_ref: &str,
        paystack_authorization_url: &str,
        amount_pesewas: i64,
        currency: &str,
    ) -> Result<(), DomainError>;

    /// Look up an initiation by paystack reference (used by webhook handler).
    async fn find_by_paystack_ref(
        &self,
        paystack_ref: &str,
    ) -> Result<Option<PaystackInitiationRow>, DomainError>;

    /// Mark an initiation as paid after webhook confirms the charge.
    async fn mark_paid(&self, id: &str) -> Result<(), DomainError>;
}

// ── In-memory store (tests) ────────────────────────────────────────────────

pub struct InMemoryCheckerStore {
    checkers: Arc<std::sync::Mutex<Vec<CheckerRow>>>,
    snapshots: Arc<std::sync::Mutex<Vec<SnapshotRow>>>,
    initiations: Arc<std::sync::Mutex<Vec<PaystackInitiationRow>>>,
}

impl Default for InMemoryCheckerStore {
    fn default() -> Self {
        Self {
            checkers: Arc::new(std::sync::Mutex::new(Vec::new())),
            snapshots: Arc::new(std::sync::Mutex::new(Vec::new())),
            initiations: Arc::new(std::sync::Mutex::new(Vec::new())),
        }
    }
}

#[async_trait]
impl CheckerStore for InMemoryCheckerStore {
    async fn store_checker(
        &self,
        id: &str,
        index_number: &str,
        exam_type: &str,
        exam_year: i16,
        encrypted_blob: &[u8],
        transaction_id: &str,
        expires_at_unix: Option<i64>,
    ) -> Result<(), DomainError> {
        let mut guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        guard.push(CheckerRow {
            id: id.to_string(),
            index_number: index_number.to_string(),
            exam_type: exam_type.to_string(),
            exam_year,
            encrypted_blob: encrypted_blob.to_vec(),
            status: "available".to_string(),
            acquired_at_unix: Utc::now().timestamp(),
            expires_at_unix,
            transaction_id: transaction_id.to_string(),
        });
        Ok(())
    }

    async fn load_checker(
        &self,
        id: &str,
        index_number: &str,
    ) -> Result<Option<CheckerRow>, DomainError> {
        let guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard
            .iter()
            .find(|r| r.id == id && r.index_number == index_number)
            .cloned())
    }

    async fn mark_spent(&self, id: &str, index_number: &str) -> Result<(), DomainError> {
        let mut guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        if let Some(row) = guard
            .iter_mut()
            .find(|r| r.id == id && r.index_number == index_number)
        {
            row.status = "spent".to_string();
            Ok(())
        } else {
            Err(DomainError::new(
                waec_common::ErrorCode::NotFound,
                "checker not found",
            ))
        }
    }

    async fn list_available(&self, index_number: &str) -> Result<Vec<CheckerRow>, DomainError> {
        let guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard
            .iter()
            .filter(|r| r.index_number == index_number && r.status != "spent")
            .cloned()
            .collect())
    }

    async fn list_all(&self, index_number: &str) -> Result<Vec<CheckerRow>, DomainError> {
        let guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard
            .iter()
            .filter(|r| r.index_number == index_number)
            .cloned()
            .collect())
    }

    async fn delete_checker(&self, id: &str, index_number: &str) -> Result<(), DomainError> {
        let mut guard = self
            .checkers
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        guard.retain(|r| !(r.id == id && r.index_number == index_number));
        Ok(())
    }
}

#[async_trait]
impl SnapshotStore for InMemoryCheckerStore {
    async fn store_snapshot(
        &self,
        snapshot_id: &str,
        index_number: &str,
        encrypted_payload: &[u8],
        fetched_at_unix: i64,
        expires_at_unix: i64,
    ) -> Result<(), DomainError> {
        let mut guard = self
            .snapshots
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        guard.push(SnapshotRow {
            id: snapshot_id.to_string(),
            index_number: index_number.to_string(),
            encrypted_payload: encrypted_payload.to_vec(),
            fetched_at_unix,
            expires_at_unix,
            created_at: Utc::now(),
        });
        Ok(())
    }

    async fn load_snapshot(&self, snapshot_id: &str) -> Result<Option<SnapshotRow>, DomainError> {
        let guard = self
            .snapshots
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard.iter().find(|r| r.id == snapshot_id).cloned())
    }

    async fn list_snapshots(&self, index_number: &str) -> Result<Vec<SnapshotRow>, DomainError> {
        let guard = self
            .snapshots
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard
            .iter()
            .filter(|r| r.index_number == index_number)
            .cloned()
            .collect())
    }

    async fn delete_snapshot(&self, snapshot_id: &str) -> Result<(), DomainError> {
        let mut guard = self
            .snapshots
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        guard.retain(|r| r.id != snapshot_id);
        Ok(())
    }
}

#[async_trait]
impl InitiationStore for InMemoryCheckerStore {
    async fn record_initiation(
        &self,
        id: &str,
        index_number: &str,
        exam_type: &str,
        exam_year: i16,
        paystack_ref: &str,
        paystack_authorization_url: &str,
        amount_pesewas: i64,
        currency: &str,
    ) -> Result<(), DomainError> {
        let mut guard = self
            .initiations
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        guard.push(PaystackInitiationRow {
            id: id.to_string(),
            index_number: index_number.to_string(),
            exam_type: exam_type.to_string(),
            exam_year,
            paystack_ref: paystack_ref.to_string(),
            paystack_authorization_url: paystack_authorization_url.to_string(),
            amount_pesewas,
            currency: currency.to_string(),
            status: "pending".to_string(),
            created_at: Utc::now(),
        });
        Ok(())
    }

    async fn find_by_paystack_ref(
        &self,
        paystack_ref: &str,
    ) -> Result<Option<PaystackInitiationRow>, DomainError> {
        let guard = self
            .initiations
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        Ok(guard
            .iter()
            .find(|r| r.paystack_ref == paystack_ref)
            .cloned())
    }

    async fn mark_paid(&self, id: &str) -> Result<(), DomainError> {
        let mut guard = self
            .initiations
            .lock()
            .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;
        if let Some(row) = guard.iter_mut().find(|r| r.id == id) {
            row.status = "paid".to_string();
            Ok(())
        } else {
            Err(DomainError::new(
                waec_common::ErrorCode::NotFound,
                "initiation not found",
            ))
        }
    }
}

// ── Migrations ──────────────────────────────────────────────────────────────

/// DDL for the checkers-schema tables. Run once at startup (plan §2.7 runs
/// migrations inline at boot, not as separate versioned files).
pub async fn run_checker_migrations(pool: &sqlx::PgPool) -> Result<(), DomainError> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS checker_vault (
            id UUID PRIMARY KEY,
            index_number CHAR(10) NOT NULL,
            exam_type TEXT NOT NULL CHECK (exam_type IN ('BECE','WASSCE_SC','WASSCE_PRIVATE')),
            exam_year SMALLINT NOT NULL,
            encrypted_blob BYTEA NOT NULL,
            status TEXT NOT NULL DEFAULT 'available' CHECK (status IN ('available','spent','expired')),
            acquired_at_unix BIGINT NOT NULL,
            expires_at_unix BIGINT,
            transaction_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_checker_vault_index
            ON checker_vault(index_number);",
    )
    .execute(pool)
    .await
    .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;

    sqlx::query(
        "CREATE TABLE IF NOT EXISTS result_snapshots (
            id UUID PRIMARY KEY,
            index_number CHAR(10) NOT NULL,
            encrypted_payload BYTEA NOT NULL,
            fetched_at_unix BIGINT NOT NULL,
            expires_at_unix BIGINT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        CREATE INDEX IF NOT EXISTS idx_result_snapshots_index
            ON result_snapshots(index_number);",
    )
    .execute(pool)
    .await
    .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;

    sqlx::query(
        "CREATE TABLE IF NOT EXISTS paystack_initiations (
            id UUID PRIMARY KEY,
            index_number CHAR(10) NOT NULL,
            exam_type TEXT NOT NULL CHECK (exam_type IN ('BECE','WASSCE_SC','WASSCE_PRIVATE')),
            exam_year SMALLINT NOT NULL,
            paystack_ref TEXT NOT NULL UNIQUE,
            paystack_authorization_url TEXT NOT NULL,
            amount_pesewas BIGINT NOT NULL,
            currency TEXT NOT NULL DEFAULT 'GHS',
            status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paid','failed')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );",
    )
    .execute(pool)
    .await
    .map_err(|e| DomainError::new(waec_common::ErrorCode::Internal, e.to_string()))?;

    Ok(())
}
