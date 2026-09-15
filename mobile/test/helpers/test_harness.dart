// Shared widget-test harness.
//
// Every screen in the app resolves its identity through BrandScope.of, which
// does a non-null `dependOnInheritedWidgetOfExactType<BrandScope>()`. Pumping
// WaecApp (or any feature screen) *without* a BrandScope ancestor therefore
// throws "Null check operator used on a null value" — the regression that made
// the whole widget-test suite red after the branding refactor.
//
// Always build test trees through wrapWithBrand / pumpApp so the brand is
// present exactly as it is in main().

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:waec_direct/core/brand.dart';

/// Brand fixture mirroring `assets/brand_kit.json`.
///
/// Built through the real [Brand.fromJson] parser (not a hand-written
/// constructor call) so the fixture exercises the same decoding path as
/// production, including hex-colour parsing and the nested support/compliance
/// structures. Deliberately inline rather than read from the asset bundle so
/// tests stay deterministic and free of I/O.
final Brand testBrand = Brand.fromJson(const <String, dynamic>{
  'appName': 'WAEC Direct',
  'packageName': 'waec_direct',
  'displayName': 'WAEC Direct',
  'version': '3.1.4',
  'buildNumber': '20260901',
  'androidApplicationId': 'gh.com.waecplatform.waecdirect',
  'iosBundleId': 'gh.com.waecplatform.waecdirect',
  'tagline': 'Official Result Verification Application',
  'splashDescription': 'Verify and retrieve official WAEC results on demand.',
  'splashStatuses': <String>[
    'Loading brand assets',
    'Preparing secure interface',
    'Connecting to WAEC gateway',
    'Almost ready',
  ],
  'logo': 'assets/brand/logo_mark.png',
  'splash': 'assets/brand/splash_logo.png',
  'colors': <String, dynamic>{
    'ink': '#0A2540',
    'teal': '#00D4B1',
    'surface': '#F8FAFC',
    'border': '#E2E8F0',
    'muted': '#64748B',
    'danger': '#EF4444',
    'amber': '#F59E0B',
  },
  'fonts': <String, dynamic>{'sans': 'DM Sans', 'mono': 'JetBrains Mono'},
  'organization': 'Edward Nyame',
  'publisher': 'Edward Nyame',
  'copyright': '(c) 2026 Edward Nyame - All Rights Reserved',
  'platform': 'Android / iOS',
  'minOs': 'Android 9+ / iOS 15+',
  'apiVersion': 'WAEC-GW/2.8',
  'support': <String, dynamic>{
    'dpoEmail': 'dpo@example.test',
    'dpoLabel': 'Data Protection Officer',
    'headOffice': 'Accra',
    'officeLabel': 'Accra',
    'mapQuery': 'Ghana, Accra',
  },
  'compliance': <Map<String, dynamic>>[
    <String, dynamic>{'label': 'WAEC API Gateway v2', 'status': 'Certified'},
    <String, dynamic>{'label': 'TLS 1.3 Encryption', 'status': 'Active'},
  ],
});

/// Wraps [child] in the same BrandScope -> ProviderScope nesting that `main()`
/// uses, so `BrandScope.of` and Riverpod both resolve.
Widget wrapWithBrand(
  Widget child, {
  List<Override> overrides = const <Override>[],
}) =>
    BrandScope(
      brand: testBrand,
      child: ProviderScope(overrides: overrides, child: child),
    );

/// Pumps [child] inside [wrapWithBrand].
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
}) =>
    tester.pumpWidget(wrapWithBrand(child, overrides: overrides));

/// The branded splash runs a fixed minimum-display animation before handing
/// off to the auth gate. Tests that care about what comes *after* the splash
/// advance past it with this helper rather than hard-coding the duration.
///
/// [duration] must exceed the splash minimum display (2200 ms).
Future<void> settlePastSplash(
  WidgetTester tester, {
  Duration duration = const Duration(milliseconds: 2400),
}) async {
  await tester.pump();
  await tester.pump(duration);
  await tester.pumpAndSettle();
}
