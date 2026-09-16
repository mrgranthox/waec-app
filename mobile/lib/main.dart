import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/brand.dart';
import 'core/design_tokens.dart';
import 'core/domain_types.dart';
import 'features/about/about_screen.dart';
import 'features/auth/auth_providers.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/biometric_gate_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/history/history_screen.dart';
import 'features/legal/privacy_screen.dart';
import 'features/legal/terms_screen.dart';
import 'features/processing/processing_screen.dart';
import 'features/results/result_canvas.dart';
import 'features/splash/branded_splash.dart';
import 'features/verification/verification_providers.dart';
import 'features/verification/verification_screen.dart';

Future<void> main() async {
  // Keep the native splash on screen until the branded Flutter splash has
  // painted, then hand off seamlessly (BrandedSplash calls remove()).
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // Load the brand kit (single source of truth for app identity) before the
  // first frame so every screen — including the splash — renders from it.
  final brand = await Brand.load();

  runApp(
    BrandScope(
      brand: brand,
      child: const ProviderScope(child: WaecApp()),
    ),
  );
}

/// Root widget. In-memory state via Riverpod (plan §3.8); themes from
/// the central design tokens (plan §3.1). App identity comes from the
/// brand kit via [BrandScope].
class WaecApp extends StatelessWidget {
  const WaecApp({super.key});

  @override
  Widget build(BuildContext context) {
    final brand = BrandScope.of(context);
    return MaterialApp(
      title: brand.appName,
      debugShowCheckedModeBanner: false,
      theme: WaecTheme.light(),
      darkTheme: WaecTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _AuthGate(),
    );
  }
}

/// Boot + auth gate: shows the branded [BrandedSplash] while starting up (its
/// minimum display AND the auth boot must both finish), then routes on the
/// [AuthStage] from [authControllerProvider]:
///
/// - [AuthStage.signUp] -> [SignUpScreen] (first run: register before sign-in)
/// - [AuthStage.signIn] -> [AuthScreen]
/// - [AuthStage.biometricUnlock] -> [BiometricGateScreen] (fingerprint prompt)
/// - [AuthStage.biometricEnroll] -> [BiometricEnrollScreen] (consent offer)
/// - [AuthStage.authenticated] -> [HomeShell]
///
/// Stays wrapped in [_LifecycleGuard] so the result-state purge on
/// backgrounding (plan §3.8) remains active for the whole session.
class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  bool _booted = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    final Widget child;
    if (!_booted || auth.stage == AuthStage.booting) {
      child = BrandedSplash(onDone: () => setState(() => _booted = true));
    } else {
      child = switch (auth.stage) {
        // booting is handled by the splash branch above.
        AuthStage.booting => const SizedBox.shrink(),
        AuthStage.signUp => SignUpScreen(
            onGoToSignIn: () =>
                ref.read(authControllerProvider.notifier).goToSignIn(),
          ),
        AuthStage.signIn => AuthScreen(
            onGoToSignUp: () =>
                ref.read(authControllerProvider.notifier).goToSignUp(),
          ),
        AuthStage.biometricUnlock => const BiometricGateScreen(),
        AuthStage.biometricEnroll => const BiometricEnrollScreen(),
        AuthStage.authenticated =>
          // Defensive: authenticated with no session must not crash the gate;
          // fall back to sign-in, which the controller can always serve.
          auth.session != null
              ? HomeShell(session: auth.session!)
              : AuthScreen(
                  onGoToSignUp: () =>
                      ref.read(authControllerProvider.notifier).goToSignUp(),
                ),
      };
    }

    return _LifecycleGuard(child: child);
  }
}

/// Wraps the shell to observe app lifecycle: purges in-memory result
/// state when backgrounded (plan §3.8).
class _LifecycleGuard extends StatefulWidget {
  const _LifecycleGuard({required this.child});
  final Widget child;

  @override
  State<_LifecycleGuard> createState() => _LifecycleGuardState();
}

