import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'core/brand.dart';
import 'core/design_tokens.dart';
import 'core/domain_types.dart';
import 'core/storage/encrypted_archive.dart';
import 'features/about/about_screen.dart';
import 'features/auth/auth_providers.dart';
import 'features/auth/auth_screen.dart';
import 'features/auth/biometric_gate_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/checker/buy_checker_screen.dart';
import 'features/checker/checker_providers.dart';
import 'features/history/history_screen.dart';
import 'features/landing/landing_screen.dart';
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

  // Open the encrypted archive before the first frame so the History tab and the
  // checker vault are ready to render. A device that cannot open it (corrupt
  // file, unavailable storage) still gets a working app: a null archive reads as
  // "empty vault" rather than crashing at launch.
  final archive = await _openArchive();

  runApp(
    BrandScope(
      brand: brand,
      child: ProviderScope(
        overrides: <Override>[archiveProvider.overrideWithValue(archive)],
        child: const WaecApp(),
      ),
    ),
  );
}

/// Open (or create) the encrypted result archive, or null when the device
/// cannot provide one.
Future<EncryptedResultArchive?> _openArchive() async {
  try {
    final dir = await getDatabasesPath();
    return await EncryptedResultArchive.open('$dir/waec_archive.db');
  } catch (_) {
    // Deliberately swallowed: storage is not a reason to deny a candidate
    // access to the app. The vault providers treat null as "no local storage"
    // and the UI says so, instead of a white screen at boot.
    return null;
  }
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

  /// Which page tab 0 (Home) is presenting: the hub, the checker purchase form,
  /// or the guided verification form.
  _HomePage _page = _HomePage.hub;

  @override
  void initState() {
    super.initState();
    // Read the vault after the first frame: it touches SQLite, which must not
    // run inside build().
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVault());
  }

  /// Pull the encrypted checker vault for this account.
  Future<void> _loadVault() {
    if (!mounted) return Future<void>.value();
    return ref.read(checkerVaultProvider.notifier).load(widget.indexNumber);
  }

  void _goHub() => setState(() => _page = _HomePage.hub);

  void _onJourneyStart() => setState(() => _showProcessing = true);

  void _onProcessingComplete() {
    setState(() {
      _showProcessing = false;
      _showResult = true;
    });
  }

  void _onTabChanged(int i) {
    setState(() {
      _tab = i;
      // Tapping Home always returns to the hub: the two-option landing page is
      // the tab's identity, not a transient sub-page.
      if (i == 0) _page = _HomePage.hub;
    });
    // The vault is only meaningful on the History tab, and reloading it there
    // keeps a checker bought in another tab immediately visible.
    if (i == 1) _loadVault();
  }

  /// Spend a stored checker straight from the History tab.
  Future<void> _redeemChecker(Checker checker) async {
    setState(() => _showProcessing = true);
    await ref
        .read(checkerPurchaseProvider.notifier)
        .redeem(indexNumber: widget.indexNumber, checkerId: checker.id);
    if (!mounted) return;

    final purchase = ref.read(checkerPurchaseProvider);
    setState(() => _showProcessing = false);
    if (purchase.stage == CheckerPurchaseStage.complete) {
      setState(() => _showResult = true);
      return;
    }
    // The checker stays in the vault on any failure, so the user can retry the
    // credential they paid for rather than buying another one.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          purchase.error ?? 'Could not check your result. Please try again.',
        ),
      ),
    );
    await _loadVault();
  }

  /// Irreversible: purge the checker and its credential from this device.
  Future<void> _deleteChecker(Checker checker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this checker?'),
        content: const Text(
          'Its serial and PIN will be erased from this device permanently. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(checkerVaultProvider.notifier)
        .delete(indexNumber: widget.indexNumber, id: checker.id);
  }

  void _closeResult() {
    setState(() {
      _showResult = false;
      _tab = 0;
      _page = _HomePage.hub;
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
              _homeTab(),
              _historyTab(),
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
        onChanged: _onTabChanged,
      ),
    );
  }

  /// Tab 0 — the two-option hub, the checker purchase form, or the guided
  /// verification form.
  Widget _homeTab() => switch (_page) {
    _HomePage.hub => LandingScreen(
      indexNumber: widget.indexNumber,
      onCheckResult: () => setState(() => _page = _HomePage.check),
      onBuyChecker: () => setState(() => _page = _HomePage.buy),
    ),
    _HomePage.check => VerificationScreen(
      indexNumber: widget.indexNumber,
      onJourneyStart: _onJourneyStart,
      onBack: _goHub,
    ),
    _HomePage.buy => BuyCheckerScreen(
      indexNumber: widget.indexNumber,
      onBack: _goHub,
      onResultReady: _onProcessingComplete,
    ),
  };

  /// Tab 1 — saved results plus every checker in the encrypted vault, each with
  /// the "Check Result" action that spends it.
  Widget _historyTab() {
    final vault = ref.watch(checkerVaultProvider);
    return HistoryScreen(
      snapshots: const [],
      graceActiveIds: const {},
      checkers: vault.checkers,
      onRefetch: (_) {},
      onOpen: (_) => setState(() => _showResult = true),
      onDelete: (_) {},
      onRedeemChecker: _redeemChecker,
      onDeleteChecker: _deleteChecker,
    );
  }
}

/// Pages hosted by the Home tab.
enum _HomePage { hub, check, buy }

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
    ('Home', Icons.home_outlined),
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

