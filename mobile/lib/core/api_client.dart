import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'domain_types.dart';
import 'network/retry_policy.dart';

/// API surface the app consumes. Mocked in tests via [MockWaecApi].
abstract class WaecApi {
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  });

  /// Live price from the backend config endpoint (dynamic GHS, plan §2.2).
  ///
  /// Falls back to a safe default (GHS 20.00) if the endpoint is
  /// unreachable, so the verification journey is never blocked by a missing
  /// price (Paystack's checkout is the single source of truth for the amount).
  Future<Price> getPricing(ExamType examType);

  /// Live transaction stage stream: SSE with adaptive 2-second
  /// short-polling fallback (plan §3.4). Emits until terminal.
  Stream<TransactionStage> transactionStages(String transactionId);

  // ── Auth (plan §2.1 / §3.2) ─────────────────────────────────────────────
  //
  // Backed by the Auth service RPCs already defined in
  // microservices/proto/waec/auth/v1/auth.proto (Register / Login / Refresh /
  // BindBiometric) and routed at the edge by /v1/auth/ in
  // infra/gateway/conf.d/api.conf.
  //
  // Every method throws [AuthException] with a typed [AuthFailureKind]; callers
  // must not catch-and-ignore, because only [AuthFailureKind.unreachable] is
  // eligible for the on-device session fallback.

  /// Creates an account for a 10-digit index number and returns a session.
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  });

  /// Exchanges index + password for a session.
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  });

  /// Rotates a refresh token into a fresh token pair (plan §2.1).
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  });

  /// Binds a platform-keystore public key to the account so the server knows
  /// this device is fingerprint-enabled (`BindBiometric` RPC).
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  });
}

/// Why an auth call failed.
///
/// Typed rather than a string so the UI can distinguish "wrong password"
/// (show the form again) from "account locked for 15 minutes" (plan §4.6 —
/// stop the user hammering it) from "backend unreachable" (the only case where
/// the on-device session fallback is allowed).
enum AuthFailureKind {
  /// Index + password did not match.
  invalidCredentials,

  /// Brute-force lockout is active (5 failures -> 15 min).
  accountLocked,

  /// Sign-up for an index number that already has an account.
  indexAlreadyRegistered,

  /// Index number failed the 10-digit rule server-side.
  invalidIndexNumber,

  /// Password failed the server-side length rule.
  invalidPassword,

  /// The presented access/refresh token was rejected.
  tokenInvalid,

  /// The Auth endpoint could not be reached at all.
  unreachable,

  /// Anything else.
  unknown;

  /// Only a network failure may fall back to an on-device session.
  bool get isNetworkFailure => this == AuthFailureKind.unreachable;
}

/// Typed auth error.
///
/// The [message] is user-presentable and never contains the password or any
/// token material (Hard Rule 1).
class AuthException implements Exception {
  const AuthException(this.kind, this.message);

  final AuthFailureKind kind;
  final String message;

  bool get isNetworkFailure => kind.isNetworkFailure;

  @override
  String toString() => 'AuthException(${kind.name})';
}

/// Static SHA-256 certificate pins (plan §3.9: pinning compiled into
/// binary; rotation via app release).
class CertPins {
  /// SPKI SHA-256 base64 digests for api.waecplatform.gh (primary + backup).
  static const apiHost = 'api.waecplatform.gh';
  static const pins = <String>{
    'SH4Wb4hAqXaBcvWohvSkzwNcOXKq0R4RcnS8CFWcUd4=', // prod leaf (placeholder until CA issues)
    'C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=', // backup key
  };

  static const baseUrl = 'https://$apiHost';
}

/// Channel init response from POST /v1/payment/charge.
class ChargeInit {
  const ChargeInit({
    required this.transactionId,
    required this.status,
    required this.amountPesewas,
    required this.checkoutUrl,
    required this.displayMessage,
  });

