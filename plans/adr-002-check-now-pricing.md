# ADR-002 — Two-part checker pricing (`check_now`)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-09-17 |
| **Scope** | Backend (`microservices/`) + mobile client (`mobile/`) |
| **Supersedes** | Nothing |
| **Related** | `plans/waec-app-enterprise-plan.md` (§2.2 dynamic pricing, Hard Rule 3), `plans/adr-001-device-local-checker-vault.md` |

## Context

The checker screen asks two questions at once: *which* exam/year the checker is
for, and *whether to spend it immediately*. Today both answers cost the same
amount, because pricing is keyed on `exam_type` alone:

- `pricing_config` has `PRIMARY KEY (exam_type)` and one `amount_pesewas`
  (`microservices/migrations/0003_pricing_config.sql`).
- `GetPricingRequest` carries only `exam_type`, and `InitChargeRequest` carries
  no "check now" flag at all.
- `PgPricingStore::price_for(exam_type)` resolves a single figure.

The product requirement is that the two purchases are **priced differently**:
buying a checker to keep costs less than buying a checker *and* having the
result retrieved in the same pass, which also buys the retrieval. The client
must be able to show the difference the moment the candidate flips the
"Also check my results now" toggle — and be charged exactly what it showed.

Two things could go wrong if this is done client-side only:

1. **Displayed ≠ charged.** The mobile client would invent the combined figure
   while the backend kept charging the checker-only amount. The candidate sees
   one number and is billed another.
2. **Fee changes need a release.** The whole point of §2.2's config endpoint is
   that a fee change is a database row, not an app-store submission. A hard
   coded surcharge in Dart breaks that.

Option B — a locally-invented difference in the app, backend unchanged — was
rejected for exactly those reasons. The displayed price must be server-derived.

## Decision

### 1. `check_now` is part of the pricing contract, on both RPCs

`GetPricingRequest` gains `bool check_now = 2`; `InitChargeRequest` gains
`bool check_now = 7`. Both fields are **additive** and default to `false`, so
the change is backward compatible: an older client keeps getting checker-only
pricing and the existing wire behaviour is preserved.

### 2. `GetPricing` resolves one authoritative amount — the client never does arithmetic

The response keeps a single `amount_pesewas` and interprets it as *"what this
exact purchase costs"*. The client asks with the flag it is about to purchase
with and renders the figure verbatim. No client-side addition, no rounding
drift between what is quoted and what is charged.

`GetPricing` is a **preview**: `InitChargeResponse.amount_pesewas` stays
authoritative, and a test asserts the two agree for the same flag
(`svc_tests.rs::check_now_pricing_flows_into_the_charge`).

### 3. The database stores *both* prices per exam type

`pricing_config` gains `check_now_pesewas`, the amount for
"buy a checker **and** retrieve the result now". The checker-only amount stays
in `amount_pesewas`. Migration `0007_pricing_check_now.sql` backfills existing
rows so no exam type is left without a combined price, and the column is
`NOT NULL DEFAULT 0 CHECK (check_now_pesewas >= 0)`.

`PgPricingStore::price_for` takes the flag and resolves the right column, so the
DB-outage fallback (`paystack::base_price_pesewas`) mirrors the same shape.

### 4. Redemption stays unaffected

Redeeming a *stored* checker later (`redeemChecker`) is a separate path that
spends an already-purchased voucher; it is not priced here and does not send
`check_now`.

## Consequences

**Positive**
- The number on screen is the number charged, for both toggle positions.
- A price change is one `UPDATE` on `pricing_config`, no release.
- Additive proto fields keep `buf breaking` green and old clients working.

**Negative / accepted risks**
- `pricing_config` now has two amounts per exam type; an operator updating a fee
  must update the pair deliberately. The `CHECK` constraint and the migration
  backfill keep them from diverging into nonsense, but a human can still set an
  odd pair. Accepted: the alternative (deriving `check_now` as base + surcharge)
  hard codes the retrieval margin into code, which is what §2.2 exists to avoid.
- Until the gateway routes `/v1/payment/pricing` (already a known gap noted in
  ADR-001), the mobile client's `check_now` is exercised against
  `MockWaecApi`/tests rather than a live endpoint.

## Verification (CI-enforced)

| Concern | Test |
|---|---|
| Checker-only vs check-now differ per exam type | `svc_tests.rs` dynamic pricing cases |
| Displayed price == charged price | `svc_tests.rs::check_now_pricing_flows_into_the_charge` |
| Static fallback honours the flag | `paystack.rs` unit test |
| Contract compatibility | `buf breaking --against '.git#branch=main,subdir=microservices/proto'` |
| Toggle reprices the mobile card and CTA with one value | `checker_providers_test.dart` / `checker_test.dart` |