class _LifecycleGuardState extends State<_LifecycleGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _purge();
    }
  }

  void _purge() {
    // Context is valid here (observer of the shell widget).
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(lifecyclePurgerProvider)(AppLifecycle.backgrounded);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Authenticated shell — the Figma App.tsx app frame: bottom navigation
/// (Check Result / History / About & Legal) with full-screen overlays for
/// the processing modal and the official result.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.session});

  /// The live session (identity + provenance). Kept whole so screens can show
  /// the offline-fallback notice and sign out without extra plumbing.
  final AuthSession session;

  String get indexNumber => session.indexNumber;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;
  bool _showProcessing = false;
  bool _showResult = false;

  void _onJourneyStart() => setState(() => _showProcessing = true);

  void _onProcessingComplete() {
    setState(() {
      _showProcessing = false;
      _showResult = true;
    });
  }

  void _closeResult() {
    setState(() {
      _showResult = false;
      _tab = 0;
    });
  }

  void _openLegal(LegalScreen screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => screen == LegalScreen.privacy
          ? const PrivacyScreen()
          : const TermsScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final journey = ref.watch(journeyProvider);

    // Journey reached a terminal failed state: drop back to the form.
    ref.listen(journeyProvider, (prev, next) {
      if (next.current == TransactionStage.failed && _showProcessing) {
        setState(() => _showProcessing = false);
      }
    });

    if (_showResult && journey.current == TransactionStage.complete) {
      return _ResultHost(
        indexNumber: widget.indexNumber,
        onBack: _closeResult,
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _tab,
            children: [
              VerificationScreen(
                onJourneyStart: _onJourneyStart,
                indexNumber: widget.indexNumber,
              ),
              HistoryScreen(
                snapshots: const [],
                graceActiveIds: const {},
                onRefetch: (_) {},
                onOpen: (_) => setState(() => _showResult = true),
                onDelete: (_) {},
              ),
              AboutScreen(onNavigate: _openLegal),
            ],
          ),
          // Verification modal overlay (Figma VerificationModal).
          if (_showProcessing && !journey.isTerminal)
            Positioned.fill(
              child: ProcessingScreen(onComplete: _onProcessingComplete),
            ),
        ],
      ),
      bottomNavigationBar: _WaecBottomNav(
        index: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
    );
  }
}

/// Result host page shown after a successful journey; supplies the
/// in-memory-only grade payload (plan §3.5).
class _ResultHost extends ConsumerWidget {
  const _ResultHost({required this.indexNumber, required this.onBack});

  final String indexNumber;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = ref.read(verificationFormProvider);
    return ResultCanvas(
      indexNumber: indexNumber,
      examType: form.examType,
      examYear: form.examYear,
      candidateName: 'CANDIDATE',
      grades: const <SubjectGradeView>[],
      aggregate: '',
      graceExpiresAt: DateTime.now().add(const Duration(hours: 24)),
      onBack: onBack,
    );
  }
}

/// Figma BottomNav: three tabs on a white bar, mint active dot.
class _WaecBottomNav extends StatelessWidget {
  const _WaecBottomNav({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _tabs = [
    ('Check Result', Icons.search),
    ('History', Icons.calendar_today_outlined),
    ('About & Legal', Icons.info_outline),
  ];

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 8),
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: InkWell(
                      onTap: () => onChanged(i),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _tabs[i].$2,
                            size: 20,
                            color: index == i
                                ? WaecColors.mint
                                : const Color(0xFFCBD5E1),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _tabs[i].$1,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: index == i
                                  ? WaecColors.navy
                                  : const Color(0xFF94A3B8),
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (index == i)
                            Container(
                              width: 4,
                              height: 4,
                              decoration: const BoxDecoration(
                                color: WaecColors.mint,
                                shape: BoxShape.circle,
                              ),
                            )
                          else
                            const SizedBox(width: 4, height: 4),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

