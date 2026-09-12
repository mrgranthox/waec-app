import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';
import 'package:waec_direct/main.dart';

/// Offline [WaecApi] so the auth journey never touches the network.
class _FakeWaecApi implements WaecApi {
  @override
  Future<Price> getPricing(ExamType examType) async =>
      const Price(amountPesewas: 450, currency: 'GHS');

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async =>
      const ChargeInit(
        transactionId: 'tx-1',
        status: 'pending',
        amountPesewas: 450,
        checkoutUrl: 'https://paystack.test/checkout',
        displayMessage: 'Approve the prompt on your phone',
      );

  @override
  Stream<TransactionStage> transactionStages(String transactionId) =>
      const Stream<TransactionStage>.empty();
}

Widget _app() => ProviderScope(
      overrides: [waecApiProvider.overrideWithValue(_FakeWaecApi())],
      child: const WaecApp(),
    );

void main() {
  testWidgets('sign in with valid credentials navigates to the app shell',
      (tester) async {
    await tester.pumpWidget(_app());

    // Starts on the auth screen.
    expect(find.text('Sign in to retrieve your results'), findsOneWidget);
    expect(find.text('Verify Results'), findsNothing);

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
    expect(find.text('Verify Results'), findsOneWidget);
  });

  testWidgets('short index number is refused without leaving auth',
      (tester) async {
    await tester.pumpWidget(_app());

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
    expect(find.text('Verify Results'), findsNothing);
  });

  testWidgets('short password is refused without leaving auth',
      (tester) async {
    await tester.pumpWidget(_app());

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '1002330440');
    await tester.enterText(fields.last, 'short'); // < 8 chars

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(find.text('Verify Results'), findsNothing);
  });

  testWidgets('non-digit index is refused', (tester) async {
    await tester.pumpWidget(_app());

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, 'abcdefghij');
    await tester.enterText(fields.last, 'password123');

    final signIn = find.widgetWithText(FilledButton, 'Sign in');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Must be exactly 10 digits'), findsOneWidget);
    expect(find.text('Verify Results'), findsNothing);
  });
}
