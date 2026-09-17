import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/domain_types.dart';
import '../../core/security/biometric_enrolment.dart';
import '../../core/security/biometric_service.dart';
import '../../core/security/session_store.dart';
import '../verification/verification_providers.dart' show waecApiProvider;

/// Where the candidate is in the auth lifecycle.
///
/// A closed enum rather than a pile of booleans, so the gate in `main.dart` can
/// switch on exactly one value and no combination of flags can render two
/// screens at once.
enum AuthStage {
  /// Reading the stored session and probing biometric capability.
  booting,

  /// No account is known on this device — registration comes first.
  signUp,

  /// An account is known — password required.
  signIn,

  /// A stored, fingerprint-enabled session exists; waiting for a biometric.
  biometricUnlock,

  /// Password sign-in just succeeded and the device can do biometrics but the
  /// candidate has not opted in yet — offer it.
  biometricEnroll,

  /// Session is live; show the app shell.
  authenticated;

  bool get isTerminal => this == AuthStage.authenticated;
}

/// Immutable auth state.
class AuthState {
  const AuthState({
    this.stage = AuthStage.booting,
    this.session,
    this.busy = false,
    this.error,
    this.errorKind,
    this.capability = const BiometricCapability.unsupported(),
    this.lastBiometricOutcome,
    this.rememberedIndex,
    this.offlineFallbackUsed = false,
    this.biometricEnrolled = false,
  });

  final AuthStage stage;
  final AuthSession? session;

  /// A request is in flight; forms disable their submit button.
  final bool busy;

  /// User-presentable error copy. Never contains a password or token.
  final String? error;

  /// Typed error, so a screen can react (e.g. stop retrying on lockout).
  final AuthFailureKind? errorKind;

  final BiometricCapability capability;

  /// Why the last biometric attempt did not succeed, for inline messaging.
  final BiometricOutcome? lastBiometricOutcome;

  /// Index number to pre-fill on the sign-in form.
  final String? rememberedIndex;

  /// True when the current session was provisioned on-device because the Auth
  /// endpoint was unreachable. Surfaced in the UI so the candidate is never
  /// silently running in a degraded mode.
  final bool offlineFallbackUsed;

  /// True when this device already has fingerprint unlock enabled for the
  /// remembered account, per the device-local enrolment record.
  ///
  /// Independent of [session]: it stays true across a sign-out, which is what
  /// lets the sign-in screen offer "Sign in with fingerprint" and lets a
  /// password sign-in restore the fast path without asking the candidate to
  /// re-enrol. See [BiometricEnrolmentStore].
  final bool biometricEnrolled;

  bool get hasError => error != null;
  bool get isAuthenticated =>
      stage == AuthStage.authenticated && session != null;
  bool get biometricsAvailable => capability.canUseBiometricLogin;

  /// True when a passwordless fingerprint sign-in may be offered.
  ///
  /// Requires both an enrolment on this device and a device that can actually
  /// prompt. A session must still exist to unlock, so the sign-in screen pairs
  /// this with its own session check.
  bool get canOfferBiometricSignIn =>
      biometricEnrolled && capability.canUseBiometricLogin;

  /// True when a lockout means "stop trying", not "try again".
  bool get isLockedOut => errorKind == AuthFailureKind.accountLocked;
}

/// Biometric authenticator — overridden in tests with a fake.
final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => LocalAuthBiometricAuthenticator(),
);

/// Secure session storage — overridden in tests with [InMemorySessionStore].
final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SecureSessionStore(),
);

/// Device-local fingerprint enrolment records — overridden in tests with
/// [InMemoryBiometricEnrolmentStore].
///
/// Kept **separate** from [sessionStoreProvider] on purpose: enrolment is a
/// device+account binding that must survive `signOut()`, whereas the session
/// (and its tokens) must not. See [BiometricEnrolmentStore].
final biometricEnrolmentStoreProvider = Provider<BiometricEnrolmentStore>(
  (ref) => SecureBiometricEnrolmentStore(),
);

/// Whether an unreachable Auth endpoint may provision an on-device session.
///
/// Off in release: production never admits a candidate it could not verify
/// (Hard Rule 5 — no weakened-auth fallback shipped to users). On in debug and
/// profile builds so UI work is not blocked by the REST facade that still has
/// to land in front of the Auth gRPC service. Overridable in tests.
final allowOfflineAuthFallbackProvider = Provider<bool>((ref) => !kReleaseMode);

