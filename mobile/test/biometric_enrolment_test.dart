// Fingerprint enrolment persistence tests.
//
// Regression under test: fingerprint unlock used to be stored as a field on
// [AuthSession]. Because `signOut()` must destroy the session, it destroyed the
// opt-in with it — so after signing out and signing back in with a password the
// candidate was pushed through the enrolment prompt again, exactly as if the
// account had only just been created.
//
// The fix moves enrolment into a device-local [BiometricEnrolmentStore] that is
// a *device + account* binding: it survives sign-out, is revoked only by an
// explicit opt-out or "forget this device", and is what a password sign-in
// consults to restore the fast path.
//
// These tests are deliberately written against the store interface (not the
// secure implementation) so they run with no Keystore, no Keychain and no
// method channel.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/design_tokens.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/security/biometric_enrolment.dart';
import 'package:waec_direct/core/security/biometric_service.dart';
import 'package:waec_direct/core/security/session_store.dart';
import 'package:waec_direct/features/auth/auth_providers.dart';

import 'helpers/test_harness.dart' show FakeBiometricAuthenticator;

const _index = '1002330440';
const _password = 'correct-horse-battery';

/// A device with an enrolled fingerprint (Class 3 strong biometric).
const _capable = BiometricCapability(
  hardwareSupported: true,
  deviceSupported: true,
  enrolled: <BiometricType>[BiometricType.fingerprint],
);

/// A device that cannot do biometrics at all.
const _incapable = BiometricCapability.unsupported();

AuthSession _serverSession({bool biometricEnabled = false}) => AuthSession(
  indexNumber: _index,
  userId: 'user-001',
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  accessExpiresAtUnix: 9999999999,
  issuedAtUnix: 1000000000,
  source: AuthSessionSource.server,
  biometricEnabled: biometricEnabled,
);

/// Scriptable [WaecApi]. Auth succeeds; nothing else is exercised here.
class _FakeAuthApi implements WaecApi {
  _FakeAuthApi({this.session}) : loginError = null;

  /// What [register] and [login] return.
  AuthSession? session;

  /// When set, [login] throws it instead of returning a session.
  Object? loginError;

  int registerCalls = 0;
  int loginCalls = 0;
  int bindBiometricCalls = 0;

  /// Fingerprint sign-in exchanges the stored refresh token for a session; these
  /// record that the exchange happened (and with what).
  int refreshCalls = 0;
  String? refreshIndexSeen;
  String? refreshTokenSeen;

  /// When set, [refresh] throws it — the offline/unreachable case.
  Object? refreshError;

