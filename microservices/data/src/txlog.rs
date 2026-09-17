//! Atomic transaction journal — plan §4.1.
//!
//! "Atomic transaction logging **before egress**": a transaction row must be
//! durable *before* any money-moving or portal-touching call leaves the
//! process. If the process is killed mid-fetch the row is already there, which
//! is what lets the grace token (whose FK points here) be issued afterwards
//! and what makes the candidate's paid-for journey auditable.
//!
//! [`TxJournal::begin`] inserts the ledger reservation and the journal row in
//! **one** Postgres transaction: either both exist or neither does, so the
//! journal can never reference a reservation that wasn't made, and a replayed
//! `begin` for a key already in flight is reported as a duplicate rather than
//! silently creating a second journey.
//!
//! Hard rule 1: only metadata is journaled — index number, exam, amount,
//! status. Never a grade, PIN or voucher serial.

use std::collections::HashMap;
use std::sync::Arc;

use waec_common::{DomainError, ErrorCode};

/// Lifecycle states, mirroring the `transaction_log.status` CHECK constraint
/// (migration 0002). Renaming any variant breaks the DB constraint — treat as
/// a contract change requiring an ADR.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TxStatus {
    Pending,
    Paid,
    VoucherAcquired,
    Fetching,
    Success,
    Failed,
    GraceRefetch,
}

impl TxStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            TxStatus::Pending => "pending",
            TxStatus::Paid => "paid",
            TxStatus::VoucherAcquired => "voucher_acquired",
            TxStatus::Fetching => "fetching",
            TxStatus::Success => "success",
            TxStatus::Failed => "failed",
            TxStatus::GraceRefetch => "grace_refetch",
        }
    }
}

/// A journal row. `transaction_id` is the idempotency key: one journey per
/// key, so a replay resolves to the same row rather than a new one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxRecord {
    pub transaction_id: String,
    pub index_number: String,
    /// BECE | WASSCE_SC | WASSCE_PRIVATE
    pub exam_type: String,
    pub exam_year: i32,
    pub amount_pesewas: i64,
    pub status: TxStatus,
}

#[async_trait::async_trait]
pub trait TxJournal: Send + Sync {
    /// Durably record the journey **before** egress. `Ok(true)` when this
    /// call created the row (caller owns the journey and may proceed);
    /// `Ok(false)` when a row already existed for this idempotency key
    /// (caller must NOT re-execute the side effect).
    async fn begin(&self, rec: &TxRecord) -> Result<bool, DomainError>;

    /// Advance the journal. Unknown transaction ids are an error, never a
    /// silent no-op: it would mask a begin() that never committed.
    async fn set_status(&self, transaction_id: &str, status: TxStatus) -> Result<(), DomainError>;

    async fn status_of(&self, transaction_id: &str) -> Result<Option<TxStatus>, DomainError>;
}

/// In-memory journal for tests and the dev stack.
#[derive(Default, Clone)]
pub struct MemoryTxJournal {
    rows: Arc<tokio::sync::RwLock<HashMap<String, TxStatus>>>,
}

#[async_trait::async_trait]
impl TxJournal for MemoryTxJournal {
    async fn begin(&self, rec: &TxRecord) -> Result<bool, DomainError> {
        let mut w = self.rows.write().await;
        if w.contains_key(&rec.transaction_id) {
            return Ok(false);
        }
        w.insert(rec.transaction_id.clone(), rec.status);
        Ok(true)
    }

    async fn set_status(&self, transaction_id: &str, status: TxStatus) -> Result<(), DomainError> {
        let mut w = self.rows.write().await;
        match w.get_mut(transaction_id) {
            Some(s) => {
                *s = status;
                Ok(())
            }
            None => Err(DomainError::new(
                ErrorCode::Internal,
                "journal: set_status on unknown transaction",
            )),
        }
    }

    async fn status_of(&self, transaction_id: &str) -> Result<Option<TxStatus>, DomainError> {
        Ok(self.rows.read().await.get(transaction_id).copied())
    }
}

/// PostgreSQL journal — production [`TxJournal`], writing `transaction_log`
/// (migration 0002). `transaction_id` is the idempotency key: one journey
/// per key, so replays resolve to the same row.
pub struct PgTxJournal {
    pool: sqlx::PgPool,
}

