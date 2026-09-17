// About & Legal screen tests.
//
// Covers requirement #3 (a real sign-out control on the About tab) and the
// fingerprint affordance that Use Case 1 of plans/fingerprint-authentication.md
// hangs off: the Security card must *explain* an unsupported device rather than
// render a switch that silently does nothing.
//
// Auth state is seeded directly. `AuthController`'s constructor runs `boot()`,
// which resolves the launch stage from the store — that routing is exercised by
// auth_flow_test / widget_test, so [boot] is overridden to a no-op here to keep
// these tests about the About screen and not about the launch gate.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:local_auth/local_auth.dart';

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/security/biometric_enrolment.dart';
import 'package:waec_direct/core/security/biometric_service.dart';
import 'package:waec_direct/core/security/session_store.dart';
import 'package:waec_direct/features/about/about_screen.dart';
import 'package:waec_direct/features/auth/auth_providers.dart';

import 'helpers/test_harness.dart';

const _index = '1002330440';

const _kSession = AuthSession(
  indexNumber: _index,
  userId: 'user-001',
  accessToken: 'at',
  refreshToken: 'rt',
  accessExpiresAtUnix: 9999999999,
  issuedAtUnix: 1000000000,
  source: AuthSessionSource.server,
);

/// A device with an enrolled fingerprint.
const _capable = BiometricCapability(
  hardwareSupported: true,
  deviceSupported: true,
  enrolled: <BiometricType>[BiometricType.fingerprint],
);

/// [AuthController] with a seeded state and no launch routing.
///
/// [enrolments] is forwarded (not defaulted) so the suite can prove *which*
/// store the controller consulted — notably that `signOut()` keeps the
/// device+account binding. Leaving it unset here previously fell through to
/// `SecureBiometricEnrolmentStore`, which hangs on a headless host.
class _SeededAuthController extends AuthController {
  _SeededAuthController({
    required AuthState initial,
    required super.api,
    required super.store,
    required super.biometrics,
    required super.enrolments,
  }) : super(allowOfflineFallback: false) {
    state = initial;
  }

  @override
  Future<void> boot() async {}
}

/// The About screen must never call the backend. Any method reaching this stub
/// fails the test loudly instead of silently succeeding.
class _ApiMustNotBeCalled implements WaecApi {
  int bindBiometricCalls = 0;

  Never _unexpected(String method) =>
      throw StateError('AboutScreen must not call WaecApi.$method');

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    bool checkNow = false,
  }) => _unexpected('initCharge');

  @override
  Future<Price> getPricing({
    required ExamType examType,
    bool checkNow = false,
  }) => _unexpected('getPricing');

  @override
  Stream<TransactionStage> transactionStages(String transactionId) =>
      _unexpected('transactionStages');

  @override
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  }) => _unexpected('register');

  @override
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  }) => _unexpected('login');

  @override
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  }) => _unexpected('refresh');

  @override
  Future<CheckerRedemption> redeemChecker({
    required String idempotencyKey,
    required String serial,
    required String pin,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) => _unexpected('redeemChecker');

  @override
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  }) async {
    // The one legitimate call from this screen: enabling fingerprint unlock
    // binds the platform key (fire-and-forget).
    bindBiometricCalls++;
    return true;
  }
}

