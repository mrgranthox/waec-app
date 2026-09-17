import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/brand.dart';
import '../../core/design_tokens.dart';
import '../../core/ui/waec_icons.dart';
import '../auth/auth_providers.dart';

/// Legal sub-routes reachable from About.
enum LegalScreen { privacy, terms }

/// About & Legal hub — port of docs/WAEC Result Verification App
/// src/screens/AboutScreen.tsx. Shows compliance badges, app metadata
/// (live from [PackageInfo], brand kit as fallback), national-office contacts
/// (tap to email/map), a fingerprint-unlock toggle (plan §3.2), and deep links
/// into the Privacy and Terms screens.
///
/// Every piece of text here comes from [Brand] (assets/brand_kit.json) — the
/// single source of truth for app identity and details.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key, required this.onNavigate});

  final void Function(LegalScreen screen) onNavigate;

  Future<void> _email(String addr) async {
    final uri = Uri.parse('mailto:$addr');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _map(String query) async {
    final q = Uri.encodeComponent(query);
    final uri = Uri.parse('https://maps.google.com/?q=$q');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = BrandScope.of(context);
    final mono = WaecTheme.monoNum(10, brand.teal);
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
                      border: Border.all(
                        color: const Color(0x3D00D4B1),
                        width: 1.5,
                      ),
                    ),
                    child: const WaecCrest(size: 34),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  Text(
                    brand.appName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    brand.tagline,
                    style: const TextStyle(
                      color: Color(0x73FFFFFF),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WaecRadii.pill),
                      color: const Color(0x1F00D4B1),
                      border: Border.all(color: const Color(0x3300D4B1)),
                    ),
                    child: FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (_, snap) {
                        final v = snap.data?.version ?? brand.version;
                        final b = snap.data?.buildNumber ?? brand.buildNumber;
                        return Text(
                          'v$v · Build $b',
                          style: mono.copyWith(fontSize: 10),
                        );
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
                        for (final c in brand.compliance)
                          _ComplianceRow(label: c.label, status: c.status),
                      ],
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  _Card(
                    label: 'Application Information',
                    child: Column(
                      children: [
                        _InfoRow(label: 'Publisher', value: brand.organization),
                        _InfoRow(label: 'Platform', value: brand.platform),
                        FutureBuilder<PackageInfo>(
                          future: PackageInfo.fromPlatform(),
                          builder: (_, snap) => Column(
                            children: [
                              _InfoRow(
                                label: 'Version',
                                value: snap.data?.version ?? brand.version,
                              ),
                              _InfoRow(
                                label: 'Build',
                                value:
                                    snap.data?.buildNumber ?? brand.buildNumber,
                              ),
                            ],
                          ),
                        ),
                        _InfoRow(label: 'API Version', value: brand.apiVersion),
                        _InfoRow(label: 'Min OS', value: brand.minOs),
                      ],
                    ),
                  ),
                  const SizedBox(height: WaecSpacing.md),
                  _Card(label: 'Security', child: _BiometricToggleRow()),
                  const SizedBox(height: WaecSpacing.md),
                  // Account management: sign-out + future account settings.
                  _AccountSection(),
                  const SizedBox(height: WaecSpacing.md),
                  _Card(
                    label: 'National Office Support',
                    child: Column(
                      children: [
                        _ContactItem(
                          icon: Icons.email_outlined,
                          label: brand.support.dpoLabel,
                          value: brand.support.dpoEmail,
                          onTap: () => _email(brand.support.dpoEmail),
                        ),
                        _ContactItem(
                          icon: Icons.location_on_outlined,
                          label: brand.support.officeLabel,
                          value: brand.support.headOffice,
                          onTap: () => _map(brand.support.mapQuery),
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
                  Text(
                    brand.copyright,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 12,
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
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: Color(0xFF64748B),
          ),
        ),
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
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
        ),
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
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF00D4B1),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                status,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF00856F),
                ),
              ),
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
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Color(0xFF0A2540),
          ),
        ),
      ],
    ),
  );
}

class _ContactItem extends StatelessWidget {
  const _ContactItem({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });
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
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF0A2540),
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
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF0A2540),
              ),
            ),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFF94A3B8), size: 18),
        ],
      ),
    ),
  );
}

/// Fingerprint-unlock switch shown in the About screen's Security card
/// (plan §3.2). Reflects and drives [authControllerProvider] directly, so it
/// stays correct whether the candidate is on the fresh sign-in flow or came
/// back later to change their mind.
class _BiometricToggleRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    final session = state.session;
    final capable = state.capability.canUseBiometricLogin;
    final enabled = session?.biometricEnabled ?? false;

    if (!capable) {
      return const Row(
        children: [
          Icon(Icons.fingerprint, size: 20, color: Color(0xFF94A3B8)),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No fingerprint enrolled on this device',
              style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        const Icon(Icons.fingerprint, size: 20, color: WaecColors.navy),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'Fingerprint unlock',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: WaecColors.navy,
            ),
          ),
        ),
        Switch(
          value: enabled,
          activeTrackColor: WaecColors.mint,
          onChanged: session == null
              ? null
              : (v) async {
                  if (v) {
                    await controller.enableBiometrics();
                  } else {
                    await controller.disableBiometrics();
                  }
                },
        ),
      ],
    );
  }
}

/// Account settings: sign-out + future account management. Lives in the About
/// & Legal tab because that is where the fingerprint toggle already is.
class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    return Container(
      padding: const EdgeInsets.all(WaecSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(WaecRadii.lg),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.person_outline,
                size: 18,
                color: WaecColors.navy,
              ),
              const SizedBox(width: WaecSpacing.sm),
              Text(
                'Account',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: WaecColors.navy,
                ),
              ),
            ],
          ),
          const SizedBox(height: WaecSpacing.md),
          _SignOutButton(
            signedIn: auth.isAuthenticated,
            onSignedOut: controller.signOut,
          ),
        ],
      ),
    );
  }
}

/// Sign-out row: ends the session without forgetting the remembered index (next
/// launch drops the user onto the sign-in form, not sign-up).
class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.signedIn, required this.onSignedOut});

  final bool signedIn;
  final Future<void> Function() onSignedOut;

  @override
  Widget build(BuildContext context) {
    if (!signedIn) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.logout, size: 20, color: Color(0xFF94A3B8)),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Signed out',
                style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
              ),
            ),
          ],
        ),
      );
    }

    return InkWell(
      // Await the async sign-out so StateNotifier updates settle within this
      // frame — a bare `onTap: onSignedOut` would fire and forget, and the
      // resulting state change would land after the microtask drain that
      // `pumpAndSettle` provides.
      onTap: () async {
        await onSignedOut();
      },
      borderRadius: BorderRadius.circular(WaecRadii.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: WaecColors.cardLight,
          borderRadius: BorderRadius.circular(WaecRadii.lg),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            const Icon(Icons.logout, size: 20, color: WaecColors.navy),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Sign out',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: WaecColors.navy,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF94A3B8), size: 18),
          ],
        ),
      ),
    );
  }
}
