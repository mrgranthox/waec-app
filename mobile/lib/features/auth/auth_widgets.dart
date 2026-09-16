import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/ui/waec_icons.dart';

/// Shared chrome for the auth screens (sign-up, sign-in, biometric gate) so
/// every entry point renders the same crest header, error banner and encrypted
/// footer as the original Figma port.

/// Navy crest header band (WAEC crest tile + wordmark + portal subtitle).
class CrestHeader extends StatelessWidget {
  const CrestHeader({super.key});

  @override
  Widget build(BuildContext context) => Container(
        color: WaecColors.navy,
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 40),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: const Color(0x1F00D4B1),
                border: Border.all(color: const Color(0x4D00D4B1), width: 1.5),
              ),
              child: const Center(child: WaecCrest(size: 38)),
            ),
            const SizedBox(height: 16),
            const Text(
              'WEST AFRICA EXAMINATIONS COUNCIL',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                letterSpacing: 2.2,
                color: WaecColors.mint,
              ),
            ),
            const SizedBox(height: 4),
            const Text('WAEC Direct',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                    color: Colors.white)),
            const SizedBox(height: 4),
            const Text('Official Result Verification Portal',
                style: TextStyle(fontSize: 13, color: Color(0x73FFFFFF))),
          ],
        ),
      );
}

/// Inline red error banner for typed auth failures (never a SnackBar race —
/// it stays on screen until the next attempt clears it).
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: WaecColors.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFB91C1C)),
              ),
            ),
          ],
        ),
      );
}

/// Amber notice for degraded states (e.g. offline fallback session).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: WaecColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF92400E)),
              ),
            ),
          ],
        ),
      );
}

/// Labelled obscured password field with a visibility toggle.
class PasswordField extends StatelessWidget {
  const PasswordField({
    super.key,
    required this.label,
    required this.controller,
    required this.visible,
    required this.hint,
    required this.validator,
    required this.onToggleVisibility,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final bool visible;
  final String hint;
  final String? Function(String?) validator;
  final VoidCallback onToggleVisibility;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: WaecColors.navy)),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            obscureText: !visible,
            enabled: enabled,
            validator: validator,
            style: const TextStyle(fontSize: 15, color: WaecColors.navy),
            decoration: _fieldDecoration(
              hint: hint,
              suffix: IconButton(
                icon: Icon(
                  visible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: const Color(0xFF94A3B8),
                ),
                onPressed: onToggleVisibility,
              ),
            ),
          ),
        ],
      );
}

InputDecoration _fieldDecoration({required String hint, Widget? suffix}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
      counterText: '',
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: WaecColors.mint.withValues(alpha: 0.6), width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
    );

/// "256-bit TLS Encrypted · WAEC Certified" footer row.
class EncryptedFooter extends StatelessWidget {
  const EncryptedFooter({super.key});

  @override
  Widget build(BuildContext context) => const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.verified_user_outlined,
              size: 12, color: Color(0xFFCBD5E1)),
          SizedBox(width: 6),
          Text('256-bit TLS Encrypted · WAEC Certified',
              style: TextStyle(fontSize: 11, color: Color(0xFFCBD5E1))),
        ],
      );
}