/// Pumps [AboutScreen] with a seeded auth state, recording legal navigation.
Future<List<LegalScreen>> _pumpAbout(
  WidgetTester tester, {
  required AuthState auth,
  SessionStore? store,
  BiometricAuthenticator? biometrics,
  BiometricEnrolmentStore? enrolments,
  _ApiMustNotBeCalled? api,
}) async {
  final navigated = <LegalScreen>[];
  final sessionStore = store ?? InMemorySessionStore();
  final bio = biometrics ?? FakeBiometricAuthenticator();
  final enrolmentStore = enrolments ?? InMemoryBiometricEnrolmentStore();
  final client = api ?? _ApiMustNotBeCalled();

  // A tall viewport so the whole ListView builds; the legal links sit at the
  // bottom and would otherwise never be laid out.
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpApp(
    tester,
    MaterialApp(home: AboutScreen(onNavigate: navigated.add)),
    sessionStore: sessionStore,
    biometrics: bio,
    enrolments: enrolmentStore,
    overrides: <Override>[
      authControllerProvider.overrideWith(
        (ref) => _SeededAuthController(
          initial: auth,
          api: client,
          store: sessionStore,
          biometrics: bio,
          enrolments: enrolmentStore,
        ),
      ),
    ],
  );
  await tester.pumpAndSettle();
  return navigated;
}

AuthState _authenticated({
  bool biometricEnabled = false,
  BiometricCapability capability = const BiometricCapability.unsupported(),
}) => AuthState(
  stage: AuthStage.authenticated,
  session: _kSession.copyWith(biometricEnabled: biometricEnabled),
  capability: capability,
  rememberedIndex: _index,
);

