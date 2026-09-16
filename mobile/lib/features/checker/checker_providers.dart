import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain_types.dart';
import '../../core/network/retry_policy.dart';
import '../../core/storage/encrypted_archive.dart';
import '../verification/verification_providers.dart';

/// The on-device encrypted archive (ADR-001).
///
/// `null` until `main()` has opened the database, and in tests that have not
/// overridden it. Every consumer must treat null as "no local storage on this
/// device" and degrade gracefully rather than crash — a device that cannot open
/// its vault still gets a usable app.
final archiveProvider = Provider<EncryptedResultArchive?>((ref) => null);

/// What the History tab knows about the checker vault.
class CheckerVaultState {
  const CheckerVaultState({
    this.checkers = const <Checker>[],
    this.loading = false,
    this.error,
  });

  /// Every checker in the vault for the signed-in account, newest first.
  final List<Checker> checkers;

  final bool loading;

  /// Set when the vault could not be read at all — a fixed, user-presentable
  /// string that never carries internal detail.
  final String? error;

  /// Checkers the user can still spend, in vault order.
  List<Checker> get usable =>
      checkers.where((c) => c.isRedeemable).toList(growable: false);

  /// Checkers whose credential is already spent or void.
  List<Checker> get spent =>
      checkers.where((c) => !c.isRedeemable).toList(growable: false);

  bool get isEmpty => checkers.isEmpty;
}

/// Reads and writes the encrypted checker vault (ADR-001).
///
/// Deliberately knows nothing about auth: the caller passes the index number it
/// already holds, so this never has to guess whose vault it is looking at.
class CheckerVaultNotifier extends StateNotifier<CheckerVaultState> {
  CheckerVaultNotifier(this._ref) : super(const CheckerVaultState());

  final Ref _ref;

  /// Read every checker for [indexNumber] out of the vault.
  Future<void> load(String indexNumber) async {
    final archive = _ref.read(archiveProvider);
    if (archive == null) {
      state = const CheckerVaultState();
      return;
    }
    state = CheckerVaultState(checkers: state.checkers, loading: true);
    try {
      final checkers = await archive.listCheckers(indexNumber);
      state = CheckerVaultState(checkers: checkers);
    } on ArchiveIntegrityException {
      // A vault that fails its AES-GCM tag check is reported, never hidden:
      // an empty list would look like the user's checkers had vanished.
      state = const CheckerVaultState(
        error: 'Your saved checkers could not be verified on this device.',
      );
    } catch (_) {
      state = const CheckerVaultState(
        error: 'Your saved checkers could not be read. Please try again.',
      );
    }
  }

  /// Forget one checker permanently, with the ADR-001 zero-out.
  Future<void> delete({
    required String indexNumber,
    required String id,
  }) async {
    final archive = _ref.read(archiveProvider);
    if (archive == null) return;
    await archive.deleteChecker(id: id, indexNumber: indexNumber);
    await load(indexNumber);
  }

  /// Retire a checker once its redemption reached terminal success.
  Future<void> markRedeemed({
    required String indexNumber,
    required String id,
  }) async {
    final archive = _ref.read(archiveProvider);
    if (archive == null) return;
    await archive.markCheckerRedeemed(
      id: id,
      indexNumber: indexNumber,
      redeemedAtUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await load(indexNumber);
  }
}

final checkerVaultProvider =
    StateNotifierProvider<CheckerVaultNotifier, CheckerVaultState>(
      (ref) => CheckerVaultNotifier(ref),
    );

/// Where a checker purchase has got to.
enum CheckerPurchaseStage {
  idle,

  /// Charge accepted; the user is approving on their phone.
  paying,

  /// Payment settled and the voucher is being provisioned.
  provisioning,

  /// The credential is in the vault, not yet spent.
  ready,

  /// Spending a stored checker against the WAEC portal.
  redeeming,

  /// Result retrieved — the checker is now spent.
  complete,

  failed,
}

/// State machine for one purchase-then-optionally-redeem flow.
class CheckerPurchaseState {
  const CheckerPurchaseState({
    this.stage = CheckerPurchaseStage.idle,
    this.transactionId = '',
    this.checkoutUrl = '',
    this.checkerId = '',
    this.error,
  });

  final CheckerPurchaseStage stage;
  final String transactionId;
  final String checkoutUrl;

  /// Vault id of the checker this flow produced, once it exists.
  final String checkerId;

  /// Fixed, user-presentable failure text. Never carries a credential.
  final String? error;

  bool get isBusy =>
      stage == CheckerPurchaseStage.paying ||
      stage == CheckerPurchaseStage.provisioning ||
      stage == CheckerPurchaseStage.redeeming;

  bool get hasFailed => stage == CheckerPurchaseStage.failed;

  /// True once the credential is safely in the vault.
  bool get hasVaultedChecker =>
      stage == CheckerPurchaseStage.ready ||
      stage == CheckerPurchaseStage.redeeming ||
      stage == CheckerPurchaseStage.complete;
}

/// Drives buy-checker, and optionally spend-it-immediately.
class CheckerPurchaseNotifier extends StateNotifier<CheckerPurchaseState> {
  CheckerPurchaseNotifier(this._ref) : super(const CheckerPurchaseState());

  final Ref _ref;

