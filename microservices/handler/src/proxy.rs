//! Residential proxy pool — plan §4.7.
//!
//! "Rotated West African residential proxy IPs + randomized browser TLS
//! fingerprints." Every WAEC egress request MUST (hard rule 4):
//!
//! 1. leave through a **rotating residential exit** — never a Hetzner DC
//!    IP — so sustained scrape load cannot pin a ban on one address;
//! 2. present a **randomized browser TLS fingerprint** drawn from real
//!    client profiles, so the WAF cannot cluster our sessions by a
//!    static JA3 hash.
//!
//! This module owns both rotations and produces the per-request egress
//! directive the pool rotator applies (`exit` + `tls_profile`). The
//! rotator sidecar terminates TLS with the requested profile; here we
//! guarantee *diversity*, not transport.

use rand::rngs::StdRng;
use rand::{RngCore, SeedableRng};
use waec_common::{DomainError, ErrorCode};

/// One residential egress point in the West African pool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyExit {
    /// Stable identifier for logs/metrics (never candidate data).
    pub id: &'static str,
    /// Metro/region label — rotation spread, not launch geography.
    pub region: &'static str,
    /// Rotator endpoint for this exit (host:port).
    pub endpoint: &'static str,
    /// Weight — higher-capacity exits serve more requests.
    pub weight: u32,
}

/// The default West African residential pool (plan §4.7). Ghana-anchored
/// with regional spread; expansion is config, not code.
pub const DEFAULT_POOL: &[ProxyExit] = &[
    ProxyExit {
        id: "gh-accra-1",
        region: "GH-Accra",
        endpoint: "pool1.residential.gh:9000",
        weight: 4,
    },
    ProxyExit {
        id: "gh-kumasi-1",
        region: "GH-Kumasi",
        endpoint: "pool2.residential.gh:9000",
        weight: 2,
    },
    ProxyExit {
        id: "ng-lagos-1",
        region: "NG-Lagos",
        endpoint: "pool3.residential.ng:9000",
        weight: 2,
    },
    ProxyExit {
        id: "ci-abidjan-1",
        region: "CI-Abidjan",
        endpoint: "pool4.residential.ci:9000",
        weight: 1,
    },
    ProxyExit {
        id: "sn-dakar-1",
        region: "SN-Dakar",
        endpoint: "pool5.residential.sn:9000",
        weight: 1,
    },
];

/// A realistic browser TLS fingerprint profile. The rotator configures
/// its TLS stack (cipher order, extensions, ALPN, h2 settings) to match
/// the chosen profile so JA3 hashes scatter across the fleet. Profiles
/// are curated from genuine client populations — synthetic field mixing
/// would create fingerprints no real browser ever emits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TlsProfile {
    pub browser: &'static str,
    pub major: u8,
    pub http2: bool,
    /// Cipher/extension ordering variant within the same browser build;
    /// distinct variants ⇒ distinct JA3 hashes for the same profile.
    pub variant: u8,
}

impl TlsProfile {
    /// Stable fingerprint label for metrics/alerts (no secrets).
    pub fn label(&self) -> String {
        format!(
            "{}-{}.h{}-v{}",
            self.browser,
            self.major,
            if self.http2 { 2 } else { 1 },
            self.variant
        )
    }
}

/// Curated profile fleet (Chrome/Firefox/Safari/Edge, h1+h2, multiple
/// ordering variants per build).
pub const TLS_PROFILES: &[TlsProfile] = &[
    TlsProfile {
        browser: "chrome",
        major: 126,
        http2: true,
        variant: 0,
    },
    TlsProfile {
        browser: "chrome",
        major: 126,
        http2: true,
        variant: 1,
    },
    TlsProfile {
        browser: "chrome",
        major: 125,
        http2: false,
        variant: 0,
    },
    TlsProfile {
        browser: "firefox",
        major: 128,
        http2: true,
        variant: 0,
    },
    TlsProfile {
        browser: "firefox",
        major: 127,
        http2: true,
        variant: 1,
    },
    TlsProfile {
        browser: "firefox",
        major: 128,
        http2: false,
        variant: 0,
    },
    TlsProfile {
        browser: "safari",
        major: 17,
        http2: true,
        variant: 0,
    },
    TlsProfile {
        browser: "safari",
        major: 16,
        http2: false,
        variant: 1,
    },
    TlsProfile {
        browser: "edge",
        major: 125,
        http2: true,
        variant: 0,
    },
];

