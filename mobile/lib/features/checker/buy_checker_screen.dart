import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../../core/ui/waec_ui.dart';
import '../verification/verification_providers.dart';
import 'checker_providers.dart';

/// Buy a result checker (requirement 2).
///
/// Two decisions on one screen: which exam/year the checker is for, and whether
/// to spend it immediately. "Also check my result now" is ON by default because
/// that is what most candidates want; turning it off is the deliberate act of
/// banking a checker for later. Either way the checker lands in the encrypted
/// vault, so the History tab can always offer it again — that is what makes the
/// purchase recoverable if the retrieval itself fails.
class BuyCheckerScreen extends ConsumerStatefulWidget {
  const BuyCheckerScreen({
    super.key,
    required this.indexNumber,
    required this.onBack,
    this.onResultReady,
  });

  final String indexNumber;
  final VoidCallback onBack;

  /// Called once a purchase-and-redeem cycle finished with a result, so the
  /// shell can show the official result canvas.
  final VoidCallback? onResultReady;

  @override
  ConsumerState<BuyCheckerScreen> createState() => _BuyCheckerScreenState();
}

class _BuyCheckerScreenState extends ConsumerState<BuyCheckerScreen> {
  ExamType _examType = ExamType.bece;
  String _examYear = kDefaultExamYear;
  bool _checkNow = true;

  Future<void> _buy() => ref
      .read(checkerPurchaseProvider.notifier)
      .buy(
        indexNumber: widget.indexNumber,
        examType: _examType,
        examYear: _examYear,
        checkNow: _checkNow,
      );

  Future<void> _checkStored(String checkerId) => ref
      .read(checkerPurchaseProvider.notifier)
      .redeem(indexNumber: widget.indexNumber, checkerId: checkerId);

  @override
  Widget build(BuildContext context) {
    final price = ref.watch(priceProvider(_examType));
    final purchase = ref.watch(checkerPurchaseProvider);

    // A completed redemption means the journey is done: hand control back so the
    // shell can reveal the official result canvas.
    ref.listen(checkerPurchaseProvider, (prev, next) {
      if (next.stage == CheckerPurchaseStage.complete &&
          prev?.stage != CheckerPurchaseStage.complete) {
        widget.onResultReady?.call();
      }
    });

    final displayPrice = price.valueOrNull ?? fallbackPrice;

    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: WaecSpacing.xl),
          children: [
            WaecNavyHeader(
              eyebrow: 'Buy Checker',
              title: 'Result Checker',
              subtitle: 'Index ${widget.indexNumber}',
              trailing: IconButton(
                tooltip: 'Back',
                onPressed: purchase.isBusy ? null : widget.onBack,
                icon: const Icon(Icons.close, color: Colors.white, size: 20),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _priceCard(displayPrice, price.isLoading),
                  const SizedBox(height: 18),
                  _examTypeField(purchase),
                  const SizedBox(height: 14),
                  _yearField(purchase),
                  const SizedBox(height: 18),
                  _checkNowToggle(purchase),
                  const SizedBox(height: 20),
                  _cta(purchase, displayPrice),
                  if (purchase.hasFailed) ...[
                    const SizedBox(height: 14),
                    _ErrorBanner(message: purchase.error ?? 'Something went wrong.'),
                  ],
                  if (purchase.hasVaultedChecker && !purchase.hasFailed) ...[
                    const SizedBox(height: 14),
                    _VaultedCard(
                      spent: purchase.stage == CheckerPurchaseStage.complete,
                      onCheck: () => _checkStored(purchase.checkerId),
                      busy: purchase.stage == CheckerPurchaseStage.redeeming,
                    ),
                  ],
                  const SizedBox(height: 20),
                  const _PurchaseNote(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Live price, presented as the single number that matters on this screen.
  Widget _priceCard(Price price, bool loading) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: WaecColors.cardLight,
      borderRadius: BorderRadius.circular(WaecRadii.lg),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'One result checker',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: WaecColors.navy,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Covers one exam and year. Single use.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
        Text(
          loading ? '...' : price.display,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: WaecColors.navy,
          ),
        ),
      ],
    ),
  );

