import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';

import '../../services/api/agent_session.dart';
import '../../services/background/autostart_service.dart';
import '../../services/background/heartbeat_service.dart';
import '../../services/background/lifecycle_controller.dart';
import '../../services/background/sync_service.dart';
import '../../services/background/tray_service.dart';
import '../../services/printer/printer_manager.dart';
import '../../services/printer/printer_service.dart';
import '../../services/printer/strategies/escpos_print_strategy.dart';
import '../../services/printer/strategies/html_print_strategy.dart';
import '../../services/printer/strategies/image_print_strategy.dart';
import '../../services/printer/strategies/pdf_print_strategy.dart';
import '../../services/printer/strategies/print_strategy.dart';
import '../../services/printer/strategies/raw_print_strategy.dart';
import '../../services/printer/strategies/text_print_strategy.dart';
import '../../services/printer/win32/windows_spooler.dart';
import '../../services/printer/windows_printer_service.dart';
import '../../services/queue/document_downloader.dart';
import '../../services/queue/job_processor.dart';
import '../../services/queue/job_reporter.dart';
import '../../services/queue/queue_engine.dart';
import '../../services/queue/queue_repository.dart';
import '../../services/updater/update_service.dart';
import '../config/app_paths.dart';
import '../config/settings_repository.dart';
import '../logging/app_logger.dart';
import '../network/connectivity_monitor.dart';
import '../security/secure_credential_store.dart';
import '../storage/dao/agent_dao.dart';
import '../storage/dao/idempotency_dao.dart';
import '../storage/dao/log_dao.dart';
import '../storage/dao/print_history_dao.dart';
import '../storage/dao/print_job_dao.dart';
import '../storage/dao/printer_dao.dart';
import '../storage/dao/settings_dao.dart';
import '../storage/dao/store_dao.dart';
import '../storage/database.dart';

/// The application's service locator.
///
/// **Division of responsibility, strictly observed:**
///  * GetIt (this file) holds infrastructure and application services — things
///    with a lifetime, a socket, a file handle or a timer.
///  * Riverpod holds reactive UI state, and reads services from here.
///
/// A service must never look up a Riverpod provider. That keeps the whole
/// service layer headless and unit-testable, and it is why the agent keeps
/// printing with no window open.
final GetIt sl = GetIt.instance;

