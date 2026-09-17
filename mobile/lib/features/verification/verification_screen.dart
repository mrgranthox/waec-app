import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../../core/ui/waec_ui.dart';
import 'verification_providers.dart';

/// Result-verification screen — port of
/// docs/WAEC Result Verification App/src/screens/HomeScreen.tsx.
///
/// Figma drives the layout (navy session bar, locked index, dropdowns,
/// navy CTA). The payment method is chosen on Paystack's hosted checkout,
/// so it is no longer collected in-app. All state comes from the existing
/// [verificationFormProvider] / [journeyProvider] Riverpod graph.
class VerificationScreen extends ConsumerWidget {
  const VerificationScreen({
    super.key,
    required this.onJourneyStart,
    required this.indexNumber,
    this.onBack,
  });

  final void Function() onJourneyStart;
  final String indexNumber;

  /// Returns to the Home hub. Null when this screen is the tab root (no hub to
  /// go back to), in which case no close affordance is rendered.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.watch(verificationFormProvider);
    // The index is locked to the signed-in account: the form state starts
    // empty and is never typed into, so the value this screen acts on is the
    // parameter — the same resolution `_start` applies. Gating the CTA on
    // `form.isValid` alone left it permanently disabled, because nothing in
    // the app ever populates `form.indexNumber` (`setIndex` has no callers):
    // the locked row cannot be typed, so the gate could never open.
    final effectiveIndex =
        form.indexNumber.isEmpty ? indexNumber : form.indexNumber;
    final canSubmit = IndexNumberValidator.isValid(effectiveIndex);
    // This flow always spends the checker it buys — "check result" is the whole
    // point of the screen — so it is priced at the checker-and-retrieve rate
    // (ADR-002), the same rate the charge below will use.
    final price = ref.watch(
      priceProvider(PriceRequest(examType: form.examType, checkNow: true)),
    );
    // The notifier guarantees a value from the first frame (the documented
    // offline price for this shape), so there is no spinner and no "..." state
    // for the CTA to sit in.
    final displayPrice = price.valueOrNull ?? fallbackCheckNowPrice;
    final back = onBack;

    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        // Top inset belongs to the navy header below.
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top bar: active session + auth pill.
            WaecNavyHeader(
              eyebrow: 'Active Session',
              title: indexNumber,
              titleIsMono: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const WaecAuthPill(),
                  if (back != null)
                    IconButton(
                      tooltip: 'Back',
                      onPressed: back,
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: WaecSpacing.xl),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Verify Results',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: WaecColors.navy)),
                        SizedBox(height: 2),
                        Text(
                            'Complete all fields to fetch your official result',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF94A3B8))),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Container(
                      decoration: waecCardDecoration(),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _cardSection(child: _lockedIndex(context)),
                          _cardSection(child: _examTypeDropdown(form, ref)),
                          _cardSection(
                              last: true,
                              child: _examYearDropdown(form, ref)),
                        ],
                      ),
                    ),
                  ),
                  // CTA with the single resolved price (plan §3.3 / ADR-002).
                  // The amount is already known on the first frame, so there is
                  // no loading state to wait through, and it is the same figure
                  // the charge will use.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: _NavyCta(
                      label: 'Pay ${displayPrice.display} & Fetch Result',
                      onPressed:
                          canSubmit ? () => _start(ref, form) : null,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(28, 12, 28, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 13, color: Color(0xFFCBD5E1)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Payment is non-refundable. Result is stored '
                            'locally on this device only. No server retention.',
                            style: TextStyle(
                                fontSize: 11,
                                height: 1.5,
                                color: Color(0xFF94A3B8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _start(WidgetRef ref, VerificationForm form) {
    ref.read(journeyProvider.notifier).start(
          indexNumber:
              form.indexNumber.isEmpty ? indexNumber : form.indexNumber,
          examType: form.examType,
          examYear: form.examYear,
          // This flow spends the checker it buys, so it must be charged at the
          // combined rate the CTA quoted (ADR-002).
          checkNow: true,
        );
    onJourneyStart();
  }

  /// One bordered row of the main card.
  Widget _cardSection({required Widget child, bool last = false}) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(
                  bottom: BorderSide(color: Color(0xFFF1F5F9)),
                ),
        ),
        child: child,
      );

  /// Index number display box — the session index is locked in (Figma).
  Widget _lockedIndex(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          waecFieldLabel('Index Number'),
          const SizedBox(height: 8),
          Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: waecFieldBoxDecoration(),
            child: Row(
              children: [
                const Icon(Icons.description_outlined,
                    size: 15, color: Color(0xFF94A3B8)),
                const SizedBox(width: 12),
                Text(indexNumber, style: WaecTheme.monoNum(14, WaecColors.navy)),
                const Spacer(),
                const WaecChip(label: 'LOCKED'),
              ],
            ),
          ),
        ],
      );

  /// Examination type dropdown (BECE / WASSCE School / WASSCE Private).
  Widget _examTypeDropdown(VerificationForm form, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          waecFieldLabel('Examination Type'),
          const SizedBox(height: 8),
          _DropdownBox<ExamType>(
            value: form.examType,
            items: const {
              ExamType.wassceSchool: 'WASSCE School',
              ExamType.wasscePrivate: 'WASSCE Private',
              ExamType.bece: 'BECE',
            },
            onChanged: ref.read(verificationFormProvider.notifier).setExam,
          ),
        ],
      );

  /// Examination year dropdown (2021..2026).
  Widget _examYearDropdown(VerificationForm form, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          waecFieldLabel('Examination Year'),
          const SizedBox(height: 8),
          _DropdownBox<String>(
            value: form.examYear,
            items: {for (final y in kExamYears) y: y},
            onChanged: ref.read(verificationFormProvider.notifier).setYear,
          ),
        ],
      );

}

/// Rounded outline used by the inset fields inside the Figma card.
OutlineInputBorder waecInputBorder({Color color = const Color(0xFFE2E8F0)}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: 1.5),
    );


/// Figma-styled select box backed by [DropdownButtonFormField].
class _DropdownBox<T> extends StatelessWidget {
  const _DropdownBox(
      {required this.value, required this.items, required this.onChanged});

  final T value;
  final Map<T, String> items;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          enabledBorder: waecInputBorder(),
          focusedBorder:
              waecInputBorder(color: WaecColors.mint.withValues(alpha: 0.6)),
          border: waecInputBorder(),
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
        ),
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w500, color: WaecColors.navy),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}


/// Full-width navy CTA button (Figma's "Pay GHc 25.00 & Fetch Result").
class _NavyCta extends StatelessWidget {
  const _NavyCta({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: WaecColors.navy,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF94A3B8),
          disabledForegroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(WaecRadii.md)),
          textStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.menu_book_rounded,
                size: 18, color: WaecColors.mint),
            const SizedBox(width: 12),
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      );
}


