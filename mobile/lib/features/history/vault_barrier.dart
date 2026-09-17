import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/security/biometric_service.dart';
import '../auth/auth_providers.dart';

/// Fingerprint barrier over locally persisted data (fingerprint use case 1).
///
/// A candidate's saved results and unspent checkers are the most sensitive
/// thing on the device: anyone holding an unlocked phone can otherwise open
/// the History tab and read them. When the account is enrolled, this barrier
/// requires a **fresh biometric confirmation** before the vault content is
/// revealed, and the host re-locks it whenever the app is backgrounded.
///
/// Distinct from the sign-in gate ([BiometricGateScreen]): that one proves
/// identity to the backend; this one authorises access to device-local
/// material. Success here never issues a token.
class VaultBarrier extends ConsumerStatefulWidget {
  const VaultBarrier({super.key, required this.onUnlocked});

  /// Called exactly once per successful biometric confirmation.
  final VoidCallback onUnlocked;

  @override
  ConsumerState<VaultBarrier> createState() => _VaultBarrierState();
}

class _VaultBarrierState extends ConsumerState<VaultBarrier> {
  bool _verifying = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    // Prompt once on presentation: the user tapped "History" intending to see
    // their data — the sensor is the fastest way to grant it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _verify());
  }

  Future<void> _verify() async {
    if (_verifying || !mounted) return;
    setState(() {
      _verifying = true;
      _failure = null;
    });
    final outcome = await ref
        .read(biometricAuthenticatorProvider)
        .authenticate(reason: 'Unlock your saved results and checkers');
    if (!mounted) return;
    setState(() => _verifying = false);
    if (outcome.isSuccess) {
      widget.onUnlocked();
      return;
    }
    // Cancel is a normal outcome, not an error: keep the barrier calm.
    setState(() {
      _failure = switch (outcome) {
        BiometricOutcome.temporaryLockout =>
          'Too many attempts. Wait a '
              'moment, then try again.',
        BiometricOutcome.permanentLockout =>
          'Fingerprint is locked. Unlock '
              'with your device passcode, then try again.',
        _ => 'Fingerprint did not match. Try again.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: WaecColors.canvasLight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 56, color: WaecColors.navy),
              const SizedBox(height: 24),
              const Text(
                'Protected by fingerprint',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: WaecColors.navy,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your saved results and checkers stay sealed until you '
                'confirm it is you.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 32),
              if (_failure != null) ...[
                Text(
                  _failure!,
                  key: const Key('vault-barrier-error'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: WaecColors.danger,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                key: const Key('vault-unlock-btn'),
                style: FilledButton.styleFrom(
                  backgroundColor: WaecColors.navy,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _verifying ? null : _verify,
                icon: _verifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.fingerprint, size: 20),
                label: Text(
                  _verifying ? 'Verifying…' : 'Unlock with fingerprint',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
