import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'log_level.dart';
import 'log_record.dart';
import 'log_sink.dart';

/// Debug-build console output. Disabled entirely in release so a distributed
/// binary produces no console noise.
class ConsoleLogSink extends BaseLogSink {
  ConsoleLogSink({super.minimumLevel = LogLevel.debug});

  @override
  Future<void> write(AppLogRecord record) async {
    if (!kDebugMode || !accepts(record)) return;
    developer.log(
      record.message,
      time: record.timestamp,
      name: record.category,
      level: _developerLevel(record.level),
      error: record.error,
    );
  }

  static int _developerLevel(LogLevel level) => switch (level) {
        LogLevel.trace => 300,
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warning => 900,
        LogLevel.error => 1000,
        LogLevel.critical => 1200,
        LogLevel.off => 2000,
      };
}
