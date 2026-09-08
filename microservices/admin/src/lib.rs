//! Admin service — plan §2.5.
//!
//! RBAC endpoints (non-admin token → 403), transaction audit-log queries
//! (metadata only — no grades per hard rule 2), health/readiness, and
//! DOM-drift alert routing.

pub mod audit;
pub mod svc;

use std::sync::Arc;

use waec_common::jwt::KeyStore;

/// Shared state.
pub struct AdminState {
    pub keystore: KeyStore,
    pub audit: Arc<dyn audit::AuditStore>,
    /// Number of DOM-drift alerts fired (Prometheus gauge source).
    pub drift_alerts: Arc<std::sync::atomic::AtomicU64>,
}

impl AdminState {
    pub fn new(keystore: KeyStore, audit: Arc<dyn audit::AuditStore>) -> Self {
        Self {
            keystore,
            audit,
            drift_alerts: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        }
    }
}

/// Binary entry point.
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("admin", "info", false);
        let keystore = waec_common::jwt::KeyStore::from_pem(
            "k1",
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pem").as_slice(),
            include_bytes!("../../common/tests/fixtures/test_rsa_key.pub.pem").as_slice(),
        )
        .expect("JWT keystore");
        let state = Arc::new(AdminState::new(
            keystore,
            Arc::new(audit::InMemoryAuditStore::default()),
        ));
        svc::serve(state, 50055).await.expect("admin server");
    });
}
