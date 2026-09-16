# Fingerprint Authentication Plan — WAEC Direct

**Parent plan:** [`plans/waec-app-enterprise-plan.md`](waec-app-enterprise-plan.md)
**Status:** Proposed — pending user approval

---

## Executive Summary

Fingerprint authentication is a mandatory, first-class feature for the WAEC Direct
mobile app. It serves two distinct purposes:

1. **Security barrier** — protects locally persisted results and checkers from
   unauthorised third-party access on the device.
2. **Password-free sign-in** — lets the user sign in without typing their password.

Both are in scope for launch. Neither is optional.

---

## Requirement: Two Fingerprint Use Cases

The fingerprint in the app works in two ways, and both are in scope.

### Use Case 1 — Security Barrier for Persisted Results and Checkers (mandatory)

A signed-in account may have results and checkers visible and usable inside the app.
Some of that data is persisted locally on the device (encrypted result snapshots and
checker vault rows). The fingerprint acts as a security barrier so an unauthorised
third person cannot view or use that persisted material.

**The requirement:** once a user has results or checkers stored on the device, the
app must let the user protect access to that data with their fingerprint. Someone who
picks up the phone without the user's fingerprint should not be able to open the app
and read the user's results or spend the user's checkers.

This barrier is about protecting locally persisted data from a third party who has
physical access to the device. It is not a second factor sent to the backend — the
backend still sees the same access token. What changes is whether the app on this
device is willing to decrypt and show the local data.

**Concrete behaviours:**

- When biometric unlock is enabled for the account, the app does not reveal persisted
  results or checkers until the fingerprint has been verified on this launch.
- The barrier covers both viewing results and viewing/using checkers, because both
  involve locally persisted credential material.
- If the fingerprint is not available (no sensor, user cancels, lockout), the app
  falls back to the password entry path rather than silently opening the protected
  data.

**Implementation notes:**

- The barrier is enforced at the `AuthStage.biometricUnlock` gate in the auth state
  machine (`mobile/lib/features/auth/auth_providers.dart`).
- The held session is considered suspended until re-verified; the access token is not
  handed to the UI until the fingerprint succeeds.
- Any screen that displays or lets the user act on persisted results or checkers must
  be behind this barrier on enrolled devices — not just the History tab, but also the
  Buy Checker and checker redemption paths that touch the vault.

### Use Case 2 — Fingerprint Sign-In (mandatory)

The fingerprint can also be used to sign in without the user entering their password.
This is the "sign-in with fingerprint" login path: the user taps a fingerprint button
on the sign-in screen, the device authenticates them, and the app obtains a session
the same way it would after a password sign-in.

**Concrete behaviours:**

- There is a visible "Sign in with fingerprint" option on the sign-in screen. It is
  not a hidden gesture; the user can choose password or fingerprint deliberately.
- A successful fingerprint sign-in produces a normal authenticated session. The user
  lands in the app in the same state as if they had typed their password.
- This path is only available to accounts that have already opted in to fingerprint
  sign-in. A fresh account cannot use it until they enable it first.
- If fingerprint sign-in fails or is unavailable, the user can still type their
  password on the same screen. Fingerprint sign-in does not block the password path.

**Implementation notes:**

- The sign-in screen (`mobile/lib/features/auth/auth_screen.dart`) already shows the
  fingerprint button when `auth.session?.biometricEnabled == true` and
  `auth.biometricsAvailable == true`.
- The `unlockWithBiometrics()` call on `AuthController` handles the platform prompt
  and, on success, transitions to `AuthStage.authenticated`.
- The password form remains fully functional alongside the fingerprint button; failure
  never removes the password path.

### Relationship Between the Two Use Cases

They protect different moments and must not be confused:

| | Use Case 1 — Security Barrier | Use Case 2 — Fingerprint Sign-In |
|---|---|---|
| What it protects | Locally persisted results and checkers on the device | The act of signing in (obtaining a session) |
| When it fires | After the app is open, when re-authorization is needed | At the start of a session, instead of password entry |
| What "success" means | Local vault unlocked; protected UI shown | A backend-authenticated session acquired |
| Failure behaviour | Re-lock the local session; prompt again | Fall back to password sign-in on the same screen |

A single enrolled reader may experience both in one session: fingerprint sign-in
gets them into the app, and the same enrolled fingerprint later re-authorises the
local session when the app needs to re-lock and re-unlock the protected local data.

**Implementation guidance:**

- Treat the two use cases as separate code paths that share the same biometric
  hardware decision (can this device do it, is this account enrolled) but differ
  in outcome. Use Case 1 re-verifies a held session. Use Case 2 acquires a new
  session. They should not share a single "biometric succeeded" callback that means
  two different things.
- Neither use case replaces the backend's access-token model. Both end with the app
  holding a valid session; the fingerprint is the local gate or the local login
  input, not a backend credential.

---

## Non-Requirements (Out of Scope v1)

- Fingerprint as a second factor sent to the backend (the backend sees only the
  access token; the fingerprint is a device-local gate).
- Multi-factor authentication beyond the fingerprint (e.g. OTP, TOTP).
- Fingerprint for admin/backend operations.
- Fingerprint on web (mobile only).
