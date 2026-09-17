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

/// Transport contract for grace-token leases (plan §4.1 / §4.3). The
/// Redis-backed [`GraceStore`] is the production impl; the in-memory
/// lease serves unit tests and the dev stack hermetically.
#[async_trait::async_trait]
pub trait GraceLease: Send + Sync {
    /// Issue a token bound to a transaction with the fixed 24 h TTL.
    async fn issue(&self, token: &str, transaction_id: &str) -> Result<(), DomainError>;
    /// Atomically read-and-delete (single use). `None` ⇒ unknown or
    /// already consumed / expired.
    async fn consume(&self, token: &str) -> Result<Option<String>, DomainError>;
}

#[async_trait::async_trait]
impl GraceLease for GraceStore {
    async fn issue(&self, token: &str, transaction_id: &str) -> Result<(), DomainError> {
        GraceStore::issue(self, token, transaction_id).await
    }

    async fn consume(&self, token: &str) -> Result<Option<String>, DomainError> {
        GraceStore::consume(self, token).await
    }
}

/// In-memory lease for tests (same GETDEL semantics).
#[derive(Default)]
pub struct MemoryGraceLease {
    map: tokio::sync::RwLock<std::collections::HashMap<String, String>>,
}

#[async_trait::async_trait]
impl GraceLease for MemoryGraceLease {
    async fn issue(&self, token: &str, transaction_id: &str) -> Result<(), DomainError> {
        self.map
            .write()
            .await
            .insert(token.to_string(), transaction_id.to_string());
        Ok(())
    }

    async fn consume(&self, token: &str) -> Result<Option<String>, DomainError> {
        Ok(self.map.write().await.remove(token))
    }
}

impl MemoryGraceLease {
    /// Test helper: pop an arbitrary outstanding token (any order).
    pub async fn consume_any(&self) -> Option<(String, String)> {
        let mut m = self.map.write().await;
        let next = m.iter().next().map(|(k, v)| (k.clone(), v.clone()));
        if let Some((k, _)) = &next {
            m.remove(k);
        }
        next
    }

    /// Test helper: no outstanding tokens remain.
    pub async fn is_empty(&self) -> bool {
        self.map.read().await.is_empty()
    }
}

/// Failure classification for post-egress disruptions (plan §4.1). The
/// voucher/PIN was already consumed upstream when these occur — the
/// candidate paid, so the failure is ours, not theirs. Pre-egress
/// validation rejections (bad index, unknown exam) never construct this
/// type and therefore can never earn a grace token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchFailureKind {
    /// Connection to the portal dropped or timed out mid-scrape.
    Transport,
    /// DOM schema validation failed — clean abort, no partial results.
    DomDrift,
    /// Any other server-side failure after egress began.
    Internal,
}

impl FetchFailureKind {
    pub fn as_str(self) -> &'static str {
        match self {
            FetchFailureKind::Transport => "transport",
            FetchFailureKind::DomDrift => "dom_drift",
            FetchFailureKind::Internal => "internal",
        }
    }
}

/// A grace token that was auto-issued for a disrupted fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraceIssued {
    pub token: String,
    pub transaction_id: String,
    /// Unix expiry — exactly 24 h after issue (plan §6 global DoD).
    pub expires_unix: i64,
}

/// A durable grace-log entry (plan §4.3).
///
/// The Redis lease is the hot single-use gate; this row is the **index
/// pointer** that makes a grace token recoverable after the candidate
/// uninstalls the app (the token string lived only on that device and is
/// gone). Recovery path: authenticate with the index number → list
/// outstanding entries → re-fetch without repurchase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraceEntry {
    pub token: String,
    pub transaction_id: String,
    /// The index pointer — what a reinstalled client can present.
    pub index_number: String,
    pub expires_unix: i64,
}

/// Durable grace log (plan §4.3: "server-side encrypted grace-log with
/// index pointers enabling re-trigger without repurchase").
///
/// PostgreSQL is encrypted at rest per the infrastructure plan; the token
/// itself is a random bearer capability, so the row leaks nothing about
/// grades (hard rule 1: no grade value is ever stored here).
#[async_trait::async_trait]
pub trait GraceLog: Send + Sync {
    async fn record(&self, entry: &GraceEntry) -> Result<(), DomainError>;
    /// Unconsumed, unexpired entries for an index number, newest first.
    async fn outstanding_for_index(
        &self,
        index_number: &str,
    ) -> Result<Vec<GraceEntry>, DomainError>;
    async fn mark_consumed(&self, token: &str) -> Result<(), DomainError>;
}

