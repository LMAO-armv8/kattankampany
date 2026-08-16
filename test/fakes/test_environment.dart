import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:wc_print_agent/core/config/app_info.dart';
import 'package:wc_print_agent/core/config/app_paths.dart';
import 'package:wc_print_agent/core/config/app_settings.dart';
import 'package:wc_print_agent/core/config/settings_repository.dart';
import 'package:wc_print_agent/core/logging/app_logger.dart';
import 'package:wc_print_agent/core/storage/dao/agent_dao.dart';
import 'package:wc_print_agent/core/storage/dao/idempotency_dao.dart';
import 'package:wc_print_agent/core/storage/dao/print_history_dao.dart';
import 'package:wc_print_agent/core/storage/dao/print_job_dao.dart';
import 'package:wc_print_agent/core/storage/dao/printer_dao.dart';
import 'package:wc_print_agent/core/storage/dao/settings_dao.dart';
import 'package:wc_print_agent/core/storage/dao/store_dao.dart';
import 'package:wc_print_agent/core/storage/database.dart';
import 'package:wc_print_agent/features/agent/domain/store_connection.dart';
import 'package:wc_print_agent/features/printers/domain/printer_device.dart';
import 'package:wc_print_agent/services/printer/printer_manager.dart';
import 'package:wc_print_agent/services/queue/queue_repository.dart';

import 'fakes.dart';

/// A disposable, fully wired stack backed by an in-memory SQLite database.
///
/// Tests get the *real* DAOs, the real queue repository and the real printer
/// manager — only the hardware and the network are faked. That way the
/// duplicate-protection and recovery guarantees are exercised against the
/// actual SQL that ships.
class TestEnvironment {
  TestEnvironment._({
    required this.database,
    required this.settings,
    required this.queue,
    required this.printerService,
    required this.printerManager,
    required this.storeDao,
    required this.agentDao,
    required this.jobDao,
    required this.idempotencyDao,
    required this.tempDir,
    required this.storeId,
  });

  final AppDatabase database;
  final SettingsRepository settings;
  final QueueRepository queue;
  final FakePrinterService printerService;
  final PrinterManager printerManager;
  final StoreDao storeDao;
  final AgentDao agentDao;
  final PrintJobDao jobDao;
  final IdempotencyDao idempotencyDao;
  final Directory tempDir;
  final String storeId;

  static bool _initialised = false;

  /// Must run once per test process before any database is opened.
  static void initialiseSqlite() {
    if (_initialised) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppInfo.debugOverride(AppInfo.forTesting());
    _initialised = true;
  }

  static Future<TestEnvironment> create({
    List<DiscoveredPrinter> printers = const <DiscoveredPrinter>[],
    AppSettings? initialSettings,
  }) async {
    initialiseSqlite();

    final tempDir = await Directory.systemTemp.createTemp('wcpa_test_');
    final paths = await AppPaths.initialize(overrideRoot: tempDir);
    AppPaths.debugOverride(paths);

    final logger = NoopLogger();
    final database = AppDatabase(logger: logger);
    await database.open(path: inMemoryDatabasePath);

    final settingsDao = SettingsDao(database);
    final settings = SettingsRepository(dao: settingsDao, logger: logger);
    await settings.load();
    if (initialSettings != null) await settings.save(initialSettings);

    final storeDao = StoreDao(database);
    final agentDao = AgentDao(database);
    final jobDao = PrintJobDao(database);
    final historyDao = PrintHistoryDao(database);
    final idempotencyDao = IdempotencyDao(database);
    final printerDao = PrinterDao(database);
    final profileDao = PrintProfileDao(database);

    final now = DateTime.now();
    const storeId = 'store-test';
    await storeDao.upsert(
      StoreConnection(
        id: storeId,
        baseUrl: 'https://store.example',
        storeName: 'Test Store',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final printerService = FakePrinterService(
      printers: List<DiscoveredPrinter>.of(printers),
      defaultPrinterKey: printers.isEmpty ? null : printers.first.printerKey,
    );

    final printerManager = PrinterManager(
      service: printerService,
      dao: printerDao,
      profileDao: profileDao,
      settings: settings,
      logger: logger,
      uuid: const Uuid(),
    );
    await printerManager.initialise();

    return TestEnvironment._(
      database: database,
      settings: settings,
      queue: QueueRepository(
        dao: jobDao,
        historyDao: historyDao,
        logger: logger,
      ),
      printerService: printerService,
      printerManager: printerManager,
      storeDao: storeDao,
      agentDao: agentDao,
      jobDao: jobDao,
      idempotencyDao: idempotencyDao,
      tempDir: tempDir,
      storeId: storeId,
    );
  }

  Future<void> dispose() async {
    await printerManager.dispose();
    await queue.dispose();
    await settings.dispose();
    await database.close();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows sometimes holds the folder briefly; harmless in tests.
    }
  }
}
