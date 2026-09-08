//! Distributor tests — acceptance: vendor outage triggers failover with
//! zero dropped transactions; no PIN leakage; fixed breaker parameters.

use std::sync::Arc;

use crate::{DistributorServiceImpl, DistributorState, MockVendor};

fn svc_with(primary: MockVendor, secondary: MockVendor) -> DistributorServiceImpl {
    let state = Arc::new(DistributorState::new(
        Arc::new(primary),
        Arc::new(secondary),
    ));
    DistributorServiceImpl::new(state)
}

fn healthy(name: &str) -> MockVendor {
    MockVendor {
        name: name.into(),
        always_fail: false,
        always_out_of_stock: false,
        latency: std::time::Duration::ZERO,
    }
}

#[tokio::test]
async fn primary_success_no_failover() {
    let s = svc_with(healthy("sellepins"), healthy("ewale"));
    let resp = s.acquire_pin("tx-1", "BECE").await.unwrap();
    let acquired = resp;
    assert_eq!(acquired.vendor, "sellepins");
    assert!(!acquired.failover_used);
    assert!(!acquired.pin.is_empty());
}

#[tokio::test]
async fn outage_reroutes_to_secondary_zero_drops() {
    // Primary hard-down (503s); secondary healthy.
    let s = svc_with(
        MockVendor {
            name: "sellepins".into(),
            always_fail: true,
            always_out_of_stock: false,
            latency: std::time::Duration::ZERO,
        },
        healthy("ewale"),
    );
    // First request already reroutes — no dropped transaction.
    let resp = s.acquire_pin("tx-2", "WASSCE_SC").await.unwrap();
    let acquired = resp;
    assert_eq!(acquired.vendor, "ewale");
    assert!(acquired.failover_used);
}

#[tokio::test]
async fn out_of_stock_reroutes() {
    let s = svc_with(
        MockVendor {
            name: "sellepins".into(),
            always_fail: false,
            always_out_of_stock: true,
            latency: std::time::Duration::ZERO,
        },
        healthy("ghvouchers"),
    );
    let resp = s.acquire_pin("tx-3", "BECE").await.unwrap();
    let acquired = resp;
    assert_eq!(acquired.vendor, "ghvouchers");
    assert!(acquired.failover_used);
}

#[tokio::test]
async fn timeout_reroutes() {
    // Primary sleeps past the 3000ms budget → Timeout classification.
    let s = svc_with(
        MockVendor {
            name: "slow".into(),
            always_fail: false,
            always_out_of_stock: false,
            latency: std::time::Duration::from_millis(3500),
        },
        healthy("ewale"),
    );
    let resp = s.acquire_pin("tx-4", "WASSCE_PRIVATE").await.unwrap();
    let acquired = resp;
    assert_eq!(acquired.vendor, "ewale");
    assert!(acquired.failover_used);
}

#[tokio::test]
async fn primary_circuit_opens_after_three_failures_then_skips_directly() {
    let s = svc_with(
        MockVendor {
            name: "sellepins".into(),
            always_fail: true,
            always_out_of_stock: false,
            latency: std::time::Duration::ZERO,
        },
        healthy("ewale"),
    );

    // Burn 3 primary failures via direct calls.
    for _ in 0..crate::breaker::FAILURE_THRESHOLD {
        let _ = s
            .try_vendor(
                &s.state.vendors.primary,
                &s.state.vendors.primary_breaker,
                "BECE",
            )
            .await;
    }
    assert_eq!(
        s.state.vendors.primary_breaker.state().await,
        crate::breaker::CircuitState::Open
    );

    // Subsequent requests still SUCCEED via secondary (zero drops) and the
    // primary is skipped (circuit open — no additional attempts on it).
    let resp = s.acquire_pin("tx-5", "BECE").await.unwrap();
    let acquired = resp;
    assert_eq!(acquired.vendor, "ewale");
    assert!(acquired.failover_used);
}

#[tokio::test]
async fn both_vendors_down_fails_cleanly() {
    let s = svc_with(
        MockVendor {
            name: "a".into(),
            always_fail: true,
            always_out_of_stock: false,
            latency: std::time::Duration::ZERO,
        },
        MockVendor {
            name: "b".into(),
            always_fail: true,
            always_out_of_stock: false,
            latency: std::time::Duration::ZERO,
        },
    );
    let err = s.acquire_pin("tx-6", "BECE").await.unwrap_err();
    assert_eq!(err.code, waec_common::ErrorCode::VendorsOutOfStock);
}

#[tokio::test]
async fn pins_are_unique_per_request() {
    let s = svc_with(healthy("sellepins"), healthy("ewale"));
    let r1 = s.acquire_pin("tx-7", "BECE").await.unwrap();
    let r2 = s.acquire_pin("tx-8", "BECE").await.unwrap();
    let p1 = r1.pin;
    let p2 = r2.pin;
    assert_ne!(p1, p2);
}
