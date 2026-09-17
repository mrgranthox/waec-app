//! RS256 JWT issuance and verification with `kid`-based key rotation.
//!
//! Access tokens are short-lived (≤ 15 min per plan §2.1); refresh tokens
//! are longer-lived and rotate on use.

use jsonwebtoken::{
    Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, decode_header, encode,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Maximum access-token lifetime (plan §2.1: expiry ≤ 15 min).
pub const ACCESS_TOKEN_TTL_SECS: i64 = 15 * 60;
/// Refresh token lifetime: 30 days.
pub const REFRESH_TOKEN_TTL_SECS: i64 = 30 * 24 * 3600;
/// Issuer claim used across the platform.
pub const ISSUER: &str = "waec-platform-auth";

#[derive(Debug, Error)]
pub enum JwtError {
    #[error("token expired")]
    Expired,
    #[error("invalid token: {0}")]
    Invalid(#[from] jsonwebtoken::errors::Error),
    #[error("unknown key id: {0}")]
    UnknownKid(String),
    #[error("missing kid header")]
    MissingKid,
    #[error("invalid claims")]
    InvalidClaims,
}

/// Claims carried by every platform token.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    /// Subject — user id.
    pub sub: String,
    /// Key id used to sign this token (rotation support).
    #[serde(rename = "kid")]
    pub kid: String,
    /// Issuer.
    pub iss: String,
    /// Expiry (unix seconds).
    pub exp: i64,
    /// Issued-at (unix seconds).
    pub iat: i64,
    /// Token kind.
    pub kind: TokenKind,
    /// RBAC role (plan §2.5). Defaults to candidate for legacy tokens.
    #[serde(default)]
    pub role: super::Role,
    /// Unique token id — guarantees refresh-rotation emits distinct pairs
    /// even within the same second.
    #[serde(default)]
    pub jti: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenKind {
    Access,
    Refresh,
}

/// In-memory signing key set supporting rotation: new keys are appended
/// with a fresh `kid`; old keys remain valid for verification until pruned.
#[derive(Clone)]
pub struct KeyStore {
    encoding: EncodingKey,
    kid: String,
    decoding: Vec<(String, DecodingKey)>,
}

impl std::fmt::Debug for KeyStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyStore")
            .field("kid", &self.kid)
            .field("rotated_keys", &self.decoding.len())
            .finish()
    }
}

impl KeyStore {
    /// Build a keystore from PEM-encoded RSA key pair.
    pub fn from_pem(kid: &str, private_pem: &[u8], public_pem: &[u8]) -> Result<Self, JwtError> {
        Ok(Self {
            encoding: EncodingKey::from_rsa_pem(private_pem)?,
            kid: kid.to_string(),
            decoding: vec![(kid.to_string(), DecodingKey::from_rsa_pem(public_pem)?)],
        })
    }

    /// Current key id.
    pub fn active_kid(&self) -> &str {
        &self.kid
    }

    /// Register an older public key so tokens signed before rotation stay
    /// verifiable during the overlap window.
    pub fn add_verification_key(&mut self, kid: &str, public_pem: &[u8]) -> Result<(), JwtError> {
        let dk = DecodingKey::from_rsa_pem(public_pem)?;
        self.decoding.push((kid.to_string(), dk));
        Ok(())
    }

    /// Sign claims into a compact RS256 JWT. The `kid` header carries the
    /// signing key id for rotation.
    pub fn sign(&self, mut claims: Claims) -> Result<String, JwtError> {
        claims.iss = ISSUER.to_string();
        let header = Header {
            alg: Algorithm::RS256,
            kid: Some(self.kid.clone()),
            ..Default::default()
        };
        Ok(encode(&header, &claims, &self.encoding)?)
    }

    /// Verify a JWT: checks kid, signature, issuer, expiry and token kind.
    pub fn verify(&self, token: &str) -> Result<Claims, JwtError> {
        let header = decode_header(token)?;
        let kid = header.kid.ok_or(JwtError::MissingKid)?;

        let decoding = self
            .decoding
            .iter()
            .find(|(k, _)| *k == kid)
            .map(|(_, dk)| dk)
            .ok_or(JwtError::UnknownKid(kid))?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[ISSUER]);
        validation.validate_exp = true;

        let data = decode::<Claims>(token, decoding, &validation)?;
        Ok(data.claims)
    }

    /// Verify and additionally require a specific token kind.
    pub fn verify_kind(&self, token: &str, kind: TokenKind) -> Result<Claims, JwtError> {
        let claims = self.verify(token)?;
        if claims.kind != kind {
            return Err(JwtError::InvalidClaims);
        }
        Ok(claims)
    }
}

fn claims_with_jti(mut c: Claims) -> Claims {
    c.jti = uuid::Uuid::new_v4().to_string();
    c
}

/// Build access-token claims for a user.
pub fn access_claims(sub: &str, now: i64) -> Claims {
    claims_with_jti(Claims {
        sub: sub.to_string(),
        kid: String::new(),
        iss: ISSUER.to_string(),
        iat: now,
        exp: now + ACCESS_TOKEN_TTL_SECS,
        kind: TokenKind::Access,
        role: super::Role::Candidate,
        jti: String::new(),
    })
}