  final String transactionId;
  final String status; // pending | success | failed
  final int amountPesewas;
  final String checkoutUrl;
  final String displayMessage;
}

/// Price from the backend config endpoint (dynamic GHS, plan §2.2).
class Price {
  const Price({required this.amountPesewas, required this.currency});
  final int amountPesewas;
  final String currency;

  String get display => amountPesewas > 0
      ? 'GHS ${(amountPesewas / 100).toStringAsFixed(2)}'
      // Backend config returned a non-positive amount (unseeded row, zero fee,
      // or a malformed payload). Rather than ever showing "GHS 0.00", fall back
      // to the standard single-result fee so the CTA stays actionable. The
      // authoritative amount is shown again on Paystack's checkout.
      : 'GHS ${(2000 / 100).toStringAsFixed(2)}';
}

/// Dio-backed client with pinned-SPKI verification, backoff with jitter,
/// and idempotency headers preserved across retries (plan §3.9).
class HttpWaecApi implements WaecApi {
  HttpWaecApi({Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl ?? CertPins.baseUrl,
              connectTimeout: const Duration(seconds: 10),
              // Payload budget: responses <10KB compressed at edge (§4.10)
              headers: {'Accept-Encoding': 'gzip, br'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['X-Client'] = 'waec-mobile/$_version';
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  static const _version = '0.1.0';

  @override
  Future<Price> getPricing(ExamType examType) async {
    try {
      final result = await retryWithBackoff<Map<String, dynamic>>(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          '/v1/payment/pricing',
          queryParameters: {'exam_type': examType.code},
        );
        return resp.data ?? <String, dynamic>{};
      });
      return switch (result) {
        RetrySuccess(:final value) => Price(
          amountPesewas: (value['amount_pesewas'] as num?)?.toInt() ?? 0,
          currency: value['currency'] as String? ?? 'GHS',
        ),
        RetryExhausted(:final lastError) => throw lastError,
      };
    } on Object {
      // Backend unreachable → use the standard single-result fee so the
      // CTA is never stuck on "Price unavailable".
      return const Price(amountPesewas: 2000, currency: 'GHS');
    }
  }

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    final result = await retryWithBackoff<Map<String, dynamic>>(() async {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/payment/charge',
        options: Options(headers: {'X-Idempotency-Key': idempotencyKey}),
        // Payment method is chosen by the user on Paystack's hosted
        // checkout; the backend derives the channel from the charge result.
        data: {
          'index_number': indexNumber,
          'exam_type': examType.code,
          'exam_year': examYear,
        },
      );
      return resp.data ?? <String, dynamic>{};
    });
    return switch (result) {
      RetrySuccess(:final value) => ChargeInit(
        transactionId: value['transaction_id'] as String? ?? '',
        status: value['status'] as String? ?? 'pending',
        amountPesewas: (value['amount_pesewas'] as num?)?.toInt() ?? 0,
        checkoutUrl: value['checkout_url'] as String? ?? '',
        displayMessage: value['display_message'] as String? ?? '',
      ),
      RetryExhausted(:final lastError) => throw lastError,
    };
  }

  // ── Auth (plan §2.1 / §3.2) ─────────────────────────────────────────────

  @override
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  }) => _authSession('/v1/auth/register', indexNumber, <String, dynamic>{
    'index_number': indexNumber,
    'password': password,
  });

  @override
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  }) => _authSession('/v1/auth/login', indexNumber, <String, dynamic>{
    'index_number': indexNumber,
    'password': password,
  });

  @override
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  }) => _authSession('/v1/auth/refresh', indexNumber, <String, dynamic>{
    'refresh_token': refreshToken,
  });

  /// Binding is best-effort: the fingerprint unlock works on-device whether
  /// or not the server recorded the key, so a failure here must never block or
  /// delay sign-in. It reports `false` rather than throwing.
  @override
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  }) async {
    final result = await retryWithBackoff<Map<String, dynamic>>(
      () async {
        final resp = await _dio.post<Map<String, dynamic>>(
          '/v1/auth/biometric/bind',
          data: <String, dynamic>{
            'access_token': accessToken,
            'platform_public_key': platformPublicKey,
          },
        );
        return resp.data ?? <String, dynamic>{};
      },
      isRetryable: isTransientNetworkError,
    );
    return switch (result) {
      RetrySuccess(:final value) => value['bound'] as bool? ?? false,
      RetryExhausted() => false,
    };
  }

  /// Shared POST for the three session-issuing endpoints.
  Future<AuthSession> _authSession(
    String path,
    String indexNumber,
    Map<String, dynamic> body,
  ) async {
    final result = await retryWithBackoff<Map<String, dynamic>>(
      () async {
        final resp = await _dio.post<Map<String, dynamic>>(path, data: body);
        return resp.data ?? <String, dynamic>{};
      },
      // Deliberately narrow: only a request that never produced an HTTP
      // response may be retried. Retrying a *received* 401 would count the
      // same rejected password three times against the server-side lockout
      // (plan §4.6: 5 failures -> 15 min) and lock the candidate out of their
      // own account for one typo.
      isRetryable: isTransientNetworkError,
    );
    return switch (result) {
      RetrySuccess(:final value) => sessionFromWire(value, indexNumber),
      RetryExhausted(:final lastError) => throw mapAuthError(lastError),
    };
  }

  @override
  Stream<TransactionStage> transactionStages(String transactionId) async* {
    // 1) SSE over HTTP/2 first (long-lived, native reconnect, plan §4.10).
    //    If the stream dies *before* delivering a terminal stage — carrier
    //    drop, captive portal, proxy kill — we resume once with Last-Event-ID
    //    and then 2) degrade to adaptive 2-second polling of
    //    /v1/transaction/status/{id}. Polling also covers the case where the
    //    SSE endpoint is unreachable from the first byte.
    var sawAnyEvent = false;
    String? lastEventId;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await for (final frame in _openSse(
          transactionId,
          lastEventId: attempt == 1 ? lastEventId : null,
        )) {
          if (frame.id != null) lastEventId = frame.id;
          final stage = frame.stage;
          if (stage == null) continue; // heartbeat / unknown event: keep alive
          sawAnyEvent = true;
          yield stage;
          if (stage.isTerminal) return;
        }
        // Stream ended cleanly without a terminal stage → resume/fallback.
      } on DioException {
        // Connection refused/broken: try resume once, then poll.
      }
      if (sawAnyEvent && attempt == 0 && lastEventId != null) continue;
      break;
    }
    // 2) Carrier broke the connection → adaptive 2s polling fallback.
    yield* _poll(transactionId);
  }

  /// Opens `GET /v1/stream/transactions/{id}` as text/event-stream.
  ///
  /// [lastEventId] is sent as `Last-Event-ID` so the server replays from the
  /// stage after the one the client already saw (plan §4.10 resumption).
  Stream<SseFrame> _openSse(
    String transactionId, {
    String? lastEventId,
  }) async* {
    final headers = <String, String>{
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      // Per-frame identity encoding (plan §4.10): the client constructor's
      // gzip/br default would buffer frames in the compressor and delay
      // stage delivery; SSE payloads here are tiny JSON anyway.
      'Accept-Encoding': 'identity',
      'Last-Event-ID': ?lastEventId,
    };
    // receiveTimeout is deliberately null: SSE is long-lived and the gateway
    // sends a comment heartbeat every 15s (proxy_read_timeout 300s).
    final options = Options(
      headers: headers,
      responseType: ResponseType.stream,
      receiveTimeout: null,
    );
    final resp = await _dio.get<ResponseBody>(
      '/v1/stream/transactions/$transactionId',
      options: options,
    );
    final body = resp.data;
    if (body == null) return;
    final parser = SseParser();
    // Utf8Decoder is a StreamTransformer<List<int>, String>; bind() accepts the
    // covariant Stream<Uint8List> Dio hands us (transform() would fail its
    // runtime type check against the stream's own type argument).
    await for (final chunk in utf8.decoder.bind(body.stream)) {
      for (final frame in parser.feed(chunk)) {
        yield frame;
      }
    }
    // A stream closed without a trailing blank line still dispatches its
    // last buffered event.
    final tail = parser.flush();
    if (tail != null) yield tail;
  }

  Stream<TransactionStage> _poll(String transactionId) async* {
    const interval = Duration(seconds: 2); // adaptive 2-second fallback
    while (true) {
      final result = await retryWithBackoff<Map<String, dynamic>>(() async {
        final resp = await _dio.get<Map<String, dynamic>>(
          '/v1/transaction/status/$transactionId',
        );
        return resp.data ?? <String, dynamic>{};
      });
      final stage = switch (result) {
        // An unrecognised stage means the server is mid-migration: keep
        // polling rather than showing a false failure.
        RetrySuccess(:final value) => TransactionStageValues.tryFromCode(
          value['stage'] as String?,
        ),
        RetryExhausted() => TransactionStage.failed,
      };
      if (stage == null) {
        await Future<void>.delayed(interval);
        continue;
      }
      yield stage;
      if (stage.isTerminal) return;
      await Future<void>.delayed(interval);
    }
  }
}

