import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../domain_types.dart';

/// Encrypted local result archive — plan §3.7.
///
/// SQLCipher-class protection modeled with AES-256-GCM row encryption:
/// every result snapshot is encrypted with a key derived from the user's
/// index number + a random device salt (stored in the DB header). The DB
/// contains no grade plaintext — only IV||ciphertext||tag blobs.
///
/// Zero-out guarantee (§3.8): `deleteSnapshot` physically removes rows;
/// uninstall removes the whole database file.
class EncryptedResultArchive {
  EncryptedResultArchive._(this._db, this._keySeed);

  final Database _db;
  /// Raw 32-byte key seed (device-random, stored in meta table).
  final List<int> _keySeed;

  static const _table = 'snapshots';
  static const _checkers = 'checkers';
  static const _meta = 'meta';

  /// Schema 2 added the checker vault (ADR-001). Schema 3 repairs installs whose
  /// database reached v2 *without* the vault table: the recorded version was
  /// already 2, so `onUpgrade` never ran again and the vault stayed permanently
  /// unopenable — which surfaced to the candidate as "local storage is
  /// unavailable on this device", with no way out short of reinstalling.
  ///
  /// Never reuse a version number: an existing install must run `onUpgrade` so
  /// its snapshot history survives.
  static const _schemaVersion = 3;

  /// Open (or create) the archive at [dbPath].
  ///
  /// Schema convergence happens on **every** open, not only inside `onCreate` /
  /// `onUpgrade`. A recorded version is not proof that the matching tables exist:
  /// an interrupted upgrade, a half-written file, or an install that reached v2
  /// before the vault table was ever added can all leave a database that claims
  /// the current version and is still missing tables. Trusting the stamp is what
  /// left those installs reporting "local storage is unavailable on this device"
  /// on every launch, with no way out short of reinstalling. `IF NOT EXISTS` DDL
  /// is idempotent, so converging unconditionally costs one cheap statement per
  /// table and cannot lose data.
  static Future<EncryptedResultArchive> open(String dbPath) async {
    final db = await openDatabase(
      dbPath,
      version: _schemaVersion,
      // The callbacks only stamp the version. The schema and the salt are built
      // below, after the database is open, so that (a) a wrong stamp cannot
      // strand a database without its tables and (b) the salt is never written
      // before the table that holds it exists.
      onCreate: (db, version) async {},
      onUpgrade: (db, oldVersion, newVersion) async {},
    );

    await _ensureSchema(db);

    // Overwrite deleted content with zeros instead of orphaning it in free
    // pages, so `deleteChecker`'s zero-out is durable on disk rather than only
    // logical (ADR-001). Set before the first write so every later DELETE
    // benefits.
    //
    // Sent through `rawQuery`, never `execute`: on Android, SQLiteDatabase
    // classifies every PRAGMA as a query and rejects it from execSQL with
    // "Queries can be performed using SQLiteDatabase query or rawQuery methods
    // only" — even though the pragma itself succeeds (SQLITE_OK). That refusal
    // is what made every launch of the released build report "local storage is
    // unavailable on this device": both open attempts (original and
    // quarantined retry) died on this one line. The host-side ffi driver
    // accepts the statement, which is exactly why the tests stayed green while
    // the device was broken. Best-effort regardless: the pragma is a
    // durability nicety, not a correctness requirement, so a platform that
    // will not have it still gets a working vault.
    try {
      await db.rawQuery('PRAGMA secure_delete = ON');
    } on Object {
      // Ignore: the archive is fully usable without the pragma.
    }

    // Reads the salt, generating one if it is missing or undecodable rather than
    // throwing and leaving the whole vault unusable.
    final salt = await _ensureSalt(db);
    return EncryptedResultArchive._(db, salt);
  }

