# ADR-001 — Device-local encrypted checker vault

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-09-15 |
| **Scope** | Mobile client (`mobile/`) — no backend/proto changes |
| **Supersedes** | Nothing |
| **Related** | `plans/waec-app-enterprise-plan.md` (Hard Rules 1, 3, 5) |

## Context

The landing-page feature lets a candidate **buy a WAEC result checker** (serial +
PIN voucher) and later **redeem it** to fetch their result. That means the
voucher — a monetary credential exactly like a scratch card — must live
somewhere between purchase and redemption.

The plan's **Hard Rule 1** says, verbatim: *"No plaintext serial/PIN at rest —
encrypted envelope only"*. Read in isolation that could be interpreted as
"never persist a checker on the device", which would make the product
requirement (History tab shows checkers with an attached **Check result**
button) impossible on an offline-capable client.

Hard Rule 3 requires every purchase to carry an **`X-Idempotency-Key`**, and
Hard Rule 5 forbids weakened-auth fallbacks in release builds.

## Decision

### 1. Checkers are persisted **on-device only**, inside the existing encrypted archive

`EncryptedResultArchive` already stores result snapshots as **AES-256-GCM
envelopes** with a key derived per-install (PBKDF2 over a random device secret)
and per-record integrity tags (`_tag`). We reuse exactly that machinery for a
new `checkers` table rather than introducing a second crypto stack.

**Narrowing of Hard Rule 1 (recorded deliberately):** the rule is interpreted
as governing **server-side storage, logs, traces, and error/telemetry output**.
Device-local persistence is permitted **iff** the secret material exists only
inside the ciphertext envelope. Concretely:

- Serial and PIN are written **only** inside the encrypted blob's plaintext
  payload (`_encrypt` input).
- Metadata columns/JSON exposed to the UI (exam type, year, status, purchased
  at, price) never contain serial or PIN.
- This is **machine-checked**: `test/checker_archive_test.dart` reads the raw
  bytes of every row in the underlying SQLite file and asserts neither the
  serial nor the PIN appears in cleartext. A regression that "simplifies" the
  envelope turns the suite red.

### 2. Deletion is a zero-out, not a tombstone

Deleting a redeemed/expired checker overwrites its ciphertext with zeros before
removing the row, so the voucher material does not linger in freed database
pages. Verified by the same raw-bytes test.

### 3. Redemption reuses the existing result-fetch grammar

`FetchResultRequest{voucher_pin, voucher_serial}` is already the wire contract
for voucher-based verification. Buying a checker therefore composes, rather
than duplicates, the existing journey: History's **Check result** button seeds
`journeyProvider` with the checker's serial/PIN and pushes the unchanged
`ProcessingScreen`.

### 4. Idempotent purchases (Hard Rule 3)

`BuyCheckerScreen` generates a UUID `X-Idempotency-Key` per purchase attempt
and keeps it stable across retries of the same attempt (a transport-level retry
must not mint two vouchers and charge twice). Locked by
`checker_test.dart` ("idempotency key is stable across retries").

### 5. Auth resilience fallback is debug/profile-only (Hard Rule 5 note)

Decision B from the implementation plan: when the Auth REST facade is
unreachable, a **local session** (`offlineFallbackUsed: true`) may be
provisioned **only when `kReleaseMode == false`**. Release builds fail closed
with the real transport error. This is the same resilience posture as the
existing `getPricing` offline fallback. The session store never contains the
password — only the `AuthSession` token envelope.

## Consequences

**Positive**
- Buy → store → redeem works fully offline after purchase; History redemption
  needs no new backend endpoint.
- One crypto implementation (audited once) covers results *and* checkers.
- Hard Rule 1 compliance is enforced by CI, not by review discipline.

**Negative / accepted risks**
- A rooted device whose per-install key secret is extracted could decrypt the
  vault. Accepted: this is strictly better than the status quo of no local
  persistence, and matches the threat model already accepted for result
  snapshots.
- Backend still lacks a REST auth/checker facade; the client's HTTP
  implementations call the documented `/v1/*` paths and fall back per §5 until
  the gateway ships them (follow-up task for the backend team).

## Verification (CI-enforced)

| Concern | Test |
|---|---|
| No plaintext serial/PIN at rest | `checker_archive_test.dart` raw SQLite blob scan |
| Delete = zero-out | `checker_archive_test.dart` post-delete blob scan |
| Tamper detection | `checker_archive_test.dart` mutated-blob rejection |
| Idempotency stability | `checker_test.dart` retry assertion |
| Status transitions | `checker_test.dart` unused → redeemed/expired |
| Release fail-closed auth | `auth_providers_test.dart` offline-fallback gating |