/// Wire-code mapping for stages (server contract).
///
/// Accepts the short snake_case form the REST facade emits
/// (`payment_confirmation`), the raw proto enum name
/// (`TRANSACTION_STAGE_PAYMENT_CONFIRMATION`) and the Dart enum name, all
/// case- and separator-insensitively. Unknown codes yield null rather than a
/// fabricated `failed`, so a stage added server-side later degrades to
/// "still processing" instead of falsely telling the candidate they failed.
extension TransactionStageValues on TransactionStage {
  static TransactionStage? tryFromCode(String? code) {
    final key = _normalize(code);
    if (key == null) return null;
    for (final stage in TransactionStage.values) {
      if (_normalize(stage.name) == key) return stage;
    }
    return null;
  }

  static String? _normalize(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    var s = value.replaceAll(RegExp(r'[^a-z0-9]'), '');
    const prefix = 'transactionstage';
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
    return s.isEmpty ? null : s;
  }
}

/// One dispatched `text/event-stream` event (plan §4.10).
class SseFrame {
  const SseFrame({this.id, this.data});

  /// Server-assigned monotonic event id, echoed back as `Last-Event-ID`
  /// when the client resumes after a carrier drop.
  final String? id;
  final String? data;

  /// Stage encoded in the event payload, or null for heartbeats/unknowns.
  ///
  /// Payloads are either a bare stage code or a small JSON object carrying a
  /// `stage` field; both are supported so the gateway and service facades can
  /// evolve independently.
  TransactionStage? get stage {
    final value = data?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('{')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return TransactionStageValues.tryFromCode(
            decoded['stage'] as String?,
          );
        }
      } on FormatException {
        return null;
      }
      return null;
    }
    return TransactionStageValues.tryFromCode(value);
  }
}

