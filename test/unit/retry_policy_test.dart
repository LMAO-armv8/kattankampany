import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/utils/retry_policy.dart';

void main() {
  group('RetryPolicy', () {
    // Jitter is deliberate in production but makes assertions fuzzy, so the
    // schedule tests disable it.
    const exact = RetryPolicy(jitterFactor: 0);

    test('attempt 1 runs immediately', () {
      expect(exact.delayBefore(1), Duration.zero);
      expect(exact.delayBefore(0), Duration.zero);
    });

    test('follows the documented 10s / 30s / 2m schedule', () {
      expect(exact.delayBefore(2), const Duration(seconds: 10));
      expect(exact.delayBefore(3), const Duration(seconds: 30));
      expect(exact.delayBefore(4), const Duration(minutes: 2));
    });

    test('doubles past the end of the list and caps at maxDelay', () {
      const policy = RetryPolicy(
        maxAttempts: 10,
        delays: <Duration>[Duration(seconds: 10)],
        maxDelay: Duration(seconds: 45),
        jitterFactor: 0,
      );
      expect(policy.delayBefore(2), const Duration(seconds: 10));
      expect(policy.delayBefore(3), const Duration(seconds: 20));
      expect(policy.delayBefore(4), const Duration(seconds: 40));
      // Capped.
      expect(policy.delayBefore(5), const Duration(seconds: 45));
      expect(policy.delayBefore(9), const Duration(seconds: 45));
    });

    test('stops after maxAttempts', () {
      expect(exact.shouldRetry(3), isTrue);
      expect(exact.shouldRetry(4), isFalse);
      expect(exact.shouldRetry(5), isFalse);
    });

    test('never retries an error that cannot succeed on a second attempt', () {
      expect(
        exact.shouldRetryError(const AuthException(), 1),
        isFalse,
        reason: 'A rejected token will still be rejected next time',
      );
      expect(exact.shouldRetryError(const NotFoundException(), 1), isFalse);
      expect(exact.shouldRetryError(const ConflictException(), 1), isFalse);
      expect(exact.shouldRetryError(const NetworkException(), 1), isTrue);
      expect(exact.shouldRetryError(const ServerException(), 1), isTrue);
    });

    test('jitter stays within the configured band', () {
      const policy = RetryPolicy(jitterFactor: 0.15);
      final random = Random(1234);
      for (var i = 0; i < 200; i++) {
        final delay = policy.delayBefore(2, random: random);
        expect(delay.inMilliseconds, greaterThanOrEqualTo(8500));
        expect(delay.inMilliseconds, lessThanOrEqualTo(11500));
      }
    });

    test('nextAttemptAt is in the future for a retry', () {
      final now = DateTime(2026, 1, 1, 12);
      final at = exact.nextAttemptAt(2, now: now);
      expect(at, now.add(const Duration(seconds: 10)));
    });

    test('summary reads sensibly in the settings screen', () {
      expect(exact.summary, '4 attempts · 10s, 30s, 2m');
      expect(RetryPolicy.never.summary, '1 attempt');
    });
  });

  group('BackoffSchedule', () {
    test('grows geometrically and clamps at the maximum', () {
      final schedule = BackoffSchedule(
        initial: const Duration(seconds: 5),
        maximum: const Duration(seconds: 30),
      );
      expect(schedule.current, const Duration(seconds: 5));
      expect(schedule.advance(), const Duration(seconds: 10));
      expect(schedule.advance(), const Duration(seconds: 20));
      expect(schedule.advance(), const Duration(seconds: 30));
      expect(schedule.advance(), const Duration(seconds: 30));
      schedule.reset();
      expect(schedule.current, const Duration(seconds: 5));
    });
  });
}
