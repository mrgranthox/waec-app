import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain_types.dart';

/// What a signed-out device keeps so the fingerprint button on the sign-in
/// screen can actually sign the candidate back in.
///
/// Sign-out has to destroy the session and its tokens. But a fingerprint
/// sign-in then needs *something* to exchange for a new session once the sensor
/// says yes, otherwise the button can only ever restore a session that no longer
/// exists — which is exactly why it did nothing. This record is that something:
/// the minimum needed to call `refresh`, kept under its own secure-storage key,
/// released only after a successful biometric prompt, and deleted by opt-out or
/// "forget this device".
///
/// Deliberately **not** a session: it carries no access token, so it cannot be
/// used to reach the backend on its own. A refresh token is single-use and
/// rotates on exchange, so a device copy is usable once and then dead — and
/// unlike the password it is revocable server-side.
class BiometricUnlockRecord {
  const BiometricUnlockRecord({
    required this.indexNumber,
    required this.refreshToken,
  });

  final String indexNumber;
  final String refreshToken;

  /// True when this record is worth keeping/presenting.
  bool get isUsable =>
      IndexNumberValidator.isValid(indexNumber) && refreshToken.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index_number': indexNumber,
    'refresh_token': refreshToken,
  };

  /// Returns null rather than throwing for anything unusable: a corrupt or
  /// truncated record must degrade to the password path, never crash launch.
  static BiometricUnlockRecord? fromJson(Map<String, dynamic> json) {
    final index = json['index_number'];
    final token = json['refresh_token'];
    if (index is! String || token is! String) return null;
    final record = BiometricUnlockRecord(
      indexNumber: index,
      refreshToken: token,
    );
    return record.isUsable ? record : null;
  }

  /// Never prints the token (Hard Rule 1).
  @override
  String toString() => 'BiometricUnlockRecord($indexNumber)';
}

/// Persistence contract for the biometric-unlockable [AuthSession].
///
/// Abstract so the whole fingerprint flow can be unit-tested with
/// [InMemorySessionStore] — no Keychain, no Keystore, no method channel.
abstract interface class SessionStore {
  /// The stored session, or null when there is none / it could not be decoded.
  ///
  /// Must never throw: a corrupt entry is treated as "no session" so launch
  /// degrades to the sign-in form instead of crashing.
  Future<AuthSession?> read();

  /// Persists [session], replacing any previous one.
  Future<void> write(AuthSession session);

  /// Removes the session but keeps the remembered index number, so the next
  /// launch offers *sign in* rather than asking the candidate to register an
  /// account that already exists.
  Future<void> clear();

  /// The index number last used on this device, or null.
  ///
  /// Not a secret (it is the candidate's own exam index), but it is kept in
  /// secure storage anyway so it never lands in a world-readable prefs file.
  Future<String?> readRememberedIndex();

  /// Records [indexNumber] as the device's known account.
  Future<void> writeRememberedIndex(String indexNumber);

  /// Full wipe: session *and* remembered account. Used when the candidate
  /// explicitly wants this device to forget them.
  Future<void> clearAll();

  /// The biometric unlock record, or null when there is none / it is unusable.
  ///
  /// Must never throw (a corrupt entry reads as "none"), so launch degrades to
  /// the password path.
  Future<BiometricUnlockRecord?> readUnlockRecord();

  /// Stores [record] so the sign-in screen's fingerprint button can mint a new
  /// session after a sign-out.
  Future<void> writeUnlockRecord(BiometricUnlockRecord record);

  /// Removes the record. Called on opt-out and on "forget this device", so a
  /// fingerprint sign-in can never outlive the enrolment it belongs to.
  Future<void> clearUnlockRecord();
}