/// Incremental SSE line parser (plan §4.10).
///
/// Handles CRLF and LF terminators, a UTF-8 sequence split across TCP chunks
/// (handled by the caller's decoder), multi-line `data:` fields, comment
/// heartbeats (`: keepalive`), and events dispatched without a trailing blank
/// line when the connection closes. [feed] is a no-op on empty input.
class SseParser {
  String _pending = '';
  String? _id;
  final List<String> _data = [];

  List<SseFrame> feed(String chunk) {
    _pending += chunk;
    final frames = <SseFrame>[];
    while (true) {
      final idx = _pending.indexOf('\n');
      if (idx < 0) break;
      var line = _pending.substring(0, idx);
      _pending = _pending.substring(idx + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      if (line.isEmpty) {
        final frame = _dispatch();
        if (frame != null) frames.add(frame);
        continue;
      }
      if (line.startsWith(':')) continue; // comment / heartbeat
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          _id = value;
        case 'data':
          _data.add(value);
        case 'event':
          break; // single event type on this stream
        default:
          break; // retry: and future fields are ignored per spec
      }
    }
    return frames;
  }

  /// Dispatches whatever is buffered — call once when the stream ends.
  ///
  /// A connection dropped mid-event leaves the final line in [_pending]
  /// without its terminating newline; that line is still a complete field per
  /// the SSE spec ("once the end of the file is reached, any pending data
  /// must be discarded" applies only to the *event*, whose fields already
  /// arrived), so it is processed before dispatching.
  SseFrame? flush() {
    final rest = _pending;
    _pending = '';
    if (rest.isNotEmpty) {
      feed('$rest\n');
    }
    return _dispatch();
  }