  @override
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  }) async {
    registerCalls++;
    return session ??= _serverSession();
  }

  @override
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  }) async {
    loginCalls++;
    if (loginError != null) throw loginError!;
    // A real server never echoes the client's biometric flag: it issues a plain
    // session. Restoring the fast path is therefore *entirely* the client's
    // responsibility, which is what makes this regression possible.
    return _serverSession();
  }

  @override
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  }) async {
    bindBiometricCalls++;
    return true;
  }

  @override
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  }) async {
    refreshCalls++;
    refreshIndexSeen = indexNumber;
    refreshTokenSeen = refreshToken;
    if (refreshError != null) throw refreshError!;
    return session ??= _serverSession();
  }

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    bool checkNow = false,
  }) async => throw UnimplementedError('not used by these tests');

  @override
  Future<Price> getPricing({
    required ExamType examType,
    bool checkNow = false,
  }) async => throw UnimplementedError('not used by these tests');

  @override
  Stream<TransactionStage> transactionStages(String transactionId) =>
      throw UnimplementedError('not used by these tests');

  @override
  Future<CheckerRedemption> redeemChecker({
    required String idempotencyKey,
    required String serial,
    required String pin,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async => throw UnimplementedError('not used by these tests');
}

/// Builds a controller whose `boot()` has already settled.
Future<AuthController> _controller({
  required InMemorySessionStore store,
  required InMemoryBiometricEnrolmentStore enrolments,
  required FakeBiometricAuthenticator biometrics,
  _FakeAuthApi? api,
}) async {
  final c = AuthController(
    api: api ?? _FakeAuthApi(),
    store: store,
    biometrics: biometrics,
    // Off, so a network failure surfaces as an error rather than silently
    // provisioning a local session — these tests assert on real sign-in.
    allowOfflineFallback: false,
    enrolments: enrolments,
  );
  // The constructor kicks off boot(); drain it before asserting.
  await c.boot();
  return c;
}

void main() {
  setUpAll(() {
    // WaecTheme builds its TextTheme through google_fonts, which otherwise
    // fires an HTTP font fetch. In a test that future completes *after* the
    // test body has finished and flutter_test reports it as a failure. The
    // fonts are not bundled as assets, so runtime fetching is disabled: the
    // resulting exception is caught and printed inside google_fonts and never
    // reaches the test zone.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('InMemoryBiometricEnrolmentStore', () {
    test('starts empty', () async {
      final store = InMemoryBiometricEnrolmentStore();
      expect(await store.enrolled(), isEmpty);
      expect(await store.isEnrolled(_index), isFalse);
    });

    test('accepts a seeded enrolment', () async {
      final store = InMemoryBiometricEnrolmentStore(enrolled: <String>[_index]);
      expect(await store.isEnrolled(_index), isTrue);
      expect(await store.enrolled(), <String>{_index});
    });

    test('enroll then isEnrolled round-trips', () async {
      final store = InMemoryBiometricEnrolmentStore();
      await store.enroll(_index);
      expect(await store.isEnrolled(_index), isTrue);
      expect(store.enrollCount, 1);
    });

    test('enroll is idempotent — one account, one record', () async {
      final store = InMemoryBiometricEnrolmentStore();
      await store.enroll(_index);
      await store.enroll(_index);
      expect(await store.enrolled(), <String>{_index});
    });

    test('revoke removes only the given account', () async {
      final store = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index, '1002330441'],
      );
      await store.revoke(_index);
      expect(await store.isEnrolled(_index), isFalse);
      expect(
        await store.isEnrolled('1002330441'),
        isTrue,
        reason: 'a shared device keeps the other account enrolled',
      );
    });

    test('revokeAll wipes every enrolment', () async {
      final store = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index, '1002330441'],
      );
      await store.revokeAll();
      expect(await store.enrolled(), isEmpty);
      expect(store.revokeAllCount, 1);
    });

    test('a malformed index is never enrolled', () async {
      final store = InMemoryBiometricEnrolmentStore();
      await store.enroll('not-an-index');
      await store.enroll('');
      await store.enroll('12345');
      expect(
        await store.enrolled(),
        isEmpty,
        reason: 'only a valid 10-digit index may be bound',
      );
    });

    test('a malformed seed is filtered out', () async {
      final store = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index, 'garbage', '123'],
      );
      expect(await store.enrolled(), <String>{_index});
    });

    test('isEnrolled is false for a malformed index', () async {
      final store = InMemoryBiometricEnrolmentStore(enrolled: <String>[_index]);
      expect(await store.isEnrolled('garbage'), isFalse);
    });

    test('enrolled() returns an unmodifiable view', () async {
      final store = InMemoryBiometricEnrolmentStore(enrolled: <String>[_index]);
      final view = await store.enrolled();
      expect(
        () => view.add('1002330441'),
        throwsUnsupportedError,
        reason: 'callers must go through enroll()/revoke()',
      );
    });
  });

  group('Enrolment survives sign-out (the reported regression)', () {
    test('signOut keeps the enrolment record', () async {
      final store = InMemorySessionStore(session: _serverSession());
      await store.writeRememberedIndex(_index);
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      await c.signOut();

      expect(
        enrolments.revokeAllCount,
        0,
        reason: 'sign-out must NOT wipe the device+account binding',
      );
      expect(enrolments.revokeCount, 0);
      expect(await enrolments.isEnrolled(_index), isTrue);
    });

    test('signOut destroys the session but reports the enrolment', () async {
      final store = InMemorySessionStore(session: _serverSession());
      await store.writeRememberedIndex(_index);
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      await c.signOut();

      // Security: the tokens are gone.
      expect(await store.read(), isNull);
      expect(c.state.session, isNull);
      expect(c.state.stage, AuthStage.signIn);
      // UX: the device still knows this account opted in.
      expect(c.state.biometricEnrolled, isTrue);
      expect(c.state.canOfferBiometricSignIn, isTrue);
      // The remembered index survives so the form is pre-filled.
      expect(c.state.rememberedIndex, _index);
    });

    test('password sign-in after sign-out restores the fast path '
        'without re-enrolment', () async {
      // Full lifecycle: enrol -> sign out -> sign in with password.
      final store = InMemorySessionStore();
      final enrolments = InMemoryBiometricEnrolmentStore();
      final bio = FakeBiometricAuthenticator(capable: _capable);
      final api = _FakeAuthApi();

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: bio,
        api: api,
      );

      // 1. Register, then opt in to fingerprint.
      await c.signUp(indexNumber: _index, password: _password);
      expect(
        c.state.stage,
        AuthStage.biometricEnroll,
        reason: 'a first-time candidate on a capable device is offered it',
      );
      await c.enableBiometrics();
      expect(c.state.stage, AuthStage.authenticated);
      expect(c.state.session!.biometricEnabled, isTrue);
      expect(await enrolments.isEnrolled(_index), isTrue);
      final promptsAfterEnroll = bio.authenticateCalls;

      // 2. Sign out.
      await c.signOut();
      expect(c.state.stage, AuthStage.signIn);
      expect(await store.read(), isNull);
      expect(
        await enrolments.isEnrolled(_index),
        isTrue,
        reason: 'the binding outlives the session',
      );

      // 3. Sign back in with the password.
      await c.signIn(indexNumber: _index, password: _password);

      // The regression: this used to land on biometricEnroll again.
      expect(
        c.state.stage,
        AuthStage.authenticated,
        reason: 'must NOT re-offer enrolment — it is already recorded',
      );
      expect(
        c.state.session!.biometricEnabled,
        isTrue,
        reason: 'the fast path is restored from the enrolment record',
      );
      expect(c.state.biometricEnrolled, isTrue);
      expect(
        bio.authenticateCalls,
        promptsAfterEnroll,
        reason: 'sign-in must not force another fingerprint prompt',
      );
    });

    test(
      'a cold boot with an enrolment but NO unlock record does not offer the '
      'fingerprint button',
      () async {
        // Simulates the next app launch: no session, but the enrolment and the
        // remembered index persisted — and no unlock record (e.g. an older
        // build, or sign-ins that never carried a refresh token). With no
        // session to restore and no record to exchange, a tap on the button
        // could only ever answer with an error, so the button is not offered.
        final store = InMemorySessionStore(rememberedIndex: _index);
        final enrolments = InMemoryBiometricEnrolmentStore(
          enrolled: <String>[_index],
        );

        final c = await _controller(
          store: store,
          enrolments: enrolments,
          biometrics: FakeBiometricAuthenticator(capable: _capable),
        );

        expect(
          c.state.stage,
          AuthStage.signIn,
          reason: 'no session to unlock, so the password form is correct',
        );
        expect(c.state.biometricEnrolled, isFalse);
        expect(c.state.canOfferBiometricSignIn, isFalse);
        // The form is still pre-filled for the password path.
        expect(c.state.rememberedIndex, _index);
      },
    );

    test(
      'a cold boot with an enrolment AND a stored unlock record offers the '
      'fingerprint button',
      () async {
        // The deliberate sign-out of an online session leaves the record
        // behind; the next launch may show "Sign in with fingerprint".
        final store = InMemorySessionStore(rememberedIndex: _index);
        await store.writeUnlockRecord(
          BiometricUnlockRecord(indexNumber: _index, refreshToken: 'rt'),
        );
        final enrolments = InMemoryBiometricEnrolmentStore(
          enrolled: <String>[_index],
        );

        final c = await _controller(
          store: store,
          enrolments: enrolments,
          biometrics: FakeBiometricAuthenticator(capable: _capable),
        );

        expect(c.state.stage, AuthStage.signIn);
        expect(c.state.biometricEnrolled, isTrue);
        expect(
          c.state.canOfferBiometricSignIn,
          isTrue,
          reason: 'the sign-in screen may show "Sign in with fingerprint"',
        );
        expect(c.state.rememberedIndex, _index);
      },
    );

    test(
      'a cold boot with a live enrolled session goes to the unlock gate',
      () async {
        final store = InMemorySessionStore(
          session: _serverSession(biometricEnabled: true),
        );
        final enrolments = InMemoryBiometricEnrolmentStore(
          enrolled: <String>[_index],
        );

        final c = await _controller(
          store: store,
          enrolments: enrolments,
          biometrics: FakeBiometricAuthenticator(capable: _capable),
        );

        expect(c.state.stage, AuthStage.biometricUnlock);
        expect(c.state.session, isNotNull);
      },
    );

    test('an enrolled session written by an older build still unlocks', () async {
      // Back-compat: the session flag alone (no enrolment record) is honoured,
      // so upgrading the app never locks a candidate out of their fast path.
      final store = InMemorySessionStore(
        session: _serverSession(biometricEnabled: true),
      );
      final enrolments = InMemoryBiometricEnrolmentStore();

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      expect(c.state.stage, AuthStage.biometricUnlock);
    });

    test('an unenrolled session never silently unlocks', () async {
      final store = InMemorySessionStore(session: _serverSession());
      final enrolments = InMemoryBiometricEnrolmentStore();

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      expect(
        c.state.stage,
        AuthStage.signIn,
        reason: 'password stays mandatory until the candidate opts in',
      );
      expect(c.state.biometricEnrolled, isFalse);
    });
  });

  group('Opt-out and forget-device revoke the binding', () {
    test('disableBiometrics revokes the enrolment', () async {
      final store = InMemorySessionStore(session: _serverSession());
      await store.writeRememberedIndex(_index);
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
        api: _FakeAuthApi(session: _serverSession(biometricEnabled: true)),
      );

      await c.disableBiometrics();

      expect(await enrolments.isEnrolled(_index), isFalse);
      expect(enrolments.revokeCount, 1);
      expect(c.state.biometricEnrolled, isFalse);
    });

    test(
      'sign-in after opt-out re-offers enrolment rather than restoring it',
      () async {
        final store = InMemorySessionStore();
        final enrolments = InMemoryBiometricEnrolmentStore();
        final bio = FakeBiometricAuthenticator(capable: _capable);

        final c = await _controller(
          store: store,
          enrolments: enrolments,
          biometrics: bio,
        );

        await c.signUp(indexNumber: _index, password: _password);
        await c.enableBiometrics();
        expect(await enrolments.isEnrolled(_index), isTrue);

        await c.disableBiometrics();
        expect(await enrolments.isEnrolled(_index), isFalse);

        await c.signIn(indexNumber: _index, password: _password);

        expect(
          c.state.stage,
          AuthStage.biometricEnroll,
          reason: 'an explicit opt-out must not be silently undone',
        );
        expect(c.state.session!.biometricEnabled, isFalse);
      },
    );

    test('forgetDevice revokes every enrolment', () async {
      final store = InMemorySessionStore(
        session: _serverSession(biometricEnabled: true),
        rememberedIndex: _index,
      );
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index, '1002330441'],
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      await c.forgetDevice();

      expect(await enrolments.enrolled(), isEmpty);
      expect(enrolments.revokeAllCount, 1);
      expect(await store.readRememberedIndex(), isNull);
      expect(c.state.stage, AuthStage.signUp);
    });
  });

  group('enableBiometrics records the binding', () {
    test('a successful prompt persists the enrolment', () async {
      final store = InMemorySessionStore();
      final enrolments = InMemoryBiometricEnrolmentStore();
      final bio = FakeBiometricAuthenticator(
        capable: _capable,
        nextOutcome: BiometricOutcome.success,
      );
      final api = _FakeAuthApi();

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: bio,
        api: api,
      );

      await c.signUp(indexNumber: _index, password: _password);
      await c.enableBiometrics();

      expect(await enrolments.isEnrolled(_index), isTrue);
      expect(enrolments.enrollCount, 1);
      expect(
        bio.authenticateCalls,
        1,
        reason: 'opt-in must be confirmed by a real biometric',
      );
      expect(bio.reasons.single, contains('fingerprint'));
      // The session flag and the store agree.
      expect((await store.read())!.biometricEnabled, isTrue);
      expect(c.state.biometricEnrolled, isTrue);
    });

    test('a cancelled prompt records nothing', () async {
      final store = InMemorySessionStore();
      final enrolments = InMemoryBiometricEnrolmentStore();
      final bio = FakeBiometricAuthenticator(
        capable: _capable,
        nextOutcome: BiometricOutcome.userCanceled,
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: bio,
      );

      await c.signUp(indexNumber: _index, password: _password);
      await c.enableBiometrics();

      expect(
        await enrolments.enrolled(),
        isEmpty,
        reason: 'a cancelled prompt must not create a binding',
      );
      expect(enrolments.enrollCount, 0);
      expect(c.state.stage, AuthStage.biometricEnroll);
      expect(c.state.session!.biometricEnabled, isFalse);
    });

    test('an incapable device is never offered enrolment', () async {
      final store = InMemorySessionStore();
      final enrolments = InMemoryBiometricEnrolmentStore();

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _incapable),
      );

      await c.signUp(indexNumber: _index, password: _password);

      expect(
        c.state.stage,
        AuthStage.authenticated,
        reason: 'no biometric hardware -> straight into the app',
      );
      expect(await enrolments.enrolled(), isEmpty);
      expect(c.state.biometricEnrolled, isFalse);
      expect(c.state.canOfferBiometricSignIn, isFalse);
    });
  });

  group('Navy system bars (requirement: colour extends into the status bar)', () {
    test('the brand style paints navy behind both bars', () {
      expect(kNavySystemBarStyle.statusBarColor, WaecColors.navy);
      expect(kNavySystemBarStyle.systemNavigationBarColor, WaecColors.navy);
    });

    test('the splash style paints white behind both bars', () {
      // The native launch window (@color/splash = #FFFFFF) is white; the
      // branded Flutter splash must carry the same white bars so the hand-off
      // does not visibly flip white → navy mid-load.
      expect(kSplashSystemBarStyle.statusBarColor, Colors.white);
      expect(kSplashSystemBarStyle.systemNavigationBarColor, Colors.white);
    });

    test('splash icons are dark, because the bar background is light', () {
      expect(kSplashSystemBarStyle.statusBarIconBrightness, Brightness.dark);
      expect(
        kSplashSystemBarStyle.systemNavigationBarIconBrightness,
        Brightness.dark,
      );
      // iOS infers icon colour from the bar brightness: light bar → dark text.
      expect(kSplashSystemBarStyle.statusBarBrightness, Brightness.light);
    });

    test('icons are light, because the bar background is dark', () {
      expect(kNavySystemBarStyle.statusBarIconBrightness, Brightness.light);
      expect(
        kNavySystemBarStyle.systemNavigationBarIconBrightness,
        Brightness.light,
      );
      // iOS has no colour API: it infers icon colour from the bar's brightness.
      expect(kNavySystemBarStyle.statusBarBrightness, Brightness.dark);
    });

    testWidgets('both themes re-assert navy under every AppBar', (
      tester,
    ) async {
      // Without this, Flutter derives the overlay style from the AppBar's own
      // brightness and the navy reverts once the first frame paints.
      //
      // testWidgets (not test) so the binding is live and can drain the
      // google_fonts async work that WaecTheme triggers while building its
      // TextTheme.
      expect(
        WaecTheme.light().appBarTheme.systemOverlayStyle,
        kNavySystemBarStyle,
      );
      expect(
        WaecTheme.dark().appBarTheme.systemOverlayStyle,
        kNavySystemBarStyle,
      );
      await tester.pump();
    });

    testWidgets('the app root annotates every route with the navy style', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          // Mirrors WaecApp.builder, which is what keeps navy applied on
          // AppBar-less routes (splash, auth, biometric gate).
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: kNavySystemBarStyle,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('no app bar here')),
        ),
      );
      await tester.pumpAndSettle();

      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(region.value.statusBarColor, WaecColors.navy);
    });
  });

  group('The fingerprint button only promises what a tap can deliver', () {
    test(
      'sign-out with an empty refresh token leaves NO fingerprint button',
      () async {
        // Debug builds mint offline-fallback sessions with no refresh token
        // when the backend is unreachable. The unlock record write is
        // correctly refused for those; offering the button anyway is what
        // made it say "sign in with your password once to turn on fingerprint
        // unlock" forever.
        final store = InMemorySessionStore(
          session: _serverSession().copyWith(refreshToken: ''),
        );
        await store.writeRememberedIndex(_index);
        final enrolments = InMemoryBiometricEnrolmentStore(
          enrolled: <String>[_index],
        );

        final c = await _controller(
          store: store,
          enrolments: enrolments,
          biometrics: FakeBiometricAuthenticator(capable: _capable),
        );

        await c.signOut();

        // Enrolment itself survives — the password fast path still works.
        expect(await enrolments.isEnrolled(_index), isTrue);
        // But the button must not promise an exchange that cannot happen.
        expect(c.state.canOfferBiometricSignIn, isFalse);
        expect(await store.readUnlockRecord(), isNull);
      },
    );

    test('a real token keeps the button after sign-out', () async {
      final store = InMemorySessionStore(session: _serverSession());
      await store.writeRememberedIndex(_index);
      final enrolments = InMemoryBiometricEnrolmentStore(
        enrolled: <String>[_index],
      );

      final c = await _controller(
        store: store,
        enrolments: enrolments,
        biometrics: FakeBiometricAuthenticator(capable: _capable),
      );

      await c.signOut();

      expect(await store.readUnlockRecord(), isNotNull);
      expect(c.state.canOfferBiometricSignIn, isTrue);
    });
  });

  group('Exam years reach the start of WAEC', () {    test('the floor is 1948, the year WAEC was established', () {
      expect(kExamYearFloor, 1948);
      expect(kExamYears.last, '1948');
    });

    test('the list is contiguous and newest-first', () {
      for (var i = 0; i < kExamYears.length - 1; i++) {
        final a = int.parse(kExamYears[i]);
        final b = int.parse(kExamYears[i + 1]);
        expect(a - b, 1, reason: 'no gaps and strictly descending at $i');
      }
    });

    test('the list spans exactly floor..default with no duplicates', () {
      expect(kExamYears.first, kDefaultExamYear);
      expect(kExamYears.toSet().length, kExamYears.length);
      expect(
        kExamYears.length,
        int.parse(kDefaultExamYear) - kExamYearFloor + 1,
      );
    });

    test('validateExamYear accepts the founding year', () {
      expect(validateExamYear('1948'), isNull);
    });

    test('validateExamYear rejects anything before the founding year', () {
      expect(validateExamYear('1947'), isNotNull);
      expect(validateExamYear('1900'), isNotNull);
    });

    test('validateExamYear still rejects a future year', () {
      final next = (DateTime.now().year + 1).toString();
      expect(validateExamYear(next), isNotNull);
    });
  });
}
