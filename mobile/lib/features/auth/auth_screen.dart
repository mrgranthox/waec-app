import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/domain_types.dart';

/// Auth & onboarding — plan §3.2.
///
/// 10-digit index validation, password entry, biometric login via
/// platform keystores; biometric falls back to PIN.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onAuthenticated});

  final void Function(String indexNumber) onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _index = TextEditingController();
  final _password = TextEditingController();
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    // Biometric availability probe; login falls back to password/PIN.
    _probeBiometrics();
  }

  Future<void> _probeBiometrics() async {
    // local_auth wiring lands with the device integration build; the
    // fallback path (password) is the default until then.
    setState(() => _biometricAvailable = false);
  }

  void _submit() {
    final indexError = IndexNumberValidator.validate(_index.text);
    if (indexError != null) {
      _snack(indexError);
      return;
    }
    if (_password.text.length < 8) {
      _snack('Password must be at least 8 characters');
      return;
    }
    widget.onAuthenticated(_index.text);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WAEC Direct')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(WaecSpacing.lg),
          children: [
            const SizedBox(height: WaecSpacing.xxl),
            Icon(Icons.verified_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.secondary),
            const SizedBox(height: WaecSpacing.md),
            Text(
              'Sign in to retrieve your results',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: WaecSpacing.xl),
            TextFormField(
              controller: _index,
              keyboardType: TextInputType.number,
              maxLength: 10,
              decoration: const InputDecoration(
                labelText: 'Index number',
                hintText: '10 digits',
                counterText: '',
              ),
            ),
            const SizedBox(height: WaecSpacing.md),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: WaecSpacing.xl),
            FilledButton(onPressed: _submit, child: const Text('Sign in')),
            if (_biometricAvailable) ...[
              const SizedBox(height: WaecSpacing.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.fingerprint),
                label: const Text('Use biometrics'),
                onPressed: () => widget.onAuthenticated(_index.text),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
