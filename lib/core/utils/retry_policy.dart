import 'dart:math';

import '../errors/app_exception.dart';

/// How the queue engine spaces out retries.
///
/// Attempt 1 runs immediately. The delay *before* attempt n (n ≥ 2) is
/// `delays[n - 2]` if that index exists, otherwise the last entry doubled for
/// each further attempt, capped at [maxDelay]. Jitter of ±[jitterFactor] is
/// applied so a fleet of agents recovering from an outage does not stampede.
///
/// Default: attempt 1, then +10 s, +30 s, +2 min.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 4,
    this.delays = const <Duration>[
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(minutes: 2),
    ],
    this.maxDelay = const Duration(minutes: 30),
    this.jitterFactor = 0.15,
  });

  final int maxAttempts;
  final List<Duration> delays;
  final Duration maxDelay;
  final double jitterFactor;

  static const RetryPolicy standard = RetryPolicy();

  /// No retries — used for operations whose failure is definitive.
  static const RetryPolicy never = RetryPolicy(
    maxAttempts: 1,
    delays: <Duration>[],
  );

  bool shouldRetry(int attemptCount) => attemptCount < maxAttempts;

  /// Whether a *specific* failure is worth retrying at all. An expired token or
  /// a 404 will never succeed on a second try, so the policy stops immediately.
  bool shouldRetryError(AppException error, int attemptCount) =>
      error.isRetryable && shouldRetry(attemptCount);

  /// Delay before the attempt numbered [nextAttempt] (1-based).
  Duration delayBefore(int nextAttempt, {Random? random}) {
    if (nextAttempt <= 1) return Duration.zero;
    final index = nextAttempt - 2;
    Duration base;
    if (delays.isEmpty) {
      base = const Duration(seconds: 10);
    } else if (index < delays.length) {
      base = delays[index];
    } else {
      final overshoot = index - delays.length + 1;
      final scaled = delays.last.inMilliseconds * pow(2, overshoot);
      base = Duration(milliseconds: scaled.toInt());
    }
    if (base > maxDelay) base = maxDelay;
    return _applyJitter(base, random);
  }

  /// Absolute time at which attempt [nextAttempt] becomes eligible.
  DateTime nextAttemptAt(int nextAttempt, {DateTime? now, Random? random}) =>
      (now ?? DateTime.now()).add(delayBefore(nextAttempt, random: random));

  Duration _applyJitter(Duration base, Random? random) {
    if (jitterFactor <= 0) return base;
    final rng = random ?? _sharedRandom;
    final span = base.inMilliseconds * jitterFactor;
    final offset = (rng.nextDouble() * 2 - 1) * span;
    final result = base.inMilliseconds + offset;
    return Duration(milliseconds: result < 0 ? 0 : result.round());
  }

  static final Random _sharedRandom = Random();

  RetryPolicy copyWith({
    int? maxAttempts,
    List<Duration>? delays,
    Duration? maxDelay,
    double? jitterFactor,
  }) =>
      RetryPolicy(
        maxAttempts: maxAttempts ?? this.maxAttempts,
        delays: delays ?? this.delays,
        maxDelay: maxDelay ?? this.maxDelay,
        jitterFactor: jitterFactor ?? this.jitterFactor,
      );

  /// Human summary for the settings screen: "4 attempts · 10s, 30s, 2m".
  String get summary {
    final parts = delays.map(_formatDuration).join(', ');
    return '$maxAttempts attempt${maxAttempts == 1 ? '' : 's'}'
        '${parts.isEmpty ? '' : ' · $parts'}';
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }
}

/// Backoff used by the sync loop while the store is unreachable — independent
/// of the per-job policy, because a network outage is not a job failure.
class BackoffSchedule {
  BackoffSchedule({
    required this.initial,
    required this.maximum,
    this.multiplier = 2.0,
  }) : _current = initial;

  final Duration initial;
  final Duration maximum;
  final double multiplier;

  Duration _current;

  Duration get current => _current;

  Duration advance() {
    final next = Duration(
      milliseconds: (_current.inMilliseconds * multiplier).round(),
    );
    _current = next > maximum ? maximum : next;
    return _current;
  }

  void reset() => _current = initial;
}
