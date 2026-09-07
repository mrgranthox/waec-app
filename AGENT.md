# AGENT.md — AI Agent Instructions for waec-app

Guidance for AI coding agents (and humans) working in this repository. Read this file before making changes.

---

## 1. Project Overview

**WAEC Automated Verification & Direct Retrieval Platform** — a Ghana-only mobile platform that retrieves official WAEC exam results on demand. Candidates pay via Paystack Ghana (MTN MoMo, Telecel Cash, AT Money, cards), the system acquires a checker PIN Just-in-Time from a wholesale vendor, scrapes the official WAEC portal, and streams the result to the phone.

**Non-negotiable architecture principle:** raw candidate grades are **never persisted server-side**. Results live only in transit and in encrypted local SQLCipher storage on the user's device.

| Fact           | Value                                                                                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Launch scope   | Ghana only (no NGN / Nigerian localization)                                                                                                              |
| Exam types     | BECE, WASSCE School, WASSCE Private (Nov-Dec "Nwasie")                                                                                                   |
| Mobile client  | Flutter (Dart), Riverpod, AOT ARM, certificate pinning                                                                                                   |
| Backend        | Rust microservices (Tokio/Actix-Web), gRPC over mTLS (rustls)                                                                                            |
| Services       | Auth, Payment, Distributor, Handler, Admin                                                                                                               |
| Data stores    | PostgreSQL 16 (pgcrypto), Redis 7, Kafka KRaft (single broker)                                                                                           |
| Payments       | Paystack Ghana; HMAC SHA-512 webhooks; `X-Idempotency-Key` UUIDv4 mandatory                                                                              |
| Vendors        | SellePins (primary), Ewale / GHVouchers (failover); circuit breaker: 3 consecutive errors, >3000 ms timeout, or OUT_OF_STOCK → open 3 min → 100% reroute |
| WAEC portals   | `eresults.waecgh.org` (BECE/WASSCE SC), `ghana.waecdirect.org` (WASSCE Private)                                                                          |
| Realtime       | SSE over HTTP/2 with adaptive 2-second polling fallback to `/transaction/status/{id}`                                                                    |
| Infrastructure | Single Hetzner CPX22 node (fsn1), Docker Compose, ~€15–18/mo                                                                                             |
| Pricing        | Dynamic GHS served from backend config endpoint                                                                                                          |

---

## 2. Authoritative Documents

Read these before non-trivial work — in this order:

1. [`docs/Now that we have everything figured out, get me a... (1).md`](docs/Now%20that%20we%20have%20everything%20figured%20out%2C%20get%20me%20a...%20%281%29.md) — original enterprise architecture (crypto, services, UI, risk matrix)
2. [`plans/waec-app-enterprise-plan.md`](plans/waec-app-enterprise-plan.md) — phased delivery plan, stakeholder decisions, decision log
3. [`plans/hetzner-infrastructure-plan.md`](plans/hetzner-infrastructure-plan.md) — single-node infrastructure: memory budget, firewall matrix, backups, DR runbook, scaling triggers

If code and plans disagree, the plans win; flag the discrepancy instead of silently picking one.

---

## 3. Repository Layout (target)

```
waec-app/
├── AGENT.md                  # This file
├── docs/                     # Architecture source documents
├── plans/                    # Delivery + infrastructure plans, ADRs
├── mobile/                   # Flutter app
│   └── lib/
│       ├── core/             # tokens, theme, crypto, network (SSE/polling/backoff), SQLCipher storage
│       └── features/         # auth/, verification/, processing/, results/, history/
├── microservices/            # Cargo workspace
│   ├── common/               # crypto.rs, jwt.rs, errors.rs, telemetry.rs (shared crate)
│   ├── proto/                # gRPC contracts — single source of truth
│   ├── auth/  payment/  distributor/  handler/  admin/
├── infra/
│   ├── terraform/hetzner/    # hcloud IaC — single CPX22 module
│   ├── gateway/              # NGINX edge configs, mTLS CA
│   ├── proxy/                # residential proxy pool + TLS fingerprint rotation
│   └── compose/              # compose.yaml, compose.prod.yaml, compose.dev.yaml
├── .github/workflows/        # CI/CD
└── scripts/                  # codegen, certs, seed data
```

---

## 4. Hard Rules (never violate)

