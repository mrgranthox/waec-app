//! Checker-schema migrations — plan §2.7.
//!
//! The `waec-data` crate runs DDL inline at service startup (matching the
//! plan's "service creates its own schema on first boot" model). This module
//! is the canonical home for those DDL strings so they stay testable and
//! drift-detectable without spinning up Postgres.

/// The SQL the checker-schema migrations execute. Kept as a public constant
/// so CI can grep for forbidden literals (e.g. a raw grade column name) and
/// so the `0006_checkers.sql` stub can be compared against it for drift.
pub const CHECKER_VAULT_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS checker_vault (
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
    ON checker_vault(index_number);
"#;

pub const RESULT_SNAPSHOTS_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS result_snapshots (
    id UUID PRIMARY KEY,
    index_number CHAR(10) NOT NULL,
    encrypted_payload BYTEA NOT NULL,
    fetched_at_unix BIGINT NOT NULL,
    expires_at_unix BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_result_snapshots_index
    ON result_snapshots(index_number);
"#;

pub const PAYSTACK_INITIATIONS_DDL: &str = r#"
CREATE TABLE IF NOT EXISTS paystack_initiations (
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
);
"#;

/// All DDL statements in order. Run each independently so a partially-applied
/// migration leaves the schema consistent (each statement is idempotent).
pub fn all_ddl() -> Vec<&'static str> {
    vec![
        CHECKER_VAULT_DDL,
        RESULT_SNAPSHOTS_DDL,
        PAYSTACK_INITIATIONS_DDL,
    ]
}

/// Run all checker-schema migrations against a pool.
pub async fn run_all(pool: &sqlx::PgPool) -> Result<(), waec_common::DomainError> {
    for ddl in all_ddl() {
        sqlx::query(ddl).execute(pool).await.map_err(|e| {
            waec_common::DomainError::new(waec_common::ErrorCode::Internal, e.to_string())
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ddl_never_contains_raw_grade_columns() {
        // Hard rule 2: no raw grade values in any server-side schema.
        let forbidden = ["grade", "score", "A1", "B2", "C3"];
        for ddl in all_ddl() {
            for f in &forbidden {
                assert!(
                    !ddl.to_lowercase().contains(&f.to_lowercase()),
                    "DDL contains forbidden literal '{}'",
                    f
                );
            }
        }
    }

    #[test]
    fn ddl_never_contains_plaintext_pin_column() {
        // Hard rule 1: PINs live only in client-encrypted blobs.
        for ddl in all_ddl() {
            assert!(
                !ddl.contains("pin TEXT"),
                "DDL must not store plaintext PINs"
            );
            assert!(
                !ddl.contains("serial TEXT"),
                "DDL must not store plaintext serials"
            );
        }
    }

    #[test]
    fn all_ddl_is_idempotent() {
        for ddl in all_ddl() {
            assert!(
                ddl.contains("IF NOT EXISTS"),
                "Every CREATE must be IF NOT EXISTS for idempotency"
            );
        }
    }

    #[test]
    fn checker_vault_has_required_columns() {
        let ddl = CHECKER_VAULT_DDL;
        for col in [
            "index_number",
            "exam_type",
            "exam_year",
            "encrypted_blob",
            "status",
            "acquired_at_unix",
            "transaction_id",
        ] {
            assert!(ddl.contains(col), "checker_vault missing column: {}", col);
        }
    }

    #[test]
    fn paystack_initiations_enforces_status_constraint() {
        assert!(PAYSTACK_INITIATIONS_DDL.contains("CHECK (status IN"));
        assert!(PAYSTACK_INITIATIONS_DDL.contains("'pending'"));
        assert!(PAYSTACK_INITIATIONS_DDL.contains("'paid'"));
    }
}