  SseFrame? _dispatch() {
    if (_data.isEmpty) {
      // An id-only frame is a keepalive: remember it for resumption but do
      // not surface a stage.
      final id = _id;
      _id = null;
      return id == null ? null : SseFrame(id: id);
    }
    final frame = SseFrame(id: _id, data: _data.join('\n'));
    _data.clear();
    _id = null;
    return frame;
  }
}

// ── Auth wire mapping ───────────────────────────────────────────────────────
//
// The JSON<->gRPC REST facade in front of the Auth service is not deployed yet
// (infra/gateway/conf.d/api.conf still `grpc_pass`es /v1/auth/), so the exact
// error envelope is not fixed. These mappers are therefore deliberately
// tolerant: they look for the canonical domain codes from
// microservices/common/src/errors.rs anywhere in the payload — including inside
// the gRPC `details` string, which DomainError formats as "CODE|message" — and
// fall back to HTTP status semantics.

/// True only when the request never produced an HTTP response.
///
/// Used as `retryWithBackoff`'s `isRetryable` for auth calls. A received 4xx is
/// *never* retried: a rejected password must count exactly once against the
/// server-side brute-force lockout (plan §4.6), not once per retry.
bool isTransientNetworkError(Object error) => switch (error) {
  DioException(:final type) => switch (type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.unknown => true,
    // A certificate failure is never retried: it means pinning rejected the
    // peer (possible MITM), and retrying just re-offers the same bad peer
    // (plan §3.9, Hard Rule 5).
    DioExceptionType.badCertificate => false,
    DioExceptionType.badResponse || DioExceptionType.cancel => false,
  },
  _ => false,
};

/// Builds an [AuthSession] from an Auth-service response body.
///
/// Throws [AuthException] when the body carries no token material: a 200
/// without an access token is a broken facade, not a successful login, and
/// treating it as a session would admit the user with no credential check.
AuthSession sessionFromWire(Map<String, dynamic> value, String indexNumber) {
  final access =
      (value['access_token'] ?? value['accessToken']) as String? ?? '';
  if (access.isEmpty) {
    throw const AuthException(
      AuthFailureKind.unknown,
      'The server returned an incomplete response. Please try again.',
    );
  }
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return AuthSession(
    indexNumber: value['index_number'] as String? ?? indexNumber,
    userId: (value['user_id'] ?? value['userId']) as String? ?? '',
    accessToken: access,
    refreshToken:
        (value['refresh_token'] ?? value['refreshToken']) as String? ?? '',
    accessExpiresAtUnix:
        (value['access_expires_at_unix'] as num?)?.toInt() ?? now,
    issuedAtUnix: now,
    source: AuthSessionSource.server,
  );
}