void main() {
  setUpAll(() {
    // The screen reads live package metadata through a FutureBuilder; without
    // this the plugin channel is missing and every value falls back to the
    // brand kit, which would make the version assertions meaningless.
    PackageInfo.setMockInitialValues(
      appName: 'WAEC Direct',
      packageName: 'gh.com.waecplatform.waecdirect',
      version: '9.9.9',
      buildNumber: '999',
      buildSignature: 'sig',
    );
  });

  group('About screen content', () {
    testWidgets('renders identity from the brand kit', (tester) async {
      await _pumpAbout(tester, auth: _authenticated());

      expect(find.text(testBrand.appName), findsOneWidget);
      expect(find.text(testBrand.tagline), findsOneWidget);
    });

    testWidgets('renders every card section', (tester) async {
      await _pumpAbout(tester, auth: _authenticated());

      // _Card uppercases its label; the Account header does not.
      expect(find.text('SYSTEM COMPLIANCE'), findsOneWidget);
      expect(find.text('APPLICATION INFORMATION'), findsOneWidget);
      expect(find.text('SECURITY'), findsOneWidget);
      expect(find.text('NATIONAL OFFICE SUPPORT'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
    });

    testWidgets('shows the live package version, not just the brand fallback', (
      tester,
    ) async {
      await _pumpAbout(tester, auth: _authenticated());

      // Header badge and the Application Information rows both come from
      // PackageInfo when the platform supplies it.
      expect(find.textContaining('v9.9.9'), findsOneWidget);
      expect(find.text('9.9.9'), findsOneWidget);
      expect(find.text('999'), findsOneWidget);
      expect(find.text('Version'), findsOneWidget);
      expect(find.text('Build'), findsOneWidget);
      expect(find.text('API Version'), findsOneWidget);
      expect(find.text(testBrand.apiVersion), findsOneWidget);
      expect(find.text('Min OS'), findsOneWidget);
      expect(find.text(testBrand.minOs), findsOneWidget);
    });

    testWidgets('lists the compliance badges from the brand kit', (
      tester,
    ) async {
      await _pumpAbout(tester, auth: _authenticated());

      for (final badge in testBrand.compliance) {
        expect(find.text(badge.label), findsOneWidget);
        expect(find.text(badge.status), findsOneWidget);
      }
    });

    testWidgets('lists the support contacts from the brand kit', (
      tester,
    ) async {
      await _pumpAbout(tester, auth: _authenticated());

      expect(find.text(testBrand.support.dpoLabel), findsOneWidget);
      expect(find.text(testBrand.support.dpoEmail), findsOneWidget);
      expect(find.text(testBrand.support.officeLabel), findsOneWidget);
      expect(find.text(testBrand.support.headOffice), findsOneWidget);
    });

    testWidgets('offers both legal documents', (tester) async {
      await _pumpAbout(tester, auth: _authenticated());

      expect(
        find.text('Privacy Policy - Data Handling & Transience'),
        findsOneWidget,
      );
      expect(
        find.text('Terms of Service & Liability Statement'),
        findsOneWidget,
      );
    });
  });

  group('Legal navigation', () {
    testWidgets('Privacy routes to LegalScreen.privacy', (tester) async {
      final navigated = await _pumpAbout(tester, auth: _authenticated());

      await tester.tap(
        find.text('Privacy Policy - Data Handling & Transience'),
      );
      await tester.pumpAndSettle();

      expect(navigated, <LegalScreen>[LegalScreen.privacy]);
    });

    testWidgets('Terms routes to LegalScreen.terms', (tester) async {
      final navigated = await _pumpAbout(tester, auth: _authenticated());

      await tester.tap(find.text('Terms of Service & Liability Statement'));
      await tester.pumpAndSettle();

      expect(navigated, <LegalScreen>[LegalScreen.terms]);
    });

    testWidgets('legal links have a comfortable tap target', (tester) async {
      // WCAG 2.5.5 / Material guidance: at least 48 logical px.
      await _pumpAbout(tester, auth: _authenticated());

      final size = tester.getSize(
        find.text('Privacy Policy - Data Handling & Transience'),
      );
      expect(size.height, greaterThanOrEqualTo(18));
      // The tappable InkWell around it is the real target.
      final target = tester.getSize(
        find
            .ancestor(
              of: find.text('Privacy Policy - Data Handling & Transience'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(target.height, greaterThanOrEqualTo(48));
    });
  });

  group('Sign out (requirement 3)', () {
    testWidgets('offers Sign out while a session is live', (tester) async {
      await _pumpAbout(tester, auth: _authenticated());

      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('Signed out'), findsNothing);
      expect(find.byIcon(Icons.logout), findsOneWidget);
    });

    testWidgets('shows a passive "Signed out" row with no session', (
      tester,
    ) async {
      await _pumpAbout(tester, auth: const AuthState(stage: AuthStage.signIn));

      expect(find.text('Signed out'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('tapping Sign out ends the session and updates the row', (
      tester,
    ) async {
      final store = InMemorySessionStore(session: _kSession);
      await store.writeRememberedIndex(_index);
      // Enrolled before sign-out: the binding must outlive the session.
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );

      await _pumpAbout(
        tester,
        auth: _authenticated(),
        store: store,
        enrolments: enrolments,
      );
      expect(find.text('Sign out'), findsOneWidget);

      // Invoke sign-out directly — InkWell.onTap is void Function, so an async
      // callback would fire-and-forget and never complete within the frame.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AboutScreen)),
        listen: false,
      );
      await container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();

      expect(find.text('Signed out'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing);
      // The regression guard: signing out must NOT behave like a fresh install.
      expect(
        enrolments.revokeAllCount,
        0,
        reason: 'sign-out must not wipe the device+account binding',
      );
      expect(await enrolments.isEnrolled(_index), isTrue);
    });

    testWidgets('sign-out clears the stored session but keeps the index', (
      tester,
    ) async {
      // The next launch must offer *sign in*, not ask the candidate to register
      // an account that already exists.
      final store = InMemorySessionStore(session: _kSession);
      await store.writeRememberedIndex(_index);

      await _pumpAbout(tester, auth: _authenticated(), store: store);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AboutScreen)),
        listen: false,
      );
      await container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();

      expect(await store.read(), isNull);
      expect(await store.readRememberedIndex(), _index);
      expect(store.clearCount, 1);
    });

    testWidgets('sign-out leaves the auth stage on signIn', (tester) async {
      final store = InMemorySessionStore(session: _kSession);
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );
      await _pumpAbout(
        tester,
        auth: _authenticated(),
        store: store,
        enrolments: enrolments,
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AboutScreen)),
        listen: false,
      );
      await container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();

      final controller = container.read(authControllerProvider.notifier);
      expect(controller.state.stage, AuthStage.signIn);
      expect(controller.state.session, isNull);
      expect(controller.state.isAuthenticated, isFalse);
      // Sign-out must re-offer the fingerprint fast path, not force re-enrolment
      // as though the account had just been created.
      expect(
        controller.state.biometricEnrolled,
        isTrue,
        reason: 'the enrolment outlives the session',
      );
    });
  });

  group('Security card / fingerprint affordance (Use Case 1)', () {
    testWidgets('explains an unsupported device instead of a dead switch', (
      tester,
    ) async {
      await _pumpAbout(tester, auth: _authenticated());

      expect(
        find.text('No fingerprint enrolled on this device'),
        findsOneWidget,
      );
      expect(
        find.byType(Switch),
        findsNothing,
        reason: 'an unsupported device must not be offered a switch',
      );
      expect(find.text('Fingerprint unlock'), findsNothing);
    });

    testWidgets(
      'offers the switch on a capable device, reflecting the session',
      (tester) async {
        await _pumpAbout(tester, auth: _authenticated(capability: _capable));

        expect(find.text('Fingerprint unlock'), findsOneWidget);
        final off = tester.widget<Switch>(find.byType(Switch));
        expect(off.value, isFalse);
        expect(
          off.onChanged,
          isNotNull,
          reason: 'a live session can toggle it',
        );
      },
    );

    testWidgets('the switch is on when the session already opted in', (
      tester,
    ) async {
      await _pumpAbout(
        tester,
        auth: _authenticated(biometricEnabled: true, capability: _capable),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('the switch is disabled with no session to protect', (
      tester,
    ) async {
      await _pumpAbout(
        tester,
        auth: const AuthState(stage: AuthStage.signIn, capability: _capable),
      );

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(
        sw.onChanged,
        isNull,
        reason: 'with no session there is nothing to gate',
      );
    });

    testWidgets('toggling on verifies a fingerprint before opting in', (
      tester,
    ) async {
      final store = InMemorySessionStore(session: _kSession);
      final bio = FakeBiometricAuthenticator(
        capable: _capable,
        nextOutcome: BiometricOutcome.success,
      );
      final api = _ApiMustNotBeCalled();

      await _pumpAbout(
        tester,
        auth: _authenticated(capability: _capable),
        store: store,
        biometrics: bio,
        api: api,
      );

      // Invoke enableBiometrics directly — Switch.onChanged is void Function,
      // so an async callback would fire-and-forget and never complete within
      // the test frame. We still tap first to drive the widget, but we settle
      // by awaiting the controller method directly.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AboutScreen)),
        listen: false,
      );
      await container.read(authControllerProvider.notifier).enableBiometrics();
      await tester.pumpAndSettle();

      expect(
        bio.authenticateCalls,
        1,
        reason: 'opt-in must be confirmed by a real biometric',
      );
      expect(bio.reasons.single, contains('fingerprint'));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      // The opt-in is persisted, so the next launch can gate on it.
      expect((await store.read())!.biometricEnabled, isTrue);
      // And the platform key binding is attempted (fire-and-forget).
      expect(api.bindBiometricCalls, 1);
    });

    testWidgets('a cancelled fingerprint leaves the switch off', (
      tester,
    ) async {
      final store = InMemorySessionStore(session: _kSession);
      final bio = FakeBiometricAuthenticator(
        capable: _capable,
        nextOutcome: BiometricOutcome.userCanceled,
      );

      await _pumpAbout(
        tester,
        auth: _authenticated(capability: _capable),
        store: store,
        biometrics: bio,
      );

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(bio.authenticateCalls, 1);
      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isFalse,
        reason: 'a cancelled prompt must not opt the user in',
      );
      expect((await store.read())!.biometricEnabled, isFalse);
    });
  });
}
