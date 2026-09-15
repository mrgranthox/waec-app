import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/main.dart';

import 'helpers/test_harness.dart';

void main() {
  testWidgets('home renders branding', (WidgetTester tester) async {
    // WaecApp resolves its identity through BrandScope, so the test tree must
    // supply one exactly as main() does (see helpers/test_harness.dart).
    await pumpApp(tester, const WaecApp());
    expect(find.text('WAEC Direct'), findsOneWidget);
  });

  testWidgets('branded splash hands off to the auth gate', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, const WaecApp());

    // Splash is on screen first, with the live progress copy from the brand kit.
    expect(find.text('Loading brand assets'), findsOneWidget);

    await settlePastSplash(tester);

    // After the minimum display elapses the auth gate takes over.
    expect(find.text('Sign in to retrieve your results'), findsOneWidget);
  });
}
