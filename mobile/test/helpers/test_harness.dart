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
import 'package:local_auth/local_auth.dart' show BiometricType;

import 'package:waec_direct/core/brand.dart';
import 'package:waec_direct/core/security/biometric_service.dart';
import 'package:waec_direct/core/security/session_store.dart';
import 'package:waec_direct/core/storage/encrypted_archive.dart';
import 'package:waec_direct/features/auth/auth_providers.dart';
import 'package:waec_direct/features/checker/checker_providers.dart';

/// Scriptable [BiometricAuthenticator] — no device, no method channel.
///
/// Defaults to "unsupported device" so widget tests that do not care about
/// biometrics get the password path deterministically. Tests that do care set
/// [capable] / [nextOutcome] / [outcomes] explicitly.
class FakeBiometricAuthenticator implements BiometricAuthenticator {
  FakeBiometricAuthenticator({
    this.capable = const BiometricCapability.unsupported(),
    this.nextOutcome = BiometricOutcome.success,
    List<BiometricOutcome>? outcomes,
  }) : outcomes = outcomes ?? <BiometricOutcome>[];

  /// What [capability] reports.
  ///
  /// Named [capable] — not [capability] — because the interface declares
  /// `capability()` as a *method*; a field of the same name is a compile
  /// error (`conflicting_field_and_method`).
  BiometricCapability capable;

  /// Outcome returned when [outcomes] is empty.
  BiometricOutcome nextOutcome;

  /// FIFO scripted outcomes; when non-empty each [authenticate] shifts one.
  final List<BiometricOutcome> outcomes;

  /// Number of [authenticate] calls made.
  int authenticateCalls = 0;

  /// Reasons passed to [authenticate], for assertion.
  final List<String> reasons = <String>[];

  bool stopCalled = false;
  bool stopResult = true;

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    authenticateCalls++;
    reasons.add(reason);
    return outcomes.isNotEmpty ? outcomes.removeAt(0) : nextOutcome;
  }

  @override
  Future<BiometricCapability> capability() async => capable;

  @override
  Future<bool> stop() async {
    stopCalled = true;
    return stopResult;
  }

  /// A device with an enrolled fingerprint (Class 3 strong biometric).
  static BiometricCapability fingerprintCapable() => const BiometricCapability(
        hardwareSupported: true,
        deviceSupported: true,
        enrolled: <BiometricType>[BiometricType.fingerprint],
      );
}

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
    'officeLabel': 'Head office',
    'mapQuery': 'Ghana, Accra',
  },
  'compliance': <Map<String, dynamic>>[
    <String, dynamic>{'label': 'WAEC API Gateway v2', 'status': 'Certified'},
    <String, dynamic>{'label': 'TLS 1.3 Encryption', 'status': 'Active'},
  ],
});

/// Wraps [child] in the same BrandScope -> ProviderScope nesting that `main()`
/// uses, so `BrandScope.of` and Riverpod both resolve.
///
/// Auth-sensitive providers get safe test defaults (in-memory session store,
/// unsupported-device biometrics, offline fallback allowed) so no test ever
/// touches a platform channel. Defaults are listed FIRST and caller
/// [overrides] LAST: Riverpod resolves duplicate overrides last-wins, so an
/// explicit caller override always beats the harness default. Prefer passing
/// instances through the named parameters instead — the harness_order_test
/// locks this contract in.
Widget wrapWithBrand(
  Widget child, {
  List<Override> overrides = const <Override>[],
  SessionStore? sessionStore,
  BiometricAuthenticator? biometrics,
  bool allowOfflineAuthFallback = true,
  EncryptedResultArchive? archive,
}) {
  return BrandScope(
    brand: testBrand,
    child: ProviderScope(
      overrides: <Override>[
        sessionStoreProvider
            .overrideWithValue(sessionStore ?? InMemorySessionStore()),
        biometricAuthenticatorProvider.overrideWithValue(
          biometrics ?? FakeBiometricAuthenticator(),
        ),
        allowOfflineAuthFallbackProvider
            .overrideWithValue(allowOfflineAuthFallback),
        // Explicit null by default: a widget test must never reach a platform
        // channel for SQLite. Pass a real archive (opened on sqflite_common_ffi)
        // in the tests that exercise the checker vault.
        archiveProvider.overrideWithValue(archive),
        ...overrides,
      ],
      child: child,
    ),
  );
}

/// Pumps [child] inside [wrapWithBrand].
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const <Override>[],
  SessionStore? sessionStore,
  BiometricAuthenticator? biometrics,
  bool allowOfflineAuthFallback = true,
  EncryptedResultArchive? archive,
}) => tester.pumpWidget(
  wrapWithBrand(
    child,
    overrides: overrides,
    sessionStore: sessionStore,
    biometrics: biometrics,
    allowOfflineAuthFallback: allowOfflineAuthFallback,
    archive: archive,
  ),
);

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
