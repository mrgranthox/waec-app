import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import 'auth_providers.dart';
import 'auth_screen.dart' show waecAuthCardDecoration, waecAuthFieldDecoration;
import 'auth_widgets.dart';

/// Sign-up screen — a candidate must register with their 10-digit index
/// number before they can sign in (plan §3.2, extended per stakeholder
/// request). Mirrors the AuthScreen layout language: navy crest header band,
/// white form card, encrypted footer.
///
/// Validation reuses [IndexNumberValidator] and [validatePassword] so the
/// client and the Auth service enforce the identical rules
/// (microservices/auth/src/svc.rs), and a password is never held in state —
/// only in the TextEditingController until submit, then dropped (Hard Rule 1).
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key, required this.onGoToSignIn});

  /// Switches to the sign-in form ("Already registered?").
  final VoidCallback onGoToSignIn;

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _index = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _passwordVisible = false;
  bool _consented = false;

  @override
  void dispose() {
    _index.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_consented) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please accept the Terms & Privacy Policy to continue'),
        ),
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    ref.read(authControllerProvider.notifier).signUp(
          indexNumber: _index.text.trim(),
          password: _password.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

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
                      const Text('Create your account',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: WaecColors.navy)),
                      const SizedBox(height: 4),
                      const Text(
                          'Register with your WAEC index number to start verifying results',
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
                        hint: 'At least $kMinPasswordLength characters',
                        validator: validatePassword,
                        onToggleVisibility: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                      const SizedBox(height: 16),
                      PasswordField(
                        label: 'CONFIRM PASSWORD',
                        controller: _confirm,
                        visible: _passwordVisible,
                        enabled: !auth.busy,
                        hint: 'Repeat your password',
                        validator: (v) {
                          final base = validatePassword(v);
                          if (base != null) return base;
                          if (v != _password.text) return 'Passwords do not match';
                          return null;
                        },
                        onToggleVisibility: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                      const SizedBox(height: 16),
                      // The whole consent row is tappable, not just the 24px
                      // checkbox: a checkbox-sized hit target fails WCAG
                      // 2.5.5 (Target Size) and is nearly impossible to tap
                      // reliably on small devices.
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: auth.busy
                            ? null
                            : () => setState(() => _consented = !_consented),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: _consented,
                                  onChanged: auth.busy
                                      ? null
                                      : (v) => setState(
                                          () => _consented = v ?? false),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'I accept the Terms of Service and Privacy Policy',
                                  style: TextStyle(
                                      fontSize: 12, color: Color(0xFF64748B)),
                                ),
                              ),
                            ],
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
                        onPressed: auth.busy ? null : _submit,
                        child: auth.busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Create account'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: auth.busy ? null : widget.onGoToSignIn,
                        child: const Text('Already registered? Sign in',
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
