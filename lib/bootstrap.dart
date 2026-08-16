import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'core/config/app_info.dart';
import 'core/config/app_paths.dart';
import 'core/config/app_settings.dart';
import 'core/config/settings_repository.dart';
import 'core/di/service_locator.dart';
import 'core/logging/app_logger.dart';
import 'core/logging/console_log_sink.dart';
import 'core/logging/database_log_sink.dart';
import 'core/logging/file_log_sink.dart';
import 'core/logging/log_level.dart';
import 'core/logging/log_sink.dart';
import 'core/storage/dao/log_dao.dart';
import 'core/storage/database.dart';
import 'services/api/agent_session.dart';

/// What [bootstrap] produced, for `main` to act on.
class BootstrapResult {
  const BootstrapResult({
    required this.logger,
    required this.paths,
    required this.database,
    required this.leaseOwner,
    required this.isPaired,
    required this.settings,
  });

  final AppLogger logger;
  final AppPaths paths;
  final AppDatabase database;

  /// Per-process identifier that owns print leases for this run. A lease held
  /// by a *different* owner is proof the previous process died mid-print.
  final String leaseOwner;

  final bool isPaired;
  final AppSettings settings;
}

/// Ordered application startup.
///
/// The sequence matters:
///   1. identity and paths — the file log sink needs a directory to exist
///   2. logging — so a migration failure is recorded rather than lost
///   3. database — settings live in it
///   4. dependency injection — services need settings
///   5. database log sink — needs the DAOs registered in step 4
///   6. session restore — needs everything above
Future<BootstrapResult> bootstrap({
  Directory? overrideRoot,
  String? databasePath,
}) async {
  // 1 ---------------------------------------------------------------------
  await AppInfo.initialize();
  final paths = await AppPaths.initialize(overrideRoot: overrideRoot);

  // 2 ---------------------------------------------------------------------
  final fileSink = FileLogSink(paths: paths, minimumLevel: LogLevel.info);
  final sinks = <LogSink>[
    if (kDebugMode) ConsoleLogSink(),
    fileSink,
  ];
  final logger = AppLogger(
    sinks: sinks,
    minimumLevel: kDebugMode ? LogLevel.debug : LogLevel.info,
  );

  logger.info(
    LogCategory.app,
    '${AppInfo.productName} starting',
    context: <String, Object?>{
      'version': AppInfo.instance.fullVersion,
      'machine': AppInfo.instance.machineName,
      'os': AppInfo.instance.osDescription,
      'data_dir': paths.root.path,
    },
  );

  // 3 ---------------------------------------------------------------------
  final database = AppDatabase(logger: logger);
  await database.open(path: databasePath);

  // 4 ---------------------------------------------------------------------
  final leaseOwner = const Uuid().v4();
  await configureDependencies(
    logger: logger,
    paths: paths,
    database: database,
    leaseOwner: leaseOwner,
  );

  // 5 ---------------------------------------------------------------------
  final settings = sl<SettingsRepository>().current;
  logger.addSink(
    DatabaseLogSink(
      dao: sl<LogDao>(),
      minimumLevel: settings.logLevel,
      maxRows: settings.maxLogRows,
    ),
  );
  fileSink
    ..maxFileSizeBytes = settings.maxLogFileSizeBytes
    ..maxFiles = settings.maxLogFiles;
  // Applies the configured floor to every sink at once.
  logger.minimumLevel = settings.logLevel;

  // 6 ---------------------------------------------------------------------
  final isPaired = await sl<AgentSession>().restore();

  return BootstrapResult(
    logger: logger,
    paths: paths,
    database: database,
    leaseOwner: leaseOwner,
    isPaired: isPaired,
    settings: settings,
  );
}
