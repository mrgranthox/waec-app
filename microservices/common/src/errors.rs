//! Platform-wide error taxonomy.
//!
//! No service may use bare `String` errors (plan §0.5). Every error maps
//! to a gRPC status code and a machine-readable code for clients.

use thiserror::Error;

/// Machine-readable error codes surfaced to clients and logs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    InvalidIndexNumber,
    InvalidExamParams,
    UnsupportedExamType,
    PaymentDeclined,
    PaymentDuplicateIdempotencyKey,
    WebhookSignatureInvalid,
    WebhookReplayDetected,
    VendorsOutOfStock,
    VendorCircuitOpen,
    WaecPortalUnavailable,
    WaecDomSchemaDrift,
    NotFound,
    CandidateNotFound,
    GracePeriodExpired,
    AuthInvalidCredentials,
    AuthTokenExpired,
    AuthTokenInvalid,
    AuthLockedOut,
    InsufficientRole,
    RateLimited,
    Internal,
}

impl ErrorCode {
    /// Stable string code for API responses and logs.
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::InvalidIndexNumber => "INVALID_INDEX_NUMBER",
            ErrorCode::InvalidExamParams => "INVALID_EXAM_PARAMS",
            ErrorCode::UnsupportedExamType => "UNSUPPORTED_EXAM_TYPE",
            ErrorCode::PaymentDeclined => "PAYMENT_DECLINED",
            ErrorCode::PaymentDuplicateIdempotencyKey => "DUPLICATE_IDEMPOTENCY_KEY",
            ErrorCode::WebhookSignatureInvalid => "WEBHOOK_SIGNATURE_INVALID",
            ErrorCode::WebhookReplayDetected => "WEBHOOK_REPLAY_DETECTED",
            ErrorCode::VendorsOutOfStock => "VENDORS_OUT_OF_STOCK",
            ErrorCode::VendorCircuitOpen => "VENDOR_CIRCUIT_OPEN",
            ErrorCode::WaecPortalUnavailable => "WAEC_PORTAL_UNAVAILABLE",
            ErrorCode::WaecDomSchemaDrift => "WAEC_DOM_SCHEMA_DRIFT",
            ErrorCode::NotFound => "NOT_FOUND",
            ErrorCode::CandidateNotFound => "CANDIDATE_NOT_FOUND",
            ErrorCode::GracePeriodExpired => "GRACE_PERIOD_EXPIRED",
            ErrorCode::AuthInvalidCredentials => "AUTH_INVALID_CREDENTIALS",
            ErrorCode::AuthTokenExpired => "AUTH_TOKEN_EXPIRED",
            ErrorCode::AuthTokenInvalid => "AUTH_TOKEN_INVALID",
            ErrorCode::AuthLockedOut => "AUTH_LOCKED_OUT",
            ErrorCode::InsufficientRole => "INSUFFICIENT_ROLE",
            ErrorCode::RateLimited => "RATE_LIMITED",
            ErrorCode::Internal => "INTERNAL",
        }
    }

    /// Mapping to tonic gRPC status codes.
    pub fn to_grpc_code(self) -> tonic::Code {
        use tonic::Code;
        match self {
            ErrorCode::InvalidIndexNumber
            | ErrorCode::InvalidExamParams
            | ErrorCode::UnsupportedExamType => Code::InvalidArgument,
            ErrorCode::PaymentDeclined
            | ErrorCode::PaymentDuplicateIdempotencyKey
            | ErrorCode::VendorsOutOfStock
            | ErrorCode::NotFound
            | ErrorCode::CandidateNotFound
            | ErrorCode::GracePeriodExpired => Code::FailedPrecondition,
            ErrorCode::WebhookSignatureInvalid
            | ErrorCode::WebhookReplayDetected
            | ErrorCode::AuthInvalidCredentials
            | ErrorCode::AuthTokenExpired
            | ErrorCode::AuthTokenInvalid => Code::Unauthenticated,
            ErrorCode::AuthLockedOut | ErrorCode::RateLimited => Code::ResourceExhausted,
            ErrorCode::InsufficientRole => Code::PermissionDenied,
            ErrorCode::VendorCircuitOpen | ErrorCode::WaecPortalUnavailable => Code::Unavailable,
            ErrorCode::WaecDomSchemaDrift => Code::DataLoss,
            ErrorCode::Internal => Code::Internal,
        }
    }
}

