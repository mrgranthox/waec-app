import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waec_direct/main.dart';

void main() {
  testWidgets('home renders branding', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: WaecApp()));
    expect(find.text('WAEC Direct'), findsOneWidget);
  });
}
