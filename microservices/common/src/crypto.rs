//! AES-256-GCM encryption engine with dynamic 96-bit IVs.
//!
//! Security contract:
//! - A fresh random 96-bit IV is generated for **every** encryption call
//!   (never reused with the same key — GCM IV reuse is catastrophic).
//! - Authentication tag verified on decrypt; any tampering returns an error.
//! - Key material is zeroized on drop.

use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use rand::RngCore;
use thiserror::Error;
use zeroize::Zeroizing;

/// Size of the AES-GCM nonce in bytes (96 bits per plan spec).
pub const NONCE_SIZE: usize = 12;
/// AES-256 key size in bytes.
pub const KEY_SIZE: usize = 32;
/// GCM authentication tag size appended to ciphertext.
pub const TAG_SIZE: usize = 16;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("plaintext too short to contain IV + tag")]
    PayloadTooShort,
    #[error("decryption failed: payload tampered or wrong key")]
    DecryptionFailed,
    #[error("invalid key length {0}, expected {KEY_SIZE}")]
    InvalidKeyLength(usize),
    #[error("ciphertext serialization failed")]
    Serialization,
}

/// Result envelope produced by [`CryptoEngine::encrypt`].
///
/// Wire layout: `iv (12B) || ciphertext+tag`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncryptedPayload {
    pub bytes: Vec<u8>,
}

impl EncryptedPayload {
    pub fn to_hex(&self) -> String {
        hex::encode(&self.bytes)
    }

    pub fn from_hex(s: &str) -> Result<Self, CryptoError> {
        let bytes = hex::decode(s).map_err(|_| CryptoError::Serialization)?;
        Ok(Self { bytes })
    }
}

/// AES-256-GCM engine. Cloneable; the key is zeroized when the last
/// handle drops.
///
/// `_key` is retained solely to guarantee zeroize-on-drop semantics for
/// the key material the cipher derives its schedule from.
#[derive(Clone)]
pub struct CryptoEngine {
    cipher: Aes256Gcm,
    _key: Zeroizing<Vec<u8>>,
}

impl std::fmt::Debug for CryptoEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CryptoEngine").finish_non_exhaustive()
    }
}

impl CryptoEngine {
    /// Build an engine from raw 32-byte key material.
    pub fn new(key: &[u8]) -> Result<Self, CryptoError> {
        if key.len() != KEY_SIZE {
            return Err(CryptoError::InvalidKeyLength(key.len()));
        }
        let key = Zeroizing::new(key.to_vec());
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key.as_slice()));
        Ok(Self { cipher, _key: key })
    }

    /// Generate a cryptographically random key.
    pub fn generate_key() -> Zeroizing<Vec<u8>> {
        let mut buf = vec![0u8; KEY_SIZE];
        OsRng.fill_bytes(&mut buf);
        Zeroizing::new(buf)
    }

    /// Encrypt `plaintext` with a freshly generated 96-bit IV.
    ///
    /// Output layout: `iv (12B) || ciphertext || tag (16B)`.
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<EncryptedPayload, CryptoError> {
        let mut iv = [0u8; NONCE_SIZE];
        OsRng.fill_bytes(&mut iv);
        let nonce = Nonce::from_slice(&iv);

        let ciphertext = self
            .cipher
            .encrypt(nonce, plaintext)
            .map_err(|_| CryptoError::Serialization)?;

        let mut bytes = Vec::with_capacity(NONCE_SIZE + ciphertext.len());
        bytes.extend_from_slice(&iv);
        bytes.extend_from_slice(&ciphertext);
        Ok(EncryptedPayload { bytes })
    }

    /// Decrypt a payload produced by [`encrypt`](Self::encrypt).
    pub fn decrypt(&self, payload: &EncryptedPayload) -> Result<Vec<u8>, CryptoError> {
        if payload.bytes.len() < NONCE_SIZE + TAG_SIZE {
            return Err(CryptoError::PayloadTooShort);
        }
        let (iv, ciphertext) = payload.bytes.split_at(NONCE_SIZE);
        let nonce = Nonce::from_slice(iv);
        self.cipher
            .decrypt(nonce, ciphertext)
            .map_err(|_| CryptoError::DecryptionFailed)
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn engine() -> CryptoEngine {
        CryptoEngine::new(&[7u8; KEY_SIZE]).unwrap()
    }

    #[test]
    fn round_trip() {
        let e = engine();
        let msg = b"WASSCE index 1002330440055, year 2025";
        let ct = e.encrypt(msg).unwrap();
        let pt = e.decrypt(&ct).unwrap();
        assert_eq!(pt, msg);
    }

    #[test]
    fn empty_plaintext_round_trip() {
        let e = engine();
        let ct = e.encrypt(b"").unwrap();
        assert_eq!(e.decrypt(&ct).unwrap(), b"");
    }

    #[test]
    fn tamper_detection() {
        let e = engine();
        let mut ct = e.encrypt(b"sensitive grades").unwrap();
        let last = ct.bytes.len() - 1;
        ct.bytes[last] ^= 0x01;
        assert!(matches!(e.decrypt(&ct), Err(CryptoError::DecryptionFailed)));
    }

    #[test]
    fn tampered_iv_detected() {
        let e = engine();
        let mut ct = e.encrypt(b"x").unwrap();
        ct.bytes[0] ^= 0xff;
        assert!(e.decrypt(&ct).is_err());
    }

    #[test]
    fn nonce_uniqueness_10k() {
        let e = engine();
        let mut seen = HashSet::with_capacity(10_000);
        for _ in 0..10_000 {
            let ct = e.encrypt(b"nonce check").unwrap();
            let iv = &ct.bytes[..NONCE_SIZE];
            assert!(seen.insert(iv.to_vec()), "IV reuse detected!");
        }
        assert_eq!(seen.len(), 10_000);
    }

    #[test]
    fn wrong_key_fails() {
        let e1 = CryptoEngine::new(&[1u8; KEY_SIZE]).unwrap();
        let e2 = CryptoEngine::new(&[2u8; KEY_SIZE]).unwrap();
        let ct = e1.encrypt(b"secret").unwrap();
        assert!(e2.decrypt(&ct).is_err());
    }

    #[test]
    fn rejects_short_key() {
        assert!(matches!(
            CryptoEngine::new(&[0u8; 16]),
            Err(CryptoError::InvalidKeyLength(16))
        ));
    }

    #[test]
    fn hex_round_trip() {
        let e = engine();
        let ct = e.encrypt(b"hex test").unwrap();
        let hex = ct.to_hex();
        let back = EncryptedPayload::from_hex(&hex).unwrap();
        assert_eq!(e.decrypt(&back).unwrap(), b"hex test");
    }

    #[test]
    fn truncated_payload_rejected() {
        let e = engine();
        let payload = EncryptedPayload { bytes: vec![0u8; 10] };
        assert!(matches!(e.decrypt(&payload), Err(CryptoError::PayloadTooShort)));
    }
}
