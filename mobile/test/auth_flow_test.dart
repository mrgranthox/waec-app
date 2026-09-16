import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;

import 'package:waec_direct/core/api_client.dart';
import 'package:waec_direct/core/domain_types.dart';
import 'package:waec_direct/core/security/biometric_service.dart';
import 'package:waec_direct/core/security/session_store.dart';
import 'package:waec_direct/features/auth/auth_providers.dart';

/// Canonical valid session used across these tests. Every required field of
/// [AuthSession] is supplied, so a constructor change surfaces here first.
const _kSession = AuthSession(
  indexNumber: '0000000000',
  userId: 'user-001',
  accessToken: 'access-token-here',
  refreshToken: 'refresh-token-here',
  accessExpiresAtUnix: 9999999999,
  issuedAtUnix: 1000000000,
  source: AuthSessionSource.server,
);

void main() {
  group('AuthStage routing', () {
    test('only authenticated is terminal', () {
      expect(AuthStage.authenticated.isTerminal, isTrue);
      for (final stage in AuthStage.values) {
        if (stage != AuthStage.authenticated) {
          expect(stage.isTerminal, isFalse, reason: '$stage is not terminal');
        }
      }
    });

    test('the state machine has exactly the six documented stages', () {
      // A new stage is a routing change; the gate in main.dart switches on
      // this enum exhaustively, so pinning the set catches drift.
      expect(AuthStage.values.length, 6);
      expect(
        AuthStage.values.map((s) => s.name).toSet(),
        {
          'booting',
          'signUp',
          'signIn',
          'biometricUnlock',
          'biometricEnroll',
          'authenticated',
        },
      );
    });
  });

  group('AuthState', () {
    test('unauthenticated defaults are all clear', () {
      const s = AuthState(stage: AuthStage.signIn);
      expect(s.isAuthenticated, isFalse);
      expect(s.hasError, isFalse);
      expect(s.isLockedOut, isFalse);
      expect(s.busy, isFalse);
      expect(s.offlineFallbackUsed, isFalse);
      expect(s.biometricsAvailable, isFalse);
      expect(s.rememberedIndex, isNull);
      expect(s.session, isNull);
    });

    test('booting is the default stage', () {
      expect(const AuthState().stage, AuthStage.booting);
    });

    test('isAuthenticated needs BOTH the stage and a session', () {
      // A session with the wrong stage is not authenticated, and the right
      // stage with no session is not either. Both must hold.
      expect(
        const AuthState(stage: AuthStage.authenticated).isAuthenticated,
        isFalse,
        reason: 'authenticated stage without a session is not authenticated',
      );
      expect(
        AuthState(stage: AuthStage.signIn, session: _kSession).isAuthenticated,
        isFalse,
        reason: 'a session on the signIn stage is not authenticated',
      );
      expect(
        AuthState(stage: AuthStage.authenticated, session: _kSession)
            .isAuthenticated,
        isTrue,
      );
    });

    test('hasError tracks the error string, not the kind', () {
      expect(
        const AuthState(error: 'Invalid credentials').hasError,
        isTrue,
      );
      // A kind without copy is still not "an error to show".
      expect(
        const AuthState(errorKind: AuthFailureKind.accountLocked).hasError,
        isFalse,
      );
    });

    test('isLockedOut is true only for accountLocked', () {
      expect(
        const AuthState(errorKind: AuthFailureKind.accountLocked).isLockedOut,
        isTrue,
      );
      for (final kind in AuthFailureKind.values) {
        if (kind != AuthFailureKind.accountLocked) {
          expect(
            AuthState(errorKind: kind).isLockedOut,
            isFalse,
            reason: '$kind must not read as a lockout',
          );
        }
      }
    });

    test('biometricsAvailable mirrors the capability gate', () {
      expect(
        const AuthState(
          capability: BiometricCapability(
            hardwareSupported: true,
            deviceSupported: true,
            enrolled: [BiometricType.fingerprint],
          ),
        ).biometricsAvailable,
        isTrue,
      );
      expect(
        const AuthState().biometricsAvailable,
        isFalse,
        reason: 'unsupported capability must not advertise biometrics',
      );
    });
  });

  group('BiometricCapability', () {
    test('unsupported() is the safe default', () {
      const cap = BiometricCapability.unsupported();
      expect(cap.hardwareSupported, isFalse);
      expect(cap.deviceSupported, isFalse);
      expect(cap.enrolled, isEmpty);
      expect(cap.hasEnrolledBiometrics, isFalse);
      expect(cap.canUseBiometricLogin, isFalse);
    });

    test('hardware alone is not enough — enrolment is required', () {
      // canCheckBiometrics can be true with nothing enrolled; showing the
      // fingerprint affordance then would just fail on tap.
      const cap = BiometricCapability(
        hardwareSupported: true,
        deviceSupported: true,
        enrolled: [],
      );
      expect(cap.hardwareSupported, isTrue);
      expect(cap.hasEnrolledBiometrics, isFalse);
      expect(cap.canUseBiometricLogin, isFalse);
    });

    test('enrolled biometrics enable the login gate', () {
      const cap = BiometricCapability(
        hardwareSupported: true,
        deviceSupported: true,
        enrolled: [BiometricType.fingerprint],
      );
      expect(cap.hasEnrolledBiometrics, isTrue);
      expect(cap.canUseBiometricLogin, isTrue);
    });

    test('toString is identifying-free', () {
      const cap = BiometricCapability(
        hardwareSupported: true,
        deviceSupported: true,
        enrolled: [BiometricType.fingerprint, BiometricType.face],
      );
      final s = cap.toString();
      expect(s, contains('hardware: true'));
      expect(s, contains('enrolled: 2'));
      expect(s, isNot(contains('fingerprint')),
          reason: 'the enrolled list must be summarised, not enumerated');
    });
  });

  group('BiometricOutcome', () {
    test('lockouts never offer the password fallback', () {
      // Dropping a locked-out user onto the password form invites them to
      // hammer it and trip the server-side brute-force lockout (plan §4.6).
      const mustNotFallBack = {
        BiometricOutcome.success,
        BiometricOutcome.temporaryLockout,
        BiometricOutcome.permanentLockout,
        BiometricOutcome.alreadyInProgress,
      };
      for (final outcome in BiometricOutcome.values) {
        expect(
          outcome.shouldOfferPasswordFallback,
          !mustNotFallBack.contains(outcome),
          reason: '$outcome fallback expectation is wrong',
        );
      }
    });

    test('userCanceled falls back to password', () {
      // Plan §3.2 acceptance: "biometric fallback to PIN".
      expect(
        BiometricOutcome.userCanceled.shouldOfferPasswordFallback,
        isTrue,
      );
      expect(BiometricOutcome.userRequestedFallback.shouldOfferPasswordFallback,
          isTrue);
    });

    test('isUnsupportedDevice covers exactly the hardware gaps', () {
      const unsupported = {
        BiometricOutcome.noHardware,
        BiometricOutcome.noDeviceCredential,
      };
      for (final outcome in BiometricOutcome.values) {
        expect(
          outcome.isUnsupportedDevice,
          unsupported.contains(outcome),
          reason: '$outcome unsupported-device flag is wrong',
        );
      }
    });

    test('notEnrolled is not "unsupported" — the sensor exists', () {
      // The affordance should stay visible-but-explained, not disappear: the
      // user can enrol a fingerprint and then use it.
      expect(BiometricOutcome.notEnrolled.isUnsupportedDevice, isFalse);
      expect(BiometricOutcome.notEnrolled.shouldOfferPasswordFallback, isTrue);
    });

    test('isSuccess is true only for success', () {
      for (final outcome in BiometricOutcome.values) {
        expect(outcome.isSuccess, outcome == BiometricOutcome.success);
      }
    });

    test('biometricMessageFor has copy for every non-success outcome', () {
      expect(biometricMessageFor(BiometricOutcome.success), isNull);
      for (final outcome in BiometricOutcome.values) {
        if (outcome == BiometricOutcome.success) continue;
        final msg = biometricMessageFor(outcome);
        expect(msg, isNotNull, reason: '$outcome has no user-facing copy');
        expect(msg, isNotEmpty, reason: '$outcome copy is blank');
      }
    });

    test('biometricMessageFor copy never leaks platform internals', () {
      for (final outcome in BiometricOutcome.values) {
        final msg = biometricMessageFor(outcome) ?? '';
        expect(msg, isNot(contains('PlatformException')));
        expect(msg, isNot(contains('local_auth')));
        expect(msg, isNot(contains(outcome.name)),
            reason: 'enum member names must not reach the UI');
      }
    });
  });

  group('AuthSessionSource', () {
    test('isServerIssued separates the two provenances', () {
      expect(AuthSessionSource.server.isServerIssued, isTrue);
      expect(AuthSessionSource.local.isServerIssued, isFalse);
    });

    test('fromWire defaults unknown values to local', () {
      // Fail closed: an unrecognised wire value must never be treated as a
      // server-issued credential.
      expect(AuthSessionSource.fromWire('server'), AuthSessionSource.server);
      expect(AuthSessionSource.fromWire('local'), AuthSessionSource.local);
      expect(AuthSessionSource.fromWire(null), AuthSessionSource.local);
      expect(AuthSessionSource.fromWire('garbage'), AuthSessionSource.local);
      expect(AuthSessionSource.fromWire('SERVER'), AuthSessionSource.local,
          reason: 'matching is exact, so uppercase is not "server"');
    });
  });

  group('AuthSession', () {
    test('toString never contains token material', () {
      // Hard Rule 1: a stray print(session) or a crash report must not leak
      // the access or refresh token.
      const session = AuthSession(
        indexNumber: '0000000000',
        userId: 'user-001',
        accessToken: 'SECRET-access-token-value',
        refreshToken: 'SECRET-refresh-token-value',
        accessExpiresAtUnix: 9999999999,
        issuedAtUnix: 1000000000,
        source: AuthSessionSource.server,
      );
      final s = session.toString();
      expect(s, isNot(contains('SECRET-access-token-value')));
      expect(s, isNot(contains('SECRET-refresh-token-value')));
      expect(s, isNot(contains(session.accessToken)));
      expect(s, isNot(contains(session.refreshToken)));
      // Identity and provenance ARE safe and useful in logs.
      expect(s, contains('0000000000'));
      expect(s, contains('server'));
    });

    test('toJson carries every field the store needs', () {
      final json = _kSession.toJson();
      expect(json['index_number'], '0000000000');
      expect(json['user_id'], 'user-001');
      expect(json['access_token'], 'access-token-here');
      expect(json['refresh_token'], 'refresh-token-here');
      expect(json['access_expires_at_unix'], 9999999999);
      expect(json['issued_at_unix'], 1000000000);
      expect(json['source'], 'server');
      expect(json['biometric_enabled'], false);
    });

    test('toJson/fromJson round-trips losslessly', () {
      const original = AuthSession(
        indexNumber: '1234567890',
        userId: 'u-42',
        accessToken: 'at',
        refreshToken: 'rt',
        accessExpiresAtUnix: 2000000000,
        issuedAtUnix: 1000000000,
        biometricEnabled: true,
        source: AuthSessionSource.local,
      );
      final restored = AuthSession.fromJson(original.toJson());
      expect(restored, isNotNull);
      expect(restored!.indexNumber, original.indexNumber);
      expect(restored.userId, original.userId);
      expect(restored.accessToken, original.accessToken);
      expect(restored.refreshToken, original.refreshToken);
      expect(restored.accessExpiresAtUnix, original.accessExpiresAtUnix);
      expect(restored.issuedAtUnix, original.issuedAtUnix);
      expect(restored.biometricEnabled, isTrue);
      expect(restored.source, AuthSessionSource.local);
    });

    test('fromJson rejects a missing index number', () {
      expect(AuthSession.fromJson({}), isNull);
      expect(
        AuthSession.fromJson({'access_token': 'at', 'refresh_token': 'rt'}),
        isNull,
      );
    });

    test('fromJson rejects a malformed index number', () {
      // A truncated or tampered store entry must fall back to sign-in rather
      // than produce a session for the wrong candidate.
      for (final bad in ['short', '12345678901', '123456789a', '', '   ']) {
        expect(AuthSession.fromJson({'index_number': bad}), isNull,
            reason: '"$bad" must be rejected');
      }
    });

    test('fromJson rejects a non-string index number', () {
      expect(AuthSession.fromJson({'index_number': 1234567890}), isNull);
      expect(AuthSession.fromJson({'index_number': null}), isNull);
    });

    test('fromJson tolerates missing optional fields', () {
      // Only the index number is load-bearing; everything else has a safe
      // default so an older store entry still parses.
      final s = AuthSession.fromJson({'index_number': '0000000000'});
      expect(s, isNotNull);
      expect(s!.userId, '');
      expect(s.accessToken, '');
      expect(s.refreshToken, '');
      expect(s.accessExpiresAtUnix, 0);
      expect(s.issuedAtUnix, 0);
      expect(s.biometricEnabled, isFalse);
      expect(s.source, AuthSessionSource.local);
    });

    test('fromJson coerces numeric timestamps', () {
      final s = AuthSession.fromJson({
        'index_number': '0000000000',
        'access_expires_at_unix': 1.5e9,
        'issued_at_unix': 1.4e9,
      });
      expect(s, isNotNull);
      expect(s!.accessExpiresAtUnix, 1500000000);
      expect(s.issuedAtUnix, 1400000000);
    });

    test('copyWith overrides only the given fields', () {
      final updated = _kSession.copyWith(biometricEnabled: true);
      expect(updated.indexNumber, _kSession.indexNumber);
      expect(updated.userId, _kSession.userId);
      expect(updated.accessToken, _kSession.accessToken);
      expect(updated.refreshToken, _kSession.refreshToken);
      expect(updated.accessExpiresAtUnix, _kSession.accessExpiresAtUnix);
      expect(updated.issuedAtUnix, _kSession.issuedAtUnix);
      expect(updated.source, AuthSessionSource.server);
      expect(updated.biometricEnabled, isTrue);
    });

    test('copyWith cannot change the identity', () {
      // indexNumber and userId are deliberately absent from copyWith: a token
      // rotation must never be able to move a session onto another candidate.
      final rotated = _kSession.copyWith(
        accessToken: 'new-at',
        refreshToken: 'new-rt',
        accessExpiresAtUnix: 2000000000,
      );
      expect(rotated.indexNumber, _kSession.indexNumber);
      expect(rotated.userId, _kSession.userId);
      expect(rotated.accessToken, 'new-at');
      expect(rotated.refreshToken, 'new-rt');
    });

    test('isAccessExpired honours the skew', () {
      const session = AuthSession(
        indexNumber: '0000000000',
        userId: 'u',
        accessToken: 'at',
        refreshToken: 'rt',
        accessExpiresAtUnix: 1000,
        issuedAtUnix: 0,
        source: AuthSessionSource.server,
      );
      expect(session.isAccessExpired(900), isFalse);
      // Default skew is 30s, so 970 is already "expired" to avoid a token
      // dying mid-request.
      expect(session.isAccessExpired(970), isTrue);
      expect(session.isAccessExpired(1000), isTrue);
      expect(session.isAccessExpired(2000), isTrue);
      expect(session.isAccessExpired(970, skewSeconds: 0), isFalse);
      expect(session.isAccessExpired(500, skewSeconds: 600), isTrue);
    });

    test('isBiometricEnabled mirrors the flag', () {
      expect(_kSession.isBiometricEnabled, isFalse);
      expect(_kSession.copyWith(biometricEnabled: true).isBiometricEnabled,
          isTrue);
    });
  });

  group('InMemorySessionStore', () {
    test('starts empty', () async {
      final store = InMemorySessionStore();
      expect(await store.read(), isNull);
      expect(await store.readRememberedIndex(), isNull);
    });

    test('accepts a seeded session and index', () async {
      final store = InMemorySessionStore(
        session: _kSession,
        rememberedIndex: '0000000000',
      );
      final loaded = await store.read();
      expect(loaded, isNotNull);
      expect(loaded!.indexNumber, '0000000000');
      expect(await store.readRememberedIndex(), '0000000000');
    });

    test('write then read round-trips the session', () async {
      final store = InMemorySessionStore();
      await store.write(_kSession);
      final loaded = await store.read();
      expect(loaded, isNotNull);
      expect(loaded!.indexNumber, _kSession.indexNumber);
      expect(loaded.userId, _kSession.userId);
      expect(loaded.accessToken, _kSession.accessToken);
      expect(store.writeCount, 1);
    });

    test('write replaces the previous session', () async {
      final store = InMemorySessionStore();
      await store.write(_kSession);
      final other = _kSession.copyWith(accessToken: 'second-token');
      await store.write(other);
      expect((await store.read())!.accessToken, 'second-token');
      expect(store.writeCount, 2);
    });

    test('clear removes the session but keeps the remembered index', () async {
      // Sign-out semantics: the next launch must offer *sign in*, not ask the
      // candidate to register an account that already exists.
      final store = InMemorySessionStore();
      await store.write(_kSession);
      await store.writeRememberedIndex('0000000000');

      await store.clear();

      expect(await store.read(), isNull);
      expect(await store.readRememberedIndex(), '0000000000');
      expect(store.clearCount, 1);
    });

    test('clearAll wipes session and remembered index', () async {
      final store = InMemorySessionStore();
      await store.write(_kSession);
      await store.writeRememberedIndex('0000000000');

      await store.clearAll();

      expect(await store.read(), isNull);
      expect(await store.readRememberedIndex(), isNull);
      expect(store.clearAllCount, 1);
    });

    test('writeRememberedIndex rejects an invalid index', () async {
      final store = InMemorySessionStore();
      for (final bad in ['short', '12345678901', 'abcdefghij', '']) {
        await store.writeRememberedIndex(bad);
        expect(await store.readRememberedIndex(), isNull,
            reason: '"$bad" must not be remembered');
      }
    });

    test('writeRememberedIndex never overwrites a good value with a bad one',
        () async {
      final store = InMemorySessionStore();
      await store.writeRememberedIndex('1234567890');
      await store.writeRememberedIndex('nope');
      expect(await store.readRememberedIndex(), '1234567890');
    });

    test('clear on an empty store is a no-op, not an error', () async {
      final store = InMemorySessionStore();
      await store.clear();
      await store.clearAll();
      expect(await store.read(), isNull);
      expect(store.clearCount, 1);
      expect(store.clearAllCount, 1);
    });
  });

  group('AuthFailureKind', () {
    test('only unreachable counts as a network failure', () {
      // The on-device session fallback is allowed ONLY for a network failure
      // (Hard Rule 5). Every other kind must be surfaced, never papered over.
      expect(AuthFailureKind.unreachable.isNetworkFailure, isTrue);
      for (final kind in AuthFailureKind.values) {
        if (kind == AuthFailureKind.unreachable) continue;
        expect(kind.isNetworkFailure, isFalse,
            reason: '$kind must not allow the offline fallback');
      }
    });

    test('wrong credentials are not a network failure', () {
      expect(AuthFailureKind.invalidCredentials.isNetworkFailure, isFalse);
      expect(AuthFailureKind.accountLocked.isNetworkFailure, isFalse);
      expect(AuthFailureKind.tokenInvalid.isNetworkFailure, isFalse);
    });
  });

  group('AuthException', () {
    test('toString exposes the kind but never the message', () {
      const e = AuthException(
        AuthFailureKind.invalidCredentials,
        'That index number and password do not match',
      );
      expect(e.toString(), 'AuthException(invalidCredentials)');
      expect(e.toString(), isNot(contains('password')));
      expect(e.message, isNotEmpty);
      expect(e.kind, AuthFailureKind.invalidCredentials);
    });

    test('isNetworkFailure delegates to the kind', () {
      const network = AuthException(AuthFailureKind.unreachable, 'offline');
      const creds = AuthException(AuthFailureKind.invalidCredentials, 'bad');
      expect(network.isNetworkFailure, isTrue);
      expect(creds.isNetworkFailure, isFalse);
    });
  });
}
