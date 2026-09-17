import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/security/biometric_enrolment.dart';
import 'package:waec_direct/core/security/biometric_service.dart';
import 'package:waec_direct/features/history/history_screen.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';
import 'package:waec_direct/main.dart';

import 'helpers/test_harness.dart';

/// Fingerprint use case 1: the fingerprint acts as a **security barrier** for
/// locally persisted results and checkers. An enrolled account must confirm
/// with the sensor before the vault (History) is revealed, and the barrier
/// re-arms when the app is backgrounded.
///
/// HomeShell is pumped directly (not through the full auth gate) so the test
/// isolates the barrier contract from the enrolment journey. The API provider
/// is stubbed so no journey action can reach the network.
class _NoopApi implements WaecApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in barrier tests');
}

AuthSession _session({bool biometricEnabled = true}) => AuthSession(
  indexNumber: '1002330440',
  userId: 'user-1',
  accessToken: '',
  refreshToken: '',
  accessExpiresAtUnix: 4102444800,
  issuedAtUnix: 1700000000,
  source: AuthSessionSource.local,
  biometricEnabled: biometricEnabled,
);

Future<void> _openHistory(WidgetTester tester) async {
  await tester.tap(find.text('History'));
  await tester.pump(); // rebuild with the barrier mounted
  await tester.pumpAndSettle(); // auto-prompt + (fake) sensor outcome
}

void main() {
  final overrides = <Override>[
    waecApiProvider.overrideWith((ref) => _NoopApi()),
  ];

  testWidgets(
    'enrolled account: History opens behind the fingerprint barrier',
    (tester) async {
      await pumpApp(
        tester,
        MaterialApp(home: HomeShell(session: _session())),
        overrides: overrides,
        biometrics: FakeBiometricAuthenticator(
          capable: FakeBiometricAuthenticator.fingerprintCapable(),
          // The barrier auto-prompts on presentation; a cancel keeps it
          // sealed so the assertions below see the barrier, not the vault.
          outcomes: [BiometricOutcome.userCanceled],
        ),
        enrolments: InMemoryBiometricEnrolmentStore(enrolled: ['1002330440']),
      );

      await _openHistory(tester);

      // Barrier is up; the vault header is not on screen yet.
      expect(find.byKey(const Key('vault-unlock-btn')), findsOneWidget);
      expect(find.text('Protected by fingerprint'), findsOneWidget);
      expect(find.byType(HistoryScreen), findsNothing);
    },
  );

  testWidgets('successful fingerprint unlocks the vault', (tester) async {
    await pumpApp(
      tester,
      MaterialApp(home: HomeShell(session: _session())),
      biometrics: FakeBiometricAuthenticator(
        capable: FakeBiometricAuthenticator.fingerprintCapable(),
        outcomes: [BiometricOutcome.success],
      ),
      enrolments: InMemoryBiometricEnrolmentStore(enrolled: ['1002330440']),
    );

    await _openHistory(tester);

    // The auto-prompt consumed the scripted success; the vault is revealed.
    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.text('Protected by fingerprint'), findsNothing);
  });

  testWidgets('cancelled fingerprint keeps the barrier with a retry', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MaterialApp(home: HomeShell(session: _session())),
      biometrics: FakeBiometricAuthenticator(
        capable: FakeBiometricAuthenticator.fingerprintCapable(),
        outcomes: [BiometricOutcome.userCanceled, BiometricOutcome.success],
      ),
      enrolments: InMemoryBiometricEnrolmentStore(enrolled: ['1002330440']),
    );

    await _openHistory(tester);

    // Cancel: still sealed, calm error copy, retry affordance present.
    expect(find.byKey(const Key('vault-unlock-btn')), findsOneWidget);
    expect(find.byKey(const Key('vault-barrier-error')), findsOneWidget);
    expect(find.byType(HistoryScreen), findsNothing);

    // Retry consumes the scripted success.
    await tester.tap(find.byKey(const Key('vault-unlock-btn')));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);
  });

  testWidgets('unenrolled account opens History with no barrier', (
    tester,
  ) async {
    await pumpApp(
      tester,
      MaterialApp(home: HomeShell(session: _session(biometricEnabled: false))),
      biometrics: FakeBiometricAuthenticator(
        capable: FakeBiometricAuthenticator.fingerprintCapable(),
        nextOutcome: BiometricOutcome.success,
      ),
      // Nobody enrolled: no barrier, and no sensor prompt either.
      enrolments: InMemoryBiometricEnrolmentStore(),
    );

    await _openHistory(tester);

    expect(find.byType(HistoryScreen), findsOneWidget);
    expect(find.text('Protected by fingerprint'), findsNothing);
  });

  testWidgets('backgrounding the app re-seals the vault', (tester) async {
    await pumpApp(
      tester,
      MaterialApp(home: HomeShell(session: _session())),
      biometrics: FakeBiometricAuthenticator(
        capable: FakeBiometricAuthenticator.fingerprintCapable(),
        // First success unlocks the vault; after the lifecycle re-seal the
        // re-mounted barrier auto-prompts again — the cancel keeps it sealed
        // so the assertions below see the re-armed barrier.
        outcomes: [BiometricOutcome.success, BiometricOutcome.userCanceled],
      ),
      enrolments: InMemoryBiometricEnrolmentStore(enrolled: ['1002330440']),
    );

    await _openHistory(tester);
    expect(find.byType(HistoryScreen), findsOneWidget);

    // App goes to background: the vault re-seals (didChangeAppLifecycleState
    // sets _vaultUnlocked = false while paused). Frames are disabled while the
    // app is paused, so the re-armed barrier only becomes visible once the
    // app is brought back to the foreground — exactly what a returning user
    // sees.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Protected by fingerprint'), findsOneWidget);
    expect(find.byType(HistoryScreen), findsNothing);
  });
}
