import 'package:flutter_test/flutter_test.dart';
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
}
