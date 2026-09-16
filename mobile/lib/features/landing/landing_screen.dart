import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/ui/waec_ui.dart';

/// Home hub — the two things a candidate can actually want (requirement 2).
///
/// "Check Result" opens the guided retrieval form; "Buy Checker" opens the
/// purchase flow, which can vault a checker for later *and* run the retrieval in
/// the same pass. Splitting the choice up front means a candidate who is not
/// ready to spend money never has to scroll past a price to reach the form.
class LandingScreen extends StatelessWidget {
  const LandingScreen({
    super.key,
    required this.indexNumber,
    required this.onCheckResult,
    required this.onBuyChecker,
  });

  /// The signed-in candidate. Shown so the user can confirm whose results they
  /// are about to open before spending anything.
  final String indexNumber;

  final VoidCallback onCheckResult;
  final VoidCallback onBuyChecker;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: WaecSpacing.xl),
          children: [
            WaecNavyHeader(
              eyebrow: 'WAEC Direct',
              title: 'Your Results',
              subtitle: 'Index $indexNumber',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _OptionCard(
                    icon: Icons.search,
                    title: 'Check Result',
                    subtitle:
                        'Buy a checker and retrieve your result straight away.',
                    ctaLabel: 'Check Result',
                    primary: false,
                    onTap: onCheckResult,
                  ),
                  const SizedBox(height: 14),
                  _OptionCard(
                    icon: Icons.confirmation_number_outlined,
                    title: 'Buy Checker',
                    subtitle:
                        'Keep a checker for later, check now, or share it with '
                        'family.',
                    ctaLabel: 'Buy Checker',
                    primary: true,
                    onTap: onBuyChecker,
                  ),
                  const SizedBox(height: 20),
                  const _AssuranceNote(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the two hub options. [primary] drives the filled navy treatment, so
/// the paid path is visually distinct from the guided form.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ctaLabel,
    required this.primary,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String ctaLabel;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: WaecColors.cardLight,
        borderRadius: BorderRadius.circular(WaecRadii.lg),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(WaecRadii.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(WaecRadii.lg),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: primary
                        ? WaecColors.navy
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(WaecRadii.md),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: primary ? WaecColors.mint : WaecColors.navy,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: WaecColors.navy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: WaecColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: primary
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: WaecColors.navy,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: onTap,
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: Text(ctaLabel),
                        )
                      : OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: WaecColors.navy,
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: onTap,
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: Text(ctaLabel),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reassurance card: results are held in memory, checkers in an encrypted vault
/// on this device (plan §3.5/§3.7, ADR-001).
class _AssuranceNote extends StatelessWidget {
  const _AssuranceNote();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFF0FDF9),
      borderRadius: BorderRadius.circular(WaecRadii.md),
      border: Border.all(color: const Color(0xFFCCFBF1)),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 16, color: Color(0xFF00856F)),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Results are never stored in the cloud. Purchased checkers are '
            'encrypted on this device only, and unlock with your fingerprint.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF0F766E),
            ),
          ),
        ),
      ],
    ),
  );
}