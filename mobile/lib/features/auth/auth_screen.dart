import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import 'auth_providers.dart';
import 'auth_widgets.dart';

/// Auth & onboarding — plan §3.2, Figma port of
/// docs/WAEC Result Verification App/src/screens/AuthScreen.tsx.
///
/// Navy crest header band + white form card. This is the *sign-in* screen;
/// first-run registration lives in SignUpScreen (a candidate must sign up with
/// their index number before signing in). All submission goes through
/// [authControllerProvider] — the screen itself owns no auth logic.
///
/// Validation behaviour is unchanged: 10-digit index, 8+ char password,
/// biometric fallback (the fingerprint affordance appears when a stored
/// session has biometric unlock enabled).
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, required this.onGoToSignUp});

  /// Switches to the sign-up form ("New here? Create an account").
  final VoidCallback onGoToSignUp;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _index = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _passwordVisible = false;
  bool _prefilled = false;

  @override
  void dispose() {
    _index.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Pre-fills the remembered index number once per screen lifetime.
  void _prefillRemembered(AuthState auth) {
    if (_prefilled) return;
    _prefilled = true;
    final remembered = auth.rememberedIndex;
    if (remembered != null && remembered.isNotEmpty) {
      _index.text = remembered;
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(authControllerProvider.notifier).signIn(
          indexNumber: _index.text.trim(),
          password: _password.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    _prefillRemembered(auth);
    final controller = ref.read(authControllerProvider.notifier);
    // Offer the fingerprint shortcut from the device-local enrolment record:
    // after sign-out the session is gone but enrolment survives, so gating on
    // `session?.biometricEnabled` would hide the button exactly when a
    // returning candidate needs it.
    final showFingerprintSignIn = auth.canOfferBiometricSignIn;

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
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Sign in to retrieve your results',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: WaecColors.navy)),
                      const SizedBox(height: 4),
                      const Text('Enter your WAEC credentials to continue',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF94A3B8))),
                      const SizedBox(height: 24),
                      if (auth.hasError) ...[
                        ErrorBanner(message: auth.error!),
                        const SizedBox(height: 16),
                      ],
                      const Text('CANDIDATE INDEX NUMBER',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: WaecColors.navy)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _index,
                        keyboardType: TextInputType.number,
                        maxLength: 10,
                        enabled: !auth.busy,
                        validator: (_) =>
                            IndexNumberValidator.validate(_index.text.trim()),
                        style: const TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 15,
                            letterSpacing: 1.2,
                            color: WaecColors.navy),
                        decoration: waecAuthFieldDecoration(
                            hint: '10-digit index number'),
                      ),
                      const SizedBox(height: 16),
                      PasswordField(
                        label: 'PASSWORD',
                        controller: _password,
                        visible: _passwordVisible,
                        enabled: !auth.busy,
                        hint: 'Password or PIN',
                        validator: validatePassword,
                        onToggleVisibility: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                      const SizedBox(height: 24),
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
                        onPressed: auth.busy ? null : _submit,
                        child: auth.busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Sign in'),
                      ),
                      if (showFingerprintSignIn) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.fingerprint, size: 22),
                          label: const Text('Use Fingerprint / Face ID'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(50),
                            foregroundColor: WaecColors.navy,
                            side: const BorderSide(color: Color(0xFFE2E8F0)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: auth.busy
                              ? null
                              : () => controller.unlockWithBiometrics(),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: auth.busy ? null : widget.onGoToSignUp,
                        child: const Text('New here? Create an account',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: WaecColors.navy)),
                      ),
                    ],
                  ),
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

/// Card + field decorations shared by the Figma auth layout.
BoxDecoration waecAuthCardDecoration() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE2E8F0)),
      boxShadow: const [
        BoxShadow(
            color: Color(0x0D0A2540), blurRadius: 12, offset: Offset(0, 2)),
      ],
    );

InputDecoration waecAuthFieldDecoration(
        {required String hint, Widget? suffix}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
      counterText: '',
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
            color: WaecColors.mint.withValues(alpha: 0.6), width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
      ),
    );
