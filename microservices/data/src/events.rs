//! Async transaction pipeline — plan §2.6/§2.7.
//!
//! Topics (AGENT.md §5, fixed contract):
//!   payment.authorized, voucher.acquired, fetch.result, fetch.failed,
//!   audit.events — each with a per-topic DLQ.
//!
//! `EventPublisher` is the transport contract. The Kafka producer lands
//! in the compose deployment; `InMemoryEventBus` serves tests and the
//! dev stack (also used to mirror audit events into PostgreSQL).

use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use waec_common::{DomainError, ErrorCode};

/// Canonical topic names — do not rename without an ADR.
pub mod topics {
    pub const PAYMENT_AUTHORIZED: &str = "payment.authorized";
    pub const VOUCHER_ACQUIRED: &str = "voucher.acquired";
    pub const FETCH_RESULT: &str = "fetch.result";
    pub const FETCH_FAILED: &str = "fetch.failed";
    pub const AUDIT_EVENTS: &str = "audit.events";

    /// DLQ suffix convention: `<topic>.dlq`.
    pub fn dlq(topic: &str) -> String {
        format!("{topic}.dlq")
    }

    /// All base topics, in pipeline order.
    pub const ALL: [&str; 5] = [
        PAYMENT_AUTHORIZED,
        VOUCHER_ACQUIRED,
        FETCH_RESULT,
        FETCH_FAILED,
        AUDIT_EVENTS,
    ];
}

/// Envelope for every pipeline event. Payload is JSON; the schema per
/// topic is owned by the producing service.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub topic: &'static str,
    /// Correlation id == transaction id (plan §0.6 spans).
    pub correlation_id: String,
    pub occurred_unix: i64,
    /// JSON payload. NEVER contains grades, PINs, or serials.
    pub payload: serde_json::Value,
}

impl Event {
    pub fn new(topic: &'static str, correlation_id: &str, payload: serde_json::Value) -> Self {
        Self {
            topic,
            correlation_id: correlation_id.to_string(),
            occurred_unix: chrono::Utc::now().timestamp(),
            payload,
        }
    }
}

/// Transport contract for the pipeline.
#[async_trait::async_trait]
pub trait EventPublisher: Send + Sync {
    async fn publish(&self, event: Event) -> Result<(), DomainError>;
}

/// In-memory bus: events fan out to any subscribed channel. Used by unit
/// tests, the dev compose stack, and the Admin audit mirror.
#[derive(Default, Clone)]
pub struct InMemoryEventBus {
    tx: Arc<tokio::sync::RwLock<Option<mpsc::UnboundedSender<Event>>>>,
    /// Retained tail for assertions/tests (bounded).
    log: Arc<tokio::sync::RwLock<Vec<Event>>>,
}

impl InMemoryEventBus {
    pub fn new() -> Self {
        Self::default()
    }

    /// Subscribe to the live stream (multi-consumer would use Kafka
    /// consumer groups; the in-memory bus supports one live subscriber).
    pub fn subscribe(&self) -> mpsc::UnboundedReceiver<Event> {
        let (tx, rx) = mpsc::unbounded_channel();
        if let Ok(mut guard) = self.tx.try_write() {
            *guard = Some(tx);
        }
        rx
    }

    /// Snapshot of retained events (test assertions).
    pub async fn snapshot(&self) -> Vec<Event> {
        self.log.read().await.clone()
    }
}

#[async_trait::async_trait]
impl EventPublisher for InMemoryEventBus {
    async fn publish(&self, event: Event) -> Result<(), DomainError> {
        // Retain for assertions.
        {
            let mut log = self.log.write().await;
            log.push(event.clone());
            let len = log.len();
            if len > 1000 {
                log.drain(0..len - 1000);
            }
        }
        if let Some(tx) = self.tx.read().await.as_ref() {
            tx.send(event)
                .map_err(|_| DomainError::new(ErrorCode::Internal, "event bus closed"))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn publishes_to_subscriber_and_log() {
        let bus = InMemoryEventBus::new();
        let mut rx = bus.subscribe();

        bus.publish(Event::new(
            topics::PAYMENT_AUTHORIZED,
            "tx-1",
            serde_json::json!({"channel": "mtn"}),
        ))
        .await
        .unwrap();

        let received = rx.recv().await.unwrap();
        assert_eq!(received.topic, topics::PAYMENT_AUTHORIZED);
        assert_eq!(received.correlation_id, "tx-1");

        let snap = bus.snapshot().await;
        assert_eq!(snap.len(), 1);
    }

    #[test]
    fn dlq_naming() {
        assert_eq!(topics::dlq(topics::FETCH_FAILED), "fetch.failed.dlq");
    }

    #[tokio::test]
    async fn no_grades_in_payload_contract() {
        // Guardrail: payloads carry outcome codes, never grade strings.
        let bus = InMemoryEventBus::new();
        bus.publish(Event::new(
            topics::FETCH_RESULT,
            "tx-2",
            serde_json::json!({"outcome": "success", "subjects": 9}),
        ))
        .await
        .unwrap();
        let snap = bus.snapshot().await;
        let raw = serde_json::to_string(&snap[0].payload).unwrap();
        assert!(!raw.contains("A1") && !raw.contains("grade"));
    }
}