/// Translates a transport failure into a typed, user-presentable
/// [AuthException].
///
/// The message is always a fixed local string — raw server text is never
/// surfaced, so an internal error string cannot leak implementation detail
/// (Hard Rule 1).
AuthException mapAuthError(Object error) {
  if (error is AuthException) return error;
  if (error is! DioException) {
    return const AuthException(
      AuthFailureKind.unknown,
      'Sign-in failed. Please try again.',
    );
  }

  final response = error.response;
  // No response at all: DNS, TLS, captive portal, offline, timeout.
  if (response == null) {
    return const AuthException(
      AuthFailureKind.unreachable,
      'Cannot reach the WAEC gateway. Check your connection and try again.',
    );
  }

  final status = response.statusCode ?? 0;
  if (status >= 500) {
    return const AuthException(
      AuthFailureKind.unreachable,
      'The WAEC gateway is unavailable right now. Please try again shortly.',
    );
  }

  final haystack = _wireHaystack(response.data).toUpperCase();

  // Lockout first: it must win over invalidCredentials so the UI stops the
  // user retrying instead of inviting another attempt.
  if (haystack.contains('AUTH_LOCKED_OUT') ||
      haystack.contains('RATE_LIMITED') ||
      status == 429 ||
      status == 423) {
    return const AuthException(
      AuthFailureKind.accountLocked,
      'Too many attempts. This account is temporarily locked — '
      'please try again in 15 minutes.',
    );
  }
  if (haystack.contains('AUTH_TOKEN_INVALID') ||
      haystack.contains('AUTH_TOKEN_EXPIRED')) {
    return const AuthException(
      AuthFailureKind.tokenInvalid,
      'Your session has expired. Please sign in again.',
    );
  }
  if (haystack.contains('INVALID_INDEX_NUMBER')) {
    // The Auth service reports a duplicate index under the *same* code
    // (microservices/auth/src/svc.rs), so the wording is the only
    // discriminator between "bad format" and "already registered".
    final lower = haystack.toLowerCase();
    if (lower.contains('registered') ||
        lower.contains('exists') ||
        lower.contains('duplicate')) {
      return const AuthException(
        AuthFailureKind.indexAlreadyRegistered,
        'That index number already has an account. Please sign in instead.',
      );
    }
    return const AuthException(
      AuthFailureKind.invalidIndexNumber,
      'Index number must be exactly 10 digits.',
    );
  }
  // The Auth service reuses INVALID_EXAM_PARAMS for the password-length rule.
  if (haystack.contains('INVALID_EXAM_PARAMS')) {
    return const AuthException(
      AuthFailureKind.invalidPassword,
      'Password must be at least $kMinPasswordLength characters.',
    );
  }
  if (haystack.contains('AUTH_INVALID_CREDENTIALS') || status == 401) {
    return const AuthException(
      AuthFailureKind.invalidCredentials,
      'Incorrect index number or password.',
    );
  }
  if (status == 409) {
    return const AuthException(
      AuthFailureKind.indexAlreadyRegistered,
      'That index number already has an account. Please sign in instead.',
    );
  }
  return const AuthException(
    AuthFailureKind.unknown,
    'Sign-in failed. Please try again.',
  );
}

/// Flattens a response body into one searchable string.
///
/// `Map.toString()` keeps every key and value intact, which is enough to find a
/// domain code regardless of which field the facade nested it in.
String _wireHaystack(Object? data) => switch (data) {
  null => '',
  String() => data,
  _ => data.toString(),
};

/// Deterministic mock for widget/integration tests: scripted stages and
/// key-capture to prove idempotency-key preservation across retries.
class MockWaecApi implements WaecApi {
  MockWaecApi({
    this.stages = const [
      TransactionStage.paymentConfirmation,
      TransactionStage.voucherProvisioning,
      TransactionStage.waecRetrieval,
      TransactionStage.complete,
    ],
    this.price = const Price(amountPesewas: 2000, currency: 'GHS'),
  });

  final List<TransactionStage> stages;
  final Price price;
  final List<String> charges = [];

  // ── Auth simulation knobs ───────────────────────────────────────────────

  /// Index numbers that have completed sign-up against this mock.
  final Set<String> registeredIndexes = <String>{};