/// In-memory durable log for tests and the dev stack.
#[derive(Default)]
pub struct MemoryGraceLog {
    rows: tokio::sync::RwLock<Vec<GraceEntry>>,
    consumed: tokio::sync::RwLock<std::collections::HashSet<String>>,
}

#[async_trait::async_trait]
impl GraceLog for MemoryGraceLog {
    async fn record(&self, entry: &GraceEntry) -> Result<(), DomainError> {
        self.rows.write().await.push(entry.clone());
        Ok(())
    }

    async fn outstanding_for_index(
        &self,
        index_number: &str,
    ) -> Result<Vec<GraceEntry>, DomainError> {
        let now = chrono::Utc::now().timestamp();
        let rows = self.rows.read().await;
        let consumed = self.consumed.read().await;
        let mut out: Vec<GraceEntry> = rows
            .iter()
            .filter(|e| e.index_number == index_number && e.expires_unix > now)
            .filter(|e| !consumed.contains(&e.token))
            .cloned()
            .collect();
        out.reverse(); // newest first, matching the Postgres ORDER BY
        Ok(out)
    }

    async fn mark_consumed(&self, token: &str) -> Result<(), DomainError> {
        self.consumed.write().await.insert(token.to_string());
        Ok(())
    }
}

/// PostgreSQL durable grace log — production impl of [`GraceLog`],
/// writing `grace_tokens` (migration 0004).
///
/// The index pointer is resolved through `transaction_log.index_number`,
/// so `grace_tokens` stores zero candidate data beyond the opaque token and
/// the transaction reference (hard rule 1). `expires_at` defaults to
/// `now() + 24 hours` in the schema, keeping the TTL invariant in one place.
pub struct PgGraceLog {
    pool: sqlx::PgPool,
}

impl PgGraceLog {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }

    fn err(e: sqlx::Error) -> DomainError {
        DomainError::new(ErrorCode::Internal, e.to_string())
    }

    fn uuid(s: &str) -> Result<uuid::Uuid, DomainError> {
        uuid::Uuid::parse_str(s).map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))
    }
}

#[async_trait::async_trait]
impl GraceLog for PgGraceLog {
    async fn record(&self, entry: &GraceEntry) -> Result<(), DomainError> {
        let token = Self::uuid(&entry.token)?;
        let tx = Self::uuid(&entry.transaction_id)?;
        sqlx::query("INSERT INTO grace_tokens (token, transaction_id) VALUES ($1, $2)")
            .bind(token)
            .bind(tx)
            .execute(&self.pool)
            .await
            .map_err(Self::err)?;
        Ok(())
    }

    async fn outstanding_for_index(
        &self,
        index_number: &str,
    ) -> Result<Vec<GraceEntry>, DomainError> {
        let rows = sqlx::query_as::<_, (uuid::Uuid, uuid::Uuid, chrono::DateTime<chrono::Utc>)>(
            "SELECT g.token, g.transaction_id, g.expires_at
             FROM grace_tokens g
             JOIN transaction_log t ON t.transaction_id = g.transaction_id
             WHERE t.index_number = $1
               AND g.consumed_at IS NULL
               AND g.expires_at > now()
             ORDER BY g.issued_at DESC",
        )
        .bind(index_number)
        .fetch_all(&self.pool)
        .await
        .map_err(Self::err)?;
        Ok(rows
            .into_iter()
            .map(|(token, tx, expires)| GraceEntry {
                token: token.to_string(),
                transaction_id: tx.to_string(),
                index_number: index_number.to_string(),
                expires_unix: expires.timestamp(),
            })
            .collect())
    }

    async fn mark_consumed(&self, token: &str) -> Result<(), DomainError> {
        let token = Self::uuid(token)?;
        sqlx::query("UPDATE grace_tokens SET consumed_at = now() WHERE token = $1")
            .bind(token)
            .execute(&self.pool)
            .await
            .map_err(Self::err)?;
        Ok(())
    }
}

/// Orchestrates the §4.1 failure path: on any post-egress disruption,
/// auto-issue a single-use 24 h re-fetch token and emit `fetch.failed`
/// to the pipeline. The grace guarantee never depends on the event bus
/// being up — the token is issued FIRST, observability is best-effort.
pub struct GraceIssuer {
    lease: std::sync::Arc<dyn GraceLease>,
    /// Durable index-pointer log (§4.3). `None` in unit tests that only
    /// exercise the hot path; production always wires the Postgres log.
    log: Option<std::sync::Arc<dyn GraceLog>>,
}

