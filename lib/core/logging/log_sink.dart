import 'log_level.dart';
import 'log_record.dart';

/// A destination for log records. Sinks must never throw — a broken sink must
/// not be able to take down the agent.
abstract class LogSink {
  /// Records below this level are dropped by the sink.
  LogLevel get minimumLevel;
  set minimumLevel(LogLevel value);

  Future<void> write(AppLogRecord record);

  /// Flush any buffered records. Called on shutdown and by "Export logs".
  Future<void> flush() async {}

  Future<void> close() async {}
}

abstract class BaseLogSink implements LogSink {
  BaseLogSink({LogLevel minimumLevel = LogLevel.info})
      : _minimumLevel = minimumLevel;

  LogLevel _minimumLevel;

  @override
  LogLevel get minimumLevel => _minimumLevel;

  @override
  set minimumLevel(LogLevel value) => _minimumLevel = value;

  bool accepts(AppLogRecord record) =>
      _minimumLevel != LogLevel.off &&
      record.level.isAtLeast(_minimumLevel);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