/// Per-request egress directive consumed by the pool rotator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EgressDirective {
    pub exit: ProxyExit,
    pub tls_profile: &'static TlsProfile,
}

/// Weighted round-robin rotator over the pool with per-request TLS
/// fingerprint randomization. Production uses OS entropy; tests inject
/// a seed for deterministic diversity proofs.
pub struct ProxyRotator {
    pool: Vec<ProxyExit>,
    weight_table: Vec<usize>,
    rr: usize,
    rng: RngBox,
}

/// Boxed RNG so call sites are not generic over R. `StdRng` (Send+Sync)
/// keeps `HandlerState` shareable across tonic's spawned tasks.
enum RngBox {
    Entropy(StdRng),
    Seeded(StdRng),
}

impl RngBox {
    fn inner(&mut self) -> &mut dyn RngCore {
        match self {
            RngBox::Entropy(r) | RngBox::Seeded(r) => r,
        }
    }
}

impl Default for ProxyRotator {
    fn default() -> Self {
        Self::with_pool(
            DEFAULT_POOL.to_vec(),
            RngBox::Entropy(StdRng::from_entropy()),
        )
    }
}

impl ProxyRotator {
    /// Deterministic rotator for tests.
    pub fn seeded(pool: Vec<ProxyExit>, seed: u64) -> Self {
        Self::with_pool(pool, RngBox::Seeded(StdRng::seed_from_u64(seed)))
    }

    fn with_pool(pool: Vec<ProxyExit>, rng: RngBox) -> Self {
        assert!(!pool.is_empty(), "proxy pool must not be empty");
        // Expand weights into an index table: an exit with weight w is
        // hit ~w times as often as weight-1 exits (capacity-aware).
        let mut weight_table = Vec::new();
        for (i, e) in pool.iter().enumerate() {
            for _ in 0..e.weight.max(1) {
                weight_table.push(i);
            }
        }
        Self {
            pool,
            weight_table,
            rr: 0,
            rng,
        }
    }

    /// Next egress directive: weighted round-robin exit + independently
    /// randomized TLS fingerprint (exit rotation and fingerprint
    /// rotation do not correlate).
    pub fn next_directive(&mut self) -> EgressDirective {
        self.rr = (self.rr + 1) % self.weight_table.len();
        let exit = self.pool[self.weight_table[self.rr]].clone();
        let idx = (self.rng.inner().next_u32() as usize) % TLS_PROFILES.len();
        EgressDirective {
            exit,
            tls_profile: &TLS_PROFILES[idx],
        }
    }

    /// Pool snapshot for metrics (exit ids + weights).
    pub fn pool(&self) -> &[ProxyExit] {
        &self.pool
    }
}