impl GraceIssuer {
    pub fn new(lease: std::sync::Arc<dyn GraceLease>) -> Self {
        Self { lease, log: None }
    }

    /// Hot lease + durable log (production wiring).
    pub fn with_log(
        lease: std::sync::Arc<dyn GraceLease>,
        log: std::sync::Arc<dyn GraceLog>,
    ) -> Self {
        Self {
            lease,
            log: Some(log),
        }
    }

    /// Record a mid-fetch failure: issue the free re-fetch token, then
    /// emit `fetch.failed` (outcome metadata only — no grades, no PIN).
    pub async fn on_fetch_failed(
        &self,
        transaction_id: &str,
        index_number: &str,
        kind: FetchFailureKind,
        publisher: &dyn crate::events::EventPublisher,
    ) -> Result<GraceIssued, DomainError> {
        // 1. Mission-critical: the token must exist even if nothing else
        //    does (chaos test: kill Handler mid-scrape → re-fetch free).
        let token = uuid::Uuid::new_v4().to_string();
        self.lease.issue(&token, transaction_id).await?;

        // 1b. Durable pointer, keyed by index number: survives an app
        //     uninstall, which is what lets a reinstalled client recover
        //     its free re-fetch (§4.3 acceptance).
        let expires_unix = chrono::Utc::now().timestamp() + GRACE_TTL_SECS as i64;
        if let Some(log) = &self.log {
            let entry = GraceEntry {
                token: token.clone(),
                transaction_id: transaction_id.to_string(),
                index_number: index_number.to_string(),
                expires_unix,
            };
            if let Err(e) = log.record(&entry).await {
                // The Redis lease already holds the token, so the candidate
                // can still re-fetch on this device; only the reinstall
                // recovery path degraded. Log and move on.
                tracing::error!(transaction_id = %transaction_id, error = %e, "grace log write failed");
            }
        }

        // 2. Observability: best-effort pipeline event.
        let event = crate::events::Event::new(
            crate::events::topics::FETCH_FAILED,
            transaction_id,
            serde_json::json!({ "outcome": "failed", "kind": kind.as_str() }),
        );
        if let Err(e) = publisher.publish(event).await {
            tracing::warn!(transaction_id = %transaction_id, error = %e, "fetch.failed publish failed; grace token unaffected");
        }

        tracing::info!(
            transaction_id = %transaction_id,
            failure = kind.as_str(),
            "grace re-fetch token auto-issued (24h)"
        );

        Ok(GraceIssued {
            token,
            transaction_id: transaction_id.to_string(),
            expires_unix,
        })
    }

    /// §4.3 re-fetch authorization: consume the single-use token.
    /// `Ok(Some(tx))` authorizes ONE free re-fetch for that transaction;
    /// `Ok(None)` rejects (unknown, already used, or expired).
    pub async fn authorize_refetch(&self, token: &str) -> Result<Option<String>, DomainError> {
        let tx = self.lease.consume(token).await?;
        // Mirror the consumption into the durable log so the entry stops
        // showing up as outstanding after a reinstall-recovery scan.
        if tx.is_some() {
            if let Some(log) = &self.log {
                if let Err(e) = log.mark_consumed(token).await {
                    tracing::error!(error = %e, "grace log consume-mark failed");
                }
            }
        }
        Ok(tx)
    }

    /// §4.3 acceptance: "uninstall + reinstall within grace → re-fetch
    /// works". The device lost the token, so the client presents only its
    /// authenticated index number; we hand back the newest outstanding
    /// token for that index (empty when none / all expired).
    pub async fn recover_for_index(
        &self,
        index_number: &str,
    ) -> Result<Vec<GraceEntry>, DomainError> {
        match &self.log {
            Some(log) => log.outstanding_for_index(index_number).await,
            None => Ok(Vec::new()),
        }
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

    // ── §4.1: mid-fetch failure auto-issues a 24h grace token ───────────

    fn issuer() -> (
        GraceIssuer,
        std::sync::Arc<MemoryGraceLease>,
        crate::events::InMemoryEventBus,
    ) {
        let lease = std::sync::Arc::new(MemoryGraceLease::default());
        let bus = crate::events::InMemoryEventBus::new();
        (GraceIssuer::new(lease.clone()), lease, bus)
    }

    #[tokio::test]
    async fn mid_fetch_failure_auto_issues_single_use_token() {
        let (g, lease, bus) = issuer();
        let issued = g
            .on_fetch_failed(
                "tx-midfetch",
                "1002330440",
                FetchFailureKind::Transport,
                &bus,
            )
            .await
            .unwrap();

        // Token is bound to the transaction with the fixed 24 h TTL.
        assert_eq!(issued.transaction_id, "tx-midfetch");
        assert_eq!(
            issued.expires_unix,
            chrono::Utc::now().timestamp() + GRACE_TTL_SECS as i64
        );

        // fetch.failed reached the pipeline with outcome metadata only.
        let snap = bus.snapshot().await;
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].topic, crate::events::topics::FETCH_FAILED);
        assert_eq!(snap[0].correlation_id, "tx-midfetch");
        assert_eq!(snap[0].payload["kind"], "transport");
        let raw = serde_json::to_string(&snap[0].payload).unwrap();
        assert!(!raw.to_lowercase().contains("grade") && !raw.contains("pin"));