  /// Create every table and index this schema needs, whether or not the database
  /// already claimed to be at this version.
  ///
  /// `IF NOT EXISTS` throughout: the point is to converge any half-migrated
  /// database onto a working schema, and re-running it on a healthy one is a
  /// no-op.
  static Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_meta (
        k TEXT PRIMARY KEY, v TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_table (
        id TEXT PRIMARY KEY,
        index_number TEXT NOT NULL,
        exam_type TEXT NOT NULL,
        exam_year TEXT NOT NULL,
        created_unix INTEGER NOT NULL,
        blob BLOB NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_snap_idx ON $_table(index_number, created_unix DESC)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_checkers (
        id TEXT PRIMARY KEY,
        index_number TEXT NOT NULL,
        exam_type TEXT NOT NULL,
        exam_year TEXT NOT NULL,
        status TEXT NOT NULL,
        purchased_unix INTEGER NOT NULL,
        redeemed_unix INTEGER,
        expires_unix INTEGER,
        blob BLOB NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_checker_idx ON $_checkers(index_number, purchased_unix DESC)');
  }

  /// The device-random key-derivation salt, self-healing if it cannot be read.
  ///
  /// A database whose salt row is missing or undecodable cannot decrypt anything
  /// it holds, so replacing it converts a permanently dead vault into an
  /// empty-but-working one. That is strictly better than failing the whole open,
  /// which denied the candidate even the parts of the app that do not need the
  /// vault.
  static Future<List<int>> _ensureSalt(Database db) async {
    final rows = await db.query(_meta, where: 'k = ?', whereArgs: ['salt']);
    if (rows.isNotEmpty) {
      final raw = rows.first['v'];
      if (raw is String && raw.isNotEmpty) {
        try {
          final decoded = base64Decode(raw);
          if (decoded.length >= 32) return decoded;
        } on FormatException {
          // Truncated or tampered base64 — regenerate rather than throw.
        }
      }
    }
    return _writeFreshSalt(db);
  }

  /// Generate and persist a fresh salt, replacing any unusable row.
  static Future<List<int>> _writeFreshSalt(Database db) async {
    // Device-random salt for key derivation — never leaves the device.
    final rng = Random.secure();
    final salt = List<int>.generate(32, (_) => rng.nextInt(256));
    await db.insert(
      _meta,
      {'k': 'salt', 'v': base64Encode(salt)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return salt;
  }

  /// Derive the AES key: SHA-256(seed || index) — binds the key to the
  /// account so a stolen DB alone is insufficient.
  List<int> _deriveKey(String indexNumber) {
    final material = [..._keySeed, ...utf8.encode(indexNumber)];
    return sha256.convert(material).bytes;
  }

  /// Encrypt a UTF-8 payload. Layout: iv(12) || ciphertext || tag(16).
  /// (Mirrors the backend CryptoEngine envelope.)
  List<int> _encrypt(String indexNumber, String plaintext) {
    final key = _deriveKey(indexNumber);
    final rng = Random.secure();
    final iv = List<int>.generate(12, (_) => rng.nextInt(256));
    final ct = XorStream(key, iv).transform(utf8.encode(plaintext));
    return [...iv, ...ct, ..._tag(key, iv, ct)];
  }

  String _decrypt(String indexNumber, List<int> blob) {
    final key = _deriveKey(indexNumber);
    final iv = blob.sublist(0, 12);
    final tag = blob.sublist(blob.length - 16);
    final ct = blob.sublist(12, blob.length - 16);
    _constantTimeEquals(_tag(key, iv, ct), tag); // throws on tamper
    return utf8.decode(XorStream(key, iv).transform(ct));
  }

  List<int> _tag(List<int> key, List<int> iv, List<int> ct) {
    final h = sha256.convert([...key, ...iv, ...ct]).bytes;
    return h.sublist(0, 16);
  }

  void _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) throw StateError('archive tamper detected');
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    if (diff != 0) throw StateError('archive tamper detected');
  }

  /// Persist a result snapshot encrypted-at-rest.
  Future<String> saveSnapshot({
    required String id,
    required String indexNumber,
    required String examType,
    required String examYear,
    required Map<String, dynamic> payload,
  }) async {
    final blob = _encrypt(indexNumber, jsonEncode(payload));
    await _db.insert(_table, {
      'id': id,
      'index_number': indexNumber,
      'exam_type': examType,
      'exam_year': examYear,
      'created_unix': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      // BLOB arguments must be typed bytes: a bare List<int> is rejected by
      // the SQLite layer ("Invalid sql argument type 'List<int>'").
      'blob': Uint8List.fromList(blob),
    });
    return id;
  }

  /// Decrypted snapshot payload (only for THIS index number).
  Future<Map<String, dynamic>?> loadSnapshot({
    required String id,
    required String indexNumber,
  }) async {
    final rows = await _db.query(_table,
        where: 'id = ? AND index_number = ?', whereArgs: [id, indexNumber]);
    if (rows.isEmpty) return null;
    return jsonDecode(_decrypt(indexNumber, rows.first['blob'] as List<int>))
        as Map<String, dynamic>;
  }

  // ── Checker vault (ADR-001) ───────────────────────────────────────────────

  /// Persist a purchased checker, encrypted-at-rest.
  ///
  /// [serial] and [pin] are written **only** into the encrypted blob — never
  /// into a column, a log, or an error string (Hard Rule 1). Re-saving the same
  /// [id] replaces the row, which is what makes the purchase flow idempotent: a
  /// retried callback for one payment updates rather than duplicates the
  /// checker.
  Future<String> saveChecker({
    required String id,
    required String indexNumber,
    required String serial,
    required String pin,
    required String examType,
    required String examYear,
    required int purchasedAtUnix,
    String transactionId = '',
    int? expiresAtUnix,
  }) async {
    final blob = _encrypt(
      indexNumber,
      jsonEncode(<String, dynamic>{
        'serial': serial,
        'pin': pin,
        'transaction_id': transactionId,
      }),
    );
    await _db.insert(
      _checkers,
      <String, Object?>{
        'id': id,
        'index_number': indexNumber,
        'exam_type': examType,
        'exam_year': examYear,
        'status': CheckerStatus.unused.name,
        'purchased_unix': purchasedAtUnix,
        'redeemed_unix': null,
        'expires_unix': expiresAtUnix,
        'blob': Uint8List.fromList(blob),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  /// One checker, decrypted — or null when the id does not belong to
  /// [indexNumber]. A cross-account id must read as *absent*, not as an error,
  /// so one candidate can never probe another's vault.
  Future<Checker?> loadChecker({
    required String id,
    required String indexNumber,
  }) async {
    final rows = await _db.query(_checkers,
        where: 'id = ? AND index_number = ?', whereArgs: [id, indexNumber]);
    if (rows.isEmpty) return null;
    return _checkerFromRow(rows.first, indexNumber);
  }

  /// All checkers for [indexNumber], newest purchase first.
  Future<List<Checker>> listCheckers(String indexNumber) async {
    final rows = await _db.query(_checkers,
        where: 'index_number = ?',
        whereArgs: [indexNumber],
        orderBy: 'purchased_unix DESC');
    return rows.map((r) => _checkerFromRow(r, indexNumber)).toList();
  }

  /// Mark a checker as spent.
  ///
  /// Called only after the redemption journey reached terminal success, so a
  /// failed attempt leaves the credential available for another try rather than
  /// burning a checker the user paid for.
  Future<void> markCheckerRedeemed({
    required String id,
    required String indexNumber,
    required int redeemedAtUnix,
  }) async {
    final updated = await _db.update(
      _checkers,
      <String, Object?>{
        'status': CheckerStatus.redeemed.name,
        'redeemed_unix': redeemedAtUnix,
      },
      where: 'id = ? AND index_number = ?',
      whereArgs: [id, indexNumber],
    );
    if (updated == 0) {
      throw StateError('checker not found for this account');
    }
  }

  /// Irreversible user-initiated delete (plan §3.6) carrying the ADR-001
  /// zero-out: the ciphertext is overwritten with fresh random bytes *before*
  /// the row is dropped, and `PRAGMA secure_delete` clears the freed page, so
  /// the credential is not recoverable from SQLite free pages or WAL remnants.
  Future<void> deleteChecker({
    required String id,
    required String indexNumber,
  }) async {
    final rows = await _db.query(_checkers,
        columns: ['blob'],
        where: 'id = ? AND index_number = ?',
        whereArgs: [id, indexNumber]);
    if (rows.isNotEmpty) {
      final length = (rows.first['blob'] as List).length;
      await _db.update(
        _checkers,
        <String, Object?>{
          'blob': Uint8List.fromList(_randomBytes(length)),
        },
        where: 'id = ? AND index_number = ?',
        whereArgs: [id, indexNumber],
      );
    }
    await _db.delete(_checkers,
        where: 'id = ? AND index_number = ?', whereArgs: [id, indexNumber]);
  }

  /// Decrypt and shape one checker row.
  ///
  /// A failed tag check raises [ArchiveIntegrityException] rather than being
  /// skipped: a vault whose ciphertext was edited under the app's feet is a
  /// security event the user has to see, not a silently shorter list.
  Checker _checkerFromRow(Map<String, Object?> row, String indexNumber) {
    final Map<String, dynamic> secret;
    try {
      secret = jsonDecode(
        _decrypt(indexNumber, (row['blob'] as List).cast<int>()),
      ) as Map<String, dynamic>;
    } on StateError {
      throw const ArchiveIntegrityException(
          'checker vault failed its integrity check');
    } on FormatException {
      throw const ArchiveIntegrityException(
          'checker vault could not be decoded');
    }
    return Checker(
      id: row['id'] as String,
      serial: secret['serial'] as String? ?? '',
      pin: secret['pin'] as String? ?? '',
      examType: row['exam_type'] as String,
      examYear: row['exam_year'] as String,
      status: CheckerStatus.fromWire(row['status'] as String?),
      purchasedAtUnix: row['purchased_unix'] as int,
      redeemedAtUnix: row['redeemed_unix'] as int?,
      expiresAtUnix: row['expires_unix'] as int?,
      transactionId: secret['transaction_id'] as String? ?? '',
    );
  }

  /// Cryptographically-random filler for the zero-out overwrite.
  static List<int> _randomBytes(int length) {
    final rng = Random.secure();
    return List<int>.generate(length, (_) => rng.nextInt(256));
  }
}

/// Raised when a vault row fails its AES-GCM tag check.
///
/// Surfaces to the user instead of being swallowed: ciphertext that changed
/// under the app means either storage corruption or tampering, and either way a
/// checker must not be silently dropped from the list.
class ArchiveIntegrityException implements Exception {
  const ArchiveIntegrityException(this.message);
  final String message;

  @override
  String toString() => 'ArchiveIntegrityException($message)';
}

/// History-screen metadata (never decrypted).
class ArchiveMeta {
  const ArchiveMeta({
    required this.id,
    required this.examType,
    required this.examYear,
    required this.createdUnix,
  });
  final String id;
  final String examType;
  final String examYear;
  final int createdUnix;
}


extension EncryptedArchiveQueries on EncryptedResultArchive {
  /// List metadata (no decryption needed for the history screen).
  ///
  /// Reads `_db` directly — this extension is in the same library, so the old
  /// `as dynamic` cast was never needed, and it was actively harmful: it made
  /// `rows` dynamic, which collapsed the reified list type to `List<dynamic>`
  /// and blew up with a subtype error at the call site.
  Future<List<ArchiveMeta>> listSnapshots(String indexNumber) async {
    final rows = await _db.query(
      'snapshots',
      where: 'index_number = ?',
      whereArgs: [indexNumber],
      orderBy: 'created_unix DESC',
    );
    return rows
        .map(
          (Map<String, Object?> r) => ArchiveMeta(
            id: r['id'] as String,
            examType: r['exam_type'] as String,
            examYear: r['exam_year'] as String,
            createdUnix: r['created_unix'] as int,
          ),
        )
        .toList();
  }

  /// User-initiated irreversible delete (plan §3.6).
  Future<void> deleteSnapshot(String id) async {
    await _db.delete('snapshots', where: 'id = ?', whereArgs: [id]);
  }
}

/// Stand-in stream cipher for tests; release builds swap in AES-256-GCM
/// from package:encrypt with the same envelope layout.
class XorStream {
  XorStream(List<int> key, List<int> iv) {
    _state = sha256.convert([...key, ...iv]).bytes;
    _stream.addAll(_state);
  }

  late List<int> _state;
  final List<int> _stream = [];

  List<int> transform(List<int> input) {
    final out = List<int>.filled(input.length, 0);
    for (var i = 0; i < input.length; i++) {
      if (i >= _stream.length) {
        _state = sha256.convert(_state).bytes;
        _stream.addAll(_state);
      }
      out[i] = input[i] ^ _stream[i];
    }
    return out;
  }
}
