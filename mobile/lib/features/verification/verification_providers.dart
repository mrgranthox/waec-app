import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
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

/// What the candidate is about to buy, as far as pricing is concerned.
///
/// Pricing is per *purchase*, not per exam type (ADR-002): a checker bought on
/// its own costs less than one spent immediately, which also pays for the
/// retrieval. Making the flag part of the provider key means a screen cannot
/// render one shape's price while buying the other.
@immutable
class PriceRequest {
  const PriceRequest({required this.examType, this.checkNow = false});

  final ExamType examType;

  /// True when the checker is spent in the same pass.
  final bool checkNow;

  @override
  bool operator ==(Object other) =>
      other is PriceRequest &&
      other.examType == examType &&
      other.checkNow == checkNow;

  @override
  int get hashCode => Object.hash(examType, checkNow);

  @override
  String toString() => 'PriceRequest(${examType.name}, checkNow: $checkNow)';
}

/// Resolves the live price for a purchase, retaining the last known figure while
/// a new one is fetched.
///
/// The state is never empty: it starts at the documented offline price for the
/// requested shape and only ever moves on to a server figure. That is what
/// removes the "the price has to load before it appears" behaviour — the price
/// card and the CTA are driven by the same value from the first frame, and
/// flipping "Also check my results now" reprices both immediately (ADR-002).
class PriceNotifier extends StateNotifier<AsyncValue<Price>> {
  PriceNotifier({required this.api, required this.request})
    : super(
        AsyncValue<Price>.data(
          fallbackPriceFor(checkNow: request.checkNow),
        ),
      ) {
    refresh();
  }

  /// The API the amount is resolved from.
  final WaecApi api;

  /// The purchase shape being priced.
  final PriceRequest request;

  /// Fetch the live amount from the backend config endpoint.
  ///
  /// `copyWithPrevious` keeps the current amount on screen while the request is
  /// in flight, so a refresh or a revisit never blanks the display or flashes a
  /// placeholder over a figure the user has already seen.
  Future<void> refresh() async {
    state = const AsyncValue<Price>.loading().copyWithPrevious(state);
    try {
      final price = await api.getPricing(
        examType: request.examType,
        checkNow: request.checkNow,
      );
      if (!mounted) return;
      state = AsyncValue<Price>.data(price);
    } catch (error, stack) {
      if (!mounted) return;
      // A failure keeps the last good amount visible rather than collapsing the
      // CTA: Paystack's checkout remains the authority on the final figure.
      state = AsyncValue<Price>.error(error, stack).copyWithPrevious(state);
    }
  }
}

/// Live price for a purchase shape (dynamic GHS, plan §2.2; two-part checker
/// pricing per ADR-002).
final priceProvider =
    StateNotifierProvider.family<PriceNotifier, AsyncValue<Price>, PriceRequest>(
      (ref, request) => PriceNotifier(
        api: ref.watch(waecApiProvider),
        request: request,
      ),
    );

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
  ///
  /// [checkNow] is passed through to the charge so the backend prices the
  /// purchase the way the screen quoted it (ADR-002).
  Future<void> start({
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    bool checkNow = false,
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
        checkNow: checkNow,
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
