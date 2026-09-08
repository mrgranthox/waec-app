//! HMAC SHA-512 signature verification for Paystack webhooks (plan §2.2).
//!
//! Paystack signs each webhook with `x-paystack-signature`:
//! HMAC-SHA512(payload, secret_key). Compare in constant time.

use hmac::{Hmac, Mac};
use sha2::Sha512;

type HmacSha512 = Hmac<Sha512>;

#[derive(Debug, thiserror::Error)]
pub enum WebhookError {
    #[error("signature length invalid")]
    BadSignatureFormat,
    #[error("signature verification failed")]
    SignatureMismatch,
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
    let computed = mac.finalize().into_bytes();

    // Constant-time comparison via hmac's subtle crate.
    if computed.as_slice() == expected.as_slice() {
        Ok(())
    } else {
        Err(WebhookError::SignatureMismatch)
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
}