/// Keystore/Keychain-backed [SessionStore].
///
/// Hardening choices:
/// - Android: `encryptedSharedPreferences` keeps values inside
///   EncryptedSharedPreferences, whose master key lives in the Android
///   Keystore; `resetOnError` wipes the entry rather than serving a value that
///   failed integrity — for a credential, failing closed is correct.
/// - iOS: `first_unlock_this_device` makes the item readable after the first
///   post-reboot unlock (so a cold launch works) but explicitly **non
///   migrating**, so it never moves to a replacement device via a backup.
/// - `synchronizable` stays false — the session must never reach iCloud.
///
/// Only the session is stored. The password is never written here (Hard Rule 1)
/// and `AuthSession.toString()` deliberately omits token material.
class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          resetOnError: true,
        ),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  final FlutterSecureStorage _storage;

  /// Storage key. Namespaced so it cannot collide with future entries.
  static const String sessionKey = 'waec_direct.auth.session';

  /// Key for the remembered index number (survives sign-out).
  static const String rememberedIndexKey = 'waec_direct.auth.remembered_index';

  /// Key for the biometric unlock record (survives sign-out, dies with the
  /// enrolment). Namespaced separately from [sessionKey] so sign-out can destroy
  /// the session without destroying the ability to sign back in with a
  /// fingerprint.
  static const String unlockRecordKey = 'waec_direct.auth.biometric_unlock';

  @override
  Future<AuthSession?> read() async {
    try {
      final raw = await _storage.read(key: sessionKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      // fromJson rejects a payload whose index number is missing or malformed,
      // which covers both truncation and tampering.
      return AuthSession.fromJson(decoded);
    } on Object {
      // Corrupt JSON, platform failure, or a keystore the OS will not release.
      // Best effort cleanup so the next launch is not stuck on the same entry.
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(AuthSession session) async {
    await _storage.write(
      key: sessionKey,
      value: jsonEncode(session.toJson()),
    );
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: sessionKey);
    } on Object {
      // Nothing actionable: if the platform cannot delete, the value was
      // almost certainly never readable either.
    }
  }

  @override
  Future<String?> readRememberedIndex() async {
    try {
      final raw = await _storage.read(key: rememberedIndexKey);
      if (raw == null) return null;
      // Re-validate on the way out: a tampered or truncated value must not be
      // pre-filled into the sign-in form.
      return IndexNumberValidator.isValid(raw) ? raw : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeRememberedIndex(String indexNumber) async {
    if (!IndexNumberValidator.isValid(indexNumber)) return;
    await _storage.write(key: rememberedIndexKey, value: indexNumber);
  }

  @override
  Future<void> clearAll() async {
    await clear();
    await clearUnlockRecord();
    try {
      await _storage.delete(key: rememberedIndexKey);
    } on Object {
      // See clear(): nothing actionable.
    }
  }

  @override
  Future<BiometricUnlockRecord?> readUnlockRecord() async {
    try {
      final raw = await _storage.read(key: unlockRecordKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return BiometricUnlockRecord.fromJson(decoded);
    } on Object {
      // Corrupt JSON or a keystore the OS will not release. Best effort cleanup
      // so the next launch is not stuck on the same entry, and fail to the
      // password path (never admit anyone on an unreadable record).
      await clearUnlockRecord();
      return null;
    }
  }

  @override
  Future<void> writeUnlockRecord(BiometricUnlockRecord record) async {
    if (!record.isUsable) return;
    await _storage.write(
      key: unlockRecordKey,
      value: jsonEncode(record.toJson()),
    );
  }

  @override
  Future<void> clearUnlockRecord() async {
    try {
      await _storage.delete(key: unlockRecordKey);
    } on Object {
      // Nothing actionable: if the platform cannot delete, the value was
      // almost certainly never readable either.
    }
  }
}

/// In-memory [SessionStore] for tests and for platforms without secure storage.
class InMemorySessionStore implements SessionStore {
  InMemorySessionStore({AuthSession? session, String? rememberedIndex})
    // Public parameter names ({session, rememberedIndex}) map onto private
    // fields; initializing formals would leak the private names into the
    // constructor's public signature.
    : _session = session, // ignore: prefer_initializing_formals
      _rememberedIndex = rememberedIndex; // ignore: prefer_initializing_formals

  AuthSession? _session;
  String? _rememberedIndex;
  BiometricUnlockRecord? _unlockRecord;

  /// Number of [write] calls, so tests can assert a value was actually saved.
  int writeCount = 0;

  /// Number of [clear] calls.
  int clearCount = 0;

  /// Number of [clearAll] calls.
  int clearAllCount = 0;

  /// Number of [writeUnlockRecord] calls, and the last value written — asserted
  /// by the "sign-out keeps a fingerprint sign-in possible" test.
  int writeUnlockRecordCount = 0;
  BiometricUnlockRecord? lastUnlockRecord;

  /// Number of [clearUnlockRecord] calls (opt-out / forget-device).
  int clearUnlockRecordCount = 0;

  @override
  Future<AuthSession?> read() async => _session;

  @override
  Future<void> write(AuthSession session) async {
    writeCount++;
    _session = session;
  }

  @override
  Future<void> clear() async {
    clearCount++;
    _session = null;
  }

  @override
  Future<String?> readRememberedIndex() async => _rememberedIndex;

  @override
  Future<void> writeRememberedIndex(String indexNumber) async {
    _rememberedIndex = IndexNumberValidator.isValid(indexNumber)
        ? indexNumber
        : _rememberedIndex;
  }

  @override
  Future<void> clearAll() async {
    clearAllCount++;
    _session = null;
    _rememberedIndex = null;
    _unlockRecord = null;
  }

  @override
  Future<BiometricUnlockRecord?> readUnlockRecord() async => _unlockRecord;

  @override
  Future<void> writeUnlockRecord(BiometricUnlockRecord record) async {
    writeUnlockRecordCount++;
    if (record.isUsable) {
      _unlockRecord = record;
      lastUnlockRecord = record;
    }
  }

  @override
  Future<void> clearUnlockRecord() async {
    clearUnlockRecordCount++;
    _unlockRecord = null;
  }
}
