//! Integration-style unit tests for the Auth service (plan §2.1).

use std::sync::Arc;

use tonic::Request;

use crate::svc::AuthServiceImpl;
use crate::{AuthState, InMemoryUserStore, UserStore, MAX_FAILED_ATTEMPTS};
use waec_common::jwt::KeyStore;
// Trait import brings the gRPC methods (register/login/…) into scope.
use waec_common::pb::waec::auth::v1::auth_service_server::AuthService;
use waec_common::pb::waec::auth::v1::{
    BindBiometricRequest, LoginRequest, RefreshRequest, RegisterRequest,
};

fn test_state() -> Arc<AuthState> {
    let keystore = KeyStore::from_pem(
        "k1",
        include_bytes!("../../common/tests/fixtures/test_rsa_key.pem").as_slice(),
        include_bytes!("../../common/tests/fixtures/test_rsa_key.pub.pem").as_slice(),
    )
    .unwrap();
    Arc::new(AuthState::new(Arc::new(InMemoryUserStore::new()), keystore))
}

fn svc() -> AuthServiceImpl {
    AuthServiceImpl::new(test_state())
}

fn req<T>(t: T) -> Request<T> {
    Request::new(t)
}

#[tokio::test]
async fn register_login_round_trip() {
    let s = svc();
    s.register(req(RegisterRequest {
        index_number: "1002330440".into(),
        password: "password123".into(),
    }))
    .await
    .unwrap();

    let resp = s
        .login(req(LoginRequest {
            index_number: "1002330440".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap()
        .into_inner();

    assert!(!resp.access_token.is_empty());
    // Access token expiry is ≤ 15 min per plan (exactly 900s here).
    assert_eq!(
        resp.access_expires_at_unix - chrono::Utc::now().timestamp(),
        900
    );
}

#[tokio::test]
async fn register_rejects_bad_index() {
    let s = svc();
    let err = s
        .register(req(RegisterRequest {
            index_number: "12345".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::InvalidArgument);
}

#[tokio::test]
async fn duplicate_registration_rejected() {
    let s = svc();
    let r = RegisterRequest {
        index_number: "1002330441".into(),
        password: "password123".into(),
    };
    s.register(req(r.clone())).await.unwrap();
    assert!(s.register(req(r)).await.is_err());
}

#[tokio::test]
async fn wrong_password_rejected_uniformly() {
    let s = svc();
    s.register(req(RegisterRequest {
        index_number: "1002330442".into(),
        password: "password123".into(),
    }))
    .await
    .unwrap();

    // Unknown account and wrong password must produce identical errors
    // (no account-existence oracle).
    let wrong_pw = s
        .login(req(LoginRequest {
            index_number: "1002330442".into(),
            password: "wrongpass99".into(),
        }))
        .await
        .unwrap_err();
    let no_user = s
        .login(req(LoginRequest {
            index_number: "9999999999".into(),
            password: "whatever1".into(),
        }))
        .await
        .unwrap_err();
    assert_eq!(wrong_pw.code(), no_user.code());
    assert_eq!(wrong_pw.message(), no_user.message());
}

#[tokio::test]
async fn brute_force_lockout_after_5_failures() {
    let s = svc();
    s.register(req(RegisterRequest {
        index_number: "1002330443".into(),
        password: "password123".into(),
    }))
    .await
    .unwrap();

    for _ in 0..MAX_FAILED_ATTEMPTS {
        let _ = s
            .login(req(LoginRequest {
                index_number: "1002330443".into(),
                password: "nope-nope".into(),
            }))
            .await;
    }
    // Even the CORRECT password is rejected while locked out.
    let err = s
        .login(req(LoginRequest {
            index_number: "1002330443".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::ResourceExhausted);
}

#[tokio::test]
async fn refresh_rotates_pair() {
    let s = svc();
    let registered = s
        .register(req(RegisterRequest {
            index_number: "1002330444".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap()
        .into_inner();

    let refreshed = s
        .refresh(req(RefreshRequest {
            refresh_token: registered.refresh_token,
        }))
        .await
        .unwrap()
        .into_inner();

    // New access token differs and verifies as Access kind.
    assert_ne!(refreshed.access_token, registered.access_token);
    let claims = s
        .state
        .keystore
        .verify_kind(&refreshed.access_token, waec_common::jwt::TokenKind::Access)
        .unwrap();
    assert!(!claims.sub.is_empty());
}

#[tokio::test]
async fn refresh_with_access_token_rejected() {
    let s = svc();
    let registered = s
        .register(req(RegisterRequest {
            index_number: "1002330445".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap()
        .into_inner();

    // An ACCESS token must NOT work as a refresh token.
    assert!(s
        .refresh(req(RefreshRequest {
            refresh_token: registered.access_token,
        }))
        .await
        .is_err());
}

#[tokio::test]
async fn biometric_binding() {
    let s = svc();
    let registered = s
        .register(req(RegisterRequest {
            index_number: "1002330446".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap()
        .into_inner();

    let resp = s
        .bind_biometric(req(BindBiometricRequest {
            access_token: registered.access_token,
            platform_public_key: "MIIBIjANBgkq".into(),
        }))
        .await
        .unwrap()
        .into_inner();
    assert!(resp.bound);
}

// ── §4.6: race-safe lockout under credential stuffing ──────────────────────

/// A credential-stuffing storm must still lock the account.
///
/// With a naive read-modify-write counter, N concurrent failures each read the
/// same value, each write `n+1`, and the account never reaches the threshold.
/// `record_failure` holds the store's write lock across increment + arm-lock,
/// so every increment is counted exactly once.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn credential_stuffing_storm_still_locks_account() {
    let s = Arc::new(svc());
    s.register(req(RegisterRequest {
        index_number: "1002330500".into(),
        password: "password123".into(),
    }))
    .await
    .unwrap();

    // Fire far more failures than the threshold, all at once.
    let storm = 40;
    let mut tasks = Vec::with_capacity(storm);
    for i in 0..storm {
        let s = Arc::clone(&s);
        tasks.push(tokio::spawn(async move {
            s.login(req(LoginRequest {
                index_number: "1002330500".into(),
                password: format!("guessed-wrong-{i}"),
            }))
            .await
        }));
    }
    let mut codes = std::collections::HashSet::new();
    for t in tasks {
        // Every response is bad-credentials or locked — never a token.
        codes.insert(
            t.await
                .unwrap()
                .map_or_else(|e| e.code(), |_| tonic::Code::Ok),
        );
    }
    assert!(
        !codes.contains(&tonic::Code::Ok),
        "storm must never authenticate, got {codes:?}"
    );

    // The decisive assertion: the lock is armed, so even the REAL password now
    // fails. Losing increments would have left the account unlocked here.
    let err = s
        .login(req(LoginRequest {
            index_number: "1002330500".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap_err();
    // AuthLockedOut maps to ResourceExhausted: the client should retry later.
    assert_eq!(err.code(), tonic::Code::ResourceExhausted);
}

/// Both commit orders must end with the account locked.
///
/// A request that verified the correct password *before* another request armed
/// the lock may not silently cancel that lockout, and a clearing request that
/// lands first must not prevent a later failure from locking. Because each
/// store method holds the write lock across its whole read-modify-write, the
/// outcome is order-independent — which is exactly what this pins down.
#[tokio::test]
async fn lockout_and_success_commit_atomically_in_both_orders() {
    async fn fresh_store() -> Arc<InMemoryUserStore> {
        let store = Arc::new(InMemoryUserStore::new());
        store
            .create(
                "1002330501",
                &waec_common::password::hash_password("password123").unwrap(),
            )
            .await
            .unwrap();
        store
    }

    // threshold 1 → a single failure arms a 900s lock at now = 1_000.
    const NOW: i64 = 1_000;

    // Order A: failure arms the lock, then a racing success tries to clear it.
    let store = fresh_store().await;
    assert!(
        store
            .record_failure("1002330501", NOW, 1, 900)
            .await
            .unwrap(),
        "failure at threshold must arm the lock"
    );
    assert!(
        !store.succeed_login("1002330501", NOW).await.unwrap(),
        "a success while locked must be refused, not applied"
    );
    assert!(
        store
            .find_by_index("1002330501")
            .await
            .unwrap()
            .locked_until
            > NOW,
        "lock must survive a racing success"
    );

    // Order B: the success lands first (counters clear), the late failure still
    // reaches the threshold and locks.
    let store = fresh_store().await;
    assert!(
        store.succeed_login("1002330501", NOW).await.unwrap(),
        "an unlocked account may clear its counters"
    );
    assert!(
        store
            .record_failure("1002330501", NOW, 1, 900)
            .await
            .unwrap(),
        "late failure must still lock"
    );
    assert!(
        store
            .find_by_index("1002330501")
            .await
            .unwrap()
            .locked_until
            > NOW,
        "late failure must have armed the lock"
    );
}

/// Locked account + correct password through the service: refused, and the
/// refusal is the same code whether the caller's password was right or wrong
/// once locked (no "you'd have gotten in" oracle is needed beyond lock state).
#[tokio::test]
async fn locked_account_rejects_correct_password() {
    let s = svc();
    s.register(req(RegisterRequest {
        index_number: "1002330502".into(),
        password: "password123".into(),
    }))
    .await
    .unwrap();

    for i in 0..MAX_FAILED_ATTEMPTS {
        let _ = s
            .login(req(LoginRequest {
                index_number: "1002330502".into(),
                password: format!("nope-{i}"),
            }))
            .await;
    }

    let err = s
        .login(req(LoginRequest {
            index_number: "1002330502".into(),
            password: "password123".into(),
        }))
        .await
        .unwrap_err();
    assert_eq!(err.code(), tonic::Code::ResourceExhausted);
}
