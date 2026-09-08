import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/design_tokens.dart';
import 'core/domain_types.dart';
import 'features/auth/auth_screen.dart';
import 'features/history/history_screen.dart';
import 'features/processing/processing_screen.dart';
import 'features/results/result_canvas.dart';
import 'features/verification/verification_providers.dart';
import 'features/verification/verification_screen.dart';

void main() {
  runApp(const ProviderScope(child: WaecApp()));
}

/// Root widget. In-memory state via Riverpod (plan §3.8); themes from
/// the central design tokens (plan §3.1).
class WaecApp extends StatelessWidget {
  const WaecApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WAEC Direct',
      debugShowCheckedModeBanner: false,
      theme: WaecTheme.light(),
      darkTheme: WaecTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _LifecycleGuard(child: AuthScreen(
        onAuthenticated: _noopAuth,
      )),
    );
  }

  static void _noopAuth(String _) {}
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
    final container =
        ProviderScope.containerOf(context, listen: false);
    container.read(lifecyclePurgerProvider)(AppLifecycle.backgrounded);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Authenticated shell: verification → processing → result; history tab.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.indexNumber});

  final String indexNumber;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  Timer? _countdownTicker;
  bool _showProcessing = false;
  bool _showResult = false;

  @override
  void dispose() {
    _countdownTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final journey = ref.watch(journeyProvider);

    // Keep a 1s ticker alive while the journey runs so the result canvas
    // countdown stays live once it renders.
    if (!journey.isTerminal && _countdownTicker == null) {
      _countdownTicker =
          Timer.periodic(const Duration(seconds: 1), (_) {});
    } else if (journey.isTerminal && _countdownTicker != null) {
      _countdownTicker?.cancel();
      _countdownTicker = null;
    }

    if (_showProcessing && !journey.isTerminal) {
      return Scaffold(
        appBar: AppBar(title: const Text('WAEC Direct')),
        body: ProcessingScreen(
          onComplete: () => setState(() {
            _showProcessing = false;
            _showResult = true;
          }),
        ),
      );
    }

    if (_showResult && journey.current == TransactionStage.complete) {
      return Scaffold(
        appBar: AppBar(title: const Text('Your Result')),
        body: ListView(
          padding: const EdgeInsets.all(WaecSpacing.md),
          children: [
            ResultCanvas(
              indexNumber: widget.indexNumber,
              examType:
                  ref.read(verificationFormProvider).examType,
              examYear: ref.read(verificationFormProvider).examYear,
              candidateName: 'CANDIDATE',
              grades: const [],
              aggregate: '',
              graceExpiresAt:
                  DateTime.now().add(const Duration(hours: 24)),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: ProcessingScreenSwap(
        showProcessing: _showProcessing,
        onJourneyStart: () => setState(() => _showProcessing = true),
        indexNumber: widget.indexNumber,
        onShowResult: () => setState(() => _showResult = true),
      ),
    );
  }
}

/// Tab shell hosting verification + history.
class ProcessingScreenSwap extends StatelessWidget {
  const ProcessingScreenSwap({
    super.key,
    required this.showProcessing,
    required this.onJourneyStart,
    required this.indexNumber,
    required this.onShowResult,
  });

  final bool showProcessing;
  final VoidCallback onJourneyStart;
  final String indexNumber;
  final VoidCallback onShowResult;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(title: const Text('WAEC Direct'), bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.fact_check_outlined), text: 'Verify'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        )),
        body: TabBarView(
          children: [
            VerificationScreen(onJourneyStart: onJourneyStart),
            HistoryScreen(
              snapshots: const [],
              graceActiveIds: const {},
              onRefetch: (_) {},
              onOpen: (_) {},
              onDelete: (_) {},
            ),
          ],
        ),
      ),
    );
  }
}