/// Build access-token claims with an explicit role (Admin service).
pub fn access_claims_with_role(sub: &str, now: i64, role: super::Role) -> Claims {
    let mut c = access_claims(sub, now);
    c.role = role;
    c
}

/// Build refresh-token claims for a user.
pub fn refresh_claims(sub: &str, now: i64) -> Claims {
    claims_with_jti(Claims {
        sub: sub.to_string(),
        kid: String::new(),
        iss: ISSUER.to_string(),
        iat: now,
        exp: now + REFRESH_TOKEN_TTL_SECS,
        kind: TokenKind::Refresh,
        role: super::Role::Candidate,
        jti: String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_PRIV: &str = include_str!("../tests/fixtures/test_rsa_key.pem");
    const TEST_PUB: &str = include_str!("../tests/fixtures/test_rsa_key.pub.pem");
    const NEW_PRIV: &str = include_str!("../tests/fixtures/test_rsa_key_2.pem");
    const NEW_PUB: &str = include_str!("../tests/fixtures/test_rsa_key_2.pub.pem");

    fn keystore() -> KeyStore {
        KeyStore::from_pem("k1", TEST_PRIV.as_bytes(), TEST_PUB.as_bytes()).unwrap()
    }

    #[test]
    fn access_round_trip() {
        let ks = keystore();
        let now = chrono::Utc::now().timestamp();
        let token = ks.sign(access_claims("user-123", now)).unwrap();
        // kid lives in the JWT header for rotation
        let header = jsonwebtoken::decode_header(&token).unwrap();
        assert_eq!(header.kid.as_deref(), Some("k1"));
        let claims = ks.verify_kind(&token, TokenKind::Access).unwrap();
        assert_eq!(claims.sub, "user-123");
        assert_eq!(claims.exp - claims.iat, ACCESS_TOKEN_TTL_SECS);
    }

    #[test]
    fn refresh_round_trip() {
        let ks = keystore();
        let now = chrono::Utc::now().timestamp();
        let token = ks.sign(refresh_claims("user-9", now)).unwrap();
        let claims = ks.verify_kind(&token, TokenKind::Refresh).unwrap();
        assert_eq!(claims.exp - claims.iat, REFRESH_TOKEN_TTL_SECS);
    }

    #[test]
    fn refresh_token_rejected_as_access() {
        let ks = keystore();
        let now = chrono::Utc::now().timestamp();
        let token = ks.sign(refresh_claims("user-9", now)).unwrap();
        assert!(ks.verify_kind(&token, TokenKind::Access).is_err());
    }

    #[test]
    fn expired_token_rejected() {
        let ks = keystore();
        let past = chrono::Utc::now().timestamp() - 3600;
        let token = ks.sign(access_claims("user-1", past)).unwrap();
        assert!(ks.verify(&token).is_err());
    }

    #[test]
    fn tampered_token_rejected() {
        let ks = keystore();
        let now = chrono::Utc::now().timestamp();
        let mut token = ks.sign(access_claims("user-1", now)).unwrap();
        let mid = token.len() / 2;
        let replacement = if &token[mid..mid + 1] == "A" {
            "B"
        } else {
            "A"
        };
        token.replace_range(mid..mid + 1, replacement);
        assert!(ks.verify(&token).is_err());
    }

    #[test]
    fn wrong_algorithm_rejected() {
        let other = jsonwebtoken::encode(
            &jsonwebtoken::Header::new(Algorithm::HS256),
            &serde_json::json!({"sub": "x", "iss": ISSUER}),
            &jsonwebtoken::EncodingKey::from_secret(b"evil"),
        )
        .unwrap();
        assert!(keystore().verify(&other).is_err());
    }

    #[test]
    fn rotation_old_key_still_verifies() {
        let now = chrono::Utc::now().timestamp();

        // Sign with the OLD (currently active) key.
        let ks_old = keystore();
        let old_token = ks_old.sign(access_claims("user-1", now)).unwrap();

        // Rotate: new key becomes active, old public key retained.
        let ks_new_base =
            KeyStore::from_pem("k2", NEW_PRIV.as_bytes(), NEW_PUB.as_bytes()).unwrap();
        let mut ks_rotated = ks_old.clone();
        ks_rotated.encoding = ks_new_base.encoding.clone();
        ks_rotated.kid = "k2".to_string();
        ks_rotated
            .add_verification_key("k1", TEST_PUB.as_bytes())
            .unwrap();

        // Old token still verifies via retained k1 verification key.
        assert!(ks_rotated.verify(&old_token).is_ok());
        // New tokens carry k2 in the header.
        let new_token = ks_rotated.sign(access_claims("user-2", now)).unwrap();
        let header = jsonwebtoken::decode_header(&new_token).unwrap();
        assert_eq!(header.kid.as_deref(), Some("k2"));
    }

    #[test]
    fn unknown_kid_rejected() {
        let ks = keystore();
        let token = "eyJhbGciOiJSUzI1NiIsImtpZCI6Im5vcmVmeiJ9.eyJzdWIiOiJ4In0.sig";
        assert!(ks.verify(token).is_err());
    }
}
