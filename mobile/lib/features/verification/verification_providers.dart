import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/domain_types.dart';
import '../../core/network/retry_policy.dart';

/// App lifecycle — plan §3.8: result state zero-out on backgrounding.
enum AppLifecycle { active, backgrounded }

/// Verification form state (index, exam, year, channel).
class VerificationForm {
  const VerificationForm({
    this.indexNumber = '',
    this.examType = ExamType.bece,
    this.examYear = '2025',
    this.channel = PaymentChannel.mtnMomo,
    this.phone = '',
  });

  final String indexNumber;
  final ExamType examType;
  final String examYear;
  final PaymentChannel channel;
  final String phone;

  VerificationForm copyWith({
    String? indexNumber,
    ExamType? examType,
    String? examYear,
    PaymentChannel? channel,
    String? phone,
  }) =>
      VerificationForm(
        indexNumber: indexNumber ?? this.indexNumber,
        examType: examType ?? this.examType,
        examYear: examYear ?? this.examYear,
        channel: channel ?? this.channel,
        phone: phone ?? this.phone,
      );

  /// CTA enabled only when the form is fully valid (plan §3.3).
  bool get isValid =>
      IndexNumberValidator.isValid(indexNumber) &&
      (channel != PaymentChannel.mtnMomo ||
          RegExp(r'^0\d{9}$').hasMatch(phone));
}

class VerificationFormNotifier extends StateNotifier<VerificationForm> {
  VerificationFormNotifier() : super(const VerificationForm());

  void setIndex(String v) => state = state.copyWith(indexNumber: v);
  void setExam(ExamType t) => state = state.copyWith(examType: t);
  void setYear(String y) => state = state.copyWith(examYear: y);
  void setChannel(PaymentChannel c) => state = state.copyWith(channel: c);
  void setPhone(String p) => state = state.copyWith(phone: p);
}

/// Live price fetched from backend config (CTA shows server-driven GHS).
final priceProvider = FutureProvider.family<Price, ExamType>((ref, exam) {
  return ref.watch(waecApiProvider).getPricing(exam);
});

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
  /// stages via SSE-with-polling-fallback.
  Future<void> start({
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    required PaymentChannel channel,
    required String phone,
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
        channel: channel,
        phone: phone,
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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

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