/// TTL for an on-device fallback session. Deliberately short: it is a
/// development convenience, not a credential.
const int offlineSessionTtlSeconds = 60 * 60; // 1 hour

/// Drives the whole auth lifecycle: boot routing, sign-up, sign-in, fingerprint
/// unlock/enrolment, and sign-out.
///
/// Routing rules (all resolved once in [boot]):
/// - a stored session that opted into fingerprint **and** a device with
///   enrolled biometrics -> [AuthStage.biometricUnlock];
/// - otherwise, a known index number -> [AuthStage.signIn] (pre-filled);
/// - otherwise -> [AuthStage.signUp], because a candidate must register before
///   they can sign in.
///
/// A stored session that did *not* enable fingerprint is never silently
/// restored: password sign-in stays mandatory, which is what makes enabling
/// fingerprint the fast path rather than the default.
class AuthController extends StateNotifier<AuthState> {
  AuthController({
    required WaecApi api,
    required SessionStore store,
    required BiometricAuthenticator biometrics,
    required bool allowOfflineFallback,
    BiometricEnrolmentStore? enrolments,
  }) : // Public constructor names map onto private fields; initializing
       // formals would leak the private names into the public signature.
       _api = api, // ignore: prefer_initializing_formals
       _store = store, // ignore: prefer_initializing_formals
       _biometrics = biometrics, // ignore: prefer_initializing_formals
       _allowOfflineFallback = // ignore: prefer_initializing_formals
           allowOfflineFallback,
       _enrolments = enrolments ?? SecureBiometricEnrolmentStore(),
       super(const AuthState()) {
    boot();
  }

  final WaecApi _api;
  final SessionStore _store;
  final BiometricAuthenticator _biometrics;
  final bool _allowOfflineFallback;

  /// Device-local fingerprint enrolment records.
  ///
  /// Deliberately **not** the session store. Enrolment is a device+account
  /// binding that must survive `signOut()`, whereas the session and its tokens
  /// must not. Persisting the opt-in on the session made every sign-out destroy
  /// it, so the candidate was asked to re-enrol after signing back in with
  /// their password — as though the account had only just been created.
  final BiometricEnrolmentStore _enrolments;

  /// Builds the next [AuthState], carrying over every field a transition should
  /// preserve unless the caller explicitly overrides it.
  ///
  /// This exists because hand-written `AuthState(...)` constructions each listed
  /// only the fields that transition cared about, so any newcomer was silently
  /// dropped by the ones that forgot it. `biometricEnrolled` was the casualty
  /// that mattered: `goToSignUp()` / `goToSignIn()` reset it to false, so the
  /// sign-in screen's "Use Fingerprint / Face ID" button vanished the moment the
  /// candidate visited the sign-up form and came back. Routing every transition
  /// through one builder makes that whole class of bug impossible to reintroduce.
  ///
  /// `error` and `lastBiometricOutcome` default to null: a fresh transition
  /// clears the previous attempt's banner.
  AuthState _resume({
    AuthStage? stage,
    AuthSession? session,
    bool clearSession = false,
    bool busy = false,
    String? error,
    AuthFailureKind? errorKind,
    BiometricCapability? capability,
    BiometricOutcome? lastBiometricOutcome,
    String? rememberedIndex,
    bool clearRememberedIndex = false,
    bool? offlineFallbackUsed,
    bool? biometricEnrolled,
  }) => AuthState(
    stage: stage ?? state.stage,
    session: clearSession ? null : (session ?? state.session),
    busy: busy,
    error: error,
    errorKind: errorKind,
    capability: capability ?? state.capability,
    lastBiometricOutcome: lastBiometricOutcome,
    rememberedIndex: clearRememberedIndex
        ? null
        : (rememberedIndex ?? state.rememberedIndex),
    offlineFallbackUsed: offlineFallbackUsed ?? state.offlineFallbackUsed,
    biometricEnrolled: biometricEnrolled ?? state.biometricEnrolled,
  );

