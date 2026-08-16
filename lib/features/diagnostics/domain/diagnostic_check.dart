/// One line of a diagnostics run.
enum DiagnosticOutcome { pass, warn, fail, skipped, running }

class DiagnosticCheck {
  const DiagnosticCheck({
    required this.id,
    required this.title,
    required this.outcome,
    this.detail,
    this.remedy,
    this.durationMs,
  });

  final String id;
  final String title;
  final DiagnosticOutcome outcome;

  /// What was observed. Safe to show; never contains a token.
  final String? detail;

  /// What the operator should do about it, when there is something to do.
  final String? remedy;

  final int? durationMs;

  DiagnosticCheck copyWith({
    DiagnosticOutcome? outcome,
    String? detail,
    String? remedy,
    int? durationMs,
  }) =>
      DiagnosticCheck(
        id: id,
        title: title,
        outcome: outcome ?? this.outcome,
        detail: detail ?? this.detail,
        remedy: remedy ?? this.remedy,
        durationMs: durationMs ?? this.durationMs,
      );

  static DiagnosticCheck pending(String id, String title) => DiagnosticCheck(
        id: id,
        title: title,
        outcome: DiagnosticOutcome.running,
      );
}

class DiagnosticsReport {
  const DiagnosticsReport({
    required this.checks,
    required this.startedAt,
    this.finishedAt,
  });

  final List<DiagnosticCheck> checks;
  final DateTime startedAt;
  final DateTime? finishedAt;

  bool get isComplete => finishedAt != null;

  bool get hasFailures =>
      checks.any((DiagnosticCheck c) => c.outcome == DiagnosticOutcome.fail);

  bool get hasWarnings =>
      checks.any((DiagnosticCheck c) => c.outcome == DiagnosticOutcome.warn);

  /// An empty report, used before the first run.
  static DiagnosticsReport empty() => DiagnosticsReport(
        checks: const <DiagnosticCheck>[],
        startedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
}
