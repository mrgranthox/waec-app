//! Circuit breaker — plan §2.3 / §4.4 with FIXED parameters (AGENT.md §4.9):
//! 3 consecutive HTTP errors, timeout >3000ms, or OUT_OF_STOCK
//! → open for 3 minutes → 100% reroute to secondary vendor.
//! Parameters must not be "tuned" without an ADR.

use std::time::{Duration, Instant};
use tokio::sync::RwLock;

/// Consecutive failures before the circuit opens.
pub const FAILURE_THRESHOLD: u32 = 3;
/// How long the circuit stays open.
pub const OPEN_DURATION: Duration = Duration::from_secs(180);
/// Vendor call budget (>3000ms counts as a timeout failure).
pub const CALL_TIMEOUT: Duration = Duration::from_millis(3000);

/// Trigger classification for observability.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    HttpError,
    Timeout,
    OutOfStock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    Closed,
    Open,
    /// Open duration elapsed; allow one probe (half-open).
    HalfOpen,
}

/// Circuit breaker for ONE vendor. Two instances = primary + secondary.
pub struct CircuitBreaker {
    state: RwLock<Inner>,
}

#[derive(Debug)]
struct Inner {
    consecutive_failures: u32,
    opened_at: Option<Instant>,
}

impl Default for CircuitBreaker {
    fn default() -> Self {
        Self::new()
    }
}

impl CircuitBreaker {
    pub fn new() -> Self {
        Self {
            state: RwLock::new(Inner {
                consecutive_failures: 0,
                opened_at: None,
            }),
        }
    }

    /// Whether a call may proceed right now.
    pub async fn allow_call(&self) -> bool {
        let s = self.state.read().await;
        match s.opened_at {
            None => true,                                      // closed
            Some(opened) => opened.elapsed() >= OPEN_DURATION, // half-open probe
        }
    }

    /// Current state (Admin §2.5 metrics/alerts consume this).
    pub async fn state(&self) -> CircuitState {
        let s = self.state.read().await;
        match s.opened_at {
            None => CircuitState::Closed,
            Some(opened) => {
                if opened.elapsed() >= OPEN_DURATION {
                    CircuitState::HalfOpen
                } else {
                    CircuitState::Open
                }
            }
        }
    }

    /// Record a success: reset counters, close the circuit.
    pub async fn record_success(&self) {
        let mut s = self.state.write().await;
        s.consecutive_failures = 0;
        s.opened_at = None;
    }

    /// Record a classified failure; opens the circuit at the threshold.
    pub async fn record_failure(&self, _kind: FailureKind) {
        let mut s = self.state.write().await;
        s.consecutive_failures += 1;
        if s.consecutive_failures >= FAILURE_THRESHOLD {
            // (Re)open — a probe failure re-opens for another full window.
            s.opened_at = Some(Instant::now());
        }
    }

    /// Whether a failure at this instant is due to an exceeded timeout.
    pub fn is_timeout(elapsed: Duration) -> bool {
        elapsed > CALL_TIMEOUT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn closed_allows_calls() {
        let cb = CircuitBreaker::new();
        assert!(cb.allow_call().await);
        assert_eq!(cb.state().await, CircuitState::Closed);
    }

    #[tokio::test]
    async fn opens_after_three_consecutive_failures() {
        let cb = CircuitBreaker::new();
        cb.record_failure(FailureKind::HttpError).await;
        cb.record_failure(FailureKind::HttpError).await;
        assert!(cb.allow_call().await, "below threshold still closed");
        cb.record_failure(FailureKind::HttpError).await;
        assert!(!cb.allow_call().await, "3rd failure opens circuit");
        assert_eq!(cb.state().await, CircuitState::Open);
    }

    #[tokio::test]
    async fn success_resets_counter() {
        let cb = CircuitBreaker::new();
        cb.record_failure(FailureKind::HttpError).await;
        cb.record_failure(FailureKind::Timeout).await;
        cb.record_success().await;
        cb.record_failure(FailureKind::HttpError).await;
        cb.record_failure(FailureKind::HttpError).await;
        assert!(cb.allow_call().await, "counter reset on success");
    }

    #[tokio::test]
    async fn out_of_stock_counts_as_failure() {
        let cb = CircuitBreaker::new();
        for _ in 0..FAILURE_THRESHOLD {
            cb.record_failure(FailureKind::OutOfStock).await;
        }
        assert!(!cb.allow_call().await);
    }

    #[tokio::test]
    async fn half_open_after_window_elapsed() {
        let cb = CircuitBreaker::new();
        for _ in 0..FAILURE_THRESHOLD {
            cb.record_failure(FailureKind::HttpError).await;
        }
        assert_eq!(cb.state().await, CircuitState::Open);
        {
            let mut s = cb.state.write().await;
            s.opened_at = Some(Instant::now() - OPEN_DURATION - Duration::from_secs(1));
        }
        assert_eq!(cb.state().await, CircuitState::HalfOpen);
        assert!(cb.allow_call().await, "half-open allows a probe");
    }

    #[tokio::test]
    async fn probe_failure_reopens_full_window() {
        let cb = CircuitBreaker::new();
        for _ in 0..FAILURE_THRESHOLD {
            cb.record_failure(FailureKind::HttpError).await;
        }
        {
            let mut s = cb.state.write().await;
            s.opened_at = Some(Instant::now() - OPEN_DURATION - Duration::from_secs(1));
        }
        cb.record_failure(FailureKind::HttpError).await;
        assert_eq!(cb.state().await, CircuitState::Open);
        assert!(!cb.allow_call().await);
    }

    #[test]
    fn timeout_classification() {
        assert!(CircuitBreaker::is_timeout(Duration::from_millis(3500)));
        assert!(!CircuitBreaker::is_timeout(Duration::from_millis(2000)));
    }
}