  /// Resolves the launch stage. Safe to call again (e.g. after the candidate
  /// enrols a fingerprint in system settings and returns to the app).
  Future<void> boot() async {
    final capability = await _biometrics.capability();
    final stored = await _store.read();
    final remembered = await _store.readRememberedIndex();

    // The enrolment record — not the session flag — is the authority on
    // whether this device may offer fingerprint. A session written by an older
    // build (or restored after a sign-in that pre-dated this store) is still
    // honoured so the fast path never regresses.
    final enrolled =
        stored != null && await _enrolments.isEnrolled(stored.indexNumber);
    final mayUnlock =
        capability.canUseBiometricLogin &&
        stored != null &&
        (enrolled || stored.biometricEnabled);

    if (mayUnlock) {
      state = _resume(
        stage: AuthStage.biometricUnlock,
        session: stored,
        capability: capability,
        rememberedIndex: stored.indexNumber,
        biometricEnrolled: true,
      );
      return;
    }

    final knownIndex = remembered ?? stored?.indexNumber;
    if (knownIndex != null) {
      final enrolledOnDevice =
          capability.canUseBiometricLogin &&
          await _enrolments.isEnrolled(knownIndex);
      state = _resume(
        stage: AuthStage.signIn,
        // A deliberately signed-out device keeps no session, so the sign-in
        // form is the right landing spot. The fingerprint button is offered
        // only when a tap can actually deliver: the account is enrolled AND —
        // with no session to restore — a usable unlock record exists for the
        // refresh exchange. Without the record check, a device whose record
        // was never usable (offline-fallback sign-ins carry no refresh token)
        // advertised a button that could only ever fail.
        session: stored,
        capability: capability,
        rememberedIndex: knownIndex,
        biometricEnrolled:
            enrolledOnDevice &&
            (stored != null || await _store.readUnlockRecord() != null),
      );
      return;
    }

    state = _resume(
      stage: AuthStage.signUp,
      capability: capability,
      clearSession: true,
      clearRememberedIndex: true,
      biometricEnrolled: false,
    );
  }

  /// Re-probes capability without changing the stage — used when returning
  /// from system settings.
  Future<void> refreshCapability() async {
    final capability = await _biometrics.capability();
    state = _resume(
      capability: capability,
      // Capability is precisely what decides whether the offer is still valid.
      biometricEnrolled:
          capability.canUseBiometricLogin &&
          (state.rememberedIndex != null
              ? await _enrolments.isEnrolled(state.rememberedIndex!)
              : false),
    );
  }

  /// Manual switch to the sign-in form ("Already registered? Sign in").
  void goToSignIn() {
    state = _resume(stage: AuthStage.signIn);
  }

  /// Manual switch to the sign-up form ("New here? Create an account").
  void goToSignUp() {
    state = _resume(stage: AuthStage.signUp);
  }

  /// Registers a new account, then lands on [AuthStage.biometricEnroll] when
  /// the device can do biometrics (so the candidate is offered fingerprint at
  /// the moment they are most likely to accept) or straight on
  /// [AuthStage.authenticated] when it cannot.
  Future<void> signUp({
    required String indexNumber,
    required String password,
  }) async {
    if (state.busy) return;
    state = _resume(busy: true);

    try {
      final session = await _api.register(
        indexNumber: indexNumber,
        password: password,
      );
      await _afterCredentialSuccess(session, offline: false);
    } on AuthException catch (e) {
      final offline = await _maybeOfflineSession(e, indexNumber);
      if (offline == null) {
        state = _resume(error: e.message, errorKind: e.kind);
        return;
      }
      await _afterCredentialSuccess(offline, offline: true);
    } on Object {
      state = _resume(
        error: 'Sign-up failed. Please try again.',
        errorKind: AuthFailureKind.unknown,
      );
    }
  }

  /// Signs in with index + password.
  Future<void> signIn({
    required String indexNumber,
    required String password,
  }) async {
    if (state.busy) return;
    state = _resume(busy: true);

    try {
      final session = await _api.login(
        indexNumber: indexNumber,
        password: password,
      );
      await _afterCredentialSuccess(session, offline: false);
    } on AuthException catch (e) {
      final offline = await _maybeOfflineSession(e, indexNumber);
      if (offline == null) {
        state = _resume(error: e.message, errorKind: e.kind);
        return;
      }
      await _afterCredentialSuccess(offline, offline: true);
    } on Object {
      state = _resume(
        error: 'Sign-in failed. Please try again.',
        errorKind: AuthFailureKind.unknown,
      );
    }
  }