/// Registers everything. Call once, from `bootstrap()`.
///
/// [leaseOwner] is a per-process UUID used to own print leases; a lease held by
/// a different owner is proof the previous process died mid-print.
Future<void> configureDependencies({
  required AppLogger logger,
  required AppPaths paths,
  required AppDatabase database,
  required String leaseOwner,
}) async {
  // ---- Core infrastructure -------------------------------------------------
  sl
    ..registerSingleton<AppLogger>(logger)
    ..registerSingleton<AppPaths>(paths)
    ..registerSingleton<AppDatabase>(database)
    ..registerSingleton<Uuid>(const Uuid());

  // ---- DAOs ----------------------------------------------------------------
  sl
    ..registerLazySingleton<SettingsDao>(() => SettingsDao(sl()))
    ..registerLazySingleton<StoreDao>(() => StoreDao(sl()))
    ..registerLazySingleton<AgentDao>(() => AgentDao(sl()))
    ..registerLazySingleton<PrinterDao>(() => PrinterDao(sl()))
    ..registerLazySingleton<PrintProfileDao>(() => PrintProfileDao(sl()))
    ..registerLazySingleton<PrintJobDao>(() => PrintJobDao(sl()))
    ..registerLazySingleton<PrintHistoryDao>(() => PrintHistoryDao(sl()))
    ..registerLazySingleton<IdempotencyDao>(() => IdempotencyDao(sl()))
    ..registerLazySingleton<LogDao>(() => LogDao(sl()));

  // ---- Settings ------------------------------------------------------------
  final settings = SettingsRepository(dao: sl<SettingsDao>(), logger: logger);
  await settings.load();
  logger.minimumLevel = settings.current.logLevel;
  sl.registerSingleton<SettingsRepository>(settings);

  // ---- Security ------------------------------------------------------------
  sl.registerLazySingleton<SecureCredentialStore>(
    () => createCredentialStore(paths: paths, logger: logger),
  );

  // ---- Network -------------------------------------------------------------
  sl.registerLazySingleton<ConnectivityMonitor>(
    () => ConnectivityMonitor(logger: logger),
  );

  // ---- Session -------------------------------------------------------------
  sl.registerLazySingleton<AgentSession>(
    () => AgentSession(
      storeDao: sl(),
      agentDao: sl(),
      credentialStore: sl(),
      settings: sl(),
      connectivity: sl(),
      logger: logger,
    ),
  );

  // ---- Printing ------------------------------------------------------------
  sl.registerLazySingleton<WindowsSpooler>(() => WindowsSpooler());

  sl.registerLazySingleton<PrintStrategyRegistry>(() {
    final pdf = PdfPrintStrategy(logger: logger);
    final image = ImagePrintStrategy(pdfStrategy: pdf, logger: logger);
    final text = TextPrintStrategy(pdfStrategy: pdf, logger: logger);
    final raw = RawPrintStrategy(spooler: sl<WindowsSpooler>(), logger: logger);
    final html = HtmlPrintStrategy(
      pdfStrategy: pdf,
      textStrategy: text,
      logger: logger,
    );
    final escpos = EscPosPrintStrategy(rawStrategy: raw, logger: logger);
    final spooler = SpoolerPrintStrategy(
      pdfStrategy: pdf,
      imageStrategy: image,
    );
    // Order matters for `auto` resolution: the first strategy that declares the
    // document type wins.
    return PrintStrategyRegistry(<PrintStrategy>[
      pdf,
      image,
      text,
      html,
      raw,
      spooler,
      escpos,
    ]);
  });

  sl.registerLazySingleton<PrinterService>(() {
    if (!Platform.isWindows) {
      return const UnsupportedPrinterService(
        reason: 'This build prints through the Windows spooler. '
            'Printing is disabled on this platform.',
      );
    }
    return WindowsPrinterService(
      spooler: sl<WindowsSpooler>(),
      strategies: sl<PrintStrategyRegistry>(),
      logger: logger,
    );
  });

  sl.registerLazySingleton<PrinterManager>(
    () => PrinterManager(
      service: sl(),
      dao: sl(),
      profileDao: sl(),
      settings: sl(),
      logger: logger,
    ),
  );

  // ---- Queue ---------------------------------------------------------------
  sl
    ..registerLazySingleton<QueueRepository>(
      () => QueueRepository(dao: sl(), historyDao: sl(), logger: logger),
    )
    ..registerLazySingleton<DocumentDownloader>(
      () => DocumentDownloader(
        session: sl(),
        settings: sl(),
        paths: paths,
        logger: logger,
      ),
    )
    ..registerLazySingleton<JobReporter>(
      () => JobReporter(
        session: sl(),
        queue: sl(),
        idempotency: sl(),
        logger: logger,
      ),
    )
    ..registerLazySingleton<JobProcessor>(
      () => JobProcessor(
        queue: sl(),
        printers: sl(),
        printerService: sl(),
        downloader: sl(),
        reporter: sl(),
        settings: sl(),
        leaseOwner: leaseOwner,
        logger: logger,
      ),
    )
    ..registerLazySingleton<QueueEngine>(
      () => QueueEngine(
        queue: sl(),
        processor: sl(),
        printers: sl(),
        settings: sl(),
        leaseOwner: leaseOwner,
        logger: logger,
      ),
    );

  // ---- Background ----------------------------------------------------------
  sl
    ..registerLazySingleton<SyncService>(
      () => SyncService(
        session: sl(),
        queue: sl(),
        engine: sl(),
        reporter: sl(),
        settings: sl(),
        connectivity: sl(),
        logger: logger,
      ),
    )
    ..registerLazySingleton<HeartbeatService>(
      () => HeartbeatService(
        session: sl(),
        printers: sl(),
        queue: sl(),
        settings: sl(),
        agentDao: sl(),
        logger: logger,
      ),
    )
    ..registerLazySingleton<AutostartService>(
      () => Platform.isWindows
          ? WindowsAutostartService(logger: logger)
          : const NoopAutostartService(),
    )
    ..registerLazySingleton<UpdateService>(() => NoopUpdateService(logger: logger));

  // ---- Tray + lifecycle ----------------------------------------------------
  // The tray needs the controller and the controller needs the tray, so the
  // tray is constructed with a late-bound handler.
  late final LifecycleController controller;
  final tray = TrayService(
    logger: logger,
    onAction: (TrayAction action) => controller.handleTrayAction(action),
  );
  sl.registerSingleton<TrayService>(tray);

  controller = LifecycleController(
    session: sl(),
    settings: sl(),
    printers: sl(),
    queue: sl(),
    engine: sl(),
    sync: sl(),
    heartbeat: sl(),
    reporter: sl(),
    connectivity: sl(),
    autostart: sl(),
    updater: sl(),
    tray: tray,
    logger: logger,
  );
  sl.registerSingleton<LifecycleController>(controller);
}

/// Tears everything down in reverse dependency order. Used on exit and in tests.
Future<void> disposeDependencies() async {
  if (sl.isRegistered<LifecycleController>()) {
    await sl<LifecycleController>().dispose();
  }
  if (sl.isRegistered<TrayService>()) await sl<TrayService>().dispose();
  if (sl.isRegistered<SyncService>()) await sl<SyncService>().dispose();
  if (sl.isRegistered<QueueEngine>()) await sl<QueueEngine>().dispose();
  if (sl.isRegistered<QueueRepository>()) await sl<QueueRepository>().dispose();
  if (sl.isRegistered<PrinterManager>()) await sl<PrinterManager>().dispose();
  if (sl.isRegistered<ConnectivityMonitor>()) {
    await sl<ConnectivityMonitor>().dispose();
  }
  if (sl.isRegistered<AgentSession>()) await sl<AgentSession>().dispose();
  if (sl.isRegistered<SettingsRepository>()) {
    await sl<SettingsRepository>().dispose();
  }
  if (sl.isRegistered<AppLogger>()) await sl<AppLogger>().close();
  if (sl.isRegistered<AppDatabase>()) await sl<AppDatabase>().close();
  await sl.reset();
}
