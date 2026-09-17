// Status-bar bleed (reported bug: a white strip above the navy header).
//
// The navy band must reach the top edge of the screen and own the status-bar
// inset, so the pixels *behind* the system bar are brand navy. This matters
// because `statusBarColor` is ignored in edge-to-edge mode (Android 15+, and
// always on iOS): the bar is transparent and simply shows whatever widget is
// painted behind it — which used to be the near-white Scaffold canvas, because a
// top `SafeArea` pushed the navy band below the bar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/ui/waec_ui.dart';
import 'package:waec_direct/features/auth/auth_screen.dart';
import 'package:waec_direct/features/auth/auth_widgets.dart';
import 'package:waec_direct/features/checker/buy_checker_screen.dart';
import 'package:waec_direct/features/landing/landing_screen.dart';
import 'package:waec_direct/features/verification/verification_providers.dart';

import 'helpers/test_harness.dart';

/// A device with a 24dp status bar (a typical Android phone).
const _statusBar = 24.0;

void _noop() {}

void _withStatusBar(WidgetTester tester) {
  // `padding` is in *physical* pixels and the default test view is 3x, so pin
  // the ratio to 1 to talk in logical pixels (what the padding arithmetic uses).
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: _statusBar);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The top padding applied *inside* [header] — where the inset must land.
double _headerTopPadding(WidgetTester tester, Finder header) {
  final container = tester.widget<Container>(
    find.descendant(of: header, matching: find.byType(Container)).first,
  );
  return (container.padding! as EdgeInsets).top;
}

void main() {
  testWidgets('the home navy header reaches the top edge behind the status bar', (
    tester,
  ) async {
    _withStatusBar(tester);
    await pumpApp(
      tester,
      const MaterialApp(
        home: LandingScreen(
          indexNumber: '1002330440',
          onCheckResult: _noop,
          onBuyChecker: _noop,
        ),
      ),
    );

    final header = find.byType(WaecNavyHeader);
    expect(
      tester.getTopLeft(header).dy,
      0,
      reason: 'nothing (least of all a white strip) may sit above the navy band',
    );
    expect(
      _headerTopPadding(tester, header),
      16 + _statusBar,
      reason: 'the band owns the inset instead of a SafeArea above it',
    );
  });

  testWidgets('the sign-in crest header reaches the top edge too', (
    tester,
  ) async {
    _withStatusBar(tester);
    await pumpApp(tester, MaterialApp(home: AuthScreen(onGoToSignUp: _noop)));

    final header = find.byType(CrestHeader);
    expect(tester.getTopLeft(header).dy, 0);
    expect(_headerTopPadding(tester, header), 48 + _statusBar);
  });

  testWidgets('the buy-checker navy header reaches the top edge', (
    tester,
  ) async {
    _withStatusBar(tester);
    await pumpApp(
      tester,
      const MaterialApp(
        home: BuyCheckerScreen(indexNumber: '1002330440', onBack: _noop),
      ),
      // Stub the API: this screen prices itself on build, and the real client
      // would open a socket (and leave a pending timer) in a widget test.
      overrides: <Override>[
        waecApiProvider.overrideWith((ref) => MockWaecApi()),
      ],
    );
    await tester.pumpAndSettle();

    final header = find.byType(WaecNavyHeader);
    expect(tester.getTopLeft(header).dy, 0);
    expect(_headerTopPadding(tester, header), 16 + _statusBar);
  });

  testWidgets('with no status bar the header padding is unchanged', (
    tester,
  ) async {
    // A device/emulator with zero top inset must not gain phantom padding.
    await pumpApp(
      tester,
      const MaterialApp(
        home: LandingScreen(
          indexNumber: '1002330440',
          onCheckResult: _noop,
          onBuyChecker: _noop,
        ),
      ),
    );

    expect(_headerTopPadding(tester, find.byType(WaecNavyHeader)), 16);
  });
}