  /// Shared tail of a successful password sign-up/sign-in: remember the index,
  /// persist the session, and offer fingerprint when the device supports it.
  Future<void> _afterCredentialSuccess(
    AuthSession session, {
    required bool offline,
  }) async {
    await _store.writeRememberedIndex(session.indexNumber);

    // Restore an existing enrolment instead of re-offering it. This is the fix
    // for "sign out, sign back in, and fingerprint is gone": the device already
    // recorded that this account opted in, so the password sign-in re-establishes
    // the fast path rather than treating the candidate as brand new.
    final alreadyEnrolled =
        state.capability.canUseBiometricLogin &&
        await _enrolments.isEnrolled(session.indexNumber);

    final restored = alreadyEnrolled
        ? session.copyWith(biometricEnabled: true)
        : session;
    await _store.write(restored);

    if (alreadyEnrolled) {
      state = _resume(
        stage: AuthStage.authenticated,
        session: restored,
        rememberedIndex: restored.indexNumber,
        offlineFallbackUsed: offline,
        biometricEnrolled: true,
      );
      // The enrolment survived, so keep the unlock record in step with it: this
      // is what lets the candidate sign out and still use the fingerprint button
      // on the sign-in screen.
      await _store.writeUnlockRecord(
        BiometricUnlockRecord(
          indexNumber: restored.indexNumber,
          refreshToken: restored.refreshToken,
        ),
      );
      return;
    }

    if (state.capability.canUseBiometricLogin) {
      state = _resume(
        stage: AuthStage.biometricEnroll,
        session: restored,
        rememberedIndex: restored.indexNumber,
        offlineFallbackUsed: offline,
      );
      return;
    }

    state = _resume(
      stage: AuthStage.authenticated,
      session: restored,
      rememberedIndex: restored.indexNumber,
      offlineFallbackUsed: offline,
    );
  }

  /// Returns a fallback session when [error] is a network failure and fallback
  /// is permitted; otherwise null so the caller surfaces the real error.
  ///
  /// Release builds set `_allowOfflineFallback` to false, so a production app
  /// never admits a candidate whose password it could not verify.
  Future<AuthSession?> _maybeOfflineSession(
    AuthException error,
    String indexNumber,
  ) async {
    if (!error.isNetworkFailure) return null;
    if (!_allowOfflineFallback) return null;
    if (!IndexNumberValidator.isValid(indexNumber)) return null;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return AuthSession(
      indexNumber: indexNumber,
      userId: '',
      accessToken: '',
      refreshToken: '',
      accessExpiresAtUnix: now + offlineSessionTtlSeconds,
      issuedAtUnix: now,
      source: AuthSessionSource.local,
    );
  }

  /// Runs the fingerprint prompt and, on success, gets the candidate signed in.
  ///
  /// Two sources can authorise the unlock:
  /// - a **live/stored session** (a cold launch with a fingerprint-enabled
  ///   session) — restored as-is;
  /// - a **biometric unlock record** (a deliberately signed-out device) — the
  ///   prompt releases the refresh token, which is exchanged for a fresh
  ///   session. Without this second source the button on the sign-in screen
  ///   after a sign-out had nothing to unlock, so it appeared to do nothing.
  ///
  /// On any non-success the state records the outcome so the screen can either
  /// explain a lockout or drop to the password form — the plan's "biometric
  /// fallback to PIN".
  Future<void> unlockWithBiometrics() async {
    final stored = state.session ?? await _store.read();
    if (stored != null) {
      await _unlockStoredSession(stored);
      return;
    }

    final record = await _store.readUnlockRecord();
    if (record == null) {
      // Nothing on this device can authorise a fingerprint sign-in. Say so,
      // instead of leaving the candidate tapping a button that never responds.
      if (state.stage == AuthStage.biometricUnlock) {
        // A fingerprint-gated launch that lost its session: re-resolve the stage
        // rather than stranding the user on a screen with no way forward.
        await boot();
        return;
      }
      state = _resume(
        stage: AuthStage.signIn,
        error: 'Fingerprint sign-in is not ready for this account on this '
            'device. Sign in with your password, then sign out once — the '
            'fingerprint button will then sign you in.',
        errorKind: AuthFailureKind.unknown,
      );
      return;
    }

    await _unlockFromRecord(record);
  }

