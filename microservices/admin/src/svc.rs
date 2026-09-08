//! AdminService gRPC — plan §2.5.
//!
//! RBAC: every privileged call verifies the JWT and requires role=Admin;
//! anything else → 403 (PermissionDenied). Audit queries surface metadata
//! only. DOM-drift alerts increment a counter for Prometheus and are
//! recorded for routing.

// tonic::Status is large but is the canonical error type at gRPC
// boundaries; boxing it would only add indirection.
#![allow(clippy::result_large_err)]

use std::sync::Arc;

use tonic::{Request, Response, Status};

use waec_common::jwt::TokenKind;
use waec_common::pb::waec::admin::v1::admin_service_server::AdminService;
use waec_common::pb::waec::admin::v1::{
    AuditEntry, HealthRequest, HealthResponse, QueryAuditLogRequest, QueryAuditLogResponse,
    ReportDomDriftRequest, ReportDomDriftResponse,
};
use waec_common::{DomainError, ErrorCode};

use crate::AdminState;

pub struct AdminServiceImpl {
    state: Arc<AdminState>,
}

impl AdminServiceImpl {
    pub fn new(state: Arc<AdminState>) -> Self {
        Self { state }
    }

    /// Verify Bearer token and require the Admin role (plan §2.5).
    fn require_admin(&self, token: &str) -> Result<String, Status> {
        let claims = self
            .state
            .keystore
            .verify_kind(token, TokenKind::Access)
            .map_err(DomainError::from)?;
        if claims.role != waec_common::Role::Admin {
            return Err(
                DomainError::new(ErrorCode::InsufficientRole, "admin role required").to_status(),
            );
        }
        Ok(claims.sub)
    }
}

#[tonic::async_trait]
impl AdminService for AdminServiceImpl {
    async fn health(
        &self,
        _request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse {
            ready: true,
            version: env!("CARGO_PKG_VERSION").into(),
        }))
    }

    async fn query_audit_log(
        &self,
        request: Request<QueryAuditLogRequest>,
    ) -> Result<Response<QueryAuditLogResponse>, Status> {
        let req = request.into_inner();
        // RBAC: metadata queries are admin-only.
        self.require_admin(&req.admin_token)?;

        let rows = self
            .state
            .audit
            .query(
                if req.index_number.is_empty() {
                    None
                } else {
                    Some(&req.index_number)
                },
                req.from_unix,
                req.to_unix,
                req.limit,
            )
            .await
            .map_err(|e| e.to_status())?;

        Ok(Response::new(QueryAuditLogResponse {
            entries: rows
                .into_iter()
                .map(|r| AuditEntry {
                    transaction_id: r.transaction_id,
                    index_number: r.index_number,
                    exam_type: r.exam_type,
                    outcome: r.outcome,
                    occurred_unix: r.occurred_unix,
                })
                .collect(),
        }))
    }

    async fn report_dom_drift(
        &self,
        request: Request<ReportDomDriftRequest>,
    ) -> Result<Response<ReportDomDriftResponse>, Status> {
        let req = request.into_inner();
        self.state
            .drift_alerts
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        // Alert payload carries NO candidate data (selectors only).
        tracing::error!(
            portal = %req.portal_host,
            exam = %req.exam_type,
            expected = %req.schema_version_expected,
            observed = %req.observed_signature,
            "DOM-DRIFT ALERT routed to engineering"
        );

        Ok(Response::new(ReportDomDriftResponse { alert_fired: true }))
    }
}