        // §4.3: re-fetch works free — exactly once.
        let auth = g.authorize_refetch(&issued.token).await.unwrap();
        assert_eq!(auth.as_deref(), Some("tx-midfetch"));
        let replay = g.authorize_refetch(&issued.token).await.unwrap();
        assert!(replay.is_none(), "token must be single-use");
        let _ = lease;
    }

    #[tokio::test]
    async fn dom_drift_failure_also_earns_grace() {
        let (g, _lease, bus) = issuer();
        let issued = g
            .on_fetch_failed("tx-drift", "2001223440", FetchFailureKind::DomDrift, &bus)
            .await
            .unwrap();
        assert!(g.authorize_refetch(&issued.token).await.unwrap().is_some());
    }

    #[tokio::test]
    async fn grace_survives_event_bus_outage() {
        // Chaos: the event bus is down mid-failure. The token must still
        // exist — observability is best-effort, the grace guarantee is not.
        let lease = std::sync::Arc::new(MemoryGraceLease::default());
        let g = GraceIssuer::new(lease.clone());
        let dead_bus = crate::events::InMemoryEventBus::new(); // no subscriber → publish errors
        let issued = g
            .on_fetch_failed(
                "tx-busdown",
                "1002330441",
                FetchFailureKind::Internal,
                &dead_bus,
            )
            .await
            .unwrap();
        assert!(g.authorize_refetch(&issued.token).await.unwrap().is_some());
        let _ = lease;
    }

    #[tokio::test]
    async fn unknown_or_replayed_token_cannot_refetch() {
        let (g, _lease, _bus) = issuer();
        assert!(
            g.authorize_refetch("not-a-real-token")
                .await
                .unwrap()
                .is_none()
        );
    }

    // ── §4.3: durable grace-log + index pointer survives reinstall ──────

    fn issuer_with_log() -> (
        GraceIssuer,
        std::sync::Arc<MemoryGraceLog>,
        crate::events::InMemoryEventBus,
    ) {
        let lease = std::sync::Arc::new(MemoryGraceLease::default());
        let log = std::sync::Arc::new(MemoryGraceLog::default());
        (
            GraceIssuer::with_log(lease, log.clone()),
            log,
            crate::events::InMemoryEventBus::new(),
        )
    }

    #[tokio::test]
    async fn reinstalled_client_recovers_token_by_index_pointer() {
        // Acceptance: "uninstall + reinstall within grace → re-fetch works".
        // The reinstalled device knows nothing but the candidate's index
        // number (recovered by authenticating); the server hands back the
        // outstanding token.
        let (g, log, bus) = issuer_with_log();
        let issued = g
            .on_fetch_failed(
                "tx-reinstall",
                "1002330440",
                FetchFailureKind::Transport,
                &bus,
            )
            .await
            .unwrap();
        assert_eq!(
            log.outstanding_for_index("1002330440").await.unwrap().len(),
            1
        );

        // Fresh "device": recover the pointer, then re-fetch free — once.
        let recovered = g.recover_for_index("1002330440").await.unwrap();
        assert_eq!(recovered[0].token, issued.token);
        assert_eq!(recovered[0].transaction_id, "tx-reinstall");

        let auth = g.authorize_refetch(&recovered[0].token).await.unwrap();
        assert_eq!(auth.as_deref(), Some("tx-reinstall"));
        assert!(
            g.recover_for_index("1002330440").await.unwrap().is_empty(),
            "consumed token must leave the outstanding set"
        );
    }

    #[tokio::test]
    async fn recovery_is_scoped_to_the_owning_index() {
        let (g, _log, bus) = issuer_with_log();
        g.on_fetch_failed("tx-a", "1002330440", FetchFailureKind::Transport, &bus)
            .await
            .unwrap();
        g.on_fetch_failed("tx-b", "2001223440", FetchFailureKind::Transport, &bus)
            .await
            .unwrap();

        let a = g.recover_for_index("1002330440").await.unwrap();
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].transaction_id, "tx-a");
        assert!(g.recover_for_index("9999999999").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn expired_entries_are_not_recoverable() {
        let log = std::sync::Arc::new(MemoryGraceLog::default());
        log.record(&GraceEntry {
            token: "tok-old".into(),
            transaction_id: "tx-old".into(),
            index_number: "1002330440".into(),
            expires_unix: chrono::Utc::now().timestamp() - 1,
        })
        .await
        .unwrap();
        assert!(
            log.outstanding_for_index("1002330440")
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn log_failure_does_not_break_the_hot_lease() {
        // Durable-write trouble must not revoke the grace promise on the
        // device still holding the token.
        #[derive(Default)]
        struct BrokenLog;
        #[async_trait::async_trait]
        impl GraceLog for BrokenLog {
            async fn record(&self, _e: &GraceEntry) -> Result<(), DomainError> {
                Err(DomainError::new(ErrorCode::Internal, "db down"))
            }
            async fn outstanding_for_index(
                &self,
                _i: &str,
            ) -> Result<Vec<GraceEntry>, DomainError> {
                Ok(Vec::new())
            }
            async fn mark_consumed(&self, _t: &str) -> Result<(), DomainError> {
                Ok(())
            }
        }
        let lease = std::sync::Arc::new(MemoryGraceLease::default());
        let g = GraceIssuer::with_log(lease, std::sync::Arc::new(BrokenLog));
        let bus = crate::events::InMemoryEventBus::new();
        let issued = g
            .on_fetch_failed("tx-partial", "1002330440", FetchFailureKind::DomDrift, &bus)
            .await
            .expect("issue must succeed even when the durable log is down");
        assert!(g.authorize_refetch(&issued.token).await.unwrap().is_some());
    }

    /// Live test against Postgres (WAEC_PG_TEST_URL), exercising the real
    /// `grace_tokens` table and the index-pointer JOIN.
    #[tokio::test]
    async fn live_pg_grace_log_round_trip() {
        let Ok(url) = std::env::var("WAEC_PG_TEST_URL") else {
            eprintln!("WAEC_PG_TEST_URL unset — skipping live pg test");
            return;
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(3)
            .connect(&url)
            .await
            .unwrap();
        let index = "1002990440";
        let key = uuid::Uuid::new_v4();
        let tx = uuid::Uuid::new_v4();

        // FK chain: payment_idempotency → transaction_log → grace_tokens.
        sqlx::query(
            "INSERT INTO payment_idempotency (idempotency_key, response_json)
             VALUES ($1, '{}'::jsonb)",
        )
        .bind(key)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO transaction_log
             (transaction_id, index_number, exam_type, exam_year, status, amount_pesewas, idempotency_key)
             VALUES ($1, $2, 'BECE', 2025, 'failed', 1500, $3)",
        )
        .bind(tx)
        .bind(index)
        .bind(key)
        .execute(&pool)
        .await
        .unwrap();

        let log = PgGraceLog::new(pool.clone());
        let token = uuid::Uuid::new_v4();
        log.record(&GraceEntry {
            token: token.to_string(),
            transaction_id: tx.to_string(),
            index_number: index.to_string(),
            expires_unix: chrono::Utc::now().timestamp() + GRACE_TTL_SECS as i64,
        })
        .await
        .unwrap();

        let found = log.outstanding_for_index(index).await.unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].token, token.to_string());
        // The 24 h TTL invariant is enforced by the schema default.
        assert!(
            found[0].expires_unix > chrono::Utc::now().timestamp() + GRACE_TTL_SECS as i64 - 60
        );

        log.mark_consumed(&token.to_string()).await.unwrap();
        assert!(log.outstanding_for_index(index).await.unwrap().is_empty());

        // Repeatable teardown.
        sqlx::query("DELETE FROM grace_tokens WHERE transaction_id = $1")
            .bind(tx)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM transaction_log WHERE transaction_id = $1")
            .bind(tx)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM payment_idempotency WHERE idempotency_key = $1")
            .bind(key)
            .execute(&pool)
            .await
            .unwrap();
    }
}