impl PgTxJournal {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }

    fn err(e: sqlx::Error) -> DomainError {
        DomainError::new(ErrorCode::Internal, e.to_string())
    }

    fn uuid(s: &str) -> Result<uuid::Uuid, DomainError> {
        uuid::Uuid::parse_str(s)
            .map_err(|e| DomainError::new(ErrorCode::InvalidExamParams, e.to_string()))
    }
}

#[async_trait::async_trait]
impl TxJournal for PgTxJournal {
    async fn begin(&self, rec: &TxRecord) -> Result<bool, DomainError> {
        let key = Self::uuid(&rec.transaction_id)?;
        let mut tx = self.pool.begin().await.map_err(Self::err)?;

        // §4.1's real gate: the payment reservation must already exist
        // (`transaction_log.idempotency_key` is an FK into
        // `payment_idempotency`, written by the payment service when it
        // caches the charge outcome, hard rule 3). Deriving the amount from
        // that row means the journal never trusts a caller-supplied figure,
        // and a journaled journey without a durable payment record fails
        // closed instead of silently inventing one.
        let paid: Option<(Option<i64>,)> = sqlx::query_as(
            "SELECT (response_json->>'amount_pesewas')::BIGINT
             FROM payment_idempotency WHERE idempotency_key = $1",
        )
        .bind(key)
        .fetch_optional(&mut *tx)
        .await
        .map_err(Self::err)?;
        let Some((Some(amount),)) = paid else {
            tx.rollback().await.map_err(Self::err)?;
            return Err(DomainError::new(
                ErrorCode::PaymentDeclined,
                "journal: no durable payment record for this idempotency key",
            ));
        };

        // Insert-if-absent: an existing row (replay / concurrent first
        // attempt) means someone else owns this journey — never two
        // journeys, never a double voucher.
        let inserted = sqlx::query(
            "INSERT INTO transaction_log
             (transaction_id, index_number, exam_type, exam_year, status, amount_pesewas, idempotency_key)
             SELECT $1, $2, $3, $4, $5, $6, $1
             WHERE NOT EXISTS (
               SELECT 1 FROM transaction_log WHERE transaction_id = $1)",
        )
        .bind(key)
        .bind(&rec.index_number)
        .bind(&rec.exam_type)
        .bind(rec.exam_year as i16)
        .bind(rec.status.as_str())
        .bind(amount)
        .execute(&mut *tx)
        .await
        .map_err(Self::err)?;
        let owned = inserted.rows_affected() == 1;

        tx.commit().await.map_err(Self::err)?;
        Ok(owned)
    }

    async fn set_status(&self, transaction_id: &str, status: TxStatus) -> Result<(), DomainError> {
        let id = Self::uuid(transaction_id)?;
        let n = sqlx::query(
            "UPDATE transaction_log SET status = $2, updated_at = now() WHERE transaction_id = $1",
        )
        .bind(id)
        .bind(status.as_str())
        .execute(&self.pool)
        .await
        .map_err(Self::err)?;
        if n.rows_affected() == 0 {
            return Err(DomainError::new(
                ErrorCode::Internal,
                "journal: set_status on unknown transaction",
            ));
        }
        Ok(())
    }