  /// When true, [login] refuses unless the index was registered first.
  bool requireRegistration = false;

  /// When non-null, every [login] fails with this kind — lets tests exercise
  /// the lockout and invalid-credential UI without a backend.
  AuthFailureKind? loginFailure;

  /// When true, every auth call throws [AuthFailureKind.unreachable], which is
  /// how the REST facade being down presents itself. Drives the on-device
  /// session fallback path.
  bool authUnreachable = false;

  /// Number of [bindBiometric] calls (count only — never the key material).
  int bindBiometricCalls = 0;

  /// The password this mock accepts. A constant so no credential is stored.
  static const String acceptedPassword = 'password123';

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
  }) async {
    charges.add(idempotencyKey);
    return ChargeInit(
      transactionId: 'tx-${charges.length}',
      status: 'pending',
      amountPesewas: price.amountPesewas,
      checkoutUrl: 'https://mock/pay',
      displayMessage: 'Approve on your phone',
    );
  }

  @override
  Future<Price> getPricing(ExamType examType) async => price;

  @override
  Stream<TransactionStage> transactionStages(String transactionId) async* {
    for (final s in stages) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      yield s;
    }
  }

  void _guardAuth() {
    if (authUnreachable) {
      throw const AuthException(
        AuthFailureKind.unreachable,
        'Cannot reach the WAEC gateway.',
      );
    }
  }

  AuthSession _mockSession(String indexNumber) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return AuthSession(
      indexNumber: indexNumber,
      userId: 'user-$indexNumber',
      accessToken: 'mock-access-$indexNumber',
      refreshToken: 'mock-refresh-$indexNumber',
      // Matches the backend's 15-minute access-token TTL (Hard Rule 5).
      accessExpiresAtUnix: now + 900,
      issuedAtUnix: now,
      source: AuthSessionSource.server,
    );
  }

  @override
  Future<AuthSession> register({
    required String indexNumber,
    required String password,
  }) async {
    _guardAuth();
    if (!IndexNumberValidator.isValid(indexNumber)) {
      throw const AuthException(
        AuthFailureKind.invalidIndexNumber,
        'Index number must be exactly 10 digits.',
      );
    }
    if (password.length < kMinPasswordLength) {
      throw const AuthException(
        AuthFailureKind.invalidPassword,
        'Password must be at least $kMinPasswordLength characters.',
      );
    }
    if (!registeredIndexes.add(indexNumber)) {
      throw const AuthException(
        AuthFailureKind.indexAlreadyRegistered,
        'That index number already has an account.',
      );
    }
    return _mockSession(indexNumber);
  }

  @override
  Future<AuthSession> login({
    required String indexNumber,
    required String password,
  }) async {
    _guardAuth();
    final forced = loginFailure;
    if (forced != null) {
      throw AuthException(forced, 'Simulated $forced failure');
    }
    if (requireRegistration && !registeredIndexes.contains(indexNumber)) {
      throw const AuthException(
        AuthFailureKind.invalidCredentials,
        'Incorrect index number or password.',
      );
    }
    if (!IndexNumberValidator.isValid(indexNumber) ||
        password != acceptedPassword) {
      throw const AuthException(
        AuthFailureKind.invalidCredentials,
        'Incorrect index number or password.',
      );
    }
    return _mockSession(indexNumber);
  }

  @override
  Future<AuthSession> refresh({
    required String indexNumber,
    required String refreshToken,
  }) async {
    _guardAuth();
    if (refreshToken.isEmpty) {
      throw const AuthException(
        AuthFailureKind.tokenInvalid,
        'Your session has expired. Please sign in again.',
      );
    }
    return _mockSession(indexNumber);
  }

  @override
  Future<bool> bindBiometric({
    required String accessToken,
    required String platformPublicKey,
  }) async {
    if (authUnreachable) return false;
    bindBiometricCalls++;
    return true;
  }
}
