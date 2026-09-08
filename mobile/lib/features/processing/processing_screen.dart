import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../verification/verification_providers.dart';

/// Direct processing overlay — plan §3.4.
///
/// Staged progress: Payment Confirmation → Voucher Provisioning →
/// WAEC Direct Retrieval → Complete. Driven by the SSE-with-polling
/// stage stream; each stage reflects a real backend event.
class ProcessingScreen extends ConsumerWidget {
  const ProcessingScreen({super.key, required this.onComplete});

  final void Function() onComplete;

  static const _orderedStages = [
    TransactionStage.paymentConfirmation,
    TransactionStage.voucherProvisioning,
    TransactionStage.waecRetrieval,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(journeyProvider, (prev, next) {
      if (next.current == TransactionStage.complete) {
        onComplete();
      }
    });

    final journey = ref.watch(journeyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Processing'),
          automaticallyImplyLeading: journey.isTerminal),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(WaecSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!journey.isTerminal) ...[
                const SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(strokeWidth: 6),
                ),
                const SizedBox(height: WaecSpacing.xl),
              ],
              for (var i = 0; i < _orderedStages.length; i++)
                _StageRow(
                  stage: _orderedStages[i],
                  state: _stageState(_orderedStages[i], journey),
                ),
              if (journey.current == TransactionStage.failed) ...[
                const SizedBox(height: WaecSpacing.lg),
                const Icon(Icons.error_outline,
                    color: WaecColors.danger, size: 40),
                const SizedBox(height: WaecSpacing.sm),
                Text(
                  journey.error ?? 'Retrieval failed',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: WaecColors.danger),
                ),
                const SizedBox(height: WaecSpacing.md),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  _StageState _stageState(
      TransactionStage stage, JourneyState journey) {
    final idx = _orderedStages.indexOf(stage);
    final curIdx = _orderedStages.indexOf(journey.current);
    if (journey.current == TransactionStage.complete ||
        curIdx > idx) {
      return _StageState.done;
    }
    if (curIdx == idx) return _StageState.active;
    return _StageState.pending;
  }
}

enum _StageState { pending, active, done }

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.state});

  final TransactionStage stage;
  final _StageState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (state) {
      _StageState.done => WaecColors.success,
      _StageState.active => WaecColors.mint,
      _StageState.pending => WaecColors.textSecondaryLight,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WaecSpacing.sm),
      child: Row(
        children: [
          Icon(
            state == _StageState.done
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            color: color,
          ),
          const SizedBox(width: WaecSpacing.md),
          Text(
            stage.displayName,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight:
                  state == _StageState.active ? FontWeight.w700 : null,
              color: state == _StageState.pending
                  ? WaecColors.textSecondaryLight
                  : null,
            ),
          ),
          if (state == _StageState.active) ...[
            const SizedBox(width: WaecSpacing.sm),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}
