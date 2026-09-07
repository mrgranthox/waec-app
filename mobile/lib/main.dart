import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/design_tokens.dart';

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
      home: const HomePlaceholder(),
    );
  }
}

/// Temporary home until feature screens land (Phase 3.2+).
class HomePlaceholder extends StatelessWidget {
  const HomePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WAEC Direct')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.secondary),
            const SizedBox(height: WaecSpacing.md),
            Text(
              'WAEC Automated Verification\n& Direct Retrieval',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: WaecSpacing.sm),
            const Text('Phase 0 foundation — screens coming next'),
          ],
        ),
      ),
    );
  }
}
