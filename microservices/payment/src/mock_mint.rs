//! Mock credential + result minting for the local test phase (requirement 7).
//!
//! Local dev contract: once a payment is confirmed we **throw a mock
//! generated checker** (serial & PIN), and when that checker is spent a
//! **random-looking result** is returned so the flow feels real end to end.
//!
//! ## Security posture (hard rule 1 compliant)
//!
//! - The plaintext credential is generated here, returned once over gRPC and
//!   immediately vaulted **client-side** (ADR-001). The backend records only
//!   a SHA-256 **hash** of the credential — never the plaintext — so a DB
//!   dump cannot spend a checker.
//! - The mock result is deterministic per (index, exam, year, credential):
//!   the same retrieval always returns the same sheet, like a real WAEC
//!   record, while different candidates get unrelated sheets.
//!
//! ## Production boundary
//!
//! Gated behind `MOCK_MINTING=1` (default **on** only in the compose dev
//! profile). With the flag off, minting returns `FeatureDisabled` and the
//! payment flow ends with the real vendor-acquired voucher from the
//! distributor.

use sha2::{Digest, Sha256};

/// A freshly minted mock credential. Plaintext lives in this struct only
/// until the gRPC response is serialized — never logged, never persisted.
#[derive(Debug, Clone)]
pub struct MintedCredential {
    pub serial: String,
    pub pin: String,
    /// SHA-256 hex of `serial:pin` — the only form the DB may remember.
    pub credential_hash: HexDigest,
}

/// Newtype so a hash can never be accidentally formatted as a credential.
#[derive(Debug, Clone)]
pub struct HexDigest(pub String);

/// Mints a mock checker credential.
///
/// - Serial: `WAEC-` + 13 uppercase base32 chars (validator: 8–24
///   alphanumeric — the hyphen is stripped client-side by
///   `CheckerValidator.normalise`).
/// - PIN: 13 digits (WAEC-style), leading zeros allowed.
pub fn mint_credential() -> MintedCredential {
    use rand::RngCore;

    let mut serial_bytes = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut serial_bytes);
    let serial = format!("WAEC-{}", encode_base32(&serial_bytes));

    let mut pin_bytes = [0u8; 13];
    rand::thread_rng().fill_bytes(&mut pin_bytes);
    let pin = pin_bytes
        .iter()
        .map(|b| format!("{}", b % 10))
        .collect::<String>();

    let mut hasher = Sha256::new();
    hasher.update(serial.as_bytes());
    hasher.update(b":");
    hasher.update(pin.as_bytes());
    let digest = hex::encode(hasher.finalize());

    MintedCredential {
        serial,
        pin,
        credential_hash: HexDigest(digest),
    }
}

/// RFC 4648 base32 (uppercase, no padding) — 8 bytes → 13 chars.
fn encode_base32(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    // Upper bound on the encoded length: one character per 5 bits.
    let mut out = String::with_capacity((bytes.len() * 8).div_ceil(5));
    let mut buffer: u32 = 0;
    let mut bits = 0u32;
    for &byte in bytes {
        buffer = (buffer << 8) | byte as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(ALPHABET[(buffer >> bits) as usize & 31] as char);
        }
    }
    if bits > 0 {
        out.push(ALPHABET[(buffer << (5 - bits)) as usize & 31] as char);
    }
    out
}

