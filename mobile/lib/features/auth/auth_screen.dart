import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';
import '../../core/ui/waec_icons.dart';

/// Auth & onboarding — plan §3.2, Figma port of
/// docs/WAEC Result Verification App/src/screens/AuthScreen.tsx.
///
/// Navy crest header band + white form card. Validation behaviour is
/// unchanged: 10-digit index, 8+ char password, biometric fallback.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onAuthenticated});

  final void Function(String indexNumber) onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _index = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _biometricAvailable = false;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    // Biometric availability probe; login falls back to password/PIN.
    _probeBiometrics();
  }

  @override
  void dispose() {
    _index.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _probeBiometrics() async {
    // local_auth wiring lands with the device integration build; the
    // fallback path (password) is the default until then.
    setState(() => _biometricAvailable = false);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    widget.onAuthenticated(_index.text);
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WaecColors.canvasLight,
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // Navy crest header band.
            Container(
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
                      border: Border.all(
                          color: const Color(0x4D00D4B1), width: 1.5),
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
                      style:
                          TextStyle(fontSize: 13, color: Color(0x73FFFFFF))),
                ],
              ),
            ),
            // Form card.
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
                      validator: (_) => IndexNumberValidator.validate(_index.text),
                      style: const TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 15,
                          letterSpacing: 1.2,
                          color: WaecColors.navy),
                      decoration:
                          waecAuthFieldDecoration(hint: '10-digit index number'),
                    ),
                    const SizedBox(height: 16),
                    const Text('PASSWORD',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                            color: WaecColors.navy)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _password,
                      obscureText: !_passwordVisible,
                      validator: (_) => _password.text.length < 8
                          ? 'Password must be at least 8 characters'
                          : null,
                      style: const TextStyle(
                          fontSize: 15, color: WaecColors.navy),
                      decoration: waecAuthFieldDecoration(
                        hint: 'Password or PIN',
                        suffix: IconButton(
                          icon: Icon(
                            _passwordVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 18,
                            color: const Color(0xFF94A3B8),
                          ),
                          onPressed: () => setState(
                              () => _passwordVisible = !_passwordVisible),
                        ),
                      ),
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
                      onPressed: _submit,
                      child: const Text('Sign in'),
                    ),
                  ],
                  ),
                ),
              ),
            ),
            // Biometrics + encrypted footer.
            if (_biometricAvailable) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.fingerprint, size: 22),
                  label: const Text('Use Fingerprint / Face ID'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    foregroundColor: WaecColors.navy,
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => widget.onAuthenticated(_index.text),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: Text(
                    'Biometric login requires prior password setup',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
              ),
            ],
            const SizedBox(height: 24),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 12, color: Color(0xFFCBD5E1)),
                SizedBox(width: 6),
                Text('256-bit TLS Encrypted · WAEC Certified',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFFCBD5E1))),
              ],
            ),
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

