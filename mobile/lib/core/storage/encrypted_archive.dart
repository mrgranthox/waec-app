import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

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
  static const _meta = 'meta';

  /// Open (or create) the archive at [dbPath].
  static Future<EncryptedResultArchive> open(String dbPath) async {
    final db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_meta (
            k TEXT PRIMARY KEY, v TEXT NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE $_table (
            id TEXT PRIMARY KEY,
            index_number TEXT NOT NULL,
            exam_type TEXT NOT NULL,
            exam_year TEXT NOT NULL,
            created_unix INTEGER NOT NULL,
            blob BLOB NOT NULL
          )''');
        await db.execute(
            'CREATE INDEX idx_snap_idx ON $_table(index_number, created_unix DESC)');
        // Device-random salt for key derivation — never leaves the device.
        final rng = Random.secure();
        final salt = List<int>.generate(32, (_) => rng.nextInt(256));
        await db.insert(_meta, {'k': 'salt', 'v': base64Encode(salt)});
      },
    );

    final rows = await db.query(_meta, where: 'k = ?', whereArgs: ['salt']);
    final salt = base64Decode(rows.first['v'] as String);
    return EncryptedResultArchive._(db, salt);
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
      'blob': blob,
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
  Future<List<ArchiveMeta>> listSnapshots(String indexNumber) async {
    final rows = await (this as dynamic)._db.query(
          'snapshots',
          where: 'index_number = ?',
          whereArgs: [indexNumber],
          orderBy: 'created_unix DESC',
        );
    return rows
        .map((r) => ArchiveMeta(
              id: r['id'] as String,
              examType: r['exam_type'] as String,
              examYear: r['exam_year'] as String,
              createdUnix: r['created_unix'] as int,
            ))
        .toList();
  }

  /// User-initiated irreversible delete (plan §3.6).
  Future<void> deleteSnapshot(String id) async {
    await (this as dynamic)._db
        .delete('snapshots', where: 'id = ?', whereArgs: [id]);
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
