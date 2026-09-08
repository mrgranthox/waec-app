//! PostgreSQL audit store — Admin service mirror of the audit topic
//! (plan §2.7: "audit topics mirrored to PostgreSQL by Admin").
//! Metadata only — hard rule 2.

use async_trait::async_trait;
use waec_common::DomainError;

/// Same shape as admin crate's AuditEntry.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct AuditRow {
    pub transaction_id: String,
    pub index_number: String,
    pub exam_type: String,
    /// success | failed | grace_refetch
    pub outcome: String,
    pub occurred_unix: i64,
}

pub struct PgAuditStore {
    pool: sqlx::PgPool,
}

impl PgAuditStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl super::AuditStore for PgAuditStore {
    async fn record(&self, e: AuditRow) -> Result<(), DomainError> {
        let occurred = chrono::DateTime::<chrono::Utc>::from_timestamp(e.occurred_unix, 0)
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());
        sqlx::query(
            "INSERT INTO audit_events (transaction_id, index_number, exam_type, outcome, occurred_at)
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(uuid::Uuid::parse_str(&e.transaction_id).ok())
        .bind(&e.index_number)
        .bind(&e.exam_type)
        .bind(&e.outcome)
        .bind(occurred)
        .execute(&self.pool)
        .await
        .map_err(|err| DomainError::new(waec_common::ErrorCode::Internal, err.to_string()))?;
        Ok(())
    }

    async fn query(
        &self,
        index_number: Option<&str>,
        from_unix: i64,
        to_unix: i64,
        limit: i32,
    ) -> Result<Vec<AuditRow>, DomainError> {
        let from = chrono::DateTime::<chrono::Utc>::from_timestamp(from_unix, 0)
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());
        let to = chrono::DateTime::<chrono::Utc>::from_timestamp(to_unix, 0)
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());
        let rows = sqlx::query_as::<
            _,
            (
                Option<String>,
                String,
                String,
                String,
                chrono::DateTime<chrono::Utc>,
            ),
        >(
            "SELECT transaction_id::text, index_number, exam_type, outcome, occurred_at
             FROM audit_events
             WHERE ($1::text IS NULL OR index_number = $1)
               AND occurred_at >= $2 AND occurred_at <= $3
             ORDER BY occurred_at DESC
             LIMIT $4",
        )
        .bind(index_number)
        .bind(from)
        .bind(to)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|err| DomainError::new(waec_common::ErrorCode::Internal, err.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|(tx, idx, exam, outcome, ts)| AuditRow {
                transaction_id: tx.unwrap_or_default(),
                index_number: idx,
                exam_type: exam,
                outcome,
                occurred_unix: ts.timestamp(),
            })
            .collect())
    }
}