/// The single error type every service returns.
#[derive(Debug, Error)]
#[error("{code:?}: {message}")]
pub struct DomainError {
    pub code: ErrorCode,
    pub message: String,
    /// True when the failure is retryable by the client.
    pub retryable: bool,
}

impl DomainError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: Self::default_retryable(code),
        }
    }

    /// Retry policy default per code (clients may still back off further).
    pub fn default_retryable(code: ErrorCode) -> bool {
        matches!(
            code,
            ErrorCode::WaecPortalUnavailable
                | ErrorCode::VendorCircuitOpen
                | ErrorCode::RateLimited
        )
    }

    /// Convert into a tonic `Status` for gRPC transport, preserving the
    /// machine-readable code in the details payload.
    pub fn to_status(&self) -> tonic::Status {
        let details = format!("{}|{}", self.code.as_str(), self.message);
        tonic::Status::with_details(
            self.code.to_grpc_code(),
            self.message.clone(),
            details.into(),
        )
    }
}

impl From<DomainError> for tonic::Status {
    fn from(e: DomainError) -> Self {
        e.to_status()
    }
}

impl From<crate::crypto::CryptoError> for DomainError {
    fn from(e: crate::crypto::CryptoError) -> Self {
        DomainError::new(ErrorCode::Internal, e.to_string())
    }
}

impl From<crate::jwt::JwtError> for DomainError {
    fn from(e: crate::jwt::JwtError) -> Self {
        use crate::jwt::JwtError;
        match e {
            JwtError::Expired => DomainError::new(ErrorCode::AuthTokenExpired, "token expired"),
            other => DomainError::new(ErrorCode::AuthTokenInvalid, other.to_string()),
        }
    }
}

/// Convenience aliases.
pub type DomainResult<T> = Result<T, DomainError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_stable() {
        assert_eq!(
            ErrorCode::InvalidIndexNumber.as_str(),
            "INVALID_INDEX_NUMBER"
        );
        assert_eq!(
            ErrorCode::WaecDomSchemaDrift.as_str(),
            "WAEC_DOM_SCHEMA_DRIFT"
        );
    }

    #[test]
    fn grpc_mapping() {
        assert_eq!(
            ErrorCode::InvalidIndexNumber.to_grpc_code(),
            tonic::Code::InvalidArgument
        );
        assert_eq!(
            ErrorCode::AuthLockedOut.to_grpc_code(),
            tonic::Code::ResourceExhausted
        );
        assert_eq!(
            ErrorCode::VendorCircuitOpen.to_grpc_code(),
            tonic::Code::Unavailable
        );
    }

    #[test]
    fn retryable_defaults() {
        assert!(!DomainError::new(ErrorCode::PaymentDeclined, "x").retryable);
        assert!(DomainError::new(ErrorCode::VendorCircuitOpen, "x").retryable);
    }

    #[test]
    fn status_round_trip_contains_code() {
        let err = DomainError::new(ErrorCode::WebhookSignatureInvalid, "bad hmac");
        let status = err.to_status();
        assert_eq!(status.code(), tonic::Code::Unauthenticated);
        let details = String::from_utf8_lossy(status.details());
        assert!(details.starts_with("WEBHOOK_SIGNATURE_INVALID|"));
    }

    #[test]
    fn crypto_error_converts() {
        let e: DomainError = crate::crypto::CryptoError::DecryptionFailed.into();
        assert_eq!(e.code, ErrorCode::Internal);
    }

    #[test]
    fn jwt_expiry_maps_to_expired_code() {
        let e: DomainError = crate::jwt::JwtError::Expired.into();
        assert_eq!(e.code, ErrorCode::AuthTokenExpired);
    }
}
