// Checker vault + purchase-flow provider tests (ADR-001, plan §3.6/§3.7).
//
// Seams used here, and why:
//   * ProviderContainer + overrides — Riverpod's own test seam. Hand-rolling a
//     `Ref` implementation does not compile (Ref is not an implementable
//     interface), and would test the fake rather than the notifier.
//   * A REAL encrypted archive on sqflite_common_ffi — `EncryptedResultArchive`
//     has a library-private constructor, so it cannot be subclassed. Running
//     against the real thing also exercises the schema and the ciphertext
//     envelope, which is the point of ADR-001.
//   * A fake `WaecApi` — the only boundary that is genuinely remote.
//
// The load-bearing guarantees under test:
//   1. A checker is never vaulted unless the payment actually completed.
//   2. A paid-but-unissued voucher fails loudly and vaults nothing (no
//      credential-less checker row).
//   3. Only a terminal *success* retires a checker; a failed redemption leaves
//      the credential the user paid for still spendable.
//   4. No credential (serial/PIN) ever reaches state or error copy.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/network/retry_policy.dart';
import 'package:waec_direct/core/storage/encrypted_archive.dart';
import 'package:waec_direct/features/checker/checker_providers.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';

const _index = '1002330440';

/// Scriptable [WaecApi]. Records every call so tests can assert on what was
/// *not* attempted (e.g. no charge after a missing vault).
class _FakeWaecApi implements WaecApi {
  /// What [initCharge] returns. Defaults to a charge that carries a voucher.
  ChargeInit? charge;

  /// Stages emitted by [transactionStages], in order.
  List<TransactionStage> stages = const <TransactionStage>[
    TransactionStage.paymentConfirmation,
    TransactionStage.voucherProvisioning,
    TransactionStage.complete,
  ];

  CheckerRedemption redemption = const CheckerRedemption(
    transactionId: 'tx-redeem',
    status: 'pending',
    displayMessage: 'Checking your result',
  );

  Object? throwOnCharge;
  Object? throwOnRedeem;

  int initChargeCalls = 0;
  int redeemCalls = 0;
  final List<String> idempotencyKeys = <String>[];

  /// The `check_now` flag presented to each [initCharge] (ADR-002), so a test
  /// can prove the toggle reached the charge rather than only the UI.
  final List<bool> checkNowFlags = <bool>[];

  /// Serials/PINs handed to [redeemChecker] — asserted against state and error
  /// copy to prove Hard Rule 1 holds end to end.
  final List<String> redeemedSerials = <String>[];
  final List<String> redeemedPins = <String>[];

  ChargeInit get _defaultCharge => const ChargeInit(
        transactionId: 'tx-1',
        status: 'pending',
        amountPesewas: 2000,
        checkoutUrl: 'https://checkout.paystack.com/tx-1',
        displayMessage: 'Approve on your phone',
        checkerSerial: 'WAESERIAL0001',
        checkerPin: 'PIN00000001',
      );

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    bool checkNow = false,
  }) async {
    initChargeCalls++;
    idempotencyKeys.add(idempotencyKey);
    checkNowFlags.add(checkNow);
    if (throwOnCharge != null) throw throwOnCharge!;
    return charge ?? _defaultCharge;
  }

  @override
  Stream<TransactionStage> transactionStages(String transactionId) async* {
    for (final s in stages) {
      yield s;
    }
  }

  @override
  Future<CheckerRedemption> redeemChecker({
    required String idempotencyKey,
    required String serial,
    required String pin,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    redeemCalls++;
    idempotencyKeys.add(idempotencyKey);
    redeemedSerials.add(serial);
    redeemedPins.add(pin);
    if (throwOnRedeem != null) throw throwOnRedeem!;
    return redemption;
  }

  @override
  Future<Price> getPricing({
    required ExamType examType,
    bool checkNow = false,
  }) async => const Price(amountPesewas: 2000, currency: 'GHS');

  static const _session = AuthSession(
    indexNumber: _index,
    userId: 'user-001',
    accessToken: 'at',
    refreshToken: 'rt',
    accessExpiresAtUnix: 9999999999,
    issuedAtUnix: 1000000000,
    source: AuthSessionSource.server,
  );

  @override
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  }) async => _session;

  @override
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  }) async => _session;

  @override
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  }) async => _session;

  @override
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  }) async => true;
}