  /// Fingerprint-gated restore of a session that is already on the device.
  Future<void> _unlockStoredSession(AuthSession stored) async {
    state = _resume(
      session: stored,
      rememberedIndex: stored.indexNumber,
      busy: true,
    );

    final outcome = await _biometrics.authenticate(
      reason: 'Unlock WAEC Direct to view your results',
    );

    if (outcome.isSuccess) {
      state = _resume(
        stage: AuthStage.authenticated,
        session: stored,
        rememberedIndex: stored.indexNumber,
        biometricEnrolled: true,
      );
      return;
    }

    state = _resume(
      // Stay on the unlock screen for lockouts (retry later); otherwise fall
      // back to the password form.
      stage: outcome.shouldOfferPasswordFallback
          ? AuthStage.signIn
          : AuthStage.biometricUnlock,
      session: stored,
      rememberedIndex: stored.indexNumber,
      lastBiometricOutcome: outcome,
      error: biometricMessageFor(outcome),
    );
  }

  /// Fingerprint sign-in for a signed-out device (Use Case 2 of the fingerprint
  /// plan): the prompt releases the refresh token, the server issues a session.
  ///
  /// The fingerprint is the *local* gate; the refresh token is what actually
  /// proves the identity to the backend. That is why a successful prompt alone
  /// never admits anyone in release builds — the exchange has to succeed too
  /// (Hard Rule 5).
  Future<void> _unlockFromRecord(BiometricUnlockRecord record) async {
    state = _resume(busy: true);

    final outcome = await _biometrics.authenticate(
      reason: 'Sign in to WAEC Direct with your fingerprint',
    );

    if (!outcome.isSuccess) {
      state = _resume(
        stage: AuthStage.signIn,
        lastBiometricOutcome: outcome,
        error: biometricMessageFor(outcome),
      );
      return;
    }

    try {
      final session = await _api.refresh(
        indexNumber: record.indexNumber,
        refreshToken: record.refreshToken,
      );
      final restored = session.copyWith(biometricEnabled: true);
      await _store.write(restored);
      await _store.writeRememberedIndex(restored.indexNumber);
      await _store.writeUnlockRecord(
        BiometricUnlockRecord(
          indexNumber: restored.indexNumber,
          // A rotated refresh token: keep the newest one so the next sign-out
          // stores a usable record.
          refreshToken: restored.refreshToken,
        ),
      );
      state = _resume(
        stage: AuthStage.authenticated,
        session: restored,
        rememberedIndex: restored.indexNumber,
        biometricEnrolled: true,
      );
    } catch (error) {
      final offline = _offlineUnlockSession(record);
      if (offline != null) {
        await _store.write(offline);
        state = _resume(
          stage: AuthStage.authenticated,
          session: offline,
          rememberedIndex: offline.indexNumber,
          offlineFallbackUsed: true,
          biometricEnrolled: true,
        );
        return;
      }
      // Release builds land here: the sensor said yes but the server could not
      // be reached, so the candidate falls back to their password. Fail closed.
      state = _resume(
        stage: AuthStage.signIn,
        error: 'Fingerprint unlock could not reach WAEC. '
            'Sign in with your password.',
        errorKind: AuthFailureKind.unreachable,
      );
    }
  }

  /// On-device session for a successful fingerprint unlock whose token exchange
  /// could not complete. Debug/profile only (Hard Rule 5); null in release.
  AuthSession? _offlineUnlockSession(BiometricUnlockRecord record) {
    if (!_allowOfflineFallback) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return AuthSession(
      indexNumber: record.indexNumber,
      userId: '',
      accessToken: '',
      refreshToken: record.refreshToken,
      accessExpiresAtUnix: now + offlineSessionTtlSeconds,
      issuedAtUnix: now,
      source: AuthSessionSource.local,
      biometricEnabled: true,
    );
  }

