import 'dart:async';

import '../errors/app_exception.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_sink.dart';
import 'redaction.dart';

/// The application logger.
///
/// * Structured: every record carries a category and a typed context map.
/// * Redacted: [Redaction] runs before any sink sees the record, so tokens and
///   pairing codes cannot reach disk.
/// * Non-throwing: a failing sink is isolated and never propagates.
/// * Non-blocking: sinks buffer internally; call sites do not await.
class AppLogger {
  AppLogger({List<LogSink>? sinks, LogLevel minimumLevel = LogLevel.info})
      : _sinks = sinks ?? <LogSink>[],
        _minimumLevel = minimumLevel;

  final List<LogSink> _sinks;
  LogLevel _minimumLevel;

  LogLevel get minimumLevel => _minimumLevel;

  /// Changes the global floor. Individual sinks may still be stricter.
  set minimumLevel(LogLevel value) {
    _minimumLevel = value;
    for (final sink in _sinks) {
      sink.minimumLevel = value;
    }
  }

  List<LogSink> get sinks => List<LogSink>.unmodifiable(_sinks);

  void addSink(LogSink sink) => _sinks.add(sink);

  T? sinkOfType<T extends LogSink>() {
    for (final sink in _sinks) {
      if (sink is T) return sink;
    }
    return null;
  }

  void trace(String category, String message,
          {Map<String, Object?>? context,}) =>
      log(LogLevel.trace, category, message, context: context);

  void debug(String category, String message,
          {Map<String, Object?>? context,}) =>
      log(LogLevel.debug, category, message, context: context);

  void info(String category, String message,
          {Map<String, Object?>? context,}) =>
      log(LogLevel.info, category, message, context: context);

  void warn(
    String category,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(LogLevel.warning, category, message,
          context: context, error: error, stackTrace: stackTrace,);

  void error(
    String category,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(LogLevel.error, category, message,
          context: context, error: error, stackTrace: stackTrace,);

  void critical(
    String category,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(LogLevel.critical, category, message,
          context: context, error: error, stackTrace: stackTrace,);

  /// Logs an [AppException] with its technical detail attached but its cause
  /// stringified — never the raw object, which could hold a token.
  void exception(
    String category,
    String message,
    Object error, [
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  ]) {
    final app = asAppException(error, stackTrace);
    log(
      app.isRetryable ? LogLevel.warning : LogLevel.error,
      category,
      message,
      context: <String, Object?>{
        ...?context,
        'code': app.code,
        'user_message': app.userMessage,
        if (app.technicalDetail != null) 'detail': app.technicalDetail,
      },
      error: app.toString(),
      stackTrace: stackTrace ?? app.stackTrace,
    );
  }

  void log(
    LogLevel level,
    String category,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_minimumLevel == LogLevel.off || !level.isAtLeast(_minimumLevel)) {
      return;
    }
    final record = AppLogRecord(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      message: Redaction.text(message),
      context: context == null || context.isEmpty
          ? const <String, Object?>{}
          : Redaction.map(context),
      error: error == null ? null : Redaction.text(error.toString()),
      stackTrace: stackTrace?.toString(),
    );
    for (final sink in _sinks) {
      try {
        unawaited(sink.write(record));
      } catch (_) {
        // Isolated: one broken sink must not stop the others.
      }
    }
  }

  Future<void> flush() async {
    for (final sink in _sinks) {
      try {
        await sink.flush();
      } catch (_) {
        /* ignore */
      }
    }
  }

  Future<void> close() async {
    for (final sink in _sinks) {
      try {
        await sink.close();
      } catch (_) {
        /* ignore */
      }
    }
  }
}

/// A logger that discards everything — the default in unit tests.
class NoopLogger extends AppLogger {
  NoopLogger() : super(sinks: <LogSink>[], minimumLevel: LogLevel.off);
}
