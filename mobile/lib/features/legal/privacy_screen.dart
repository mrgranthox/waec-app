import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';

/// Privacy & transience policy — port of
/// docs/WAEC Result Verification App/src/screens/PolicyPrivacyScreen.tsx.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const _sections = [
    ('1. No Permanent Storage',
        'WAEC Direct does not permanently store your examination results on this device or on our servers beyond the live verification session. Once a result is displayed, it is held only in volatile memory and is purged when you leave the screen or lock your phone.'),
    ('2. Data We Process',
        'To verify a result we transmit your index number, exam year and exam type to the WAEC gateway over TLS 1.3. We never receive or store your WAEC portal password; payment is handled entirely by our PCI-DSS compliant processor.'),
    ('3. Payment Data',
        'Transaction references, amounts and channel are retained for the minimum period required for reconciliation and dispute resolution, after which they are anonymised. Card and mobile-money credentials are tokenised by the processor and never touch WAEC Direct infrastructure.'),
    ('4. Device Security',
        'The app enforces a locked device check before any result is displayed and automatically wipes cached content from RAM on app background. We do not use third-party advertising or analytics SDKs that track you across apps.'),
  ];

  @override
  Widget build(BuildContext context) => const LegalShell(
        title: 'Privacy Policy',
        subtitle: 'Data Handling & Transience',
        sections: _sections,
      );
}

/// Shared scrollable legal document shell used by the Privacy and Terms
/// screens.
class LegalShell extends StatelessWidget {
  const LegalShell(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.sections});
  final String title;
  final String subtitle;
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: WaecColors.navy,
          foregroundColor: Colors.white,
          title: Text(title),
        ),
        body: ListView(
          padding: const EdgeInsets.all(WaecSpacing.md),
          children: [
            Text(subtitle,
                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: WaecSpacing.md),
            for (final (heading, body) in sections) ...[
              Text(heading,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0A2540))),
              const SizedBox(height: 6),
              Text(body,
                  style: const TextStyle(
                      fontSize: 14, height: 1.5, color: Color(0xFF475569))),
              const SizedBox(height: WaecSpacing.md),
            ],
          ],
        ),
      );
}
