//! WAEC data-tier adapters — plan §2.7.
//!
//! PostgreSQL (users, transactions, audit, idempotency, pricing, grace)
//! and Redis (24 h grace TTL keys). One crate shared by all services so
//! the store implementations never drift.

pub mod events;
pub mod grace;
pub mod idempotency;
pub mod pg_audit;
pub mod pricing;
pub mod users;

use async_trait::async_trait;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

/// Build a Postgres pool from a `DATABASE_URL`-style connection string.
pub async fn connect_pool(url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(url)
        .await
}

/// Audit store contract (Admin §2.5). The in-memory impl lives in the
/// admin crate for unit tests; this Pg adapter is the production impl.
#[async_trait]
pub trait AuditStore: Send + Sync {
    async fn record(&self, e: pg_audit::AuditRow) -> Result<(), waec_common::DomainError>;
    async fn query(
        &self,
        index_number: Option<&str>,
        from_unix: i64,
        to_unix: i64,
        limit: i32,
    ) -> Result<Vec<pg_audit::AuditRow>, waec_common::DomainError>;
}
