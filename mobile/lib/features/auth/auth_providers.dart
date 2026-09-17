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
      state = AuthState(
        stage: AuthStage.biometricUnlock,
        session: stored,
        capability: capability,
        rememberedIndex: stored.indexNumber,
      );
      return;
    }

    final knownIndex = remembered ?? stored?.indexNumber;
    if (knownIndex != null) {
      state = AuthState(
        stage: AuthStage.signIn,
        capability: capability,
        rememberedIndex: knownIndex,
        // Tells the sign-in screen it may show "Sign in with fingerprint"
        // once a session exists to unlock.
        biometricEnrolled:
            capability.canUseBiometricLogin &&
            await _enrolments.isEnrolled(knownIndex),
      );
      return;
    }

    state = AuthState(stage: AuthStage.signUp, capability: capability);
  }

  /// Re-probes capability without changing the stage — used when returning
  /// from system settings.
  Future<void> refreshCapability() async {
    final capability = await _biometrics.capability();
    state = AuthState(
      stage: state.stage,
      session: state.session,
      capability: capability,
      rememberedIndex: state.rememberedIndex,
      offlineFallbackUsed: state.offlineFallbackUsed,
    );
  }

  /// Manual switch to the sign-in form ("Already registered? Sign in").
  void goToSignIn() {
    state = AuthState(
      stage: AuthStage.signIn,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      session: state.session,
    );
  }

  /// Manual switch to the sign-up form ("New here? Create an account").
  void goToSignUp() {
    state = AuthState(
      stage: AuthStage.signUp,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
    );
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
    state = AuthState(
      stage: state.stage,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      busy: true,
    );

    try {
      final session = await _api.register(
        indexNumber: indexNumber,
        password: password,
      );
      await _afterCredentialSuccess(session, offline: false);
    } on AuthException catch (e) {
      final offline = await _maybeOfflineSession(e, indexNumber);
      if (offline == null) {
        state = AuthState(
          stage: state.stage,
          capability: state.capability,
          rememberedIndex: state.rememberedIndex,
          error: e.message,
          errorKind: e.kind,
        );
        return;
      }
      await _afterCredentialSuccess(offline, offline: true);
    } on Object {
      state = AuthState(
        stage: state.stage,
        capability: state.capability,
        rememberedIndex: state.rememberedIndex,
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
    state = AuthState(
      stage: state.stage,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      busy: true,
    );

    try {
      final session = await _api.login(
        indexNumber: indexNumber,
        password: password,
      );
      await _afterCredentialSuccess(session, offline: false);
    } on AuthException catch (e) {
      final offline = await _maybeOfflineSession(e, indexNumber);
      if (offline == null) {
        state = AuthState(
          stage: state.stage,
          capability: state.capability,
          rememberedIndex: state.rememberedIndex,
          error: e.message,
          errorKind: e.kind,
        );
        return;
      }
      await _afterCredentialSuccess(offline, offline: true);
    } on Object {
      state = AuthState(
        stage: state.stage,
        capability: state.capability,
        rememberedIndex: state.rememberedIndex,
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
      state = AuthState(
        stage: AuthStage.authenticated,
        session: restored,
        capability: state.capability,
        rememberedIndex: restored.indexNumber,
        offlineFallbackUsed: offline,
        biometricEnrolled: true,
      );
      return;
    }

    if (state.capability.canUseBiometricLogin) {
      state = AuthState(
        stage: AuthStage.biometricEnroll,
        session: restored,
        capability: state.capability,
        rememberedIndex: restored.indexNumber,
        offlineFallbackUsed: offline,
      );
      return;
    }

    state = AuthState(
      stage: AuthStage.authenticated,
      session: restored,
      capability: state.capability,
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

  /// Runs the fingerprint prompt for the stored session (plan §3.2).
  ///
  /// On success the stored session is restored and the candidate lands in the
  /// shell. On any non-success the state records the outcome so the screen can
  /// either explain a lockout or drop to the password form — the plan's
  /// "biometric fallback to PIN".
  Future<void> unlockWithBiometrics() async {
    final stored = state.session ?? await _store.read();
    if (stored == null) {
      await boot();
      return;
    }

    state = AuthState(
      stage: state.stage,
      session: stored,
      capability: state.capability,
      rememberedIndex: stored.indexNumber,
      offlineFallbackUsed: state.offlineFallbackUsed,
      busy: true,
    );

    final outcome = await _biometrics.authenticate(
      reason: 'Unlock WAEC Direct to view your results',
    );

    if (outcome.isSuccess) {
      state = AuthState(
        stage: AuthStage.authenticated,
        session: stored,
        capability: state.capability,
        rememberedIndex: stored.indexNumber,
        offlineFallbackUsed: state.offlineFallbackUsed,
      );
      return;
    }

    state = AuthState(
      // Stay on the unlock screen for lockouts (retry later); otherwise fall
      // back to the password form.
      stage: outcome.shouldOfferPasswordFallback
          ? AuthStage.signIn
          : AuthStage.biometricUnlock,
      session: stored,
      capability: state.capability,
      rememberedIndex: stored.indexNumber,
      offlineFallbackUsed: state.offlineFallbackUsed,
      lastBiometricOutcome: outcome,
      error: biometricMessageFor(outcome),
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

    state = AuthState(
      stage: state.stage,
      session: session,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      offlineFallbackUsed: state.offlineFallbackUsed,
      busy: true,
    );

    final outcome = await _biometrics.authenticate(
      reason: 'Confirm your fingerprint to enable quick unlock',
    );

    if (!outcome.isSuccess) {
      state = AuthState(
        stage: AuthStage.biometricEnroll,
        session: session,
        capability: state.capability,
        rememberedIndex: state.rememberedIndex,
        offlineFallbackUsed: state.offlineFallbackUsed,
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

    state = AuthState(
      stage: AuthStage.authenticated,
      session: enabled,
      capability: state.capability,
      rememberedIndex: enabled.indexNumber,
      offlineFallbackUsed: state.offlineFallbackUsed,
      biometricEnrolled: true,
    );
  }

  /// Declines the fingerprint offer and continues into the app.
  void declineBiometrics() {
    final session = state.session;
    if (session == null) return;
    state = AuthState(
      stage: AuthStage.authenticated,
      session: session,
      capability: state.capability,
      rememberedIndex: session.indexNumber,
      offlineFallbackUsed: state.offlineFallbackUsed,
    );
  }

  /// Turns fingerprint unlock off and drops the stored session, so the next
  /// launch requires the password again. The remembered index is kept.
  Future<void> disableBiometrics() async {
    final session = state.session;
    if (session != null) {
      await _store.write(session.copyWith(biometricEnabled: false));
      // Opt-out must remove the device+account binding, otherwise the next
      // password sign-in would silently re-enable the fast path the candidate
      // just turned off.
      await _enrolments.revoke(session.indexNumber);
    }
    await _store.clear();
    state = AuthState(
      stage: state.stage,
      session: session?.copyWith(biometricEnabled: false),
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      offlineFallbackUsed: state.offlineFallbackUsed,
      biometricEnrolled: false,
    );
  }

  /// Ends the session but keeps the remembered index (next launch -> sign-in).
  ///
  /// **Keeps the fingerprint enrolment.** Sign-out must destroy the session and
  /// its tokens, but enrolment is a device+account binding: wiping it here was
  /// what forced candidates to re-enrol after every sign-out. The next password
  /// sign-in restores the fast path from the enrolment record.
  Future<void> signOut() async {
    final remembered = state.rememberedIndex;
    await _store.clear();
    state = AuthState(
      stage: AuthStage.signIn,
      capability: state.capability,
      rememberedIndex: remembered,
      biometricEnrolled:
          remembered != null && await _enrolments.isEnrolled(remembered),
    );
  }

  /// Forgets this device entirely (next launch -> sign-up).
  ///
  /// Unlike [signOut], this *does* revoke enrolment: the candidate asked the
  /// device to forget them, so the fingerprint binding goes too.
  Future<void> forgetDevice() async {
    await _store.clearAll();
    await _enrolments.revokeAll();
    state = AuthState(stage: AuthStage.signUp, capability: state.capability);
  }

  /// Drops the inline error banner without changing the stage.
  void clearError() {
    state = AuthState(
      stage: state.stage,
      session: state.session,
      capability: state.capability,
      rememberedIndex: state.rememberedIndex,
      offlineFallbackUsed: state.offlineFallbackUsed,
      lastBiometricOutcome: state.lastBiometricOutcome,
    );
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