/// Serve with standard health checks.
pub async fn serve(state: Arc<AdminState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<waec_common::pb::waec::admin::v1::admin_service_server::AdminServiceServer<AdminServiceImpl>>()
        .await;

    let svc = waec_common::pb::waec::admin::v1::admin_service_server::AdminServiceServer::new(
        AdminServiceImpl::new(state),
    );

    tracing::info!(%port, "admin service listening");
    tonic::transport::Server::builder()
        .add_service(health_service)
        .add_service(svc)
        .serve(addr)
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::{AuditEntry as DomainAuditEntry, InMemoryAuditStore};
    use tonic::Request;
    use waec_common::jwt::{access_claims_with_role, KeyStore};
    use waec_common::pb::waec::admin::v1::admin_service_server::AdminService as AdminServiceTrait;
    use waec_common::pb::waec::admin::v1::{HealthRequest, QueryAuditLogRequest};

    fn keystore() -> KeyStore {
        KeyStore::from_pem(
            "k1",
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pem").as_slice(),
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pub.pem").as_slice(),
        )
        .unwrap()
    }

    fn svc() -> AdminServiceImpl {
        AdminServiceImpl::new(Arc::new(AdminState::new(
            keystore(),
            Arc::new(InMemoryAuditStore::default()),
        )))
    }

    fn admin_token(ks: &KeyStore) -> String {
        let now = chrono::Utc::now().timestamp();
        ks.sign(access_claims_with_role(
            "admin-1",
            now,
            waec_common::Role::Admin,
        ))
        .unwrap()
    }

    fn candidate_token(ks: &KeyStore) -> String {
        let now = chrono::Utc::now().timestamp();
        ks.sign(access_claims_with_role(
            "cand-1",
            now,
            waec_common::Role::Candidate,
        ))
        .unwrap()
    }

    #[tokio::test]
    async fn health_is_open() {
        let s = svc();
        let r = s
            .health(Request::new(HealthRequest {}))
            .await
            .unwrap()
            .into_inner();
        assert!(r.ready);
    }

    #[tokio::test]
    async fn admin_token_can_query_audit() {
        let s = svc();
        let ks = keystore();
        let token = admin_token(&ks);
        let resp = s
            .query_audit_log(Request::new(QueryAuditLogRequest {
                admin_token: token,
                index_number: String::new(),
                from_unix: 0,
                to_unix: 9999,
                limit: 10,
            }))
            .await
            .unwrap();
        assert_eq!(resp.into_inner().entries.len(), 0);
    }

    #[tokio::test]
    async fn non_admin_token_is_denied() {
        let s = svc();
        let ks = keystore();
        let token = candidate_token(&ks);
        let err = s
            .query_audit_log(Request::new(QueryAuditLogRequest {
                admin_token: token,
                index_number: String::new(),
                from_unix: 0,
                to_unix: 9999,
                limit: 10,
            }))
            .await
            .unwrap_err();
        // Plan acceptance: non-admin token → 403 (PermissionDenied).
        assert_eq!(err.code(), tonic::Code::PermissionDenied);
    }

    #[tokio::test]
    async fn invalid_token_is_unauthenticated() {
        let s = svc();
        let err = s
            .query_audit_log(Request::new(QueryAuditLogRequest {
                admin_token: "garbage".into(),
                index_number: String::new(),
                from_unix: 0,
                to_unix: 9999,
                limit: 10,
            }))
            .await
            .unwrap_err();
        assert_eq!(err.code(), tonic::Code::Unauthenticated);
    }

    #[tokio::test]
    async fn dom_drift_increments_alert_counter() {
        let s = svc();
        let before = s
            .state
            .drift_alerts
            .load(std::sync::atomic::Ordering::Relaxed);
        let resp = s
            .report_dom_drift(Request::new(ReportDomDriftRequest {
                portal_host: "eresults.waecgh.org".into(),
                exam_type: "BECE".into(),
                schema_version_expected: "v1".into(),
                observed_signature: "sig-changed".into(),
            }))
            .await
            .unwrap()
            .into_inner();
        assert!(resp.alert_fired);
        let after = s
            .state
            .drift_alerts
            .load(std::sync::atomic::Ordering::Relaxed);
        assert_eq!(after - before, 1);
    }

    #[tokio::test]
    async fn audit_query_returns_recorded_rows() {
        let state = Arc::new(AdminState::new(
            keystore(),
            Arc::new(InMemoryAuditStore::default()),
        ));
        state
            .audit
            .record(DomainAuditEntry {
                transaction_id: "t1".into(),
                index_number: "1002330440".into(),
                exam_type: "BECE".into(),
                outcome: "success".into(),
                occurred_unix: chrono::Utc::now().timestamp(),
            })
            .await
            .unwrap();
        let s = AdminServiceImpl::new(state.clone());
        let ks = keystore();
        let resp = s
            .query_audit_log(Request::new(QueryAuditLogRequest {
                admin_token: admin_token(&ks),
                index_number: "1002330440".into(),
                from_unix: 0,
                to_unix: chrono::Utc::now().timestamp() + 10,
                limit: 10,
            }))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(resp.entries.len(), 1);
        assert_eq!(resp.entries[0].transaction_id, "t1");
    }
}
