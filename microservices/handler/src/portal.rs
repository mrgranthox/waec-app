//! Portal HTTP client. Production egress goes through the residential
//! proxy pool (PROXY_POOL_URL); the pool rotator injects rotating West
//! African exit IPs + randomized TLS fingerprints (plan task 1.7).
//! Dev/test injects mock portals via the [`PortalClient`] trait.

use async_trait::async_trait;
use waec_common::{DomainError, ErrorCode, ExamType};

/// Raw portal response. `html` is transient — dropped after parse.
pub struct PortalResponse {
    pub html: String,
}

/// One WAEC portal transport.
#[async_trait]
pub trait PortalClient: Send + Sync {
    async fn fetch(
        &self,
        exam: ExamType,
        index_number: &str,
        exam_year: &str,
        voucher_pin: &str,
        directive: &crate::proxy::EgressDirective,
    ) -> Result<PortalResponse, DomainError>;
}

/// Live HTTP portal client through the proxy pool.
pub struct HttpPortal {
    /// Base URL of the rotator (e.g. http://proxy-rotator:8081). The
    /// rotator forwards to the selected portal host with a rotating
    /// residential exit IP.
    pub proxy_pool_url: String,
    pub http: reqwest::Client,
}

impl HttpPortal {
    pub fn from_env() -> Self {
        Self {
            proxy_pool_url: std::env::var("PROXY_POOL_URL")
                .unwrap_or_else(|_| "http://localhost:8081".into()),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()
                .expect("reqwest client"),
        }
    }

    fn portal_url(exam: ExamType) -> &'static str {
        match exam {
            ExamType::Bece | ExamType::WassceSchool => "https://eresults.waecgh.org",
            ExamType::WasscePrivate => "https://ghana.waecdirect.org",
        }
    }
}

#[async_trait::async_trait]
impl PortalClient for HttpPortal {
    async fn fetch(
        &self,
        exam: ExamType,
        index_number: &str,
        exam_year: &str,
        voucher_pin: &str,
        directive: &crate::proxy::EgressDirective,
    ) -> Result<PortalResponse, DomainError> {
        // The rotator is on the internal network; it applies the
        // directive's residential exit + TLS fingerprint and forwards to
        // the portal (plan §4.7). Direct portal URLs are never used here.
        let url = format!("{}/fetch", self.proxy_pool_url);
        let resp = self
            .http
            .post(&url)
            .json(&serde_json::json!({
                "target": Self::portal_url(exam),
                "exit": directive.exit.id,
                "tls_profile": directive.tls_profile.label(),
                "form": {
                    "indexNumber": index_number,
                    "examYear": exam_year,
                    "pin": voucher_pin,
                }
            }))
            .send()
            .await
            .map_err(|e| DomainError::new(ErrorCode::WaecPortalUnavailable, e.to_string()))?;

        if !resp.status().is_success() {
            return Err(DomainError::new(
                ErrorCode::WaecPortalUnavailable,
                format!("portal egress status {}", resp.status()),
            ));
        }

        let html = resp
            .text()
            .await
            .map_err(|e| DomainError::new(ErrorCode::WaecPortalUnavailable, e.to_string()))?;
        Ok(PortalResponse { html })
    }
}

/// Mock portal for tests — returns canned HTML or drift fixtures.
/// Records the directives it received so tests can assert rotation.
pub struct MockPortal {
    pub html_for: std::collections::HashMap<ExamType, String>,
    pub seen_directives: std::sync::Mutex<Vec<crate::proxy::EgressDirective>>,
}

impl MockPortal {
    pub fn new(html_for: std::collections::HashMap<ExamType, String>) -> Self {
        Self {
            html_for,
            seen_directives: std::sync::Mutex::new(Vec::new()),
        }
    }
}

#[async_trait::async_trait]
impl PortalClient for MockPortal {
    async fn fetch(
        &self,
        exam: ExamType,
        _index: &str,
        _year: &str,
        _pin: &str,
        directive: &crate::proxy::EgressDirective,
    ) -> Result<PortalResponse, DomainError> {
        self.seen_directives
            .lock()
            .expect("mock lock")
            .push(directive.clone());
        self.html_for
            .get(&exam)
            .cloned()
            .map(|html| PortalResponse { html })
            .ok_or_else(|| DomainError::new(ErrorCode::WaecPortalUnavailable, "no fixture"))
    }
}
