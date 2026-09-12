import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/design_tokens.dart';
import '../../core/ui/waec_icons.dart';

/// Legal sub-routes reachable from About.
enum LegalScreen { privacy, terms }

/// About & Legal hub — port of docs/WAEC Result Verification App
/// src/screens/AboutScreen.tsx. Shows compliance badges, app metadata
/// (live from [PackageInfo]), national-office contacts (tap to email/map),
/// and deep links into the Privacy and Terms screens.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.onNavigate});

  final void Function(LegalScreen screen) onNavigate;

  static const _compliance = [
    ('WAEC API Gateway v2', 'Certified'),
    ('Ghana Data Protection Act 2012', 'Compliant'),
    ('TLS 1.3 Encryption', 'Active'),
    ('NCA Type Approval', 'Approved'),
    ('Bank of Ghana PSP License', 'Licensed'),
  ];

  Future<void> _email(String addr) async {
    final uri = Uri.parse('mailto:$addr');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _map() async {
    final q = Uri.encodeComponent('WAEC Ghana, P.O. Box GP 125, Accra');
    final uri = Uri.parse('https://maps.google.com/?q=$q');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final mono = WaecTheme.monoNum(10, const Color(0xFF00D4B1));
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: WaecSpacing.xl),
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: WaecSpacing.lg),
              color: WaecColors.navy,
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: const Color(0x1F00D4B1),
                      border: Border.all(color: const Color(0x3D00D4B1), width: 1.5),
                    ),
                    child: const WaecCrest(size: 34),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  const Text('WAEC Direct',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Official Result Verification Application',
                      style: TextStyle(color: Color(0x73FFFFFF), fontSize: 12)),
                  const SizedBox(height: WaecSpacing.md),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WaecRadii.pill),
                      color: const Color(0x1F00D4B1),
                      border: Border.all(color: const Color(0x3300D4B1)),
                    ),
                    child: FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (_, snap) {
                        final v = snap.data?.version ?? '3.1.4';
                        final b = snap.data?.buildNumber ?? '20260901';
                        return Text('v$v · Build $b',
                            style: mono.copyWith(fontSize: 10));
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(WaecSpacing.md),
              child: Column(
                children: [
                  _Card(
                    label: 'System Compliance',
                    child: Column(
                      children: [
                        for (final t in _compliance)
                          _ComplianceRow(label: t.$1, status: t.$2),
                      ],
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  _Card(
                    label: 'Application Information',
                    child: Column(
                      children: [
                        _InfoRow(label: 'Publisher', value: 'WAEC Ghana'),
                        _InfoRow(label: 'Platform', value: 'Android / iOS'),
                        FutureBuilder<PackageInfo>(
                          future: PackageInfo.fromPlatform(),
                          builder: (_, snap) => Column(
                            children: [
                              _InfoRow(
                                  label: 'Version',
                                  value: snap.data?.version ?? '3.1.4'),
                              _InfoRow(
                                  label: 'Build',
                                  value: snap.data?.buildNumber ?? '20260901.1'),
                            ],
                          ),
                        ),
                        _InfoRow(label: 'API Version', value: 'WAEC-GW/2.8'),
                        _InfoRow(label: 'Min OS', value: 'Android 9+ / iOS 15+'),
                      ],
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  _Card(
                    label: 'National Office Support',
                    child: Column(
                      children: [
                        _ContactItem(
                          icon: Icons.email_outlined,
                          label: 'Data Protection Officer',
                          value: 'dpo@waec.org.gh',
                          onTap: () => _email('dpo@waec.org.gh'),
                        ),
                        _ContactItem(
                          icon: Icons.location_on_outlined,
                          label: 'Head Office',
                          value: 'P.O. Box GP 125, Accra',
                          onTap: () => _map(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  _PolicyLink(
                    label: 'Privacy Policy - Data Handling & Transience',
                    onTap: () => onNavigate(LegalScreen.privacy),
                  ),
                  const SizedBox(height: WaecSpacing.sm),
                  _PolicyLink(
                    label: 'Terms of Service & Liability Statement',
                    onTap: () => onNavigate(LegalScreen.terms),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  const Text(
                      '\u00a9 2026 West Africa Examinations Council \u00b7 All Rights Reserved',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(WaecSpacing.md),
        decoration: BoxDecoration(
          color: WaecColors.cardLight,
          borderRadius: BorderRadius.circular(WaecRadii.lg),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: Color(0xFF64748B))),
            const SizedBox(height: WaecSpacing.sm),
            child,
          ],
        ),
      );
}

class _ComplianceRow extends StatelessWidget {
  const _ComplianceRow({required this.label, required this.status});
  final String label;
  final String status;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF475569))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(WaecRadii.pill),
                color: const Color(0xFFF0FDF9),
                border: Border.all(color: const Color(0xFFCCFBF1)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 5,
                    height: 5,
                    child: DecoratedBox(
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00D4B1)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(status,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF00856F))),
                ],
              ),
            ),
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8))),
            Text(value,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF0A2540))),
          ],
        ),
      );
}

class _ContactItem extends StatelessWidget {
  const _ContactItem(
      {required this.icon, required this.label, required this.value, this.onTap});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: const Color(0xFFF8FAFC),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Icon(icon, size: 16, color: WaecColors.navy),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                    Text(value,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF0A2540))),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WaecRadii.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: WaecColors.cardLight,
            borderRadius: BorderRadius.circular(WaecRadii.lg),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF0A2540)))),
              const Icon(Icons.chevron_right, color: Color(0xFF94A3B8), size: 18),
            ],
          ),
        ),
      );
}
