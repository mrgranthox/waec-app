//! WAEC platform shared library: crypto, JWT, errors, telemetry,
//! Argon2id password hashing, domain types and gRPC contracts.

pub mod crypto;
pub mod errors;
pub mod idempotency;
pub mod jwt;
pub mod password;
pub mod telemetry;
pub mod webhook;

/// Role claim values for Admin RBAC (plan §2.5: non-admin → 403).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    #[default]
    Candidate,
    Admin,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Candidate => "candidate",
            Role::Admin => "admin",
        }
    }
}

/// Generated protobuf/gRPC types from `proto/` (single source of truth).
///
/// Module tree mirrors the proto package hierarchy so that prost's
/// `super::` cross-package references resolve correctly.
/// Warnings are silenced: this is machine-generated code.
#[allow(clippy::all, clippy::pedantic, dead_code)]
pub mod pb {
    pub mod waec {
        pub mod common {
            pub mod v1 {
                tonic::include_proto!("waec.common.v1");
            }
        }
        pub mod auth {
            pub mod v1 {
                tonic::include_proto!("waec.auth.v1");
            }
        }
        pub mod payment {
            pub mod v1 {
                tonic::include_proto!("waec.payment.v1");
            }
        }
        pub mod distributor {
            pub mod v1 {
                tonic::include_proto!("waec.distributor.v1");
            }
        }
        pub mod handler {
            pub mod v1 {
                tonic::include_proto!("waec.handler.v1");
            }
        }
        pub mod admin {
            pub mod v1 {
                tonic::include_proto!("waec.admin.v1");
            }
        }
    }
}

// Convenience re-exports for the most-used shared types.
pub mod pb_aliases {
    pub use crate::pb::waec::common::v1::{
        ExamType, PaymentChannel, ResultPayload, TransactionStage,
    };
}

pub use errors::{DomainError, DomainResult, ErrorCode};

/// WAEC index number validation — exactly 10 digits (plan §3.2).
pub fn is_valid_index_number(index: &str) -> bool {
    index.len() == 10 && index.chars().all(|c| c.is_ascii_digit())
}

/// Exam types supported at launch (Ghana only, plan Appendix A).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExamType {
    Bece,
    WassceSchool,
    WasscePrivate,
}

impl ExamType {
    pub fn as_str(self) -> &'static str {
        match self {
            ExamType::Bece => "BECE",
            ExamType::WassceSchool => "WASSCE_SC",
            ExamType::WasscePrivate => "WASSCE_PRIVATE",
        }
    }

    /// Official WAEC portal per exam type (plan §2.4).
    pub fn portal_host(self) -> &'static str {
        match self {
            ExamType::Bece | ExamType::WassceSchool => "eresults.waecgh.org",
            ExamType::WasscePrivate => "ghana.waecdirect.org",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_validation() {
        assert!(is_valid_index_number("1002330440"));
        assert!(!is_valid_index_number("10023304")); // too short
        assert!(!is_valid_index_number("10023304400")); // too long
        assert!(!is_valid_index_number("100233044O")); // letter
        assert!(!is_valid_index_number("")); // empty
    }

    #[test]
    fn exam_portal_mapping() {
        assert_eq!(ExamType::Bece.portal_host(), "eresults.waecgh.org");
        assert_eq!(ExamType::WassceSchool.portal_host(), "eresults.waecgh.org");
        assert_eq!(
            ExamType::WasscePrivate.portal_host(),
            "ghana.waecdirect.org"
        );
    }
}