  Widget _examTypeField(CheckerPurchaseState purchase) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _FieldLabel('Examination'),
      const SizedBox(height: 6),
      DropdownButtonFormField<ExamType>(
        key: const Key('buy-checker-exam-type'),
        initialValue: _examType,
        decoration: _fieldDecoration,
        items: {
          for (final t in ExamType.values) t: t.displayName,
        }.entries
            .map(
              (e) => DropdownMenuItem<ExamType>(
                value: e.key,
                child: Text(e.value, style: const TextStyle(fontSize: 14)),
              ),
            )
            .toList(),
        onChanged: purchase.isBusy
            ? null
            : (v) => setState(() => _examType = v ?? _examType),
      ),
    ],
  );

  Widget _yearField(CheckerPurchaseState purchase) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _FieldLabel('Examination year'),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        key: const Key('buy-checker-exam-year'),
        initialValue: _examYear,
        decoration: _fieldDecoration,
        items: [
          for (final y in kExamYears)
            DropdownMenuItem<String>(
              value: y,
              child: Text(y, style: const TextStyle(fontSize: 14)),
            ),
        ],
        onChanged: purchase.isBusy
            ? null
            : (v) => setState(() => _examYear = v ?? _examYear),
      ),
    ],
  );

  /// The "check my result now" opt-in. On by default: buying a checker and not
  /// using it is the less common intent, and the result is what the candidate
  /// actually came for.
  Widget _checkNowToggle(CheckerPurchaseState purchase) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    decoration: BoxDecoration(
      color: WaecColors.cardLight,
      borderRadius: BorderRadius.circular(WaecRadii.md),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Also check my result now',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: WaecColors.navy,
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Off: the checker is saved for later.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
        Switch(
          key: const Key('buy-checker-check-now'),
          value: _checkNow,
          onChanged: purchase.isBusy
              ? null
              : (v) => setState(() => _checkNow = v),
        ),
      ],
    ),
  );

  Widget _cta(CheckerPurchaseState purchase, Price price) => FilledButton(
    key: const Key('buy-checker-submit'),
    style: FilledButton.styleFrom(
      backgroundColor: WaecColors.navy,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 16),
    ),
    // The CTA is disabled for the whole in-flight window so a double tap cannot
    // open a second charge (the idempotency key protects retries, not taps).
    onPressed: purchase.isBusy ? null : _buy,
    child: Text(
      purchase.isBusy
          ? 'Please wait...'
          : 'Buy Checker — ${price.display}',
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );

  InputDecoration get _fieldDecoration => const InputDecoration(
    isDense: true,
    filled: true,
    fillColor: WaecColors.cardLight,
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(),
  );
}

/// Small uppercase field label, matching the verification form's treatment.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      color: Color(0xFF64748B),
    ),
  );
}

/// Inline failure banner. The message is always a fixed local string produced by
/// the provider — no transport error text reaches the screen.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('buy-checker-error'),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFEF2F2),
      borderRadius: BorderRadius.circular(WaecRadii.md),
      border: Border.all(color: const Color(0xFFFECACA)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 16, color: WaecColors.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFFB91C1C),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The purchased checker, with a "Check Result" action attached to it.
///
/// This is the button requirement 2 asks for: it spends *this* checker, using
/// the serial and PIN held in the vault, without the user re-typing anything.
/// Once spent the action is replaced by a clear "used" state so the same
/// credential can never be offered twice.
class _VaultedCard extends StatelessWidget {
  const _VaultedCard({
    required this.spent,
    required this.busy,
    required this.onCheck,
  });

  final bool spent;
  final bool busy;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('buy-checker-vaulted'),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF0FDF9),
      borderRadius: BorderRadius.circular(WaecRadii.lg),
      border: Border.all(color: const Color(0xFFCCFBF1)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              spent ? Icons.check_circle_outline : Icons.lock_outline,
              size: 16,
              color: const Color(0xFF00856F),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                spent ? 'Checker used' : 'Checker saved on this device',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F766E),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          spent
              ? 'This serial and PIN have been spent. Buy a new checker to '
                    'check again.'
              : 'Serial and PIN are encrypted here. Tap below to use them.',
          style: const TextStyle(
            fontSize: 12,
            height: 1.4,
            color: Color(0xFF0F766E),
          ),
        ),
        if (!spent) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('checker-check-result'),
              style: FilledButton.styleFrom(
                backgroundColor: WaecColors.navy,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: busy ? null : onCheck,
              icon: const Icon(Icons.search, size: 16),
              label: Text(busy ? 'Checking...' : 'Check Result'),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Explains where the credential lives, so the user understands the trade-off
/// they are making (ADR-001).
class _PurchaseNote extends StatelessWidget {
  const _PurchaseNote();

  @override
  Widget build(BuildContext context) => const Text(
    'Your checker is stored encrypted on this device only — never on our '
    'servers. Deleting it here is permanent. Results themselves are never '
    'written to disk.',
    style: TextStyle(fontSize: 11, height: 1.5, color: Color(0xFF94A3B8)),
  );
}