// Encrypted checker vault tests (ADR-001).
//
// These run against a REAL SQLite database (sqflite_common_ffi), not a mock, so
// the schema, the migration and the ciphertext envelope are all exercised the
// way the device will exercise them.
//
// The load-bearing test here is
// 'the raw database file carries no serial or PIN plaintext': it is the
// machine-checked form of Hard Rule 1 — proof that the credential exists only
// inside the AES-256-GCM blob, and therefore cannot be recovered from the file
// at rest (or from a freepage, or a log of the row).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/storage/encrypted_archive.dart';

const _index = '1002330440';
const _otherIndex = '1002330499';

/// Byte-wise ASCII search, used to prove a string is absent from the file.
bool _containsAscii(List<int> haystack, String needle) {
  final n = needle.codeUnits;
  for (var i = 0; i + n.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('waec_vault_test');
    path = '${dir.path}/archive.db';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<EncryptedResultArchive> open() => EncryptedResultArchive.open(path);

  Future<String> seed(
    EncryptedResultArchive archive, {
    String id = 'ck-1',
    String indexNumber = _index,
    String serial = 'WAESERIAL0001',
    String pin = 'PIN00000001',
  }) => archive.saveChecker(
    id: id,
    indexNumber: indexNumber,
    serial: serial,
    pin: pin,
    examType: ExamType.bece.code,
    examYear: '2025',
    purchasedAtUnix: 1700000000,
  );

  group('checker vault round trip', () {
    test('recovers the serial and PIN it stored', () async {
      final archive = await open();
      await seed(archive);

      final loaded = await archive.loadChecker(
        id: 'ck-1',
        indexNumber: _index,
      );

      expect(loaded, isNotNull);
      expect(loaded!.serial, 'WAESERIAL0001');
      expect(loaded.pin, 'PIN00000001');
      expect(loaded.examType, ExamType.bece.code);
      expect(loaded.examYear, '2025');
      expect(loaded.status, CheckerStatus.unused);
      expect(loaded.redeemedAtUnix, isNull);
    });

    test('a new checker starts unused so it can be spent', () async {
      final archive = await open();
      await seed(archive);
      final loaded = await archive.loadChecker(
        id: 'ck-1',
        indexNumber: _index,
      );
      expect(loaded!.isRedeemable, isTrue);
    });

    test('re-saving the same id replaces rather than duplicates', () async {
      final archive = await open();
      await seed(archive, serial: 'WAESERIAL0001');
      await seed(archive, serial: 'WAESERIAL0002');

      final all = await archive.listCheckers(_index);
      expect(all, hasLength(1));
      expect(all.single.serial, 'WAESERIAL0002');
    });

    test('lists newest purchase first', () async {
      final archive = await open();
      await archive.saveChecker(
        id: 'older',
        indexNumber: _index,
        serial: 'WAESERIAL0000',
        pin: 'PIN00000000',
        examType: ExamType.bece.code,
        examYear: '2024',
        purchasedAtUnix: 1000,
      );
      await archive.saveChecker(
        id: 'newer',
        indexNumber: _index,
        serial: 'WAESERIAL0001',
        pin: 'PIN00000001',
        examType: ExamType.bece.code,
        examYear: '2025',
        purchasedAtUnix: 2000,
      );

      final all = await archive.listCheckers(_index);
      expect(all.map((c) => c.id), ['newer', 'older']);
    });
  });

  group('account isolation', () {
    test('another index cannot read this checker', () async {
      final archive = await open();
      await seed(archive);

      // A cross-account id must read as absent, not as an error, so one
      // candidate cannot probe another's vault by guessing ids.
      final probed = await archive.loadChecker(
        id: 'ck-1',
        indexNumber: _otherIndex,
      );
      expect(probed, isNull);
    });

    test('another index sees an empty vault', () async {
      final archive = await open();
      await seed(archive);
      expect(await archive.listCheckers(_otherIndex), isEmpty);
      expect(await archive.listCheckers(_index), hasLength(1));
    });

    test('another index cannot spend or delete this checker', () async {
      final archive = await open();
      await seed(archive);

      await expectLater(
        archive.markCheckerRedeemed(
          id: 'ck-1',
          indexNumber: _otherIndex,
          redeemedAtUnix: 1,
        ),
        throwsStateError,
      );
      // No-op delete: nothing to remove, so nothing to fail on.
      await archive.deleteChecker(id: 'ck-1', indexNumber: _otherIndex);
      expect(
        (await archive.loadChecker(id: 'ck-1', indexNumber: _index))!.serial,
        'WAESERIAL0001',
      );
    });
  });

  group('redemption lifecycle', () {
    test('markCheckerRedeemed retires the checker for good', () async {
      final archive = await open();
      await seed(archive);

      await archive.markCheckerRedeemed(
        id: 'ck-1',
        indexNumber: _index,
        redeemedAtUnix: 1700001234,
      );

      final loaded = await archive.loadChecker(id: 'ck-1', indexNumber: _index);
      expect(loaded!.status, CheckerStatus.redeemed);
      expect(loaded.redeemedAtUnix, 1700001234);
      expect(loaded.isRedeemable, isFalse);
    });

    test('an unknown id throws rather than reporting success', () async {
      final archive = await open();
      await expectLater(
        archive.markCheckerRedeemed(
          id: 'missing',
          indexNumber: _index,
          redeemedAtUnix: 1,
        ),
        throwsStateError,
      );
    });

    test('deleteChecker removes the row permanently', () async {
      final archive = await open();
      await seed(archive);

      await archive.deleteChecker(id: 'ck-1', indexNumber: _index);

      expect(
        await archive.loadChecker(id: 'ck-1', indexNumber: _index),
        isNull,
      );
      expect(await archive.listCheckers(_index), isEmpty);
    });

    test('deleteChecker is safe to call twice', () async {
      final archive = await open();
      await seed(archive);
      await archive.deleteChecker(id: 'ck-1', indexNumber: _index);
      await archive.deleteChecker(id: 'ck-1', indexNumber: _index);
      expect(await archive.listCheckers(_index), isEmpty);
    });
  });

  group('Hard Rule 1: credential never in plaintext', () {
    test('the raw database file carries no serial or PIN plaintext', () async {
      final archive = await open();
      await seed(archive);

      final bytes = File(path).readAsBytesSync();

      // Control: the file is real and contains the non-secret metadata, so the
      // assertions below are meaningful rather than vacuous.
      expect(_containsAscii(bytes, '2025'), isTrue);
      expect(_containsAscii(bytes, ExamType.bece.code), isTrue);
      expect(_containsAscii(bytes, _index), isTrue);

      // The credential itself must be nowhere in the file — not in a column,
      // not in a freepage, not in the WAL.
      expect(_containsAscii(bytes, 'WAESERIAL0001'), isFalse);
      expect(_containsAscii(bytes, 'PIN00000001'), isFalse);
    });

    test('a spent checker leaves no plaintext behind after deletion', () async {
      final archive = await open();
      await seed(archive);
      await archive.markCheckerRedeemed(
        id: 'ck-1',
        indexNumber: _index,
        redeemedAtUnix: 1700001234,
      );
      await archive.deleteChecker(id: 'ck-1', indexNumber: _index);

      final bytes = File(path).readAsBytesSync();
      expect(_containsAscii(bytes, 'WAESERIAL0001'), isFalse);
      expect(_containsAscii(bytes, 'PIN00000001'), isFalse);
    });
  });

  group('integrity', () {
    Future<void> corruptFirstByte({bool iv = true}) async {
      final db = await databaseFactory.openDatabase(
        path,
        // A separate connection: closing it must not take the archive's own
        // connection down with it (sqflite shares one instance per path).
        options: OpenDatabaseOptions(version: 2, singleInstance: false),
      );
      final rows = await db.query('checkers', columns: ['blob']);
      final blob = Uint8List.fromList(
        (rows.first['blob'] as List).cast<int>(),
      );
      blob[iv ? 0 : blob.length - 1] =
          blob[iv ? 0 : blob.length - 1] ^ 0xFF;
      await db.update(
        'checkers',
        {'blob': blob},
        where: 'id = ?',
        whereArgs: ['ck-1'],
      );
      await db.close();
    }

    test('a tampered blob is reported, never silently dropped', () async {
      final archive = await open();
      await seed(archive);
      await corruptFirstByte(iv: false); // inside the 16-byte tag

      await expectLater(
        archive.listCheckers(_index),
        throwsA(isA<ArchiveIntegrityException>()),
      );
    });

    test('loadChecker surfaces a tampered row too', () async {
      final archive = await open();
      await seed(archive);
      await corruptFirstByte(iv: true); // inside the IV

      await expectLater(
        archive.loadChecker(id: 'ck-1', indexNumber: _index),
        throwsA(isA<ArchiveIntegrityException>()),
      );
    });
  });

  group('schema migration', () {
    test('a v1 database gains the checker vault', () async {
      // Build a genuine v1 archive by hand: meta + snapshots only, no vault.
      final v1 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
            );
            await db.execute('''
              CREATE TABLE snapshots (
                id TEXT PRIMARY KEY,
                index_number TEXT NOT NULL,
                exam_type TEXT NOT NULL,
                exam_year TEXT NOT NULL,
                created_unix INTEGER NOT NULL,
                blob BLOB NOT NULL
              )''');
            await db.insert('meta', {
              'k': 'salt',
              'v': base64Encode(List<int>.filled(32, 7)),
            });
          },
        ),
      );
      await v1.close();

      final archive = await open();

      // The vault exists and is empty — not a "no such table" failure.
      expect(await archive.listCheckers(_index), isEmpty);

      // A fresh checker can be written on the upgraded schema.
      final id = await seed(archive);
      expect(id, 'ck-1');
      expect(await archive.listCheckers(_index), hasLength(1));
    });

    test('a database stuck at v2 without the vault is repaired', () async {
      // The regression the candidate hit: the database had already recorded
      // version 2, so `onUpgrade` was never called again and the missing vault
      // table could never appear. Every launch then reported "local storage is
      // unavailable on this device" with no way out but a reinstall.
      final stuck = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
            );
            await db.execute('''
              CREATE TABLE snapshots (
                id TEXT PRIMARY KEY,
                index_number TEXT NOT NULL,
                exam_type TEXT NOT NULL,
                exam_year TEXT NOT NULL,
                created_unix INTEGER NOT NULL,
                blob BLOB NOT NULL
              )''');
            await db.insert('meta', {
              'k': 'salt',
              'v': base64Encode(List<int>.filled(32, 9)),
            });
            // Deliberately no `checkers` table, despite claiming v2.
          },
        ),
      );
      await stuck.close();

      final archive = await open();

      // The vault is usable now, and the history the user already had survived.
      expect(await archive.listCheckers(_index), isEmpty);
      await seed(archive);
      expect(await archive.listCheckers(_index), hasLength(1));
      expect(await archive.listSnapshots(_index), isEmpty);
    });

    test('a missing salt is regenerated instead of failing the open', () async {
      // Without this, one bad row made the entire archive unopenable — and the
      // candidate lost access to everything else in the app with it.
      final saltless = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
            );
            // No salt row at all.
          },
        ),
      );
      await saltless.close();

      final archive = await open();
      await seed(archive);

      final loaded = await archive.loadChecker(
        id: 'ck-1',
        indexNumber: _index,
      );
      expect(loaded, isNotNull);
      expect(loaded!.serial, 'WAESERIAL0001');
    });

    test('an undecodable salt is replaced, not trusted', () async {
      final corruptSalt = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
            );
            // Truncated base64: decoding it would either throw or yield a key
            // that can never match the ciphertext that is already on disk.
            await db.insert('meta', {'k': 'salt', 'v': 'not-base64!!!'});
          },
        ),
      );
      await corruptSalt.close();

      final archive = await open();
      await seed(archive);

      expect(
        (await archive.loadChecker(id: 'ck-1', indexNumber: _index))!.pin,
        'PIN00000001',
      );
    });
  });

  group('snapshot regression', () {
    test('existing result storage is unaffected by the vault', () async {
      final archive = await open();

      final id = await archive.saveSnapshot(
        id: 'snap-1',
        indexNumber: _index,
        examType: ExamType.bece.code,
        examYear: '2025',
        payload: <String, dynamic>{'aggregate': '12'},
      );
      expect(id, 'snap-1');

      final loaded = await archive.loadSnapshot(
        id: 'snap-1',
        indexNumber: _index,
      );
      expect(loaded, isNotNull);
      expect(loaded!['aggregate'], '12');
      expect((await archive.listSnapshots(_index)).single.examYear, '2025');

      // And the two stores stay independent.
      await seed(archive);
      expect(await archive.listCheckers(_index), hasLength(1));
      expect(await archive.listSnapshots(_index), hasLength(1));
    });
  });
}