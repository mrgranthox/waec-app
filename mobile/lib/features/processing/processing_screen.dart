import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../verification/verification_providers.dart';

/// Verification bottom sheet — port of
/// docs/WAEC Result Verification App/src/components/VerificationModal.tsx.
///
/// Same visual language as the Figma modal (navy crest tile, stepper rows,
/// index reference, "Do not close this screen" footer), but step progression
/// is driven by the real backend stage stream from [journeyProvider]
/// instead of hard-coded timers (plan §3.4).
class ProcessingScreen extends ConsumerWidget {
  const ProcessingScreen({super.key, required this.onComplete});

  final void Function() onComplete;

  static const _orderedStages = [
    (TransactionStage.paymentConfirmation, 'Payment Verified'),
    (
      TransactionStage.voucherProvisioning,
      'Querying WAEC Direct Central Server',
    ),
    (TransactionStage.waecRetrieval, 'Encrypted Payload Delivered'),
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
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: journey.isTerminal,
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: const Color(0xB80A2540),
              child: const SizedBox.expand(),
            ),
          ),
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                    color: Color(0x2E0A2540),
                    blurRadius: 40,
                    offset: Offset(0, -8)),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const _ModalTitleRow(),
                const SizedBox(height: 24),
                for (var i = 0; i < _orderedStages.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _StepRow(
                      label: _orderedStages[i].$2,
                      state: _stageState(_orderedStages[i].$1, journey),
                    ),
                  ),
                if (journey.current == TransactionStage.failed)
                  _ErrorRow(message: journey.error ?? 'Retrieval failed'),
                const SizedBox(height: 20),
                _IndexRefRow(
                  indexNumber:
                      ref.watch(verificationFormProvider).indexNumber,
                ),
                const SizedBox(height: 16),
                const Text('Do not close this screen',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xFFCBD5E1))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _StepState _stageState(TransactionStage stage, JourneyState journey) {
    final idx = _orderedStages.indexWhere((s) => s.$1 == stage);
    final curIdx = _orderedStages.indexWhere((s) => s.$1 == journey.current);
    if (journey.current == TransactionStage.complete ||
        (curIdx >= 0 && curIdx > idx)) {
      return _StepState.done;
    }
    if (curIdx == idx && journey.current != TransactionStage.failed) {
      return _StepState.active;
    }
    return _StepState.pending;
  }
}


/// Navy crest tile + title text at the top of the modal.
class _ModalTitleRow extends StatelessWidget {
  const _ModalTitleRow();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: WaecColors.navy,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(child: _SheetCrest()),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Verifying Result',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: WaecColors.navy)),
                SizedBox(height: 2),
                Text('Secure connection to WAEC servers',
                    style:
                        TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              ],
            ),
          ),
        ],
      );
}

/// Failed-stage message row.
class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            const Icon(Icons.error_outline,
                color: WaecColors.danger, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 12, color: WaecColors.danger)),
            ),
          ],
        ),
      );
}

/// Candidate index reference strip at the foot of the modal.
class _IndexRefRow extends StatelessWidget {
  const _IndexRefRow({required this.indexNumber});
  final String indexNumber;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Candidate Index',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
            Text(indexNumber.isEmpty ? '-' : indexNumber,
                style: WaecTheme.monoNum(14, WaecColors.navy)),
          ],
        ),
      );
}


/// One stepper row of the verification modal.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final done = state == _StepState.done;
    final active = state == _StepState.active;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFF0FDF9) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: done
                ? const Color(0xFFCCFBF1)
                : const Color(0xFFE2E8F0),
            width: done || active ? 1 : 0),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? WaecColors.mint : const Color(0xFFF1F5F9),
              border: done
                  ? null
                  : Border.all(
                      color: active
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFFF1F5F9),
                      width: 2),
            ),
            child: done
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : active
                    ? const Padding(
                        padding: EdgeInsets.all(6),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: WaecColors.navy),
                      )
                    : Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFCBD5E1),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: done
                    ? const Color(0xFF00856F)
                    : active
                        ? WaecColors.navy
                        : const Color(0xFF94A3B8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small crest glyph inside the modal's navy tile.
class _SheetCrest extends StatelessWidget {
  const _SheetCrest();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(painter: _SheetCrestPainter()),
      );
}

class _SheetCrestPainter extends CustomPainter {
  const _SheetCrestPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 20;
    final stroke = Paint()
      ..color = WaecColors.mint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shield = Path()
      ..moveTo(10 * s, 2.5 * s)
      ..lineTo(3 * s, 5.5 * s)
      ..lineTo(3 * s, 10 * s)
      ..cubicTo(3 * s, 14 * s, 6.2 * s, 17.6 * s, 10 * s, 18.5 * s)
      ..cubicTo(13.8 * s, 17.6 * s, 17 * s, 14 * s, 17 * s, 10 * s)
      ..lineTo(17 * s, 5.5 * s)
      ..close();
    canvas.drawPath(shield, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(7 * s, 10 * s)
        ..lineTo(9 * s, 12 * s)
        ..lineTo(13 * s, 8 * s),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _StepState { pending, active, done }
