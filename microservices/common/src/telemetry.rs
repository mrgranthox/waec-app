//! Telemetry: `tracing` initialisation with correlation IDs (plan §0.6).
//!
//! Services initialise this once at startup; spans propagate correlation
//! IDs across gRPC boundaries via the standard `tracing` context.

use tracing_subscriber::fmt;
use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

/// Initialise global tracing with JSON output and env-filtered levels.
///
/// `RUST_LOG` overrides `default_level` when set.
/// JSON is used in production for Loki ingestion; human format suits dev.
pub fn init_telemetry(service_name: &str, default_level: &str, json: bool) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(format!("{default_level},hyper=warn,tonic=warn")));

    let registry = tracing_subscriber::registry().with(filter);

    if json {
        registry
            .with(
                fmt::layer()
                    .json()
                    .with_current_span(true)
                    .with_span_list(false)
                    .with_target(true)
                    .with_thread_ids(false)
                    .with_file(false)
                    .with_line_number(false)
                    .with_current_span(true),
            )
            .init();
    } else {
        registry
            .with(fmt::layer().with_target(true).compact())
            .init();
    }

    tracing::info!(service = service_name, "telemetry initialised");
}

/// Convenience guard for tests that need logging without panicking on
/// double-init (already-set global subscriber is ignored).
pub fn init_telemetry_for_tests(service_name: &str) {
    let _ = tracing_subscriber::fmt::try_init();
    tracing::debug!(service = service_name, "test telemetry ready");
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_init_does_not_panic() {
        super::init_telemetry_for_tests("test-service");
    }
}
