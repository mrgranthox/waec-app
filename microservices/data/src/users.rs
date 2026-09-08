//! PostgreSQL user store — implements the auth service `UserStore` trait.
//!
//! Contract: Argon2id hashes only; zero grades/PINs. Lockout state lives
//! in columns (`failed_attempts`, `locked_until`).

use sqlx::Row;
use uuid::Uuid;

/// Mirror of the auth crate's `UserRecord` (kept structurally identical;
/// the auth crate converts at the boundary to avoid a circular dep).
#[derive(Debug, Clone)]
pub struct UserRow {
    pub user_id: String,
    pub index_number: String,
    pub password_hash: String,
    pub biometric_public_key: Option<String>,
    pub failed_attempts: u32,
    /// Seconds since epoch; 0 = not locked.
    pub locked_until: i64,
}

#[derive(Debug, thiserror::Error)]
pub enum UserStoreError {
    #[error("index number already registered")]
    DuplicateIndex,
    #[error("user not found")]
    NotFound,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
}

pub struct PgUserStore {
    pool: sqlx::PgPool,
}

impl PgUserStore {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

impl UserRow {
    fn from_row(row: &sqlx::postgres::PgRow) -> Self {
        let locked: chrono::DateTime<chrono::Utc> = row.get("locked_until");
        Self {
            user_id: row.get::<Uuid, _>("user_id").to_string(),
            index_number: row.get::<String, _>("index_number"),
            password_hash: row.get("password_hash"),
            biometric_public_key: row.get("biometric_public_key"),
            failed_attempts: row.get::<i32, _>("failed_attempts") as u32,
            locked_until: locked.timestamp(),
        }
    }
}

const COLS: &str =
    "user_id, index_number, password_hash, biometric_public_key, failed_attempts, locked_until";

impl PgUserStore {
    /// Insert a new user; errors on duplicate index.
    pub async fn create(
        &self,
        index_number: &str,
        password_hash: &str,
    ) -> Result<UserRow, UserStoreError> {
        let row = sqlx::query(&format!(
            "INSERT INTO users (index_number, password_hash) VALUES ($1, $2) RETURNING {COLS}"
        ))
        .bind(index_number)
        .bind(password_hash)
        .fetch_optional(&self.pool)
        .await?;

        row.map(|r| UserRow::from_row(&r))
            .ok_or(UserStoreError::NotFound)
    }

    pub async fn find_by_index(&self, index_number: &str) -> Result<UserRow, UserStoreError> {
        let row = sqlx::query(&format!("SELECT {COLS} FROM users WHERE index_number = $1"))
            .bind(index_number)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|r| UserRow::from_row(&r))
            .ok_or(UserStoreError::NotFound)
    }

    pub async fn find_by_user_id(&self, user_id: &str) -> Result<UserRow, UserStoreError> {
        let id = Uuid::parse_str(user_id).map_err(|_| UserStoreError::NotFound)?;
        let row = sqlx::query(&format!("SELECT {COLS} FROM users WHERE user_id = $1"))
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|r| UserRow::from_row(&r))
            .ok_or(UserStoreError::NotFound)
    }

    /// Persist lockout/biometric state.
    pub async fn update(&self, u: &UserRow) -> Result<(), UserStoreError> {
        let id = Uuid::parse_str(&u.user_id).map_err(|_| UserStoreError::NotFound)?;
        let locked = chrono::DateTime::<chrono::Utc>::from_timestamp(u.locked_until, 0)
            .unwrap_or_else(|| chrono::DateTime::from_timestamp(0, 0).unwrap());
        let n = sqlx::query(
            "UPDATE users SET password_hash=$2, biometric_public_key=$3,
             failed_attempts=$4, locked_until=$5, updated_at=now()
             WHERE user_id=$1",
        )
        .bind(id)
        .bind(&u.password_hash)
        .bind(&u.biometric_public_key)
        .bind(u.failed_attempts as i32)
        .bind(locked)
        .execute(&self.pool)
        .await?;
        if n.rows_affected() == 0 {
            return Err(UserStoreError::NotFound);
        }
        Ok(())
    }

    /// Apply a migration file's SQL (used by the smoke test / CI).
    pub async fn run_migration(&self, sql: &str) -> Result<(), UserStoreError> {
        sqlx::query(sql).execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Live integration against local Postgres (skips if DATABASE_URL
    /// unset — CI runs the compose stack first).
    #[tokio::test]
    async fn pg_user_store_round_trip() {
        let Ok(url) = std::env::var("WAEC_PG_TEST_URL") else {
            eprintln!("WAEC_PG_TEST_URL unset — skipping live pg test");
            return;
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(3)
            .connect(&url)
            .await
            .unwrap();
        let store = PgUserStore::new(pool);

        let idx = format!("9{}", rand_suffix());
        let created = store.create(&idx, "$argon2id$hash").await.unwrap();
        assert_eq!(created.index_number, idx);

        let found = store.find_by_index(&idx).await.unwrap();
        assert_eq!(found.user_id, created.user_id);

        // Duplicate rejected.
        assert!(matches!(
            store.create(&idx, "x").await,
            Err(UserStoreError::DuplicateIndex) | Err(UserStoreError::Db(_))
        ));

        // find_by_user_id + update lockout.
        let mut u = found.clone();
        u.failed_attempts = 5;
        u.locked_until = chrono::Utc::now().timestamp() + 900;
        store.update(&u).await.unwrap();
        let r = store.find_by_user_id(&created.user_id).await.unwrap();
        assert_eq!(r.failed_attempts, 5);
    }

    fn rand_suffix() -> u32 {
        use rand::Rng;
        rand::thread_rng().gen_range(0..1_000_000_000u32)
    }
}
