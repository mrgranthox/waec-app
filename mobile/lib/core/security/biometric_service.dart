import 'package:flutter/services.dart' show PlatformException;
import 'package:local_auth/local_auth.dart';

/// Result of a single biometric authentication attempt.
///
/// Modelled as a closed enum rather than a bool so callers can distinguish
/// "user backed out" (offer the password form) from "sensor is locked out"
/// (tell them to come back later) from "this device has no fingerprint
/// hardware" (never show the fingerprint affordance again). Plan §3.2
/// acceptance is "biometric fallback to PIN", which only works if the UI knows
/// *why* biometrics did not succeed.
enum BiometricOutcome {
  /// The user authenticated.
  success,

  /// The user dismissed the prompt. Not an error — fall back to password.
  userCanceled,

  /// The OS cancelled the prompt (e.g. the app was backgrounded and
  /// `stickyAuth` could not resume it).
  systemCanceled,

  /// The prompt timed out without a decision.
  timeout,

  /// Too many failed attempts; the sensor is briefly locked. Retry later.
  temporaryLockout,

  /// Locked until the device credential (passcode/pattern) is entered once.
  /// The user must resolve this in system settings; we cannot clear it.
  permanentLockout,

  /// No biometric sensor on this device.
  noHardware,

  /// Sensor present but the user has not enrolled any biometrics.
  notEnrolled,

  /// Neither biometrics nor a device credential are configured.
  noDeviceCredential,

  /// Sensor exists but is momentarily unusable (in use by another app, or
  /// previously-paired external hardware is disconnected).
  temporarilyUnavailable,

  /// The user explicitly asked for a non-biometric option via system UI.
  userRequestedFallback,

  /// An authentication attempt is already outstanding.
  alreadyInProgress,

  /// Any other device-level or unmapped failure.
  failed;

  bool get isSuccess => this == BiometricOutcome.success;

  /// True when the right response is to show the password/PIN form.
  ///
  /// Deliberately excludes the lockouts: silently dropping a locked-out user
  /// onto the password form invites them to hammer it and trip the server-side
  /// brute-force lockout (plan §4.6, 5 failures -> 15 min).
  bool get shouldOfferPasswordFallback =>
      switch (this) {
        BiometricOutcome.userCanceled ||
        BiometricOutcome.systemCanceled ||
        BiometricOutcome.timeout ||
        BiometricOutcome.noHardware ||
        BiometricOutcome.notEnrolled ||
        BiometricOutcome.noDeviceCredential ||
        BiometricOutcome.temporarilyUnavailable ||
        BiometricOutcome.userRequestedFallback ||
        BiometricOutcome.failed => true,
        BiometricOutcome.success ||
        BiometricOutcome.temporaryLockout ||
        BiometricOutcome.permanentLockout ||
        BiometricOutcome.alreadyInProgress => false,
      };

  /// True when the device cannot do biometrics at all, so the fingerprint
  /// affordance should be hidden rather than shown-and-failing.
  bool get isUnsupportedDevice =>
      this == BiometricOutcome.noHardware ||
      this == BiometricOutcome.noDeviceCredential;
}

/// What this device can actually do, probed before any prompt is shown.
class BiometricCapability {
  const BiometricCapability({
    required this.hardwareSupported,
    required this.deviceSupported,
    required this.enrolled,
  });

  /// Nothing works on this device (also the safe default if the probe throws).
  const BiometricCapability.unsupported()
    : hardwareSupported = false,
      deviceSupported = false,
      enrolled = const <BiometricType>[];

  /// `canCheckBiometrics`: the device has biometric hardware.
  final bool hardwareSupported;

  /// `isDeviceSupported()`: biometrics *or* a device-credential fallback.
  final bool deviceSupported;

  /// Biometrics the user has actually enrolled. `canCheckBiometrics` alone is
  /// not enough — hardware can exist with nothing enrolled.
  final List<BiometricType> enrolled;

  bool get hasEnrolledBiometrics => enrolled.isNotEmpty;

  /// Gate for showing the fingerprint affordance at all.
  bool get canUseBiometricLogin => hardwareSupported && hasEnrolledBiometrics;

  /// Copy suitable for logging — never includes anything identifying.
  @override
  String toString() =>
      'BiometricCapability(hardware: $hardwareSupported, '
      'device: $deviceSupported, enrolled: ${enrolled.length})';
}

/// Platform-independent biometric contract.
///
/// Injected everywhere instead of calling `LocalAuthentication` directly, so
/// the whole fingerprint flow is unit-testable without a device or a method
/// channel (see test/biometric_service_test.dart).
abstract interface class BiometricAuthenticator {
  /// Probes hardware + enrolment. Must never throw — returns
  /// [BiometricCapability.unsupported] on any platform error.
  Future<BiometricCapability> capability();

