//! Argon2id password hashing (plan §2.1: Argon2id credentials).
//!
//! Parameters follow OWASP guidance: m=19456 KiB (19 MiB), t=2, p=1.

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

/// Errors from password hashing/verification.
#[derive(Debug, thiserror::Error)]
pub enum PasswordError {
    #[error("hash formatting invalid: {0}")]
    InvalidHash(String),
    #[error("password mismatch")]
    Mismatch,
}

/// Hash a password with Argon2id. Output is a PHC-format string that
/// embeds algorithm, parameters, salt and hash.
pub fn hash_password(password: &str) -> Result<String, PasswordError> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| PasswordError::InvalidHash(e.to_string()))
}

/// Verify a password against a stored PHC hash. Constant-time comparison
/// is provided by the underlying implementation.
pub fn verify_password(password: &str, phc_hash: &str) -> Result<(), PasswordError> {
    let parsed =
        PasswordHash::new(phc_hash).map_err(|e| PasswordError::InvalidHash(e.to_string()))?;
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .map_err(|_| PasswordError::Mismatch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_then_verify_ok() {
        let h = hash_password("correct horse battery staple").unwrap();
        assert!(h.starts_with("$argon2id$"));
        verify_password("correct horse battery staple", &h).unwrap();
    }

    #[test]
    fn wrong_password_rejected() {
        let h = hash_password("hunter2").unwrap();
        assert!(matches!(
            verify_password("hunter3", &h),
            Err(PasswordError::Mismatch)
        ));
    }

    #[test]
    fn hashes_are_salted_unique() {
        let a = hash_password("same").unwrap();
        let b = hash_password("same").unwrap();
        assert_ne!(a, b, "salts must differ between hashes");
    }

    #[test]
    fn malformed_hash_rejected() {
        assert!(matches!(
            verify_password("x", "not-a-phc-hash"),
            Err(PasswordError::InvalidHash(_))
        ));
    }
}