/// Hard rule 4 guard: the directive must never target a datacenter or
/// internal address. Every egress path asserts this before sending.
pub fn assert_no_dc_leak(directive: &EgressDirective) -> Result<(), DomainError> {
    const FORBIDDEN: &[&str] = &["hetzner", "cpx", "169.254", "10.", "192.168.", "127."];
    let ep = directive.exit.endpoint.to_ascii_lowercase();
    if FORBIDDEN.iter().any(|f| ep.contains(f)) {
        return Err(DomainError::new(
            ErrorCode::WaecPortalUnavailable,
            "egress leak: datacenter/internal address in proxy pool",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn tiny_pool() -> Vec<ProxyExit> {
        vec![
            ProxyExit {
                id: "a",
                region: "GH",
                endpoint: "a.residential.gh:9000",
                weight: 3,
            },
            ProxyExit {
                id: "b",
                region: "NG",
                endpoint: "b.residential.ng:9000",
                weight: 1,
            },
        ]
    }

    #[test]
    fn weight_ratio_follows_pool_capacity() {
        let mut r = ProxyRotator::seeded(tiny_pool(), 42);
        let mut a = 0;
        let mut b = 0;
        for _ in 0..400 {
            match r.next_directive().exit.id {
                "a" => a += 1,
                "b" => b += 1,
                other => unreachable!("unexpected exit {other}"),
            }
        }
        assert_eq!((a, b), (300, 100), "3:1 weight must hold");
    }

    #[test]
    fn fingerprint_diversity_over_sustained_load() {
        // Plan acceptance: "fingerprint diversity verified" under
        // sustained scrape load.
        let mut r = ProxyRotator::seeded(DEFAULT_POOL.to_vec(), 7);
        let mut labels = HashSet::new();
        for _ in 0..500 {
            labels.insert(r.next_directive().tls_profile.label());
        }
        assert!(
            labels.len() >= TLS_PROFILES.len() - 1,
            "fingerprint diversity unproven: {} distinct labels",
            labels.len()
        );
    }

    #[test]
    fn exits_rotate_across_sustained_load() {
        let mut r = ProxyRotator::seeded(DEFAULT_POOL.to_vec(), 11);
        let mut ids = HashSet::new();
        for _ in 0..100 {
            ids.insert(r.next_directive().exit.id);
        }
        assert_eq!(ids.len(), DEFAULT_POOL.len(), "every exit must serve");
    }

    #[test]
    fn exit_and_fingerprint_do_not_correlate() {
        // If the fingerprint were tied to the round-robin position, the
        // (exit, profile) pair would cycle with a fixed period. Check the
        // pairing over one weight cycle is not constant.
        let mut r = ProxyRotator::seeded(tiny_pool(), 3);
        let mut pairs = HashSet::new();
        for _ in 0..8 {
            let d = r.next_directive();
            pairs.insert((d.exit.id, d.tls_profile.label()));
        }
        assert!(pairs.len() > 4, "pairing looks deterministic: {pairs:?}");
    }

    #[test]
    fn no_dc_leak_accepts_residential_rejects_internal() {
        let good = EgressDirective {
            exit: DEFAULT_POOL[0].clone(),
            tls_profile: &TLS_PROFILES[0],
        };
        assert!(assert_no_dc_leak(&good).is_ok());

        let mut private_ip = good.clone();
        private_ip.exit.endpoint = "10.0.0.5:8080";
        assert!(assert_no_dc_leak(&private_ip).is_err());

        let mut dc = good.clone();
        dc.exit.endpoint = "cpx22.hetzner.fsn1:9000";
        assert!(assert_no_dc_leak(&dc).is_err());

        let mut loopback = good.clone();
        loopback.exit.endpoint = "127.0.0.1:9000";
        assert!(assert_no_dc_leak(&loopback).is_err());
    }

    #[test]
    fn default_pool_is_residential_shaped() {
        assert!(DEFAULT_POOL.len() >= 3, "rotation needs spread");
        for e in DEFAULT_POOL {
            assert!(
                e.endpoint.contains(".residential."),
                "bad endpoint {}",
                e.endpoint
            );
            let d = EgressDirective {
                exit: e.clone(),
                tls_profile: &TLS_PROFILES[0],
            };
            assert!(assert_no_dc_leak(&d).is_ok());
        }
    }

    #[test]
    fn profile_labels_are_unique() {
        let labels: HashSet<_> = TLS_PROFILES.iter().map(|p| p.label()).collect();
        assert_eq!(
            labels.len(),
            TLS_PROFILES.len(),
            "duplicate profile in fleet"
        );
    }
}
