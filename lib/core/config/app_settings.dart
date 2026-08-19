import 'package:freezed_annotation/freezed_annotation.dart';

import '../logging/log_level.dart';
import '../utils/retry_policy.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

/// What to do with a job that was `printing` when the agent stopped.
///
/// The default is [ask] because reprinting a shipping label that already came
/// out of the printer costs money and reprinting an invoice confuses customers.
enum JobRecoveryBehaviour {
  @JsonValue('ask')
  ask,
  @JsonValue('mark_printed')
  markPrinted,
  @JsonValue('reprint')
  reprint;

  String get label => switch (this) {
        JobRecoveryBehaviour.ask => 'Ask me (recommended)',
        JobRecoveryBehaviour.markPrinted => 'Assume it printed',
        JobRecoveryBehaviour.reprint => 'Print it again',
      };

  String get description => switch (this) {
        JobRecoveryBehaviour.ask =>
          'Interrupted jobs wait for you to confirm whether they printed.',
        JobRecoveryBehaviour.markPrinted =>
          'Interrupted jobs are reported as completed without reprinting.',
        JobRecoveryBehaviour.reprint =>
          'Interrupted jobs are printed again. May produce duplicates.',
      };
}

enum AppThemeMode {
  @JsonValue('system')
  system,
  @JsonValue('light')
  light,
  @JsonValue('dark')
  dark;

  String get label => switch (this) {
        AppThemeMode.system => 'Match Windows',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };
}

