import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain_types.dart';

/// Device-local record of *which* index numbers have fingerprint unlock
/// enabled on **this** device.
///
/// ## Why this exists separately from [AuthSession.biometricEnabled]
///
/// Enrolment is a **device + account binding**, not a property of a session.
/// Modelling it as a session field means `signOut()` — which must destroy the
/// session tokens — also destroys the enrolment, so the candidate is asked to
/// re-enrol after every sign-out as though they had just created the account.
/// That is the regression this store fixes.
///
/// Lifecycle contract:
/// - written by `AuthController.enableBiometric()`
/// - removed by `AuthController.disableBiometric()`
/// - **survives** `signOut()` (session cleared, enrolment kept)
/// - removed by `forgetDevice()` (the device is asked to forget the candidate)
///
/// Abstract so the whole flow is unit-testable with
/// [InMemoryBiometricEnrolmentStore] — no Keystore, no Keychain, no channel.
abstract interface class BiometricEnrolmentStore {
  /// True when [indexNumber] has fingerprint unlock enabled on this device.
  ///
  /// Must never throw: a corrupt entry reads as "not enrolled" so launch
  /// degrades to the password path instead of crashing.
  Future<bool> isEnrolled(String indexNumber);

  /// Every index number enrolled on this device. Used at boot to decide
  /// whether a passwordless unlock may be offered.
  Future<Set<String>> enrolled();

  /// Records fingerprint unlock as enabled for [indexNumber].
  Future<void> enroll(String indexNumber);

  /// Removes the enrolment for [indexNumber] (opt-out, or credential revoked).
  Future<void> revoke(String indexNumber);

  /// Full wipe — used by "forget this device".
  Future<void> revokeAll();
}

/// Keystore/Keychain-backed [BiometricEnrolmentStore].
///
/// Same hardening posture as [SecureSessionStore]: Android values live in
/// EncryptedSharedPreferences whose master key is in the Android Keystore;
/// iOS items are non-migrating and never synchronised to iCloud.
///
/// Only index numbers are stored here — no token, no password, no biometric
/// template (the OS never exposes templates; `local_auth` only answers
/// yes/no). An index number is the candidate's own exam number, not a secret,
/// but it is kept in secure storage so it never lands in a world-readable
/// preferences file.
class SecureBiometricEnrolmentStore implements BiometricEnrolmentStore {
  SecureBiometricEnrolmentStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              encryptedSharedPreferences: true,
              resetOnError: true,
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;

  /// Storage key. Namespaced so it cannot collide with the session entry.
  static const String enrolmentKey = 'waec_direct.biometric.enrolled';

  @override
  Future<Set<String>> enrolled() async {
    try {
      final raw = await _storage.read(key: enrolmentKey);
      if (raw == null || raw.isEmpty) return <String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      // Re-validate on the way out: a tampered or truncated entry must not
      // pre-fill an unlock offer for a malformed index.
      return decoded
          .whereType<String>()
          .where(IndexNumberValidator.isValid)
          .toSet();
    } on Object {
      // Corrupt JSON or a keystore the OS will not release. Best-effort
      // cleanup so the next launch is not stuck on the same entry.
      await revokeAll();
      return <String>{};
    }
  }

  @override
  Future<bool> isEnrolled(String indexNumber) async {
    if (!IndexNumberValidator.isValid(indexNumber)) return false;
    return (await enrolled()).contains(indexNumber);
  }

  @override
  Future<void> enroll(String indexNumber) async {
    if (!IndexNumberValidator.isValid(indexNumber)) return;
    final next = await enrolled()
      ..add(indexNumber);
    await _persist(next);
  }

  @override
  Future<void> revoke(String indexNumber) async {
    final next = await enrolled()
      ..remove(indexNumber);
    await _persist(next);
  }

  @override
  Future<void> revokeAll() async {
    try {
      await _storage.delete(key: enrolmentKey);
    } on Object {
      // Nothing actionable: if the platform cannot delete, the value was
      // almost certainly never readable either.
    }
  }

  Future<void> _persist(Set<String> values) async {
    await _storage.write(
      key: enrolmentKey,
      value: jsonEncode(values.toList(growable: false)..sort()),
    );
  }
}

/// In-memory [BiometricEnrolmentStore] for tests and for platforms without
/// secure storage.
class InMemoryBiometricEnrolmentStore implements BiometricEnrolmentStore {
  InMemoryBiometricEnrolmentStore({Iterable<String>? enrolled})
    : _enrolled = <String>{...?enrolled?.where(IndexNumberValidator.isValid)};

  final Set<String> _enrolled;

  /// Number of [enroll] calls, so tests can assert a value was saved.
  int enrollCount = 0;

  /// Number of [revoke] calls.
  int revokeCount = 0;

  /// Number of [revokeAll] calls — asserted by the sign-out test to prove
  /// sign-out does NOT wipe enrolment.
  int revokeAllCount = 0;

  @override
  Future<Set<String>> enrolled() async => Set<String>.unmodifiable(_enrolled);

  @override
  Future<bool> isEnrolled(String indexNumber) async {
    if (!IndexNumberValidator.isValid(indexNumber)) return false;
    return _enrolled.contains(indexNumber);
  }

  @override
  Future<void> enroll(String indexNumber) async {
    if (!IndexNumberValidator.isValid(indexNumber)) return;
    enrollCount++;
    _enrolled.add(indexNumber);
  }

  @override
  Future<void> revoke(String indexNumber) async {
    revokeCount++;
    _enrolled.remove(indexNumber);
  }

  @override
  Future<void> revokeAll() async {
    revokeAllCount++;
    _enrolled.clear();
  }
}
