//! Transaction audit store — metadata only (hard rule 2: zero grade
//! data server-side). Postgres adapter lands in task 2.7; the trait
//! keeps the service testable now.

use async_trait::async_trait;
use std::sync::RwLock;
use waec_common::DomainError;

/// One audit row. Contains NO grades, NO PINs, NO serials.
#[derive(Debug, Clone, PartialEq)]
pub struct AuditEntry {
    pub transaction_id: String,
    pub index_number: String,
    pub exam_type: String,
    /// success | failed | grace_refetch
    pub outcome: String,
    pub occurred_unix: i64,
}

#[async_trait]
pub trait AuditStore: Send + Sync {
    async fn record(&self, entry: AuditEntry) -> Result<(), DomainError>;
    async fn query(
        &self,
        index_number: Option<&str>,
        from_unix: i64,
        to_unix: i64,
        limit: i32,
    ) -> Result<Vec<AuditEntry>, DomainError>;
}

/// In-memory audit store (dev/tests).
#[derive(Default)]
pub struct InMemoryAuditStore {
    rows: RwLock<Vec<AuditEntry>>,
}

#[async_trait]
impl AuditStore for InMemoryAuditStore {
    async fn record(&self, entry: AuditEntry) -> Result<(), DomainError> {
        self.rows.write().unwrap().push(entry);
        Ok(())
    }

    async fn query(
        &self,
        index_number: Option<&str>,
        from_unix: i64,
        to_unix: i64,
        limit: i32,
    ) -> Result<Vec<AuditEntry>, DomainError> {
        let rows = self.rows.read().unwrap();
        let out = rows
            .iter()
            .filter(|r| index_number.map_or(true, |i| r.index_number == i))
            .filter(|r| r.occurred_unix >= from_unix && r.occurred_unix <= to_unix)
            .rev()
            .take(if limit <= 0 { 50 } else { limit as usize })
            .cloned()
            .collect();
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(tx: &str, idx: &str, ts: i64) -> AuditEntry {
        AuditEntry {
            transaction_id: tx.into(),
            index_number: idx.into(),
            exam_type: "BECE".into(),
            outcome: "success".into(),
            occurred_unix: ts,
        }
    }

    #[tokio::test]
    async fn record_and_query_filters() {
        let store = InMemoryAuditStore::default();
        store.record(entry("t1", "1002330440", 100)).await.unwrap();
        store.record(entry("t2", "1002330441", 200)).await.unwrap();
        store.record(entry("t3", "1002330440", 300)).await.unwrap();

        let all = store.query(None, 0, 9999, 10).await.unwrap();
        assert_eq!(all.len(), 3);

        let by_index = store.query(Some("1002330440"), 0, 9999, 10).await.unwrap();
        assert_eq!(by_index.len(), 2);
        // Newest first
        assert_eq!(by_index[0].transaction_id, "t3");

        let windowed = store.query(None, 150, 250, 10).await.unwrap();
        assert_eq!(windowed.len(), 1);
    }

    #[tokio::test]
    async fn limit_respected() {
        let store = InMemoryAuditStore::default();
        for i in 0..10 {
            store
                .record(entry(&format!("t{i}"), "idx", 100 + i))
                .await
                .unwrap();
        }
        assert_eq!(store.query(None, 0, 9999, 3).await.unwrap().len(), 3);
    }
}