  /// Opts in to fingerprint unlock after a successful password sign-in.
  ///
  /// Verifies a real biometric before flipping the flag — otherwise a candidate
  /// could "enable" fingerprint on a device with nothing enrolled and then be
  /// locked out of their own fast path. Also binds the platform key to the
  /// account (plan §2.1); that call is best-effort and never blocks.
  Future<void> enableBiometrics() async {
    final session = state.session;
    if (session == null) return;

    state = _resume(session: session, busy: true);

    final outcome = await _biometrics.authenticate(
      reason: 'Confirm your fingerprint to enable quick unlock',
    );

    if (!outcome.isSuccess) {
      state = _resume(
        stage: AuthStage.biometricEnroll,
        session: session,
        lastBiometricOutcome: outcome,
        error: biometricMessageFor(outcome),
      );
      return;
    }

    final enabled = session.copyWith(biometricEnabled: true);
    await _store.write(enabled);

    // Persist the enrolment as a device+account binding so it outlives the
    // session. Without this the opt-in dies at the next sign-out.
    await _enrolments.enroll(enabled.indexNumber);

    // And keep a record the sign-in screen can spend after a sign-out, so
    // "Use Fingerprint / Face ID" has something to exchange for a session.
    await _store.writeUnlockRecord(
      BiometricUnlockRecord(
        indexNumber: enabled.indexNumber,
        refreshToken: enabled.refreshToken,
      ),
    );

    // Server-side binding is fire-and-forget: the on-device unlock already
    // works, and a facade outage must not strand the candidate on this screen.
    if (enabled.accessToken.isNotEmpty) {
      unawaited(
        _api
            .bindBiometric(
              accessToken: enabled.accessToken,
              platformPublicKey: deviceBiometricKeyId,
            )
            .catchError((Object _) => false),
      );
    }

    state = _resume(
      stage: AuthStage.authenticated,
      session: enabled,
      rememberedIndex: enabled.indexNumber,
      biometricEnrolled: true,
    );
  }

  /// Declines the fingerprint offer and continues into the app.
  void declineBiometrics() {
    final session = state.session;
    if (session == null) return;
    state = _resume(
      stage: AuthStage.authenticated,
      session: session,
      rememberedIndex: session.indexNumber,
    );
  }

  /// Turns fingerprint unlock off and drops the stored session, so the next
  /// launch requires the password again. The remembered index is kept.
  ///
  /// **Requires a fresh fingerprint to confirm.** Turning the protection off is
  /// exactly the action an unauthorised person holding an unlocked phone would
  /// want to take, so it is gated the same way the fast path itself is. A failed
  /// or cancelled prompt changes nothing.
  ///
  /// Returns the outcome so the caller can explain a cancellation inline. A
  /// switch's `onChanged` is `void`, so it is the screen's job to await this.
  Future<BiometricOutcome?> disableBiometrics() async {
    final session = state.session;

    final outcome = await _biometrics.authenticate(
      reason: 'Confirm your fingerprint to turn off quick unlock',
    );
    if (!outcome.isSuccess) {
      state = _resume(
        lastBiometricOutcome: outcome,
        error: biometricMessageFor(outcome),
      );
      return outcome;
    }

    if (session != null) {
      await _store.write(session.copyWith(biometricEnabled: false));
      // Opt-out must remove the device+account binding, otherwise the next
      // password sign-in would silently re-enable the fast path the candidate
      // just turned off.
      await _enrolments.revoke(session.indexNumber);
    }
    await _store.clear();
    // The unlock record is the fingerprint sign-in; an opt-out revokes it too.
    await _store.clearUnlockRecord();
    state = _resume(
      session: session?.copyWith(biometricEnabled: false),
      biometricEnrolled: false,
    );
    return outcome;
  }

