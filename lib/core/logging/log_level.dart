/// Severity levels, ordered. A sink emits a record when
/// `record.level.priority >= minimumLevel.priority`.
enum LogLevel {
  trace(0, 'TRACE'),
  debug(1, 'DEBUG'),
  info(2, 'INFO'),
  warning(3, 'WARN'),
  error(4, 'ERROR'),
  critical(5, 'CRIT'),
  off(6, 'OFF');

  const LogLevel(this.priority, this.label);

  final int priority;
  final String label;

  bool isAtLeast(LogLevel other) => priority >= other.priority;

  static LogLevel fromName(String? name, {LogLevel fallback = LogLevel.info}) {
    if (name == null) return fallback;
    for (final level in LogLevel.values) {
      if (level.name.toLowerCase() == name.toLowerCase()) return level;
    }
    return fallback;
  }
}

/// Coarse categories so the log viewer can filter by subsystem.
abstract final class LogCategory {
  static const String app = 'app';
  static const String auth = 'auth';
  static const String agent = 'agent';
  static const String api = 'api';
  static const String sync = 'sync';
  static const String queue = 'queue';
  static const String printing = 'printing';
  static const String printer = 'printer';
  static const String document = 'document';
  static const String storage = 'storage';
  static const String security = 'security';
  static const String tray = 'tray';
  static const String updater = 'updater';
  static const String diagnostics = 'diagnostics';

  static const List<String> all = <String>[
    app,
    auth,
    agent,
    api,
    sync,
    queue,
    printing,
    printer,
    document,
    storage,
    security,
    tray,
    updater,
    diagnostics,
  ];
}