1. **Never log, persist, or cache** raw grades, checker PINs, voucher serials, passwords, or full payment payloads — not in logs, traces, databases, or error messages. The Handler streams results and forgets them.
2. **Never store grades server-side.** Only encrypted transaction metadata, auth hashes, and grace-period pointers belong in PostgreSQL.
3. **Every payment and fetch request carries `X-Idempotency-Key` (UUIDv4)** generated client-side and preserved across retries. Duplicate keys must return the original outcome — never double-charge, never buy a second voucher.
4. **Never call WAEC portals from Hetzner datacenter IPs directly.** Handler egress goes through the rotated West African residential proxy pool with randomized TLS fingerprints.
5. **Never weaken crypto:** AES-256-GCM with fresh 12-byte nonces, Argon2id for passwords, RS256 JWTs (≤15 min expiry), TLS 1.3 edge, mTLS internal. No exceptions, no "temporary" plaintext fallbacks.
6. **Never commit secrets.** Use SOPS/age. Pre-commit scanning must stay active.
7. **Never parse WAEC HTML "best effort."** Schema validation is decoupled: on structure drift, abort cleanly (no partial results), fire a DOM-drift alert, schedule client retry.
8. **Respect the 8 GB memory budget** on the CPX22 — every container gets `mem_limit`/`cpus` per [`plans/hetzner-infrastructure-plan.md`](plans/hetzner-infrastructure-plan.md) §4. Do not add unbounded in-memory caches.
9. **Circuit breaker parameters are fixed:** 3 consecutive HTTP errors, timeout >3000 ms, or OUT_OF_STOCK → open 3 minutes → 100% reroute to secondary vendor. Do not "tune" without an ADR.
10. **Payload budget:** result payloads must compress to <10 KB (Gzip/Brotli at NGINX).

---

## 5. Coding Conventions

### Rust (microservices)

- Workspace at [`microservices/Cargo.toml`](microservices/Cargo.toml); shared code goes in `common`, never duplicated.
- Typed errors only (`common` error taxonomy) — no `String` errors, no `unwrap()` outside tests.
- `clippy -D warnings` and `cargo fmt` must pass; unit tests accompany every crypto, parser, and state-machine change.
- gRPC contracts live in `proto/`; regenerate code via the scripts in `scripts/`; never hand-edit generated pb files.
- All inter-service calls: mTLS (rustls), explicit deadlines, retry policies.
- Kafka topics: `payment.authorized`, `voucher.acquired`, `fetch.result`, `fetch.failed`, `audit.events` + per-topic DLQ. Audit topics are mirrored to PostgreSQL by Admin.

### Flutter (mobile)

- State: Riverpod only. Result payloads live in state trees that zero out on screen disposal and app backgrounding (`AppLifecycleState`).
- Design tokens centralized in one file: navy `#0A2540`, mint `#00D4B1`, canvas `#F8FAFC`/`#051424`, cards `#FFFFFF`/`#0D1F35`, Public Sans. Light + dark themes.
- Network layer: TLS 1.3 + SHA-256 cert pinning; exponential backoff with randomized jitter (base 1.5 s, max 3 retries); SSE with graceful degradation to 2 s polling of `/transaction/status/{id}`.
- Local persistence: SQLCipher only. No grade plaintext outside it. `flutter analyze` must pass.
- Exam type selector maps to the proto enum: `BECE`, `WASSCE_SC`, `WASSCE_PRIVATE`.

### Terraform / Infra

- hcloud provider; single CPX22 module under `infra/terraform/hetzner/`; remote state on Hetzner Object Storage with locking.
- Firewall: only 443, 80, 51820/UDP (WireGuard) inbound. SSH only via WireGuard.
- Compose files are the runtime of record — do not introduce Kubernetes, Ansible, or a second orchestrator without an ADR.

---

## 6. Testing Requirements

- **Unit:** crypto round-trip/tamper/nonce-uniqueness, JWT lifecycle, HMAC webhook verification, HTML parser fixtures for **both** portals, circuit-breaker state machine, form validators.
- **Integration:** service-to-service gRPC over mTLS in the compose stack; Paystack Ghana sandbox (MoMo/Telecel/AT/cards); vendor sandbox adapters.
- **Contract:** `buf breaking` on proto changes in CI.
- **E2E:** full payment → retrieval → grace re-fetch journey on emulator, including degraded-network scenarios (3G throttle, packet loss, tower handoff).
- **Security:** SAST, `cargo audit`, secret scanning, MITM refusal, memory-dump verification, SQLCipher at-rest audit.
- **Chaos:** mid-fetch kill, container crash recovery, vendor 5xx storms, SSE severance, idempotency replay storms.
- A change is not done until the relevant test tier passes in CI.

---

## 7. Common Commands

```bash
# Rust workspace
cd microservices && cargo check && cargo clippy -- -D warnings && cargo test

# Protobuf
buf lint && buf breaking --against '.git#branch=main,subdir=microservices/proto'

# Flutter
cd mobile && flutter analyze && flutter test

# Local full stack (dev override adds mock WAEC portals)
docker compose -f infra/compose/compose.yaml -f infra/compose/compose.dev.yaml up -d

# Production deploy (CI does this over WireGuard SSH; takes a pre-deploy snapshot first)
docker compose -f infra/compose/compose.yaml -f infra/compose/compose.prod.yaml pull && \
docker compose -f infra/compose/compose.yaml -f infra/compose/compose.prod.yaml up -d

# Terraform
cd infra/terraform/hetzner/envs/prod && terraform plan
```

---

## 8. When You Are Unsure

- Check the decision log in [`plans/waec-app-enterprise-plan.md`](plans/waec-app-enterprise-plan.md) §7 first.
- If a change would alter a hard rule (§4), a circuit-breaker parameter, the memory budget, the data-storage model, or a proto contract — **stop and ask the user**; write an ADR in `plans/` before implementing.
- Never silently expand scope (e.g., adding Nigerian support, new vendors, new exam types) — those are stakeholder decisions.
