import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';
import 'package:waec_direct/main.dart';

import 'helpers/test_harness.dart';

/// Boots the whole app and advances past the branded splash so the auth gate
/// is on screen and ready for interaction.
///
/// Uses the shipped [MockWaecApi] rather than a test-local stub: it is already
/// fully configurable (price, stages, auth failures, unreachable facade), so
/// the tests exercise the same mock the rest of the suite uses instead of
/// maintaining a parallel fake that can drift from the real [WaecApi] surface.
///
/// `stages: const []` keeps the journey stream empty so no processing overlay
/// interferes with the auth assertions.
///
/// The gate boots into [SignUpScreen] (requirement #3: a candidate must
/// register with their index number before signing in), so sign-in tests call
/// [_goToSignIn] to cross over through the "Already registered?" link.
Future<void> _bootToAuth(
  WidgetTester tester, {
  MockWaecApi? api,
}) async {
  await pumpApp(
    tester,
    const WaecApp(),
    overrides: [
      waecApiProvider.overrideWithValue(
        api ??
            MockWaecApi(
              stages: const <TransactionStage>[],
              price: const Price(amountPesewas: 450, currency: 'GHS'),
            ),
      ),
    ],
  );
  await settlePastSplash(tester);
}

/// Walks from the first-run sign-up gate to the sign-in form via the
/// "Already registered? Sign in" link, asserting the handoff actually
/// happened (guards against the link regressing to a no-op).
Future<void> _goToSignIn(WidgetTester tester) async {
  final link = find.text('Already registered? Sign in');
  await tester.ensureVisible(link);
  await tester.pumpAndSettle();
  await tester.tap(link, warnIfMissed: false);
  await tester.pumpAndSettle();

  expect(find.text('Sign in to retrieve your results'), findsOneWidget);
}

void main() {
  testWidgets('first run lands on sign-up before sign-in', (tester) async {
    await _bootToAuth(tester);

    // Requirement #3: with no account known on the device, registration is
    // the first screen — sign-in is only reachable through the link below.
    expect(find.text('Create your account'), findsOneWidget);
        expect(find.text('Sign in to retrieve your results'), findsNothing);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('sign-up without consent is blocked before registration',
      (tester) async {
    await _bootToAuth(tester);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3)); // index, password, confirm
    await tester.enterText(fields.at(0), '1002330440');
    await tester.enterText(fields.at(1), 'password123'); // >= 8 chars
    await tester.enterText(fields.at(2), 'password123'); // must match

    final create = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    // Deliberately leave the consent checkbox unticked.
    await tester.tap(create, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(
      find.text('Please accept the Terms & Privacy Policy to continue'),
      findsOneWidget,
    );
    // Still on the sign-up gate — nothing was registered.
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Verify Results'), findsNothing);
  });

  testWidgets('sign-up with valid details registers and enters the app shell',
      (tester) async {
    await _bootToAuth(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '1002330440'); // 10-digit index
    await tester.enterText(fields.at(1), 'password123');
    await tester.enterText(fields.at(2), 'password123');

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    // The whole consent row is a tappable target, so tap the label text
    // (not the 24px checkbox) exactly as a user would.
    await tester.tap(find.text('I accept the Terms of Service and Privacy Policy'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isTrue,
      reason: 'Tapping the consent label must toggle consent',
    );

    final create = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create, warnIfMissed: false);
    await tester.pumpAndSettle();

        // The registered session is live immediately. The harness fake reports an
    // unsupported biometric device, so enrollment is skipped and the gate
    // hands straight to the shell.
    expect(find.text('Create your account'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('sign in with valid credentials navigates to the app shell',
      (tester) async {
    await _bootToAuth(tester);
    await _goToSignIn(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '1002330440'); // 10-digit index
    await tester.enterText(fields.last, 'password123'); // >= 8 chars

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

        // Regression guard: the button previously called a no-op callback,
    // so the auth screen stayed mounted forever.
    expect(find.text('Sign in to retrieve your results'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('short index number is refused without leaving auth',
      (tester) async {
    await _bootToAuth(tester);
    await _goToSignIn(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '123456'); // not 10 digits
    await tester.enterText(fields.last, 'password123');

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

        expect(find.text('Must be exactly 10 digits'), findsOneWidget);
    expect(find.text('Sign in to retrieve your results'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('short password is refused without leaving auth',
      (tester) async {
    await _bootToAuth(tester);
    await _goToSignIn(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '1002330440');
    await tester.enterText(fields.last, 'short'); // < 8 chars

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

        expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('non-digit index is refused', (tester) async {
    await _bootToAuth(tester);
    await _goToSignIn(tester);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, 'abcdefghij');
    await tester.enterText(fields.last, 'password123');

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

        expect(find.text('Must be exactly 10 digits'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });
}