void main() {
  group('CheckerPurchaseStage', () {
    test('has exactly the seven documented stages', () {
      // The purchase screen switches on this enum; pinning the set means a new
      // stage cannot be added without the UI being revisited.
      expect(CheckerPurchaseStage.values.length, 7);
      expect(
        CheckerPurchaseStage.values.map((s) => s.name).toSet(),
        {
          'idle',
          'paying',
          'provisioning',
          'ready',
          'redeeming',
          'complete',
          'failed',
        },
      );
    });
  });

  group('CheckerPurchaseState', () {
    test('defaults to a clean idle state', () {
      const s = CheckerPurchaseState();
      expect(s.stage, CheckerPurchaseStage.idle);
      expect(s.transactionId, '');
      expect(s.checkoutUrl, '');
      expect(s.checkerId, '');
      expect(s.error, isNull);
      expect(s.isBusy, isFalse);
      expect(s.hasFailed, isFalse);
      expect(s.hasVaultedChecker, isFalse);
    });

    test('isBusy covers exactly the in-flight stages', () {
      const busy = {
        CheckerPurchaseStage.paying,
        CheckerPurchaseStage.provisioning,
        CheckerPurchaseStage.redeeming,
      };
      for (final stage in CheckerPurchaseStage.values) {
        expect(
          CheckerPurchaseState(stage: stage).isBusy,
          busy.contains(stage),
          reason: '$stage busy flag is wrong',
        );
      }
    });

    test('hasVaultedChecker is true once the credential is stored', () {
      // `ready` is the first stage at which a real serial+PIN exists on device,
      // and it must stay true through redemption so the UI can offer a retry.
      const vaulted = {
        CheckerPurchaseStage.ready,
        CheckerPurchaseStage.redeeming,
        CheckerPurchaseStage.complete,
      };
      for (final stage in CheckerPurchaseStage.values) {
        expect(
          CheckerPurchaseState(stage: stage).hasVaultedChecker,
          vaulted.contains(stage),
          reason: '$stage vaulted flag is wrong',
        );
      }
    });

    test('a failed purchase is neither busy nor vaulted', () {
      const s = CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'The payment did not complete.',
      );
      expect(s.hasFailed, isTrue);
      expect(s.isBusy, isFalse);
      expect(s.hasVaultedChecker, isFalse);
      expect(s.error, isNotNull);
    });
  });

  group('CheckerVaultState', () {
    Checker make(String id, CheckerStatus status) => Checker(
          id: id,
          serial: 'SER$id',
          pin: 'PIN$id',
          examType: ExamType.bece.code,
          examYear: '2025',
          status: status,
          purchasedAtUnix: 1700000000,
        );

    test('empty by default', () {
      const s = CheckerVaultState();
      expect(s.isEmpty, isTrue);
      expect(s.checkers, isEmpty);
      expect(s.usable, isEmpty);
      expect(s.spent, isEmpty);
      expect(s.loading, isFalse);
      expect(s.error, isNull);
    });

    test('partitions usable from spent', () {
      final s = CheckerVaultState(checkers: <Checker>[
        make('a', CheckerStatus.unused),
        make('b', CheckerStatus.redeemed),
        make('c', CheckerStatus.expired),
      ]);
      expect(s.isEmpty, isFalse);
      expect(s.usable.map((c) => c.id), <String>['a']);
      expect(s.spent.map((c) => c.id), <String>['b', 'c']);
      // Partitioning must be exhaustive and non-overlapping.
      expect(s.usable.length + s.spent.length, s.checkers.length);
    });

    test('every checker is either usable or spent, never both', () {
      for (final status in CheckerStatus.values) {
        final s = CheckerVaultState(checkers: <Checker>[make('x', status)]);
        final inUsable = s.usable.isNotEmpty;
        final inSpent = s.spent.isNotEmpty;
        expect(inUsable ^ inSpent, isTrue,
            reason: '$status must land in exactly one partition');
        expect(inUsable, status.isRedeemable);
      }
    });
  });

  group('describeCheckerError', () {
    test('surfaces a curated CheckerException message', () {
      const e = CheckerException(
        CheckerFailureKind.checkerRejected,
        'That checker has already been used.',
      );
      expect(describeCheckerError(e), 'That checker has already been used.');
    });

    test('replaces any other error with fixed copy', () {
      expect(
        describeCheckerError(Exception('boom')),
        'Something went wrong. Please try again.',
      );
      expect(
        describeCheckerError(StateError('internal')),
        'Something went wrong. Please try again.',
      );
    });

    test('never echoes the underlying exception text', () {
      // A transport error can carry a URL or a request body containing the
      // serial/PIN. It must never be forwarded to the UI.
      const leaky = 'https://api.example/v1?serial=WAESERIAL0001&pin=PIN00000001';
      final msg = describeCheckerError(Exception(leaky));
      expect(msg, isNot(contains('WAESERIAL0001')));
      expect(msg, isNot(contains('PIN00000001')));
      expect(msg, isNot(contains('serial')));
    });
  });

  group('IdempotencyKeys', () {
    test('creates unique non-empty keys', () {
      final keys = <String>{for (var i = 0; i < 200; i++) IdempotencyKeys.create()};
      expect(keys.length, 200, reason: 'idempotency keys must not collide');
      expect(keys.every((k) => k.isNotEmpty), isTrue);
    });

    test('creates a UUIDv4-shaped key', () {
      final key = IdempotencyKeys.create();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
                r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(key),
        isTrue,
        reason: 'expected UUIDv4, got "$key"',
      );
    });
  });

  // ── Provider-level tests ──────────────────────────────────────────────────

  group('providers', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    late Directory dir;
    late EncryptedResultArchive archive;
    late _FakeWaecApi api;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('waec_providers_test');
      archive = await EncryptedResultArchive.open('${dir.path}/archive.db');
      api = _FakeWaecApi();
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// A container wired to the real archive + the fake API.
    ProviderContainer container({EncryptedResultArchive? vault}) {
      final c = ProviderContainer(
        overrides: <Override>[
          archiveProvider.overrideWithValue(vault),
          waecApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    /// A container whose vault is deliberately absent (storage unavailable).
    ProviderContainer containerWithoutVault() => container(vault: null);

    group('CheckerVaultNotifier', () {
      test('load with no vault yields an empty state, not an error', () async {
        // A device that cannot open its vault still gets a usable app.
        final c = containerWithoutVault();
        await c.read(checkerVaultProvider.notifier).load(_index);
        final s = c.read(checkerVaultProvider);
        expect(s.isEmpty, isTrue);
        expect(s.error, isNull);
      });

      test('load surfaces the vault contents for the signed-in index', () async {
        await archive.saveChecker(
          id: 'ck-1',
          indexNumber: _index,
          serial: 'WAESERIAL0001',
          pin: 'PIN00000001',
          examType: ExamType.bece.code,
          examYear: '2025',
          purchasedAtUnix: 1700000000,
        );
        final c = container(vault: archive);
        await c.read(checkerVaultProvider.notifier).load(_index);
        final s = c.read(checkerVaultProvider);
        expect(s.checkers.length, 1);
        expect(s.usable.length, 1);
        expect(s.error, isNull);
      });

      test('load never exposes another candidate\'s vault', () async {
        await archive.saveChecker(
          id: 'ck-1',
          indexNumber: '1002330499',
          serial: 'WAESERIAL0001',
          pin: 'PIN00000001',
          examType: ExamType.bece.code,
          examYear: '2025',
          purchasedAtUnix: 1700000000,
        );
        final c = container(vault: archive);
        await c.read(checkerVaultProvider.notifier).load(_index);
        expect(c.read(checkerVaultProvider).isEmpty, isTrue);
      });

      test('delete removes the checker and refreshes state', () async {
        await archive.saveChecker(
          id: 'ck-1',
          indexNumber: _index,
          serial: 'WAESERIAL0001',
          pin: 'PIN00000001',
          examType: ExamType.bece.code,
          examYear: '2025',
          purchasedAtUnix: 1700000000,
        );
        final c = container(vault: archive);
        final n = c.read(checkerVaultProvider.notifier);
        await n.load(_index);
        expect(c.read(checkerVaultProvider).checkers.length, 1);

        await n.delete(indexNumber: _index, id: 'ck-1');
        expect(c.read(checkerVaultProvider).isEmpty, isTrue);
        // The row is really gone, not just filtered from state.
        expect(await archive.loadChecker(id: 'ck-1', indexNumber: _index), isNull);
      });

      test('delete with no vault is a silent no-op', () async {
        final c = containerWithoutVault();
        await c
            .read(checkerVaultProvider.notifier)
            .delete(indexNumber: _index, id: 'ck-1');
        expect(c.read(checkerVaultProvider).isEmpty, isTrue);
      });

      test('markRedeemed retires the checker', () async {
        await archive.saveChecker(
          id: 'ck-1',
          indexNumber: _index,
          serial: 'WAESERIAL0001',
          pin: 'PIN00000001',
          examType: ExamType.bece.code,
          examYear: '2025',
          purchasedAtUnix: 1700000000,
        );
        final c = container(vault: archive);
        final n = c.read(checkerVaultProvider.notifier);
        await n.load(_index);
        expect(c.read(checkerVaultProvider).usable.length, 1);

        await n.markRedeemed(indexNumber: _index, id: 'ck-1');
        final s = c.read(checkerVaultProvider);
        expect(s.usable, isEmpty);
        expect(s.spent.length, 1);
        expect(s.spent.single.status, CheckerStatus.redeemed);
      });
    });

    group('CheckerPurchaseNotifier.buy', () {
      test('refuses to charge when there is no vault, and calls no API', () async {
        // The credential has nowhere to live, so money must not move. This is
        // the ordering that protects the candidate from paying for a checker
        // the device cannot keep.
        final c = containerWithoutVault();
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.failed);
        expect(s.error, isNotNull);
        expect(s.error, contains('storage'));
        expect(api.initChargeCalls, 0, reason: 'no charge may be attempted');
      });

      test('happy path vaults the checker and lands on ready', () async {
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.ready);
        expect(s.transactionId, 'tx-1');
        expect(s.checkerId, isNotEmpty);
        expect(s.hasVaultedChecker, isTrue);
        expect(s.error, isNull);
        expect(api.initChargeCalls, 1);

        // The credential is really in the vault, decryptable for this index.
        final stored =
            await archive.loadChecker(id: s.checkerId, indexNumber: _index);
        expect(stored, isNotNull);
        expect(stored!.serial, 'WAESERIAL0001');
        expect(stored.status, CheckerStatus.unused);
        expect(stored.transactionId, 'tx-1');

        // ...and the vault state was refreshed for the History tab.
        expect(c.read(checkerVaultProvider).checkers.length, 1);
      });

      test('the check-now flag reaches the charge (ADR-002)', () async {
        // The screen quotes the combined rate when "Also check my results now"
        // is on. The flag must therefore travel with the charge, or the
        // candidate would be quoted one figure and billed another.
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
              checkNow: true,
            );
        expect(api.checkNowFlags, <bool>[true]);
        // And because the checker is spent in the same pass, the purchase runs
        // straight through to a completed redemption.
        expect(api.redeemCalls, 1);
        expect(
          c.read(checkerPurchaseProvider).stage,
          CheckerPurchaseStage.complete,
        );
      });

      test('a checker kept for later is charged the checker-only rate',
          () async {
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
              checkNow: false,
            );
        expect(api.checkNowFlags, <bool>[false]);
        // Off: nothing is spent in this pass, so the checker stays in the vault
        // ready to be used later.
        expect(api.redeemCalls, 0);
        expect(
          c.read(checkerPurchaseProvider).stage,
          CheckerPurchaseStage.ready,
        );
        expect(c.read(checkerPurchaseProvider).hasVaultedChecker, isTrue);
      });

      test('state never carries the serial or PIN', () async {
        // Hard Rule 1: the credential is read from the vault at redemption time
        // and must never be copied into observable state.
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
              checkNow: true,
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.toString(), isNot(contains('WAESERIAL0001')));
        expect(s.toString(), isNot(contains('PIN00000001')));
        expect(s.checkerId, isNot('WAESERIAL0001'));
        expect(s.error ?? '', isNot(contains('WAESERIAL0001')));
        expect(s.error ?? '', isNot(contains('PIN00000001')));
      });

      test('a paid charge that issued no voucher fails and vaults nothing', () async {
        // Paid, but the gateway returned no credential. Must fail loudly with a
        // support reference rather than storing a checker with an empty PIN.
        api.charge = const ChargeInit(
          transactionId: 'tx-novoucher',
          status: 'success',
          amountPesewas: 2000,
          checkoutUrl: 'https://checkout.paystack.com/tx-novoucher',
          displayMessage: 'Paid',
          // checkerSerial / checkerPin deliberately empty
        );
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.failed);
        expect(s.error, contains('tx-novoucher'),
            reason: 'the user needs a reference to give support');
        expect(s.hasVaultedChecker, isFalse);
        expect(await archive.listCheckers(_index), isEmpty);
      });

      test('a failed payment vaults nothing', () async {
        api.stages = const <TransactionStage>[
          TransactionStage.paymentConfirmation,
          TransactionStage.failed,
        ];
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.failed);
        expect(s.error, contains('No checker was issued'));
        expect(await archive.listCheckers(_index), isEmpty);
      });

      test('a charge that throws is reported without leaking detail', () async {
        api.throwOnCharge = Exception('socket hang up serial=WAESERIAL0001');
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.failed);
        expect(s.error, isNotNull);
        expect(s.error, isNot(contains('WAESERIAL0001')));
        expect(s.error, isNot(contains('socket hang up')));
        expect(await archive.listCheckers(_index), isEmpty);
      });

      test('every charge attempt carries a fresh idempotency key', () async {
        // Plan §3.9/§4.9: one key per logical operation, reused across retries
        // of *that* operation, never shared between two purchases.
        final c = container(vault: archive);
        final n = c.read(checkerPurchaseProvider.notifier);
        await n.buy(indexNumber: _index, examType: ExamType.bece, examYear: '2025');
        await n.buy(indexNumber: _index, examType: ExamType.bece, examYear: '2024');
        expect(api.initChargeCalls, 2);
        expect(api.idempotencyKeys.toSet().length, 2,
            reason: 'two purchases must not share an idempotency key');
      });
    });

    group('CheckerPurchaseNotifier.redeem', () {
      Future<String> seedChecker({CheckerStatus status = CheckerStatus.unused}) async {
        final id = await archive.saveChecker(
          id: 'ck-1',
          indexNumber: _index,
          serial: 'WAESERIAL0001',
          pin: 'PIN00000001',
          examType: ExamType.bece.code,
          examYear: '2025',
          purchasedAtUnix: 1700000000,
        );
        if (status == CheckerStatus.redeemed) {
          await archive.markCheckerRedeemed(
            id: id,
            indexNumber: _index,
            redeemedAtUnix: 1700000100,
          );
        }
        return id;
      }

      test('refuses when there is no vault', () async {
        final c = containerWithoutVault();
        final stage = await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'ck-1');
        expect(stage, TransactionStage.failed);
        expect(c.read(checkerPurchaseProvider).stage, CheckerPurchaseStage.failed);
        expect(api.redeemCalls, 0);
      });

      test('refuses a checker that is not in the vault', () async {
        final c = container(vault: archive);
        final stage = await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'does-not-exist');
        expect(stage, TransactionStage.failed);
        expect(c.read(checkerPurchaseProvider).error, contains('not saved'));
        expect(api.redeemCalls, 0);
      });

      test('refuses to spend an already-redeemed checker', () async {
        await seedChecker(status: CheckerStatus.redeemed);
        final c = container(vault: archive);
        final stage = await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'ck-1');
        expect(stage, TransactionStage.failed);
        expect(c.read(checkerPurchaseProvider).error, contains('already been used'));
        expect(api.redeemCalls, 0, reason: 'a spent credential must not be retried');
      });

      test('success retires the checker exactly once', () async {
        await seedChecker();
        final c = container(vault: archive);
        final stage = await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'ck-1');

        expect(stage, TransactionStage.complete);
        expect(c.read(checkerPurchaseProvider).stage, CheckerPurchaseStage.complete);
        expect(api.redeemCalls, 1);

        final stored = await archive.loadChecker(id: 'ck-1', indexNumber: _index);
        expect(stored!.status, CheckerStatus.redeemed);
        expect(stored.redeemedAtUnix, isNotNull);
      });

      test('a failed redemption leaves the checker spendable', () async {
        // The user paid for this credential; a portal failure must not burn it.
        await seedChecker();
        api.stages = const <TransactionStage>[
          TransactionStage.waecRetrieval,
          TransactionStage.failed,
        ];
        final c = container(vault: archive);
        final stage = await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'ck-1');

        expect(stage, TransactionStage.failed);
        expect(c.read(checkerPurchaseProvider).stage, CheckerPurchaseStage.failed);
        final stored = await archive.loadChecker(id: 'ck-1', indexNumber: _index);
        expect(stored!.status, CheckerStatus.unused,
            reason: 'a failed fetch must not retire the checker');
        expect(c.read(checkerVaultProvider).usable, isEmpty,
            reason: 'vault state is only refreshed by load/markRedeemed');
      });

      test('hands the real credential to the API but never to state', () async {
        await seedChecker();
        final c = container(vault: archive);
        await c
            .read(checkerPurchaseProvider.notifier)
            .redeem(indexNumber: _index, checkerId: 'ck-1');

        // The portal call needs the plaintext credential...
        expect(api.redeemedSerials.single, 'WAESERIAL0001');
        expect(api.redeemedPins.single, 'PIN00000001');
        // ...but observable state must not carry it.
        final s = c.read(checkerPurchaseProvider);
        expect(s.toString(), isNot(contains('WAESERIAL0001')));
        expect(s.toString(), isNot(contains('PIN00000001')));
        final journey = c.read(journeyProvider);
        expect(journey.toString(), isNot(contains('WAESERIAL0001')));
        expect(journey.error ?? '', isNot(contains('PIN00000001')));
      });

      test('buy(checkNow: true) purchases then redeems in one pass', () async {
        final c = container(vault: archive);
        await c.read(checkerPurchaseProvider.notifier).buy(
              indexNumber: _index,
              examType: ExamType.bece,
              examYear: '2025',
              checkNow: true,
            );
        final s = c.read(checkerPurchaseProvider);
        expect(s.stage, CheckerPurchaseStage.complete);
        expect(api.initChargeCalls, 1);
        expect(api.redeemCalls, 1);
        final stored =
            await archive.loadChecker(id: s.checkerId, indexNumber: _index);
        expect(stored!.status, CheckerStatus.redeemed);
      });
    });
  });
}
