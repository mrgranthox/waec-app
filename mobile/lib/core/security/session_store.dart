import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain_types.dart';

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
    try {
      await _storage.delete(key: rememberedIndexKey);
    } on Object {
      // See clear(): nothing actionable.
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

  /// Number of [write] calls, so tests can assert a value was actually saved.
  int writeCount = 0;

  /// Number of [clear] calls.
  int clearCount = 0;

  /// Number of [clearAll] calls.
  int clearAllCount = 0;

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
  }
}