  /// Runs one authentication prompt. Never throws; every failure mode is
  /// reported as a [BiometricOutcome].
  Future<BiometricOutcome> authenticate({required String reason});

  /// Cancels an in-flight prompt. Best effort.
  Future<bool> stop();
}

/// `local_auth`-backed implementation (plan §3.2).
///
/// Configuration choices:
/// - `biometricOnly: true` — this is the *fingerprint* path. The plan's
///   "fallback to PIN" means our own branded password form, not the OS
///   passcode sheet, so we never silently accept a weaker factor.
/// - `stickyAuth: true` — resumes the prompt when the app is foregrounded
///   instead of failing outright. Matters on Ghanaian networks where an
///   incoming call or tower handoff backgrounds the app mid-prompt.
/// - `sensitiveTransaction: true` — keeps the platform's extra confirmation
///   step (e.g. after face unlock) because unlocking grants access to exam
///   results and payment history.
/// - `useErrorDialogs: false` — we render our own error copy from
///   [BiometricOutcome] rather than the plugin's generic dialogs.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  static const AuthenticationOptions _options = AuthenticationOptions(
    biometricOnly: true,
    stickyAuth: true,
    sensitiveTransaction: true,
    useErrorDialogs: false,
  );

  @override
  Future<BiometricCapability> capability() async {
    try {
      // Run the probes concurrently: they are independent method-channel
      // round-trips and the splash gate is waiting on this.
      final results = await Future.wait(<Future<Object>>[
        _auth.canCheckBiometrics,
        _auth.isDeviceSupported(),
        _auth.getAvailableBiometrics(),
      ]);
      return BiometricCapability(
        hardwareSupported: results[0] as bool,
        deviceSupported: results[1] as bool,
        enrolled: (results[2] as List<BiometricType>).toList(growable: false),
      );
    } on Object {
      // Simulators, desktop, and unsupported platforms land here. Degrading to
      // "no biometrics" keeps the password path — the plan's required fallback.
      return const BiometricCapability.unsupported();
    }
  }

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    assert(reason.isNotEmpty, 'localizedReason must not be empty');
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: _options,
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.userCanceled;
    } on PlatformException catch (e) {
      return mapBiometricErrorCode(e.code);
    } on Object {
      return BiometricOutcome.failed;
    }
  }

  @override
  Future<bool> stop() async {
    try {
      return await _auth.stopAuthentication();
    } on Object {
      return false;
    }
  }
}

/// Maps a plugin error code onto a [BiometricOutcome].
///
/// Both spellings are accepted: the classic local_auth 2.x Android codes
/// (`noHardware`, `lockedOut`, ...) and the newer `LocalAuthExceptionCode`
/// names (`noBiometricHardware`, `temporaryLockout`, ...). Matching both makes
/// the mapping survive a plugin major-version bump without silently degrading
/// every failure into [BiometricOutcome.failed].
BiometricOutcome mapBiometricErrorCode(String? code) {
  switch (code) {
    // -- cancellation / timing -------------------------------------------
    case 'Canceled':
    case 'UserCancel':
    case 'userCanceled':
      return BiometricOutcome.userCanceled;
    case 'Timeout':
    case 'timeout':
      return BiometricOutcome.timeout;
    case 'SystemCancel':
    case 'systemCanceled':
      return BiometricOutcome.systemCanceled;

    // -- capability -------------------------------------------------------
    case 'noHardware':
    case 'NoHardware':
    case 'noBiometricHardware':
      return BiometricOutcome.noHardware;
    case 'notEnrolled':
    case 'NotEnrolled':
    case 'noBiometricsEnrolled':
      return BiometricOutcome.notEnrolled;
    case 'notAvailable':
    case 'NotAvailable':
    case 'biometricHardwareTemporarilyUnavailable':
      return BiometricOutcome.temporarilyUnavailable;
    case 'passcodeNotSet':
    case 'PasscodeNotSet':
    case 'noCredentialsSet':
      return BiometricOutcome.noDeviceCredential;

    // -- lockouts ---------------------------------------------------------
    case 'lockedOut':
    case 'LockedOut':
    case 'temporaryLockout':
      return BiometricOutcome.temporaryLockout;
    case 'permanentlyLockedOut':
    case 'PermanentlyLockedOut':
    case 'biometricLockout':
      return BiometricOutcome.permanentLockout;

    // -- misc -------------------------------------------------------------
    case 'userRequestedFallback':
      return BiometricOutcome.userRequestedFallback;
    case 'authInProgress':
    case 'AuthInProgress':
      return BiometricOutcome.alreadyInProgress;
    default:
      return BiometricOutcome.failed;
  }
}
