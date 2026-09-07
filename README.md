# WAEC Automated Verification & Direct Retrieval Platform

On-demand retrieval of official WAEC examination results for Ghanaian
candidates (BECE, WASSCE School, WASSCE Private/"Nwasie").

**Architecture:** On-Demand Direct Retrieval — payment + verification in
real time; **raw grades are never persisted server-side**. Results live
only in client memory and an encrypted local SQLCipher store owned by
the user until deleted.

- Architecture doc: [`docs/`](docs/)
- Implementation plan: [`plans/waec-app-enterprise-plan.md`](plans/waec-app-enterprise-plan.md)
- Infrastructure plan: [`plans/hetzner-infrastructure-plan.md`](plans/hetzner-infrastructure-plan.md)

## Repository Layout

```
waec-app/
├── docs/              # Architecture documents (source of truth)
├── plans/             # Implementation + infrastructure plans, ADRs
├── mobile/            # Flutter app (Riverpod, TLS pinning, SQLCipher)
│   └── lib/core/      # Design tokens, domain types, network layer
├── microservices/     # Rust workspace (tokio + tonic gRPC)
│   ├── common/        # CryptoEngine, JWT, Argon2id, error taxonomy, pb
│   ├── proto/         # gRPC contracts — single source of truth
│   ├── auth/          # Argon2id + RS256 JWT service
│   ├── payment/       # Paystack Ghana engine (MoMo, cards, idempotency)
│   ├── distributor/   # JIT voucher acquisition + circuit breaker
│   ├── handler/       # WAEC portal scraper (schema-validated DOM)
│   └── admin/         # RBAC, audit, metrics, DOM-drift alerts
├── infra/             # Terraform (Hetzner), gateway, compose files
└── .github/workflows/ # CI: fmt/clippy/tests, analyze/test, buf
```

## Prerequisites

| Tool      | Version    | Install                                            |
| --------- | ---------- | -------------------------------------------------- |
| Rust      | ≥ 1.75     | https://sh.rustup.rs                               |
| Flutter   | stable     | https://docs.flutter.dev/get-started/install/linux |
| buf (CLI) | latest     | https://buf.build — for proto lint in CI           |

## Build & Test

```bash
# Rust workspace
cd microservices
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings

# Flutter app
cd mobile
flutter pub get
flutter analyze
flutter test
```

## Regenerating gRPC types

`microservices/common/build.rs` uses the pure-Rust `protox` compiler —
no `protoc` install needed. Types regenerate automatically on
`cargo build` whenever files under `microservices/proto/` change.

## Security Invariants (non-negotiable)

1. No secret, PIN, or raw grade value in logs, DB, or traces.
2. Every payment/fetch request carries `X-Idempotency-Key` (UUIDv4).
3. Vendor PINs and voucher serials are never logged.
4. Result payloads < 10KB compressed at the edge.
5. Grace-period re-fetch tokens expire at 24h.
