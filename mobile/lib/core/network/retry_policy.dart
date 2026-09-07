import 'dart:math';
import 'package:uuid/uuid.dart';

/// Generates UUIDv4 idempotency keys. Preserved across retries of the
/// same logical operation (plan §3.9, §4.9).
class IdempotencyKeys {
  static final Uuid _uuid = Uuid();

  /// Create a fresh key for a new payment/fetch operation.
  static String create() => _uuid.v4();
}

/// Exponential backoff with randomized jitter.
///
/// Plan §3.9: base delay 1.5s, max 3 retries. Jitter guards against
/// thundering-herd on retry after tower handoffs.
class BackoffPolicy {
  BackoffPolicy({
    this.baseDelay = const Duration(milliseconds: 1500),
    this.maxRetries = 3,
    this.maxDelay = const Duration(seconds: 12),
    this.multiplier = 2.0,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Duration baseDelay;
  final int maxRetries;
  final Duration maxDelay;
  final double multiplier;
  final Random _random;

  int _attempt = 0;

  /// Remaining retries before exhaustion.
  int get remaining => maxRetries - _attempt;

  bool get exhausted => _attempt >= maxRetries;

  /// Compute the delay before the next attempt (full jitter).
  Duration nextDelay() {
    _attempt++;
    final exponential = baseDelay * pow(multiplier, _attempt - 1).toDouble();
    final capped = exponential > maxDelay ? maxDelay : exponential;
    final jitterMs = _random.nextInt(capped.inMilliseconds + 1);
    return Duration(milliseconds: jitterMs);
  }

  /// Reset for a new logical operation.
  void reset() => _attempt = 0;
}

/// Outcome of a retryable network operation.
sealed class RetryResult<T> {
  const RetryResult();
}

class RetrySuccess<T> extends RetryResult<T> {
  const RetrySuccess(this.value);
  final T value;
}

class RetryExhausted<T> extends RetryResult<T> {
  const RetryExhausted(this.lastError);
  final Object lastError;
}

/// Runs [operation] with exponential backoff + jitter. The operation
/// receives the current attempt (0-based) so callers can rotate
/// idempotency keys appropriately — they should NOT rotate per retry;
/// the same key must be reused across attempts for dedup.
Future<RetryResult<T>> retryWithBackoff<T>(
  Future<T> Function() operation, {
  BackoffPolicy? policy,
  bool Function(Object error)? isRetryable,
}) async {
  final p = policy ?? BackoffPolicy();
  p.reset();

  while (true) {
    try {
      return RetrySuccess(await operation());
    } catch (e) {
      final retryable = isRetryable?.call(e) ?? true;
      if (!retryable || p.exhausted) {
        return RetryExhausted(e);
      }
      await Future<void>.delayed(p.nextDelay());
    }
  }
}
