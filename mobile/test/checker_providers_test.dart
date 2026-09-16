// Checker purchase + redemption flow tests (requirement 2).
//
// Uses a REAL encrypted vault on sqflite_common_ffi and a scripted API, so the
// whole journey — pay, provision, vault, spend, retire — is exercised end to end.
//
// What these tests pin down:
//   * a checker that was never paid for never enters the vault;
//   * only a terminal SUCCESS retires a credential (a failed redemption must
//     leave the user's paid checker usable);
//   * the credential that reaches the portal is the one from the vault, not a
//     re-typed one.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/storage/encrypted_archive.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/features/checker/checker_providers.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';

const _index = '1002330440';

/// A mock that reports a paid charge but provisions no voucher, which is how a
/// gateway bug presents itself.
class _NoVoucherMock extends MockWaecApi {
  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    final init = await super.initCharge(
      idempotencyKey: idempotencyKey,
      indexNumber: indexNumber,
      examType: examType,
      examYear: examYear,
    );
    // Strip the credential while keeping every other field identical.
    return ChargeInit(
      transactionId: init.transactionId,
      status: init.status,
      amountPesewas: init.amountPesewas,
      checkoutUrl: init.checkoutUrl,
      displayMessage: init.displayMessage,
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String path;
  late ProviderContainer container;
  late MockWaecApi api;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('waec_purchase_test');
    path = '${dir.path}/archive.db';
    api = MockWaecApi();
  });

  tearDown(() async {
    container.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<EncryptedResultArchive> boot({MockWaecApi? mock}) async {
    api = mock ?? api;
    final archive = await EncryptedResultArchive.open(path);
    container = ProviderContainer(
      overrides: [
        archiveProvider.overrideWithValue(archive),
        waecApiProvider.overrideWithValue(api),
      ],
    );
    return archive;
  }

  Future<void> buy({bool checkNow = false}) =>
      container
          .read(checkerPurchaseProvider.notifier)
          .buy(
            indexNumber: _index,
            examType: ExamType.bece,
            examYear: '2025',
            checkNow: checkNow,
          );

  group('buy', () {
    test('fails cleanly when the device has no local storage', () async {
      container = ProviderContainer();
      addTearDown(container.dispose);

      await buy();

      final state = container.read(checkerPurchaseProvider);
      expect(state.hasFailed, isTrue);
      expect(state.error, contains('Local storage is unavailable'));
      expect(container.read(checkerVaultProvider).isEmpty, isTrue);
    });

    test('vaults a usable checker and reports ready', () async {
      await boot();
      final archive = container.read(archiveProvider)!;

      await buy();

      final state = container.read(checkerPurchaseProvider);
      expect(state.stage, CheckerPurchaseStage.ready);
      expect(state.hasVaultedChecker, isTrue);
      expect(state.checkerId, isNotEmpty);
      expect(state.transactionId, 'tx-1');
      expect(api.charges, hasLength(1));

      final vaulted = await archive.loadChecker(
        id: state.checkerId,
        indexNumber: _index,
      );
      expect(vaulted, isNotNull);
      expect(vaulted!.isRedeemable, isTrue);
      expect(vaulted.transactionId, 'tx-1');

      // And the History tab sees it immediately.
      expect(container.read(checkerVaultProvider).usable, hasLength(1));
    });

    test('buy + check now ends with the result and a spent checker', () async {
      await boot();
      final archive = container.read(archiveProvider)!;

      await buy(checkNow: true);

      final state = container.read(checkerPurchaseProvider);
      expect(state.stage, CheckerPurchaseStage.complete);
      expect(
        container.read(journeyProvider).current,
        TransactionStage.complete,
      );

      final vaulted = await archive.loadChecker(
        id: state.checkerId,
        indexNumber: _index,
      );
      expect(vaulted!.status, CheckerStatus.redeemed);
      expect(vaulted.isRedeemable, isFalse);
      expect(container.read(checkerVaultProvider).usable, isEmpty);
      expect(container.read(checkerVaultProvider).spent, hasLength(1));

      // The credential that reached the portal is the vaulted one.
      expect(api.redeemedSerials, [vaulted.serial]);
      expect(api.redemptions, hasLength(1));
    });

    test('a failed payment never vaults a checker', () async {
      await boot(
        mock: MockWaecApi(
          stages: [
            TransactionStage.paymentConfirmation,
            TransactionStage.failed,
          ],
        ),
      );
      final archive = container.read(archiveProvider)!;

      await buy();

      final state = container.read(checkerPurchaseProvider);
      expect(state.hasFailed, isTrue);
      expect(
        state.error,
        'The payment did not complete. No checker was issued.',
      );
      expect(await archive.listCheckers(_index), isEmpty);
    });

    test('a paid charge with no voucher fails with a support reference',
        () async {
      await boot(mock: _NoVoucherMock());
      final archive = container.read(archiveProvider)!;

      await buy();

      final state = container.read(checkerPurchaseProvider);
      expect(state.hasFailed, isTrue);
      expect(state.error, contains('The checker was not issued'));
      expect(state.error, contains('tx-1'));
      expect(await archive.listCheckers(_index), isEmpty);
    });

    test('mints exactly one idempotency key per purchase', () async {
      await boot();

      await buy();
      await buy();

      expect(api.charges, hasLength(2));
      // Distinct logical operations get distinct keys.
      expect(api.charges[0], isNot(api.charges[1]));
    });
  });

  group('redeem a stored checker', () {
    test('spends the vaulted credential and retires the checker', () async {
      await boot();
      final archive = container.read(archiveProvider)!;

      await buy();
      final checkerId = container.read(checkerPurchaseProvider).checkerId;
      final terminal = await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: checkerId);

      expect(terminal, TransactionStage.complete);
      expect(api.redeemedSerials, hasLength(1));
      expect(api.redemptions, hasLength(1));

      final spent = await archive.loadChecker(
        id: checkerId,
        indexNumber: _index,
      );
      expect(spent!.status, CheckerStatus.redeemed);
      expect(container.read(checkerVaultProvider).usable, isEmpty);
    });

    test('keeps the checker usable when WAEC rejects it', () async {
      await boot(mock: MockWaecApi()..redemptionRejects = true);
      final archive = container.read(archiveProvider)!;

      await buy();
      final checkerId = container.read(checkerPurchaseProvider).checkerId;

      final terminal = await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: checkerId);

      // The checker stays in the vault so the user can retry the credential
      // they paid for instead of buying another one.
      expect(terminal, isNot(TransactionStage.complete));
      final still = await archive.loadChecker(
        id: checkerId,
        indexNumber: _index,
      );
      expect(still!.isRedeemable, isTrue);
      expect(container.read(checkerPurchaseProvider).hasFailed, isTrue);
      expect(container.read(checkerPurchaseProvider).error, isNotNull);
    });

    test('keeps the checker usable when the gateway is unreachable', () async {
      await boot(mock: MockWaecApi()..redemptionUnreachable = true);
      final archive = container.read(archiveProvider)!;

      await buy();
      final checkerId = container.read(checkerPurchaseProvider).checkerId;

      await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: checkerId);

      final still = await archive.loadChecker(
        id: checkerId,
        indexNumber: _index,
      );
      expect(still!.isRedeemable, isTrue);
    });

    test('refuses to spend a checker that is already used', () async {
      await boot();
      final archive = container.read(archiveProvider)!;

      await buy();
      final checkerId = container.read(checkerPurchaseProvider).checkerId;
      // First spend succeeds...
      await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: checkerId);

      // ...the second must be refused without calling the portal again.
      final portalCallsBefore = api.redeemedSerials.length;
      await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: checkerId);

      expect(api.redeemedSerials.length, portalCallsBefore);
      final state = container.read(checkerPurchaseProvider);
      expect(state.hasFailed, isTrue);
      expect(state.error, 'That checker has already been used.');
      expect(
        (await archive.loadChecker(id: checkerId, indexNumber: _index))!
            .status,
        CheckerStatus.redeemed,
      );
    });

    test('refuses an unknown checker id', () async {
      await boot();

      await container
          .read(checkerPurchaseProvider.notifier)
          .redeem(indexNumber: _index, checkerId: 'nope');

      final state = container.read(checkerPurchaseProvider);
      expect(state.hasFailed, isTrue);
      expect(state.error, 'That checker is not saved on this device.');
      expect(api.redeemedSerials, isEmpty);
    });
  });

  group('checker vault notifier', () {
    test('reads an empty vault with no archive on the device', () async {
      container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(checkerVaultProvider.notifier).load(_index);

      final state = container.read(checkerVaultProvider);
      expect(state.isEmpty, isTrue);
      expect(state.error, isNull);
    });

    test('reports a fixed message instead of leaking a storage error',
        () async {
      await boot();
      // Drop the vault table so listCheckers fails for a non-integrity reason,
      // which is what a corrupt database presents as.
      final db = await databaseFactory.openDatabase(
        path,
        // Separate connection, so closing it does not tear down the archive's.
        options: OpenDatabaseOptions(version: 2, singleInstance: false),
      );
      await db.execute('DROP TABLE checkers');
      await db.close();

      await container.read(checkerVaultProvider.notifier).load(_index);

      expect(
        container.read(checkerVaultProvider).error,
        'Your saved checkers could not be read. Please try again.',
      );
    });

    test('delete removes a checker from the loaded vault', () async {
      await boot();
      final notifier = container.read(checkerVaultProvider.notifier);
      final archive = container.read(archiveProvider)!;

      final id = await archive.saveChecker(
        id: 'ck-1',
        indexNumber: _index,
        serial: 'WAESERIAL0001',
        pin: 'PIN00000001',
        examType: ExamType.bece.code,
        examYear: '2025',
        purchasedAtUnix: 1700000000,
      );
      await notifier.load(_index);
      expect(container.read(checkerVaultProvider).checkers, hasLength(1));

      await notifier.delete(indexNumber: _index, id: id);
      expect(container.read(checkerVaultProvider).isEmpty, isTrue);
      expect(await archive.listCheckers(_index), isEmpty);
    });

    test('splits the vault into usable and spent views', () async {
      await boot();
      final archive = container.read(archiveProvider)!;
      final notifier = container.read(checkerVaultProvider.notifier);

      await archive.saveChecker(
        id: 'fresh',
        indexNumber: _index,
        serial: 'WAESERIAL0001',
        pin: 'PIN00000001',
        examType: ExamType.bece.code,
        examYear: '2025',
        purchasedAtUnix: 1700000000,
      );
      await archive.saveChecker(
        id: 'spent',
        indexNumber: _index,
        serial: 'WAESERIAL0002',
        pin: 'PIN00000002',
        examType: ExamType.bece.code,
        examYear: '2024',
        purchasedAtUnix: 1700000100,
      );
      await archive.markCheckerRedeemed(
        id: 'spent',
        indexNumber: _index,
        redeemedAtUnix: 1700000200,
      );
      await notifier.load(_index);

      final state = container.read(checkerVaultProvider);
      expect(state.usable.map((c) => c.id), ['fresh']);
      expect(state.spent.map((c) => c.id), ['spent']);
    });
  });
}