  /// Buy a checker and, when [checkNow] is set, spend it in the same pass.
  ///
  /// The idempotency key is minted once and reused by every retry of the charge
  /// (plan §3.9 / §4.9), so a network flap can never bill the candidate twice.
  Future<void> buy({
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    bool checkNow = false,
  }) async {
    final archive = _ref.read(archiveProvider);
    if (archive == null) {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'Local storage is unavailable on this device, so a checker '
            'cannot be saved here.',
      );
      return;
    }

    state = const CheckerPurchaseState(stage: CheckerPurchaseStage.paying);
    final api = _ref.read(waecApiProvider);
    try {
      final init = await api.initCharge(
        idempotencyKey: IdempotencyKeys.create(),
        indexNumber: indexNumber,
        examType: examType,
        examYear: examYear,
      );
      state = CheckerPurchaseState(
        stage: CheckerPurchaseStage.provisioning,
        transactionId: init.transactionId,
        checkoutUrl: init.checkoutUrl,
      );

      // Wait for payment + provisioning to settle before writing anything: a
      // checker that was never paid for must never enter the vault.
      final stream = api.transactionStages(init.transactionId);
      await for (final stage in stream) {
        if (stage == TransactionStage.failed) {
          state = CheckerPurchaseState(
            stage: CheckerPurchaseStage.failed,
            transactionId: init.transactionId,
            error: 'The payment did not complete. No checker was issued.',
          );
          return;
        }
        if (stage.isTerminal) break;
      }

      if (!init.hasChecker) {
        // Paid, but the gateway returned no voucher. Fail loudly and hand the
        // user a reference rather than vaulting a credential-less checker.
        state = CheckerPurchaseState(
          stage: CheckerPurchaseStage.failed,
          transactionId: init.transactionId,
          error: 'The checker was not issued. Please contact support with '
              'reference ${init.transactionId}.',
        );
        return;
      }

      final id = IdempotencyKeys.create();
      await archive.saveChecker(
        id: id,
        indexNumber: indexNumber,
        serial: init.checkerSerial,
        pin: init.checkerPin,
        examType: examType.code,
        examYear: examYear,
        purchasedAtUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        transactionId: init.transactionId,
      );
      state = CheckerPurchaseState(
        stage: CheckerPurchaseStage.ready,
        transactionId: init.transactionId,
        checkoutUrl: init.checkoutUrl,
        checkerId: id,
      );
      await _ref.read(checkerVaultProvider.notifier).load(indexNumber);

      if (checkNow) {
        await redeem(indexNumber: indexNumber, checkerId: id);
      }
    } catch (e) {
      state = CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: describeCheckerError(e),
      );
    }
  }

  /// Spend a stored checker on a result retrieval.
  ///
  /// The credential is read from the vault here and handed straight to the
  /// journey — it is never copied into [CheckerPurchaseState], never logged, and
  /// never rendered (Hard Rule 1). Only a terminal *success* retires the
  /// checker; any other outcome leaves it in the vault so the user can retry a
  /// credential they paid for.
  Future<TransactionStage> redeem({
    required String indexNumber,
    required String checkerId,
  }) async {
    final archive = _ref.read(archiveProvider);
    if (archive == null) {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'Local storage is unavailable on this device.',
      );
      return TransactionStage.failed;
    }

    final Checker? checker;
    try {
      checker = await archive.loadChecker(
        id: checkerId,
        indexNumber: indexNumber,
      );
    } on ArchiveIntegrityException {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'This checker failed its security check on this device. '
            'It has not been used.',
      );
      return TransactionStage.failed;
    } catch (_) {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'This checker could not be read from this device.',
      );
      return TransactionStage.failed;
    }

    if (checker == null) {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'That checker is not saved on this device.',
      );
      return TransactionStage.failed;
    }
    if (!checker.isRedeemable) {
      state = const CheckerPurchaseState(
        stage: CheckerPurchaseStage.failed,
        error: 'That checker has already been used.',
      );
      return TransactionStage.failed;
    }

    state = CheckerPurchaseState(
      stage: CheckerPurchaseStage.redeeming,
      transactionId: state.transactionId,
      checkerId: checkerId,
    );

    final terminal = await _ref
        .read(journeyProvider.notifier)
        .redeemChecker(
          serial: checker.serial,
          pin: checker.pin,
          indexNumber: indexNumber,
          examType: ExamType.fromCode(checker.examType),
          examYear: checker.examYear,
        );

    if (terminal == TransactionStage.complete) {
      await _ref.read(checkerVaultProvider.notifier).markRedeemed(
        indexNumber: indexNumber,
        id: checkerId,
      );
      state = CheckerPurchaseState(
        stage: CheckerPurchaseStage.complete,
        transactionId: state.transactionId,
        checkerId: checkerId,
      );
      return TransactionStage.complete;
    }

    state = CheckerPurchaseState(
      stage: CheckerPurchaseStage.failed,
      transactionId: state.transactionId,
      checkerId: checkerId,
      error:
          _ref.read(journeyProvider).error ??
          'The checker could not be redeemed. It is still saved, so you can '
              'try again.',
    );
    return terminal;
  }
}

final checkerPurchaseProvider =
    StateNotifierProvider<CheckerPurchaseNotifier, CheckerPurchaseState>(
      (ref) => CheckerPurchaseNotifier(ref),
    );