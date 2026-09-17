//! Payment service — plan §2.2.
//!
//! Paystack Ghana charge init for MoMo/Telecel/AT/cards; dynamic GHS
//! pricing; HMAC SHA-512 webhook verification; X-Idempotency-Key
//! enforcement — duplicate keys return the original outcome, never
//! double-charge (hard rule 3 / §4.9).

pub mod mock_mint;
pub mod paystack;
pub mod svc;

use std::sync::Arc;

pub use paystack::{ChargeMetadata, ChargeRequest, PaystackTransport, base_price_pesewas};
use waec_common::DomainError;
use waec_common::idempotency::{IdempotencyStore, InMemoryIdempotencyStore};

/// Shared state.
pub struct PaymentState {
    pub transport: Arc<dyn PaystackTransport>,
    pub idempotency: Arc<dyn IdempotencyStore>,
    /// HMAC secret for webhook verification (never logged).
    pub webhook_secret: String,
}

impl PaymentState {
    pub fn new(
        transport: Arc<dyn PaystackTransport>,
        idempotency: Arc<dyn IdempotencyStore>,
        webhook_secret: String,
    ) -> Self {
        Self {
            transport,
            idempotency,
            webhook_secret,
        }
    }
}

/// Mock transport for tests: succeeds unless configured to fail. Counts
/// invocations so §4.9 tests can prove a retry storm charges once.
#[derive(Default)]
pub struct MockTransport {
    pub fail: bool,
    pub calls: std::sync::atomic::AtomicUsize,
}

#[async_trait::async_trait]
impl PaystackTransport for MockTransport {
    async fn initialize_transaction(
        &self,
        req: &ChargeRequest<'_>,
    ) -> Result<paystack::ChargeData, DomainError> {
        self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if self.fail {
            return Err(DomainError::new(
                waec_common::ErrorCode::PaymentDeclined,
                "declined",
            ));
        }
        Ok(paystack::ChargeData {
            status: "pending".into(),
            display_text: Some("Approve on your phone".into()),
            authorization_url: Some(format!("https://checkout.paystack.com/{}", req.reference)),
        })
    }
}

/// Binary entry point.
pub fn run() {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        waec_common::telemetry::init_telemetry("payment", "info", false);
        let secret = std::env::var("PAYSTACK_SECRET").unwrap_or_else(|_| "sk_test_dev".into());
        let webhook =
            std::env::var("PAYSTACK_WEBHOOK_SECRET").unwrap_or_else(|_| "whsec_dev".into());
        let mock_minting = std::env::var("MOCK_MINTING").as_deref() != Ok("0");
        let state = Arc::new(PaymentState::new(
            Arc::new(paystack::PaystackHttp {
                secret,
                base_url: "https://api.paystack.co".into(),
                http: reqwest::Client::new(),
            }),
            Arc::new(InMemoryIdempotencyStore::default()),
            webhook,
        ));

        // Requirement 4: dynamic pricing from the database. Neon takes
        // precedence over the compose-internal Postgres (see .env.example).
        // A DB outage degrades to the static table — pricing must never take
        // the payment path down.
        let database_url = std::env::var("NEON_DATABASE_URL")
            .or_else(|_| std::env::var("DATABASE_URL"))
            .ok();
        let pricing = match database_url {
            Some(url) => match waec_data::connect_pool(&url).await {
                Ok(pool) => {
                    if let Err(e) = waec_data::run_migrations(&pool).await {
                        tracing::warn!(error = %e, "migrations failed — serving static pricing");
                        None
                    } else {
                        tracing::info!("dynamic pricing enabled (Postgres/Neon)");
                        Some(Arc::new(waec_data::pricing::PgPricingStore::new(pool)))
                    }
                }
                Err(e) => {
                    tracing::warn!(error = %e, "database unreachable — serving static pricing");
                    None
                }
            },
            None => {
                tracing::info!("no DATABASE_URL — serving static pricing");
                None
            }
        };

        match pricing {
            Some(store) => svc::serve_with_pricing(state, store, 50052).await,
            None => svc::serve(state, 50052).await,
        }
        .expect("payment server");

        if mock_minting {
            tracing::info!("mock checker minting enabled (local test phase)");
        }
    });
}

/// Serve with standard health checks.
pub async fn serve(state: Arc<PaymentState>, port: u16) -> Result<(), Box<dyn std::error::Error>> {
    svc::serve(state, port).await
}

#[cfg(test)]
mod svc_tests;
