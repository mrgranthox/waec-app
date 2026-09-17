//! WAEC data-tier adapters — plan §2.7.
//!
//! PostgreSQL (users, transactions, audit, idempotency, pricing, grace)
//! and Redis (24 h grace TTL keys). One crate shared by all services so
//! the store implementations never drift.

pub mod checker_migrations;
pub mod checkers;

pub mod events;
pub mod grace;
pub mod idempotency;
pub mod pg_audit;
pub mod pricing;
pub mod txlog;
pub mod users;

use async_trait::async_trait;
use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;

/// Build a Postgres pool from a `DATABASE_URL`-style connection string.
pub async fn connect_pool(url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(url)
        .await
}

/// Run the workspace SQL migrations (microservices/migrations). Called at
/// service boot so Neon and the compose Postgres converge on the same schema.
pub async fn run_migrations(pool: &PgPool) -> Result<(), sqlx::migrate::MigrateError> {
    sqlx::migrate!("../migrations").run(pool).await
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
