//! AuthService gRPC implementation (plan §2.1).
//!
//! Flow rules:
//! - Register: index must be exactly 10 digits (hard validation).
//! - Login: verify Argon2id hash; 5 consecutive failures → 15 min lockout.
//! - Refresh: rotation — old token invalidated by issuing a fresh pair.
//! - Biometric: binds platform keystore public key to the account.

// tonic::Status is large but canonical at gRPC boundaries.
#![allow(clippy::result_large_err)]

use std::sync::Arc;

use tonic::{Request, Response, Status};

use waec_common::pb::waec::auth::v1::auth_service_server::AuthService;
use waec_common::pb::waec::auth::v1::{
    AuthResponse, BindBiometricRequest, BindBiometricResponse, LoginRequest, RefreshRequest,
    RegisterRequest,
};
use waec_common::{DomainError, ErrorCode};

use crate::store::StoreError;
use crate::{AuthState, LOCKOUT_SECS, MAX_FAILED_ATTEMPTS};

pub struct AuthServiceImpl {
    pub(crate) state: Arc<AuthState>,
}

impl AuthServiceImpl {
    pub fn new(state: Arc<AuthState>) -> Self {
        Self { state }
    }

    fn now() -> i64 {
        chrono::Utc::now().timestamp()
    }

    fn auth_response(&self, user_id: &str) -> Result<AuthResponse, DomainError> {
        let now = Self::now();
        let access = self
            .state
            .keystore
            .sign(waec_common::jwt::access_claims(user_id, now))?;
        let refresh = self
            .state
            .keystore
            .sign(waec_common::jwt::refresh_claims(user_id, now))?;
        Ok(AuthResponse {
            access_token: access,
            refresh_token: refresh,
            access_expires_at_unix: now + waec_common::jwt::ACCESS_TOKEN_TTL_SECS,
            user_id: user_id.to_string(),
        })
    }
}

#[tonic::async_trait]
impl AuthService for AuthServiceImpl {
    async fn register(
        &self,
        request: Request<RegisterRequest>,
    ) -> Result<Response<AuthResponse>, Status> {
        let req = request.into_inner();

        if !waec_common::is_valid_index_number(&req.index_number) {
            return Err(DomainError::new(
                ErrorCode::InvalidIndexNumber,
                "index number must be exactly 10 digits",
            )
            .into());
        }
        if req.password.len() < 8 {
            return Err(DomainError::new(
                ErrorCode::InvalidExamParams,
                "password must be at least 8 characters",
            )
            .into());
        }

        let hash = waec_common::password::hash_password(&req.password)
            .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;

        let user = match self.state.users.create(&req.index_number, &hash).await {
            Ok(u) => u,
            Err(StoreError::DuplicateIndex) => {
                return Err(DomainError::new(
                    ErrorCode::InvalidIndexNumber,
                    "index number already registered",
                )
                .into());
            }
            Err(e) => return Err(DomainError::new(ErrorCode::Internal, e.to_string()).into()),
        };

        tracing::info!(user_id = %user.user_id, "user registered");
        Ok(Response::new(self.auth_response(&user.user_id)?))
    }

    async fn login(
        &self,
        request: Request<LoginRequest>,
    ) -> Result<Response<AuthResponse>, Status> {
        let req = request.into_inner();
        let now = Self::now();

        let mut user = match self.state.users.find_by_index(&req.index_number).await {
            Ok(u) => u,
            Err(_) => {
                // Uniform error — never reveal whether the account exists.
                return Err(DomainError::new(
                    ErrorCode::AuthInvalidCredentials,
                    "invalid credentials",
                )
                .into());
            }
        };

        // Lockout check (plan §4.6).
        if user.locked_until > now {
            return Err(DomainError::new(
                ErrorCode::AuthLockedOut,
                "account temporarily locked; try later",
            )
            .into());
        }

        match waec_common::password::verify_password(&req.password, &user.password_hash) {
            Ok(()) => {
                if user.failed_attempts != 0 || user.locked_until != 0 {
                    user.failed_attempts = 0;
                    user.locked_until = 0;
                    self.state
                        .users
                        .update(user.clone())
                        .await
                        .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;
                }
                tracing::info!(user_id = %user.user_id, "login ok");
                Ok(Response::new(self.auth_response(&user.user_id)?))
            }
            Err(_) => {
                user.failed_attempts += 1;
                if user.failed_attempts >= MAX_FAILED_ATTEMPTS {
                    user.locked_until = now + LOCKOUT_SECS;
                    user.failed_attempts = 0;
                    tracing::warn!(user_id = %user.user_id, "account locked out");
                }
                let _ = self.state.users.update(user).await;
                Err(
                    DomainError::new(ErrorCode::AuthInvalidCredentials, "invalid credentials")
                        .into(),
                )
            }
        }
    }

    async fn refresh(
        &self,
        request: Request<RefreshRequest>,
    ) -> Result<Response<AuthResponse>, Status> {
        let req = request.into_inner();
        // Rotation: verify the refresh token, then issue a fresh pair bound
        // to the same subject. (Revocation list lands with Postgres in 2.7.)
        let claims = self
            .state
            .keystore
            .verify_kind(&req.refresh_token, waec_common::jwt::TokenKind::Refresh)
            .map_err(DomainError::from)?;

        Ok(Response::new(self.auth_response(&claims.sub)?))
    }

    async fn bind_biometric(
        &self,
        request: Request<BindBiometricRequest>,
    ) -> Result<Response<BindBiometricResponse>, Status> {
        let req = request.into_inner();
        let claims = self
            .state
            .keystore
            .verify_kind(&req.access_token, waec_common::jwt::TokenKind::Access)
            .map_err(DomainError::from)?;

        // Resolve the account by JWT subject (user_id), not index.
        let mut user = self
            .state
            .users
            .find_by_user_id(&claims.sub)
            .await
            .map_err(|_| DomainError::new(ErrorCode::AuthTokenInvalid, "unknown subject"))?;
        user.biometric_public_key = Some(req.platform_public_key);
        self.state
            .users
            .update(user)
            .await
            .map_err(|e| DomainError::new(ErrorCode::Internal, e.to_string()))?;

        Ok(Response::new(BindBiometricResponse { bound: true }))
    }
}

/// Serve the gRPC service on the given port with standard health checks.
pub async fn serve(state: Arc<AuthState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::auth::v1::auth_service_server::AuthServiceServer<
            AuthServiceImpl,
        >>()
        .await;

    let svc = waec_common::pb::waec::auth::v1::auth_service_server::AuthServiceServer::new(
        AuthServiceImpl::new(state),
    );

    tracing::info!(%port, "auth service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}
