import 'package:flutter/material.dart';

import 'privacy_screen.dart';

/// Terms of service — port of
/// docs/WAEC Result Verification App/src/screens/PolicyTermsScreen.tsx.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const _sections = [
    ('1. Service Description',
        'WAEC Direct is an official result-verification client. It confirms the authenticity of WAEC certificates for employers, institutions and individuals by querying the WAEC gateway in real time.'),
    ('2. Fees & Refunds',
        'Each verification is a paid transaction. If a verification cannot be completed due to a WAEC gateway fault, you are issued a grace token that lets you re-run the same verification at no additional cost. No cash refunds are issued for successfully rendered results.'),
    ('3. Acceptable Use',
        'You agree not to automate, scrape or resell the service, not to attempt to bypass device or network security controls, and to provide accurate candidate details. Abuse results in immediate revocation of access.'),
    ('4. Liability',
        'The app reflects data returned by the WAEC gateway. WAEC Direct is not liable for errors originating in source records. Decisions made on the basis of a verification are the sole responsibility of the relying party.'),
  ];

  @override
  Widget build(BuildContext context) => const LegalShell(
        title: 'Terms of Service',
        subtitle: 'Liability Statement',
        sections: _sections,
      );
}
