//! HMAC SHA-512 signature verification for Paystack webhooks (plan §2.2,
//! §4.5). Paystack signs each webhook with `x-paystack-signature`:
//! HMAC-SHA512(payload, secret_key). Compare in constant time.
//!
//! Replay window (plan §4.5 "HMAC SHA-512 signature verification +
//! timestamp window"): a valid signature proves authenticity but not
//! freshness — a captured webhook replayed hours later would still
//! verify. Callers therefore pass the event timestamp from the delivery
//! envelope; it must fall inside [`MAX_SKEW_SECS`] of "now". Forged
//! webhooks fail the signature check; replayed genuine webhooks fail the
//! freshness window.

use hmac::{Hmac, Mac};
use sha2::Sha512;

type HmacSha512 = Hmac<Sha512>;

/// Accepted clock skew for a webhook event. Older than this ⇒ replay.
pub const MAX_SKEW_SECS: i64 = 5 * 60;

#[derive(Debug, thiserror::Error)]
pub enum WebhookError {
    #[error("signature length invalid")]
    BadSignatureFormat,
    #[error("signature verification failed")]
    SignatureMismatch,
    #[error("event timestamp outside replay window")]
    StaleTimestamp,
    #[error("event timestamp required in strict mode")]
    MissingTimestamp,
    #[error("hmac init failed")]
    Init,
}

/// Verify a Paystack webhook signature against the raw body.
pub fn verify_paystack_signature(
    secret: &str,
    raw_body: &[u8],
    signature_hex: &str,
) -> Result<(), WebhookError> {
    let expected = hex::decode(signature_hex).map_err(|_| WebhookError::BadSignatureFormat)?;

    let mut mac = HmacSha512::new_from_slice(secret.as_bytes()).map_err(|_| WebhookError::Init)?;
    mac.update(raw_body);

    // Constant-time verification. `verify_slice` compares without
    // short-circuiting on the first differing byte; plain `==` on slices
    // leaks how many leading bytes of a forged tag match the real one.
    mac.verify_slice(&expected)
        .map_err(|_| WebhookError::SignatureMismatch)
}

/// Signature + freshness window (plan §4.5).
///
/// * `event_unix` — timestamp carried by the delivery envelope (Paystack
///   events expose `createdAt`; the edge facade lifts it here).
/// * `now_unix` — receiver clock.
/// * `strict` — when true, a missing/unparsable timestamp is itself a
///   rejection (deployments that always receive an envelope timestamp
///   should set this).
pub fn verify_webhook_fresh(
    secret: &str,
    raw_body: &[u8],
    signature_hex: &str,
    event_unix: Option<i64>,
    now_unix: i64,
    strict: bool,
) -> Result<(), WebhookError> {
    verify_paystack_signature(secret, raw_body, signature_hex)?;
    match event_unix {
        Some(ts) if (now_unix - ts).abs() <= MAX_SKEW_SECS => Ok(()),
        Some(_) => Err(WebhookError::StaleTimestamp),
        None if strict => Err(WebhookError::MissingTimestamp),
        None => Ok(()),
    }
}

/// Compute the signature for a body (used by tests + mock servers).
pub fn compute_paystack_signature(secret: &str, raw_body: &[u8]) -> String {
    let mut mac = HmacSha512::new_from_slice(secret.as_bytes()).expect("hmac accepts any key len");
    mac.update(raw_body);
    hex::encode(mac.finalize().into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "whsec_test_secret";

    #[test]
    fn valid_signature_passes() {
        let body = br#"{"event":"charge.success","data":{"reference":"ref-1"}}"#;
        let sig = compute_paystack_signature(SECRET, body);
        assert!(verify_paystack_signature(SECRET, body, &sig).is_ok());
    }

    #[test]
    fn forged_body_rejected() {
        let body = br#"{"event":"charge.success","data":{"reference":"ref-1"}}"#;
        let sig = compute_paystack_signature(SECRET, body);
        let tampered = br#"{"event":"charge.success","data":{"reference":"ref-2"}}"#;
        assert!(matches!(
            verify_paystack_signature(SECRET, tampered, &sig),
            Err(WebhookError::SignatureMismatch)
        ));
    }

    #[test]
    fn wrong_secret_rejected() {
        let body = br#"{}"#;
        let sig = compute_paystack_signature("other-secret", body);
        assert!(verify_paystack_signature(SECRET, body, &sig).is_err());
    }

    #[test]
    fn malformed_hex_rejected() {
        assert!(matches!(
            verify_paystack_signature(SECRET, b"{}", "not-hex!"),
            Err(WebhookError::BadSignatureFormat)
        ));
    }

    // ── §4.5 timestamp window ───────────────────────────────────────────

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn fresh_event_inside_window_accepted() {
        let body = br#"{"event":"charge.success"}"#;
        let sig = compute_paystack_signature(SECRET, body);
        for skew in [0i64, 60, MAX_SKEW_SECS, -MAX_SKEW_SECS] {
            assert!(
                verify_webhook_fresh(SECRET, body, &sig, Some(NOW + skew), NOW, true).is_ok(),
                "skew {skew}s must be accepted"
            );
        }
    }

    #[test]
    fn replayed_event_outside_window_rejected() {
        let body = br#"{"event":"charge.success"}"#;
        let sig = compute_paystack_signature(SECRET, body);
        // Delivered 6 minutes after the event — replay.
        assert!(matches!(
            verify_webhook_fresh(SECRET, body, &sig, Some(NOW - MAX_SKEW_SECS - 1), NOW, true),
            Err(WebhookError::StaleTimestamp)
        ));
        // Clock far in the future is equally untrustworthy.
        assert!(matches!(
            verify_webhook_fresh(SECRET, body, &sig, Some(NOW + MAX_SKEW_SECS + 1), NOW, true),
            Err(WebhookError::StaleTimestamp)
        ));
    }

    #[test]
    fn forged_webhook_rejected_even_when_fresh() {
        let body = br#"{"event":"charge.success","data":{"amount":100}}"#;
        let forged_sig = compute_paystack_signature("attacker", body);
        assert!(matches!(
            verify_webhook_fresh(SECRET, body, &forged_sig, Some(NOW), NOW, true),
            Err(WebhookError::SignatureMismatch)
        ));
    }

    #[test]
    fn missing_timestamp_policy_is_configurable() {
        let body = br#"{"event":"charge.success"}"#;
        let sig = compute_paystack_signature(SECRET, body);
        // Lax facade: signature-only acceptance.
        assert!(verify_webhook_fresh(SECRET, body, &sig, None, NOW, false).is_ok());
        // Strict facade: envelope timestamp is mandatory.
        assert!(matches!(
            verify_webhook_fresh(SECRET, body, &sig, None, NOW, true),
            Err(WebhookError::MissingTimestamp)
        ));
    }
}
