import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/domain_types.dart';
import '../../core/network/retry_policy.dart';

/// App lifecycle — plan §3.8: result state zero-out on backgrounding.
enum AppLifecycle { active, backgrounded }

/// Verification form state (index, exam, year). Payment method is chosen by
/// the user on Paystack's hosted checkout, so it is no longer collected in-app.
class VerificationForm {
  const VerificationForm({
    this.indexNumber = '',
    this.examType = ExamType.bece,
    this.examYear = '2025',
  });

  final String indexNumber;
  final ExamType examType;
  final String examYear;

  VerificationForm copyWith({
    String? indexNumber,
    ExamType? examType,
    String? examYear,
  }) =>
      VerificationForm(
        indexNumber: indexNumber ?? this.indexNumber,
        examType: examType ?? this.examType,
        examYear: examYear ?? this.examYear,
      );

  /// CTA enabled only when the locked index number is valid (plan §3.3).
  bool get isValid => IndexNumberValidator.isValid(indexNumber);
}

class VerificationFormNotifier extends StateNotifier<VerificationForm> {
  VerificationFormNotifier() : super(const VerificationForm());

  void setIndex(String v) => state = state.copyWith(indexNumber: v);
  void setExam(ExamType t) => state = state.copyWith(examType: t);
  void setYear(String y) => state = state.copyWith(examYear: y);
}

/// Live price fetched from backend config (CTA shows server-driven GHS).
/// If the backend is unreachable the UI falls back to a default so the
/// journey is never blocked (see verification_screen.dart).
final priceProvider = FutureProvider.family<Price, ExamType>((ref, exam) {
  return ref.watch(waecApiProvider).getPricing(exam);
});

/// Offline-safe price used when the pricing endpoint is unreachable.
/// Matches the backend's standard single-result fee (GHS 20.00).
const fallbackPrice = Price(amountPesewas: 2000, currency: 'GHS');

final verificationFormProvider =
    StateNotifierProvider<VerificationFormNotifier, VerificationForm>(
        (ref) => VerificationFormNotifier());

/// Stages emitted during one retrieval journey.
class JourneyState {
  const JourneyState({
    this.transactionId = '',
    this.stages = const [],
    this.current = TransactionStage.paymentConfirmation,
    this.error,
  });

  final String transactionId;
  final List<TransactionStage> stages;
  final TransactionStage current;
  final String? error;

  bool get isTerminal => current.isTerminal;
  bool get hasError => error != null;
}

class JourneyNotifier extends StateNotifier<JourneyState> {
  JourneyNotifier(this._api) : super(const JourneyState());

  final WaecApi _api;
  StreamSubscription<TransactionStage>? _sub;

  /// Begin the retrieval journey: init charge (idempotent), then stream
  /// stages via SSE-with-polling-fallback. Payment method is chosen by the
  /// user on Paystack's hosted checkout, so no in-app channel/phone is sent.
  Future<void> start({
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    // Idempotency key created ONCE and preserved across all retries of
    // this logical operation (plan §3.9 / §4.9).
    final key = IdempotencyKeys.create();
    try {
      final init = await _api.initCharge(
        idempotencyKey: key,
        indexNumber: indexNumber,
        examType: examType,
        examYear: examYear,
      );
      state = JourneyState(transactionId: init.transactionId);
      _sub = _api.transactionStages(init.transactionId).listen(
        (stage) {
          state = JourneyState(
            transactionId: init.transactionId,
            stages: [...state.stages, stage],
            current: stage,
          );
        },
        onError: (Object e) {
          state = JourneyState(
            transactionId: init.transactionId,
            stages: state.stages,
            current: TransactionStage.failed,
            error: e.toString(),
          );
        },
      );
    } catch (e) {
      state = JourneyState(
        current: TransactionStage.failed,
        error: e.toString(),
      );
    }
  }

  /// Zero-out on dispose/background (plan §3.8).
  void purge() {
    _sub?.cancel();
    _sub = null;
    state = const JourneyState();
  }

  /// Begin a *checker redemption* journey (ADR-001): spend a serial + PIN the
  /// user already owns instead of buying a new result.
  ///
  /// Shares [journeyProvider] with [start], so the existing ProcessingScreen
  /// overlay renders progress identically on both paths. Resolves with the
  /// terminal stage so the caller can drive its own follow-up UI — the purchase
  /// flow uses that to decide whether to mark the checker spent.
  ///
  /// The serial and PIN are read from the encrypted vault by the caller and are
  /// never placed in JourneyState nor in an error message (Hard Rule 1).
  Future<TransactionStage> redeemChecker({
    required String serial,
    required String pin,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    // One key per logical redemption, reused by every retry of the portal call
    // (plan §3.9 / §4.9) — a flaky network must not spend the checker twice.
    final key = IdempotencyKeys.create();
    try {
      final redemption = await _api.redeemChecker(
        idempotencyKey: key,
        serial: serial,
        pin: pin,
        indexNumber: indexNumber,
        examType: examType,
        examYear: examYear,
      );
      state = JourneyState(transactionId: redemption.transactionId);
      // Consumed directly rather than through [_sub]: the loop is bounded by a
      // terminal stage, so there is no long-lived subscription left dangling.
      var last = TransactionStage.waecRetrieval;
      final stream = _api.transactionStages(redemption.transactionId);
      await for (final stage in stream) {
        last = stage;
        state = JourneyState(
          transactionId: redemption.transactionId,
          stages: [...state.stages, stage],
          current: stage,
        );
        if (stage.isTerminal) break;
      }
      return last;
    } catch (e) {
      state = JourneyState(
        current: TransactionStage.failed,
        error: describeCheckerError(e),
      );
      return TransactionStage.failed;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Human-readable failure text that cannot leak implementation detail.
///
/// Only a [CheckerException]'s curated, credential-free message is shown;
/// anything else falls back to a fixed string, so no transport error can echo a
/// serial, a PIN or an internal URL into the UI (Hard Rule 1).
String describeCheckerError(Object error) => error is CheckerException
    ? error.message
    : 'Something went wrong. Please try again.';

final journeyProvider =
    StateNotifierProvider<JourneyNotifier, JourneyState>((ref) {
  return JourneyNotifier(ref.watch(waecApiProvider));
});

/// API provider — overridden with MockWaecApi in tests.
final waecApiProvider = Provider<WaecApi>((ref) => HttpWaecApi());

/// Lifecycle listener: purges in-memory result state when backgrounded
/// (plan §3.8: "auto zero-out on screen disposal and app backgrounding").
final lifecyclePurgerProvider = Provider<void Function(AppLifecycle)>((ref) {
  return (lifecycle) {
    if (lifecycle == AppLifecycle.backgrounded) {
      ref.read(journeyProvider.notifier).purge();
    }
  };
});
