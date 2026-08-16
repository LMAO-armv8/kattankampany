import 'dart:convert';

import 'log_level.dart';

/// One structured log entry. Context is a flat map of primitives so it can be
/// written as JSON to the file sink and as a TEXT column to SQLite.
class AppLogRecord {
  AppLogRecord({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.context = const <String, Object?>{},
    this.error,
    this.stackTrace,
    this.id,
  });

  final int? id;
  final DateTime timestamp;
  final LogLevel level;
  final String category;
  final String message;
  final Map<String, Object?> context;
  final String? error;
  final String? stackTrace;

  String get contextJson => context.isEmpty ? '{}' : jsonEncode(context);

  /// Single-line, machine-parseable representation used by the file sink.
  String toLogLine() {
    final buffer = StringBuffer()
      ..write(timestamp.toUtc().toIso8601String())
      ..write(' [')
      ..write(level.label.padRight(5))
      ..write('] ')
      ..write(category.padRight(11))
      ..write(' ')
      ..write(message);
    if (context.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(contextJson);
    }
    if (error != null) {
      buffer
        ..write(' | error=')
        ..write(error);
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    return buffer.toString();
  }

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'timestamp': timestamp.millisecondsSinceEpoch,
        'level': level.name,
        'category': category,
        'message': message,
        'context_json': contextJson,
        'error': error,
        'stack_trace': stackTrace,
      };

  static AppLogRecord fromDatabaseRow(Map<String, Object?> row) {
    Map<String, Object?> context = const <String, Object?>{};
    final raw = row['context_json'] as String?;
    if (raw != null && raw.isNotEmpty && raw != '{}') {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) context = decoded.cast<String, Object?>();
      } catch (_) {
        context = <String, Object?>{'_raw': raw};
      }
    }
    return AppLogRecord(
      id: row['id'] as int?,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch((row['timestamp'] as int?) ?? 0),
      level: LogLevel.fromName(row['level'] as String?),
      category: (row['category'] as String?) ?? LogCategory.app,
      message: (row['message'] as String?) ?? '',
      context: context,
      error: row['error'] as String?,
      stackTrace: row['stack_trace'] as String?,
    );
  }
}
