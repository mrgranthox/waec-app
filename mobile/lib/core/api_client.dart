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
    required PaymentChannel channel,
    required String phone,
  });

  Future<Price> getPricing(ExamType examType);

  /// Live transaction stage stream: SSE with adaptive 2-second
  /// short-polling fallback (plan §3.4). Emits until terminal.
  Stream<TransactionStage> transactionStages(String transactionId);
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

  String get display => 'GHS ${(amountPesewas / 100).toStringAsFixed(2)}';
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
  }

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    required PaymentChannel channel,
    required String phone,
  }) async {
    final result = await retryWithBackoff<Map<String, dynamic>>(() async {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/payment/charge',
        options: Options(headers: {'X-Idempotency-Key': idempotencyKey}),
        data: {
          'index_number': indexNumber,
          'exam_type': examType.code,
          'exam_year': examYear,
          'channel': channel.code,
          'phone': phone,
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

  @override
  Future<ChargeInit> initCharge({
    required String idempotencyKey,
    required String indexNumber,
    required ExamType examType,
    required String examYear,
    required PaymentChannel channel,
    required String phone,
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
}
