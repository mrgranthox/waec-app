import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waec_app/core/api_client.dart';
import 'package:waec_app/core/domain_types.dart';
import 'package:waec_app/core/network/retry_policy.dart';

void main() {
  group('IndexNumberValidator', () {
    test('accepts exactly 10 digits', () {
      expect(IndexNumberValidator.isValid('1002330440'), isTrue);
    });

    test('rejects short, long, non-digit input', () {
      expect(IndexNumberValidator.isValid('10023304'), isFalse);
      expect(IndexNumberValidator.isValid('10023304400'), isFalse);
      expect(IndexNumberValidator.isValid('100233044O'), isFalse);
      expect(IndexNumberValidator.isValid(''), isFalse);
    });

    test('validate returns message for bad input', () {
      expect(IndexNumberValidator.validate('12'), contains('10 digits'));
      expect(IndexNumberValidator.validate('1002330440'), isNull);
    });
  });

  group('IdempotencyKeys', () {
    test('creates valid UUIDv4 keys', () {
      final key = IdempotencyKeys.create();
      expect(key.length, 36);
      expect(key.split('-').length, 5);
    });

    test('keys are unique', () {
      final keys = {for (var i = 0; i < 1000; i++) IdempotencyKeys.create()};
      expect(keys.length, 1000);
    });
  });

  group('BackoffPolicy', () {
    test('full jitter keeps delays within [0, cap]', () {
      final policy = BackoffPolicy(baseDelay: const Duration(milliseconds: 100), maxRetries: 5);
      for (var i = 0; i < 5; i++) {
        final d = policy.nextDelay();
        expect(d.inMilliseconds, lessThanOrEqualTo(1600)); // 100 * 2^i cap within max
        expect(d.inMilliseconds, greaterThanOrEqualTo(0));
      }
    });

    test('exhausts after maxRetries', () {
      final policy = BackoffPolicy(maxRetries: 3);
      expect(policy.exhausted, isFalse);
      policy.nextDelay();
      policy.nextDelay();
      expect(policy.exhausted, isFalse);
      policy.nextDelay();
      expect(policy.exhausted, isTrue);
    });

    test('reset restores attempts', () {
      final policy = BackoffPolicy(maxRetries: 1);
      policy.nextDelay();
      expect(policy.exhausted, isTrue);
      policy.reset();
      expect(policy.exhausted, isFalse);
    });
  });

  group('retryWithBackoff', () {
    test('returns value on first success', () async {
      var calls = 0;
      final result = await retryWithBackoff<int>(() async {
        calls++;
        return 42;
      });
      expect(result, isA<RetrySuccess<int>>());
      expect((result as RetrySuccess<int>).value, 42);
      expect(calls, 1);
    });

    test('retries with same operation then succeeds', () async {
      var calls = 0;
      final result = await retryWithBackoff<int>(
        () async {
          calls++;
          if (calls < 3) throw Exception('transient');
          return 7;
        },
        policy: BackoffPolicy(baseDelay: const Duration(milliseconds: 1), maxRetries: 3),
      );
      expect((result as RetrySuccess<int>).value, 7);
      expect(calls, 3);
    });

    test('exhausts and surfaces last error', () async {
      var calls = 0;
      final result = await retryWithBackoff<int>(
        () async {
          calls++;
          throw Exception('always fails');
        },
        policy: BackoffPolicy(baseDelay: const Duration(milliseconds: 1), maxRetries: 2),
      );
      expect(result, isA<RetryExhausted<int>>());
      expect(calls, 3); // initial + 2 retries
    });

    test('non-retryable errors stop immediately', () async {
      var calls = 0;
      final result = await retryWithBackoff<int>(
        () async {
          calls++;
          throw Exception('fatal');
        },
        policy: BackoffPolicy(baseDelay: const Duration(milliseconds: 1), maxRetries: 3),
        isRetryable: (_) => false,
      );
      expect(result, isA<RetryExhausted<int>>());
      expect(calls, 1);
    });
  });

  group('ExamType', () {
    test('covers all Ghana exam types', () {
      expect(ExamType.values.length, 3);
      expect(ExamType.bece.code, 'BECE');
      expect(ExamType.wasscePrivate.displayName, contains('Nwasie'));
    });
  });

  group('TransactionStageValues.tryFromCode', () {
    test('accepts the REST snake_case wire form', () {
      expect(
        TransactionStageValues.tryFromCode('payment_confirmation'),
        TransactionStage.paymentConfirmation,
      );
      expect(
        TransactionStageValues.tryFromCode('waec_retrieval'),
        TransactionStage.waecRetrieval,
      );
    });

    test('accepts the raw proto enum name', () {
      expect(
        TransactionStageValues.tryFromCode(
            'TRANSACTION_STAGE_VOUCHER_PROVISIONING'),
        TransactionStage.voucherProvisioning,
      );
    });

    test('is case insensitive and matches Dart enum names', () {
      expect(
        TransactionStageValues.tryFromCode('Complete'),
        TransactionStage.complete,
      );
      expect(
        TransactionStageValues.tryFromCode('transactionstagefailed'),
        TransactionStage.failed,
      );
    });

    test('unknown / empty yields null — never a fabricated failure', () {
      // A stage added server-side later must degrade to "still processing",
      // not tell the candidate they failed.
      expect(TransactionStageValues.tryFromCode('refunding'), isNull);
      expect(TransactionStageValues.tryFromCode(''), isNull);
      expect(TransactionStageValues.tryFromCode(null), isNull);
    });
  });

  group('SseParser', () {
    test('parses a simple event', () {
      final frames =
          SseParser().feed('id: 7\ndata: payment_confirmation\n\n');
      expect(frames, hasLength(1));
      expect(frames.single.id, '7');
      expect(frames.single.stage, TransactionStage.paymentConfirmation);
    });

    test('handles CRLF terminators', () {
      final frames = SseParser().feed('data: complete\r\n\r\n');
      expect(frames.single.stage, TransactionStage.complete);
    });

    test('an event split across chunks is buffered, not dropped', () {
      final parser = SseParser();
      expect(parser.feed('data: waec_retr'), isEmpty);
      final frames = parser.feed('ieval\n\n');
      expect(frames.single.stage, TransactionStage.waecRetrieval);
    });

    test('feeding one character at a time still dispatches once', () {
      const wire = 'id: 12\ndata: {"stage":"failed"}\n\n';
      final parser = SseParser();
      final out = <SseFrame>[];
      for (var i = 0; i < wire.length; i++) {
        out.addAll(parser.feed(wire[i]));
      }
      expect(out, hasLength(1));
      expect(out.single.id, '12');
      expect(out.single.stage, TransactionStage.failed);
    });

    test('JSON payload carrying a stage field is understood', () {
      final frames =
          SseParser().feed('data: {"stage":"voucher_provisioning"}\n\n');
      expect(frames.single.stage, TransactionStage.voucherProvisioning);
    });

    test('malformed JSON yields no stage rather than throwing', () {
      final frames = SseParser().feed('data: {"stage": broken\n\n');
      expect(frames.single.stage, isNull);
    });

    test('comment heartbeats produce no frame', () {
      expect(SseParser().feed(': keepalive\n\n'), isEmpty);
    });

    test('multi-line data fields are joined', () {
      final frames = SseParser().feed('data: line1\ndata: line2\n\n');
      expect(frames.single.data, 'line1\nline2');
    });

    test('flush dispatches a final event missing its blank line', () {
      // Real-world: carrier drops the connection mid-event.
      final parser = SseParser();
      expect(parser.feed('id: 3\ndata: complete'), isEmpty);
      expect(parser.flush()?.stage, TransactionStage.complete);
    });

    test('ids are tracked per event for Last-Event-ID resumption', () {
      final frames = SseParser()
          .feed('id: 1\ndata: payment_confirmation\n\nid: 2\ndata: complete\n\n');
      expect(frames.map((f) => f.id).toList(), ['1', '2']);
    });

    test('feed on empty input is a no-op', () {
      expect(SseParser().feed(''), isEmpty);
    });
  });

  group('HttpWaecApi.transactionStages (SSE + 2s fallback, plan §4.10)', () {
    test('emits stages from a live SSE stream and stops at terminal',
        () async {
      final requests = <RequestOptions>[];
      const wire = 'id: 1\ndata: payment_confirmation\n\n'
          'id: 2\ndata: voucher_provisioning\n\n'
          'id: 3\ndata: waec_retrieval\n\n'
          'id: 4\ndata: complete\n\n';
      final api = HttpWaecApi(
        dio: _stubDio(requests, (options) {
          expect(options.headers['Accept'], 'text/event-stream');
          // Streams must not be compressed: gzip buffers frames and the
          // gateway would hold stages back (§4.10).
          expect(options.headers['Accept-Encoding'], 'identity');
          return _sseResponse(wire);
        }),
      );

      final stages = await api.transactionStages('tx-1').toList();
      expect(stages, [
        TransactionStage.paymentConfirmation,
        TransactionStage.voucherProvisioning,
        TransactionStage.waecRetrieval,
        TransactionStage.complete,
      ]);
      // Terminal event ends the stream without falling back to polling.
      expect(requests, hasLength(1));
      expect(requests.single.path, '/v1/stream/transactions/tx-1');
    });

    test('heartbeats and unknown stages are skipped, not surfaced', () async {
      final api = HttpWaecApi(
        dio: _stubDio([], (options) {
          return _sseResponse(': keepalive\n\n'
              'data: refunding\n\n' // a stage this client does not know yet
              'data: complete\n\n');
        }),
      );
      final stages = await api.transactionStages('tx-1').toList();
      expect(stages, [TransactionStage.complete]);
    });

    test('connection failure before any byte falls back to polling',
        () async {
      final requests = <RequestOptions>[];
      final polls = <String>[];
      final api = HttpWaecApi(
        dio: _stubDio(requests, (options) {
          final path = options.path;
          if (path.startsWith('/v1/stream/')) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            );
          }
          polls.add(path);
          return _jsonResponse(
              path, {'stage': polls.length < 2 ? 'waec_retrieval' : 'complete'});
        }),
      );

      final stages = await api.transactionStages('tx-9').toList();
      expect(stages.last, TransactionStage.complete);
      expect(polls, isNotEmpty);
      expect(polls.first, '/v1/transaction/status/tx-9');
    });

    test('stream that ends before terminal resumes once with Last-Event-ID',
        () async {
      final seenResumeTokens = <String?>[];
      var streamCalls = 0;
      final api = HttpWaecApi(
        dio: _stubDio([], (options) {
          if (!options.path.startsWith('/v1/stream/')) {
            return _jsonResponse(options.path, {'stage': 'complete'});
          }
          streamCalls++;
          seenResumeTokens.add(options.headers['Last-Event-ID'] as String?);
          if (streamCalls == 1) {
            // Carrier drops the link after stage 2; no terminal reached.
            return _sseResponse('id: 1\ndata: payment_confirmation\n\n'
                'id: 2\ndata: refunding\n\n');
          }
          return _sseResponse('id: 5\ndata: complete\n\n');
        }),
      );

      final stages = await api.transactionStages('tx-2').toList();
      expect(streamCalls, 2);
      // First attempt has no token; the second resumes from event "2".
      expect(seenResumeTokens[0], isNull);
      expect(seenResumeTokens[1], '2');
      expect(stages.first, TransactionStage.paymentConfirmation);
      expect(stages.last, TransactionStage.complete);
    });
  });
}

/// Dio whose transport is a script, so SSE and poll behaviour are testable
/// without a socket. The interceptor short-circuits before any adapter runs.
Dio _stubDio(
  List<RequestOptions> captured,
  dynamic Function(RequestOptions options) handler,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, controller) async {
        captured.add(options);
        try {
          controller.resolve(handler(options) as Response<dynamic>);
        } on DioException catch (e) {
          controller.reject(e);
        }
      },
    ),
  );
  return dio;
}

Response<ResponseBody> _sseResponse(String wire) {
  final chunk = Uint8List.fromList(utf8.encode(wire));
  return Response<ResponseBody>(
    data: ResponseBody(Stream<Uint8List>.value(chunk), 200,
        headers: const {'content-type': ['text/event-stream']}),
    statusCode: 200,
    requestOptions: RequestOptions(path: '/v1/stream/transactions'),
  );
}

Response<Map<String, dynamic>> _jsonResponse(
        String path, Map<String, dynamic> body) =>
    Response<Map<String, dynamic>>(
      data: body,
      statusCode: 200,
      requestOptions: RequestOptions(path: path),
    );