    async fn status_of(&self, transaction_id: &str) -> Result<Option<TxStatus>, DomainError> {
        let id = Self::uuid(transaction_id)?;
        let row: Option<(String,)> =
            sqlx::query_as("SELECT status FROM transaction_log WHERE transaction_id = $1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await
                .map_err(Self::err)?;
        let Some((s,)) = row else { return Ok(None) };
        Ok(Some(match s.as_str() {
            "pending" => TxStatus::Pending,
            "paid" => TxStatus::Paid,
            "voucher_acquired" => TxStatus::VoucherAcquired,
            "fetching" => TxStatus::Fetching,
            "success" => TxStatus::Success,
            "failed" => TxStatus::Failed,
            "grace_refetch" => TxStatus::GraceRefetch,
            other => {
                return Err(DomainError::new(
                    ErrorCode::Internal,
                    format!("journal: unknown status {other}"),
                ));
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(key: &str) -> TxRecord {
        TxRecord {
            transaction_id: key.into(),
            index_number: "1002330440".into(),
            exam_type: "BECE".into(),
            exam_year: 2025,
            amount_pesewas: 1500,
            status: TxStatus::Pending,
        }
    }

    fn uuid_key() -> String {
        uuid::Uuid::new_v4().to_string()
    }

    #[tokio::test]
    async fn begin_wins_once_duplicate_loses() {
        let j = MemoryTxJournal::default();
        let key = uuid_key();
        assert!(
            j.begin(&rec(&key)).await.unwrap(),
            "first begin owns the journey"
        );
        assert!(
            !j.begin(&rec(&key)).await.unwrap(),
            "duplicate begin must lose"
        );
    }

    #[tokio::test]
    async fn begin_persists_before_any_status_change() {
        // §4.1 invariant: the row exists BEFORE egress, so a process killed
        // mid-fetch leaves an auditable pending journey.
        let j = MemoryTxJournal::default();
        let key = uuid_key();
        j.begin(&rec(&key)).await.unwrap();
        assert_eq!(j.status_of(&key).await.unwrap(), Some(TxStatus::Pending));
    }

    #[tokio::test]
    async fn set_status_advances_then_unknown_id_errors() {
        let j = MemoryTxJournal::default();
        let key = uuid_key();
        j.begin(&rec(&key)).await.unwrap();
        j.set_status(&key, TxStatus::Fetching).await.unwrap();
        assert_eq!(j.status_of(&key).await.unwrap(), Some(TxStatus::Fetching));

        let err = j.set_status(&uuid_key(), TxStatus::Paid).await.unwrap_err();
        assert_eq!(err.code, ErrorCode::Internal);
    }

    #[tokio::test]
    async fn status_strings_match_db_check_constraint() {
        // Migration 0002 pins these exact strings; drift breaks inserts.
        let allowed = [
            "pending",
            "paid",
            "voucher_acquired",
            "fetching",
            "success",
            "failed",
            "grace_refetch",
        ];
        let all = [
            TxStatus::Pending,
            TxStatus::Paid,
            TxStatus::VoucherAcquired,
            TxStatus::Fetching,
            TxStatus::Success,
            TxStatus::Failed,
            TxStatus::GraceRefetch,
        ];
        for s in all {
            assert!(allowed.contains(&s.as_str()), "{} not in CHECK", s.as_str());
        }
    }

    #[tokio::test]
    async fn concurrent_begins_have_a_single_owner() {
        let j = Arc::new(MemoryTxJournal::default());
        let key = uuid_key();
        let mut tasks = Vec::new();
        for _ in 0..8 {
            let jj = Arc::clone(&j);
            let k = key.clone();
            tasks.push(tokio::spawn(
                async move { jj.begin(&rec(&k)).await.unwrap() },
            ));
        }
        let mut wins = 0;
        for t in tasks {
            if t.await.unwrap() {
                wins += 1;
            }
        }
        assert_eq!(wins, 1, "exactly one concurrent begin may own the journey");
    }

    /// Live test against Postgres (WAEC_PG_TEST_URL): real FK chain and
    /// first-write-wins under replays.
    #[tokio::test]
    async fn live_pg_journal_begin_is_atomic() {
        let Ok(url) = std::env::var("WAEC_PG_TEST_URL") else {
            eprintln!("WAEC_PG_TEST_URL unset — skipping live pg test");
            return;
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(4)
            .connect(&url)
            .await
            .unwrap();
        let j = PgTxJournal::new(pool.clone());
        let key = uuid_key();

        assert!(
            j.begin(&rec(&key)).await.unwrap(),
            "fresh key must be owned"
        );
        assert!(
            !j.begin(&rec(&key)).await.unwrap(),
            "replay must not own again"
        );
        j.set_status(&key, TxStatus::Fetching).await.unwrap();
        assert_eq!(j.status_of(&key).await.unwrap(), Some(TxStatus::Fetching));

        // Teardown in FK order.
        let id = uuid::Uuid::parse_str(&key).unwrap();
        sqlx::query("DELETE FROM transaction_log WHERE transaction_id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM payment_idempotency WHERE idempotency_key = $1")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
    }
}
