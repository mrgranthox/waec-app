//! Vendor abstraction (SellePins primary / Ewale secondary — plan §2.3).
//!
//! The trait keeps the service testable: unit tests inject canned
//! adapters; production wires HTTP clients per vendor contract.

use async_trait::async_trait;
use waec_common::{DomainError, ErrorCode};

/// A Just-in-Time acquired voucher PIN. NEVER log this (hard rule 1).
#[derive(Debug, Clone)]
pub struct Voucher {
    pub pin: String,
    pub serial: String,
}

/// Outcome of an acquire attempt against one vendor.
#[derive(Debug)]
pub enum VendorOutcome {
    Acquired(Voucher),
    /// Vendor explicitly out of stock (counts toward breaker threshold).
    OutOfStock,
}

/// One vendor adapter.
#[async_trait]
pub trait VendorClient: Send + Sync {
    fn name(&self) -> &str;
    async fn acquire(&self, exam_type: &str) -> Result<VendorOutcome, DomainError>;
}

/// Mock/fixture vendor for tests and the dev compose mock.
pub struct MockVendor {
    pub name: String,
    /// When true, always return 503-style errors.
    pub always_fail: bool,
    /// When true, always return OUT_OF_STOCK.
    pub always_out_of_stock: bool,
    /// Simulated latency (set > 3000ms to trigger timeout classification).
    pub latency: std::time::Duration,
}

#[async_trait]
impl VendorClient for MockVendor {
    fn name(&self) -> &str {
        &self.name
    }

    async fn acquire(&self, _exam_type: &str) -> Result<VendorOutcome, DomainError> {
        if self.latency > std::time::Duration::ZERO {
            tokio::time::sleep(self.latency).await;
        }
        if self.always_fail {
            return Err(DomainError::new(ErrorCode::Internal, "vendor 503"));
        }
        if self.always_out_of_stock {
            return Ok(VendorOutcome::OutOfStock);
        }
        Ok(VendorOutcome::Acquired(Voucher {
            pin: format!("PIN-{}-{}", self.name, uuid::Uuid::new_v4()),
            serial: format!("SER-{}-{}", self.name, uuid::Uuid::new_v4()),
        }))
    }
}
