// Two-part checker pricing (ADR-002).
//
// The reported bugs were: (a) the price card sat on "..." while the buy button
// already showed a figure, so the label appeared to "have to load" while the
// price "fluctuated"; and (b) flipping "Also check my results now" did not
// reprice anything, even though a checker spent in the same pass also buys the
// retrieval.
//
// These tests pin the contract that fixes both: one resolved value drives the
// card and the CTA, that value exists from the first frame, and it follows the
// toggle — with the flag reaching the charge so the quoted figure is the
// charged figure.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/features/checker/buy_checker_screen.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';

import 'helpers/test_harness.dart';

const _index = '1002330440';

void _noop() {}

Widget _screen() => const MaterialApp(
  home: BuyCheckerScreen(indexNumber: _index, onBack: _noop),
);

Future<void> _pumpBuyChecker(WidgetTester tester, {MockWaecApi? api}) => pumpApp(
  tester,
  _screen(),
  overrides: <Override>[
    waecApiProvider.overrideWith((ref) => api ?? MockWaecApi()),
  ],
);

/// The figure rendered in the price card — the one the bug left as "...".
String _cardPrice(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('buy-checker-price'))).data!;

final _toggle = find.byKey(const Key('buy-checker-check-now'));

void main() {
  group('PriceRequest', () {
    test('keys the provider on the purchase shape, not just the exam type', () {
      // If two purchase shapes compared equal, Riverpod would serve the cached
      // amount for the wrong one and the toggle would stop repricing.
      expect(
        const PriceRequest(examType: ExamType.bece, checkNow: true),
        const PriceRequest(examType: ExamType.bece, checkNow: true),
        reason: 'same shape must be the same family key',
      );
      expect(
        const PriceRequest(examType: ExamType.bece, checkNow: true) ==
            const PriceRequest(examType: ExamType.bece, checkNow: false),
        isFalse,
        reason: 'the flag must be part of the key',
      );
      expect(
        const PriceRequest(examType: ExamType.bece, checkNow: true) ==
            const PriceRequest(examType: ExamType.wassceSchool, checkNow: true),
        isFalse,
        reason: 'the exam type must be part of the key',
      );
      expect(
        const PriceRequest(examType: ExamType.bece, checkNow: true).hashCode,
        const PriceRequest(examType: ExamType.bece, checkNow: true).hashCode,
      );
    });
  });

  group('fallbackPriceFor', () {
    test('is flag-aware, so the offline price matches the toggle', () {
      expect(fallbackPriceFor(checkNow: false).display, 'GHS 26.00');
      expect(fallbackPriceFor(checkNow: true).display, 'GHS 36.00');
      expect(fallbackCheckerPrice.amountPesewas, 2600);
      expect(fallbackCheckNowPrice.amountPesewas, 3600);
    });
  });

  group('BuyCheckerScreen pricing', () {
    testWidgets('the card and the CTA show one figure from the first frame', (
      tester,
    ) async {
      await _pumpBuyChecker(tester);

      // Deliberately no pumpAndSettle: this is the first frame, which is exactly
      // when the reported bug showed "..." in the card while the button below it
      // already had a price.
      expect(find.text('...'), findsNothing);
      expect(_cardPrice(tester), 'GHS 36.00');
      expect(find.text('Buy Checker — GHS 36.00'), findsOneWidget);
    });

    testWidgets('turning the toggle off drops to the checker-only rate', (
      tester,
    ) async {
      await _pumpBuyChecker(tester);
      await tester.pumpAndSettle();
      expect(_cardPrice(tester), 'GHS 36.00');

      await tester.tap(_toggle);
      await tester.pumpAndSettle();

      expect(_cardPrice(tester), 'GHS 26.00');
      expect(find.text('Buy Checker — GHS 26.00'), findsOneWidget);
      // The caption naming what the extra money buys goes with the rate.
      expect(
        find.byKey(const Key('buy-checker-price-includes-check')),
        findsNothing,
      );
    });

    testWidgets('turning it back on reprices to the combined rate', (
      tester,
    ) async {
      await _pumpBuyChecker(tester);
      await tester.pumpAndSettle();

      await tester.tap(_toggle);
      await tester.pumpAndSettle();
      expect(_cardPrice(tester), 'GHS 26.00');

      await tester.tap(_toggle);
      await tester.pumpAndSettle();
      expect(_cardPrice(tester), 'GHS 36.00');
      expect(find.text('Buy Checker — GHS 36.00'), findsOneWidget);
      expect(
        find.byKey(const Key('buy-checker-price-includes-check')),
        findsOneWidget,
        reason: 'the combined rate is explained, not just charged',
      );
    });

    testWidgets('the server rate wins over the offline fallback', (
      tester,
    ) async {
      // A fee change is a config row, not a release: whatever the endpoint
      // returns is what is shown, for the shape that was asked for.
      await _pumpBuyChecker(
        tester,
        api: MockWaecApi(
          price: const Price(amountPesewas: 2900, currency: 'GHS'),
          checkNowPrice: const Price(amountPesewas: 4100, currency: 'GHS'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_cardPrice(tester), 'GHS 41.00');

      await tester.tap(_toggle);
      await tester.pumpAndSettle();
      expect(_cardPrice(tester), 'GHS 29.00');
      expect(find.text('Buy Checker — GHS 29.00'), findsOneWidget);
    });
  });
}