//! Integration-style unit tests for the Auth service (plan §2.1).

use std::sync::Arc;

use tonic::Request;

use crate::svc::AuthServiceImpl;
use crate::{AuthState, InMemoryUserStore, MAX_FAILED_ATTEMPTS};
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
