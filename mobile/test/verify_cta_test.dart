// The Verify Results CTA was permanently disabled on device: the form's index
// starts empty, nothing in the app ever populates it (the locked row is not
// typable), and the gate read only `form.isValid`. The gate now resolves the
// same effective index `_start` acts on, so a signed-in candidate's locked
// account number enables the button.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/features/verification/verification_providers.dart'
    show waecApiProvider;
import 'package:waec_direct/features/verification/verification_screen.dart';

import 'helpers/test_harness.dart';

const _index = '1002330440';
const _indexBad = '10023304400';

void _noop() {}

Future<void> _pump(
  WidgetTester tester, {
  required String indexNumber,
}) => pumpApp(
  tester,
  MaterialApp(home: VerificationScreen(indexNumber: indexNumber, onJourneyStart: _noop)),
  overrides: <Override>[
    waecApiProvider.overrideWith((ref) => MockWaecApi()),
  ],
);

void main() {
  // The label carries the price the CTA charges ("Pay GHS 36.00 & Fetch
  // Result" — the check-now rate, ADR-002).
  Finder cta(String price) =>
      find.widgetWithText(FilledButton, 'Pay $price & Fetch Result');

  FilledButton button(WidgetTester tester, Finder finder) =>
      tester.widget<FilledButton>(finder);

  testWidgets('a valid locked index enables the CTA', (tester) async {
    await _pump(tester, indexNumber: _index);
    await tester.pumpAndSettle();

    final b = button(tester, cta('GHS 36.00'));
    expect(
      b.onPressed,
      isNotNull,
      reason: 'a signed-in candidate must be able to start the journey',
    );
  });

  testWidgets('an invalid locked index keeps the CTA disabled', (tester) async {
    await _pump(tester, indexNumber: _indexBad);
    await tester.pumpAndSettle();

    final b = button(tester, cta('GHS 36.00'));
    expect(b.onPressed, isNull);
  });
}