  /// Ends the session but keeps the remembered index (next launch -> sign-in).
  ///
  /// **Keeps the fingerprint enrolment.** Sign-out must destroy the session and
  /// its tokens, but enrolment is a device+account binding: wiping it here was
  /// what forced candidates to re-enrol after every sign-out. The next password
  /// sign-in restores the fast path from the enrolment record.
  Future<void> signOut() async {
    final session = state.session;
    // The account identity must not depend on the remembered index having been
    // set: a sign-up → enable → sign-out pass reached this line with
    // `rememberedIndex` null, which silently downgraded `enrolled` to false and
    // threw away the binding. The session knows the account too.
    final remembered = state.rememberedIndex ?? session?.indexNumber;
    final enrolled =
        remembered != null && await _enrolments.isEnrolled(remembered);

    // Sign-out destroys the session and its tokens. What it must *not* destroy
    // is the candidate's ability to use the fingerprint button on the sign-in
    // screen, so an enrolled account leaves behind the minimum needed to mint a
    // new session after a successful prompt: the index and the refresh token,
    // under their own secure key (see [BiometricUnlockRecord]).
    if (enrolled && session != null) {
      await _store.writeUnlockRecord(
        BiometricUnlockRecord(
          indexNumber: remembered,
          refreshToken: session.refreshToken,
        ),
      );
    } else if (!enrolled) {
      // Nothing is enrolled, so no fingerprint sign-in may be offered: drop any
      // record left over from a previous account on this device. (Enrolled but
      // session-less — a torn state — keeps any existing record: the binding is
      // real, and a record written by an earlier sign-out stays valid.)
      await _store.clearUnlockRecord();
    }

    await _store.clear();

    // The button's promise must match what a tap can actually deliver: it
    // signs in by exchanging the unlock record for a fresh session. When the
    // session's refresh token was empty — the offline-fallback sessions debug
    // builds mint when the backend is unreachable — the write above was
    // refused, and offering the button would only ever produce an error.
    // Reading back keeps promise and reality in lock-step: a record left by an
    // earlier, fully-online sign-out keeps the button available.
    final record = await _store.readUnlockRecord();
    state = _resume(
      stage: AuthStage.signIn,
      clearSession: true,
      rememberedIndex: remembered,
      biometricEnrolled: record != null,
    );
  }

  /// Forgets this device entirely (next launch -> sign-up).
  ///
  /// Unlike [signOut], this *does* revoke enrolment: the candidate asked the
  /// device to forget them, so the fingerprint binding — and the unlock record
  /// that goes with it — goes too.
  Future<void> forgetDevice() async {
    await _store.clearAll();
    await _store.clearUnlockRecord();
    await _enrolments.revokeAll();
    state = _resume(
      stage: AuthStage.signUp,
      clearSession: true,
      clearRememberedIndex: true,
      biometricEnrolled: false,
    );
  }

  /// Drops the inline error banner without changing the stage.
  void clearError() {
    state = _resume(lastBiometricOutcome: state.lastBiometricOutcome);
  }
}

/// Stable identifier sent to `BindBiometric` as the platform public key.
///
/// A full attested Keystore/Secure-Enclave key pair requires native code on
/// both platforms; until that lands, the client reports a stable per-install
/// device identifier so the server can still tell *which* device is
/// fingerprint-enabled. Swapping in a real attested public key later is a
/// drop-in change at this one call site.
const String deviceBiometricKeyId = 'waec-direct-local-auth-v1';

/// Human-readable copy for a biometric outcome.
///
/// Fixed local strings only, so nothing platform-internal leaks into the UI.
String? biometricMessageFor(BiometricOutcome outcome) => switch (outcome) {
  BiometricOutcome.success => null,
  BiometricOutcome.userCanceled =>
    'Fingerprint cancelled. Use your password to continue.',
  BiometricOutcome.systemCanceled =>
    'Fingerprint was interrupted. Please try again.',
  BiometricOutcome.timeout => 'Fingerprint timed out. Please try again.',
  BiometricOutcome.temporaryLockout =>
    'Too many fingerprint attempts. Please try again in a few minutes.',
  BiometricOutcome.permanentLockout =>
    'Fingerprint is locked. Unlock your device with its passcode, then retry.',
  BiometricOutcome.noHardware =>
    'This device has no fingerprint sensor. Use your password.',
  BiometricOutcome.notEnrolled =>
    'No fingerprint is enrolled on this device yet.',
  BiometricOutcome.noDeviceCredential =>
    'Set a device passcode or fingerprint to use quick unlock.',
  BiometricOutcome.temporarilyUnavailable =>
    'The fingerprint sensor is busy. Please try again.',
  BiometricOutcome.userRequestedFallback => 'Use your password to continue.',
  BiometricOutcome.alreadyInProgress => 'A fingerprint prompt is already open.',
  BiometricOutcome.failed => 'Fingerprint did not succeed. Please try again.',
};

/// The auth controller. Overridden in tests to inject fakes.
final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    return AuthController(
      api: ref.watch(waecApiProvider),
      store: ref.watch(sessionStoreProvider),
      biometrics: ref.watch(biometricAuthenticatorProvider),
      allowOfflineFallback: ref.watch(allowOfflineAuthFallbackProvider),
      enrolments: ref.watch(biometricEnrolmentStoreProvider),
    );
  },
);
