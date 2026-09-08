//! Auth service — plan §2.1.
//!
//! Registration, login, Argon2id verification, RS256 JWT issuance +
//! refresh rotation, biometric token binding.
//! Acceptance: brute-force lockout; JWT expiry ≤ 15 min; refresh rotation.
//! Hard rule 1: passwords are never logged; only Argon2id hashes stored.

pub mod store;
pub mod svc;

use std::sync::Arc;

pub use store::{InMemoryUserStore, SharedUserStore, UserRecord, UserStore};

/// Brute-force lockout policy (plan §4.6).
pub const MAX_FAILED_ATTEMPTS: u32 = 5;
/// Lockout window after max failures.
pub const LOCKOUT_SECS: i64 = 15 * 60;

/// Shared service state.
pub struct AuthState {
    pub users: SharedUserStore,
    pub keystore: waec_common::jwt::KeyStore,
}

impl AuthState {
    pub fn new(users: SharedUserStore, keystore: waec_common::jwt::KeyStore) -> Self {
        Self { users, keystore }
    }
}

/// Entry point for the standalone binary (src/bin/auth.rs).
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("auth", "info", false);
        // Test fixtures here; production loads real keys via SOPS secrets.
        let keystore = waec_common::jwt::KeyStore::from_pem(
            "k1",
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pem").as_slice(),
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pub.pem").as_slice(),
        )
        .expect("JWT keystore");
        let state = Arc::new(AuthState::new(Arc::new(InMemoryUserStore::new()), keystore));
        svc::serve(state, 50051).await.expect("auth server");
    });
}

#[cfg(test)]
mod svc_tests;