/// Every user-configurable value in one immutable object.
///
/// Persisted one field per row in the `settings` table (key = the snake_case
/// JSON name), so a new field defaults sensibly on an existing installation
/// instead of resetting everything.
@freezed
class AppSettings with _$AppSettings {
  const factory AppSettings({
    // ---- General ----------------------------------------------------------
    @Default(true) bool startWithWindows,
    @Default(true) bool minimizeToTray,
    @Default(false) bool startMinimized,

    /// Closing the window keeps the agent running in the tray. Turning this off
    /// means the X button really does stop printing.
    @Default(true) bool closeToTray,

    /// Ask Windows not to sleep while the agent is running.
    ///
    /// On by default because an agent that only receives orders while somebody
    /// is at the keyboard is not doing its job. Turn it off on a laptop that
    /// should sleep on battery.
    @Default(true) bool keepComputerAwake,
    @Default(AppThemeMode.system) AppThemeMode themeMode,

    // ---- Connection -------------------------------------------------------
    /// Base poll interval in seconds. Presets: 3, 5, 10, 30, 60.
    @Default(3) int syncIntervalSeconds,
    @Default(20) int connectionTimeoutSeconds,
    @Default(60) int heartbeatIntervalSeconds,

    /// Widen the poll interval while the queue stays empty, to cut idle traffic.
    @Default(true) bool idleBackoffEnabled,
    @Default(4) int idleBackoffAfterEmptyPolls,
    @Default(30) int maxIdleIntervalSeconds,
    @Default(30) int offlineRetryIntervalSeconds,

    // ---- Printing ---------------------------------------------------------
    /// How many times a job is attempted before it is left as failed.
    ///
    /// Ten rather than a handful because the failures that matter here are
    /// transient — the store asleep, a claim being reaped, a printer switched
    /// off for a minute — and each attempt is spaced by the retry delays below,
    /// so ten attempts spans a long while rather than ten rapid retries.
    @Default(10) int retryMaxAttempts,
    @Default(<int>[10, 30, 120]) List<int> retryDelaysSeconds,

    /// Used when the server does not name a printer.
    String? defaultPrinterKey,

    /// Only ever used when the *job* sets `allow_fallback`.
    String? fallbackPrinterKey,
    @Default(15) int printerStatusPollSeconds,
    @Default(1) int maxConcurrentJobsPerPrinter,
    @Default(50 * 1024 * 1024) int maxDocumentSizeBytes,
    @Default(JobRecoveryBehaviour.ask) JobRecoveryBehaviour recoveryBehaviour,

    /// Show a Windows notification when a job fails.
    @Default(true) bool notifyOnFailure,

    // ---- Logs -------------------------------------------------------------
    @Default(LogLevel.info) LogLevel logLevel,
    @Default(5 * 1024 * 1024) int maxLogFileSizeBytes,
    @Default(5) int maxLogFiles,
    @Default(5000) int maxLogRows,

    // ---- History ----------------------------------------------------------
    @Default(30) int historyRetentionDays,
    @Default(20000) int maxHistoryRows,

    // ---- Updates ----------------------------------------------------------
    @Default(false) bool automaticUpdates,
    @Default(24) int updateCheckIntervalHours,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsFromJson(json);

  static const AppSettings defaults = AppSettings();

  Duration get syncInterval => Duration(seconds: syncIntervalSeconds);
  Duration get connectionTimeout => Duration(seconds: connectionTimeoutSeconds);
  Duration get heartbeatInterval => Duration(seconds: heartbeatIntervalSeconds);
  Duration get maxIdleInterval => Duration(seconds: maxIdleIntervalSeconds);
  Duration get offlineRetryInterval =>
      Duration(seconds: offlineRetryIntervalSeconds);
  Duration get printerStatusPollInterval =>
      Duration(seconds: printerStatusPollSeconds);
  Duration get updateCheckInterval => Duration(hours: updateCheckIntervalHours);

  RetryPolicy get retryPolicy => RetryPolicy(
        maxAttempts: retryMaxAttempts,
        delays: retryDelaysSeconds
            .map((int s) => Duration(seconds: s))
            .toList(growable: false),
      );

  /// The intervals offered in Settings → Connection.
  static const List<int> syncIntervalPresets = <int>[3, 5, 10, 30, 60];

  /// Clamps every value into a range the agent can actually honour, so a hand
  /// edited settings row cannot produce a busy loop or a 0-attempt retry policy.
  AppSettings sanitised() => copyWith(
        syncIntervalSeconds: syncIntervalSeconds.clamp(1, 3600),
        connectionTimeoutSeconds: connectionTimeoutSeconds.clamp(5, 300),
        heartbeatIntervalSeconds: heartbeatIntervalSeconds.clamp(15, 3600),
        idleBackoffAfterEmptyPolls: idleBackoffAfterEmptyPolls.clamp(1, 1000),
        maxIdleIntervalSeconds:
            maxIdleIntervalSeconds.clamp(syncIntervalSeconds.clamp(1, 3600), 3600),
        offlineRetryIntervalSeconds: offlineRetryIntervalSeconds.clamp(5, 3600),
        retryMaxAttempts: retryMaxAttempts.clamp(1, 20),
        retryDelaysSeconds: retryDelaysSeconds.isEmpty
            ? const <int>[10]
            : retryDelaysSeconds
                .map((int s) => s.clamp(1, 86400))
                .toList(growable: false),
        printerStatusPollSeconds: printerStatusPollSeconds.clamp(5, 3600),
        maxConcurrentJobsPerPrinter: maxConcurrentJobsPerPrinter.clamp(1, 8),
        maxDocumentSizeBytes:
            maxDocumentSizeBytes.clamp(64 * 1024, 512 * 1024 * 1024),
        maxLogFileSizeBytes:
            maxLogFileSizeBytes.clamp(256 * 1024, 128 * 1024 * 1024),
        maxLogFiles: maxLogFiles.clamp(1, 50),
        maxLogRows: maxLogRows.clamp(100, 200000),
        historyRetentionDays: historyRetentionDays.clamp(1, 3650),
        maxHistoryRows: maxHistoryRows.clamp(100, 1000000),
        updateCheckIntervalHours: updateCheckIntervalHours.clamp(1, 720),
      );
}
