import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import 'auth_providers.dart';
import 'auth_screen.dart' show waecAuthCardDecoration;
import 'auth_widgets.dart';

/// Fingerprint unlock gate — shown at launch when the stored session opted in
/// to biometric unlock (plan §3.2: "biometric login via platform keystores").
///
/// Prompts automatically once on first frame (the industry-standard behaviour:
/// the user opened the app expecting to be asked), then offers an explicit
/// retry button and a "Use password instead" escape hatch — the plan's
/// "Biometric fallback to PIN" acceptance criterion.
class BiometricGateScreen extends ConsumerStatefulWidget {
  const BiometricGateScreen({super.key});

  @override
  ConsumerState<BiometricGateScreen> createState() =>
      _BiometricGateScreenState();
}

class _BiometricGateScreenState extends ConsumerState<BiometricGateScreen> {
  bool _prompted = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    final index = auth.session?.indexNumber ?? auth.rememberedIndex ?? '';

    // Auto-prompt once after the first frame — not during build, and never
    // while another attempt is in flight.
    if (!_prompted && !auth.busy) {
      _prompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) controller.unlockWithBiometrics();
      });
    }

    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        // Top inset belongs to the navy crest header below.
        top: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const CrestHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: waecAuthCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Welcome back',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: WaecColors.navy)),
                    const SizedBox(height: 4),
                    Text(
                      index.isEmpty
                          ? 'Unlock with your fingerprint to continue'
                          : 'Unlock $index with your fingerprint',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrains Mono',
                          color: Color(0xFF94A3B8)),
                    ),
                    const SizedBox(height: 28),
                    if (auth.hasError) ...[
                      ErrorBanner(message: auth.error!),
                      const SizedBox(height: 20),
                    ],
                    Center(
                      child: GestureDetector(
                        onTap: auth.busy
                            ? null
                            : () => controller.unlockWithBiometrics(),
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFF0FDF9),
                            border: Border.all(
                                color: WaecColors.mint.withValues(alpha: 0.4),
                                width: 2),
                          ),
                          child: auth.busy
                              ? const Center(
                                  child: SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: WaecColors.mint),
                                  ),
                                )
                              : const Icon(Icons.fingerprint,
                                  size: 52, color: WaecColors.navy),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: WaecColors.navy,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      onPressed: auth.busy
                          ? null
                          : () => controller.unlockWithBiometrics(),
                      child: const Text('Unlock with Fingerprint'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: auth.busy ? null : controller.goToSignIn,
                      child: const Text('Use password instead',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B))),
                    ),
                  ],
                ),
              ),
            ),
            const EncryptedFooter(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// Post-sign-in consent card offering fingerprint unlock (plan §3.2).
///
/// Shown once after a successful password sign-in when the device has enrolled
/// biometrics. "Not now" continues into the app without enabling; the offer
/// remains available later via the About screen's Security toggle.
class BiometricEnrollScreen extends ConsumerWidget {
  const BiometricEnrollScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);

    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        // Top inset belongs to the navy crest header below.
        top: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const CrestHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: waecAuthCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: Icon(Icons.fingerprint,
                          size: 64, color: WaecColors.navy),
                    ),
                    const SizedBox(height: 16),
                    const Text('Enable Fingerprint?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: WaecColors.navy)),
                    const SizedBox(height: 8),
                    const Text(
                      'Unlock WAEC Direct with your fingerprint instead of '
                      'typing your password every time. Your password is never '
                      'stored on this device — only an encrypted session that '
                      'your fingerprint releases.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, height: 1.5, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 24),
                    if (auth.hasError) ...[
                      ErrorBanner(message: auth.error!),
                      const SizedBox(height: 16),
                    ],
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: WaecColors.navy,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      onPressed:
                          auth.busy ? null : () => controller.enableBiometrics(),
                      icon: auth.busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.fingerprint, size: 20),
                      label: const Text('Enable Fingerprint'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed:
                          auth.busy ? null : controller.declineBiometrics,
                      child: const Text('Not now',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B))),
                    ),
                  ],
                ),
              ),
            ),
            const EncryptedFooter(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