/// Deterministic mock grade sheet.
///
/// Mirrors the mobile `MockResult.generate` seed contract (FNV-1a over
/// index + exam + year + credential) so both sides agree without a shared
/// crate dependency beyond `waec-common`.
#[derive(Debug, Clone, serde::Serialize)]
pub struct MockResultSheet {
    pub candidate_name: String,
    pub exam_year: String,
    pub subjects: Vec<SubjectGrade>,
    pub aggregate: i32,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SubjectGrade {
    pub subject: String,
    pub grade: String,
}

/// Generates the mock result for a redeemed checker.
pub fn mock_result_for(
    index_number: &str,
    exam_type: &str,
    exam_year: &str,
    credential: &str,
) -> MockResultSheet {
    fn fnv1a(parts: &[&str]) -> u64 {
        let mut hash: u64 = 0xcbf29ce484222325;
        for part in parts {
            for &byte in part.as_bytes() {
                hash ^= byte as u64;
                hash = hash.wrapping_mul(0x01000193);
            }
        }
        hash
    }

    let seed = fnv1a(&[index_number, exam_type, exam_year, credential]);
    // xorshift64* — tiny deterministic PRNG, stable across platforms.
    let mut state = seed | 1;
    let mut next = move || {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        state.wrapping_mul(0x2545F4914F6CDD1D)
    };

    let surnames = [
        "Mensah", "Owusu", "Boateng", "Asante", "Amoah", "Addai", "Darko", "Osei",
    ];
    let first_names = [
        "Kwame", "Ama", "Kofi", "Akosua", "Yaw", "Abena", "Kojo", "Adwoa",
    ];
    let is_bece = exam_type.contains("BECE");

    let (grades, points): (&[&str], fn(&str) -> i32) = if is_bece {
        (
            &["1", "2", "2", "3", "3", "4", "4", "5", "6", "7"],
            |g: &str| g.parse().unwrap_or(9),
        )
    } else {
        (
            &[
                "A1", "B2", "B2", "B3", "B3", "C4", "C4", "C5", "C6", "D7", "E8",
            ],
            |g: &str| match g.as_bytes()[0] {
                b'A' => 1,
                b'B' | b'C' => (g.as_bytes()[1] - b'0') as i32,
                b'D' => 7,
                b'E' => 8,
                _ => 9,
            },
        )
    };

    let subjects: &[&str] = if is_bece {
        &[
            "English Language",
            "Mathematics",
            "Integrated Science",
            "Social Studies",
            "Religious & Moral Education",
            "ICT",
            "Ghanaian Language",
            "French",
        ]
    } else {
        &[
            "English Language",
            "Mathematics",
            "Integrated Science",
            "Social Studies",
            "Elective Mathematics",
            "Physics",
            "Chemistry",
            "Biology",
        ]
    };

    let sheet: Vec<SubjectGrade> = subjects
        .iter()
        .map(|subject| SubjectGrade {
            subject: subject.to_string(),
            grade: grades[(next() % grades.len() as u64) as usize].to_string(),
        })
        .collect();

    // Aggregate = sum of the best six grade points (standard WAEC rule).
    let mut pts: Vec<i32> = sheet.iter().map(|s| points(&s.grade)).collect();
    pts.sort_unstable();
    let aggregate: i32 = pts.iter().take(6).sum();

    MockResultSheet {
        candidate_name: format!(
            "{}, {}",
            surnames[(next() % surnames.len() as u64) as usize],
            first_names[(next() % first_names.len() as u64) as usize],
        ),
        exam_year: exam_year.to_string(),
        subjects: sheet,
        aggregate,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_credential_passes_client_validator_shapes() {
        let c = mint_credential();
        // Client validator: 8–24 alphanumeric after normalisation (the mobile
        // app strips the hyphen before validating).
        let norm: String = c
            .serial
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect();
        assert!((8..=24).contains(&norm.len()));
        assert!(norm.chars().all(|c| c.is_ascii_alphanumeric()));
        assert_eq!(c.pin.len(), 13);
        assert!(c.pin.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn minted_credentials_are_unique() {
        let a = mint_credential();
        let b = mint_credential();
        assert_ne!(a.serial, b.serial);
        assert_ne!(a.credential_hash.0, b.credential_hash.0);
    }

    #[test]
    fn credential_hash_is_sha256_of_serial_colon_pin() {
        let c = mint_credential();
        let mut hasher = Sha256::new();
        hasher.update(c.serial.as_bytes());
        hasher.update(b":");
        hasher.update(c.pin.as_bytes());
        assert_eq!(c.credential_hash.0, hex::encode(hasher.finalize()));
    }

    #[test]
    fn mock_result_is_deterministic_per_identity() {
        let grades = |s: &MockResultSheet| {
            s.subjects
                .iter()
                .map(|g| g.grade.clone())
                .collect::<Vec<_>>()
        };
        let a = mock_result_for("1002330440", "WASSCE_SC", "2025", "WAEC-AAAA");
        let b = mock_result_for("1002330440", "WASSCE_SC", "2025", "WAEC-AAAA");
        assert_eq!(a.candidate_name, b.candidate_name);
        assert_eq!(grades(&a), grades(&b));
        // Different credential → unrelated sheet.
        let c = mock_result_for("1002330440", "WASSCE_SC", "2025", "WAEC-BBBB");
        assert_ne!(grades(&a), grades(&c));
    }

    #[test]
    fn aggregate_is_best_six_sum_in_range() {
        let bece = mock_result_for("1002330440", "BECE", "2025", "WAEC-CCCC");
        assert!((6..=30).contains(&bece.aggregate));
        let wassce = mock_result_for("1002330440", "WASSCE_SC", "2025", "WAEC-CCCC");
        assert!((6..=48).contains(&wassce.aggregate));
    }
}
