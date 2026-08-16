import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/config/app_settings.dart';
import 'package:wc_print_agent/core/config/settings_repository.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/errors/error_codes.dart';
import 'package:wc_print_agent/core/logging/app_logger.dart';
import 'package:wc_print_agent/core/logging/log_level.dart';
import 'package:wc_print_agent/core/storage/dao/idempotency_dao.dart';
import 'package:wc_print_agent/core/storage/dao/settings_dao.dart';
import 'package:wc_print_agent/features/print_queue/domain/print_job.dart';
import 'package:wc_print_agent/features/printers/domain/printer_device.dart';
import 'package:wc_print_agent/services/queue/job_processor.dart';

import '../fakes/fakes.dart';
import '../fakes/test_environment.dart';
import 'printer_test.dart' show discovered;
import 'queue_persistence_test.dart' show buildJob;

void main() {
  group('AppSettings', () {
    test('defaults match the documented behaviour', () {
      const settings = AppSettings.defaults;
      expect(settings.syncIntervalSeconds, 3);
      expect(settings.retryMaxAttempts, 4);
      expect(settings.retryDelaysSeconds, <int>[10, 30, 120]);
      expect(settings.startWithWindows, isTrue);
      expect(settings.closeToTray, isTrue);
      expect(settings.recoveryBehaviour, JobRecoveryBehaviour.ask);
      expect(settings.automaticUpdates, isFalse);
    });

    test('the retry policy is derived from the stored values', () {
      const settings = AppSettings(
        retryMaxAttempts: 3,
        retryDelaysSeconds: <int>[5, 15],
      );
      final policy = settings.retryPolicy;
      expect(policy.maxAttempts, 3);
      expect(policy.delays, <Duration>[
        const Duration(seconds: 5),
        const Duration(seconds: 15),
      ]);
    });

    test('sanitising clamps values that would produce a busy loop', () {
      const hostile = AppSettings(
        syncIntervalSeconds: 0,
        connectionTimeoutSeconds: 0,
        retryMaxAttempts: 0,
        retryDelaysSeconds: <int>[],
        printerStatusPollSeconds: 0,
        maxConcurrentJobsPerPrinter: 0,
        maxLogFiles: 0,
      );
      final safe = hostile.sanitised();
      expect(safe.syncIntervalSeconds, greaterThanOrEqualTo(1));
      expect(safe.connectionTimeoutSeconds, greaterThanOrEqualTo(5));
      expect(safe.retryMaxAttempts, greaterThanOrEqualTo(1));
      expect(safe.retryDelaysSeconds, isNotEmpty);
      expect(safe.printerStatusPollSeconds, greaterThanOrEqualTo(5));
      expect(safe.maxConcurrentJobsPerPrinter, greaterThanOrEqualTo(1));
      expect(safe.maxLogFiles, greaterThanOrEqualTo(1));
    });

    test('the maximum idle interval is never shorter than the base interval',
        () {
      const settings = AppSettings(
        syncIntervalSeconds: 60,
        maxIdleIntervalSeconds: 5,
      );
      expect(
        settings.sanitised().maxIdleIntervalSeconds,
        greaterThanOrEqualTo(60),
      );
    });
  });

  group('SettingsRepository', () {
    late TestEnvironment env;

    setUp(() async {
      env = await TestEnvironment.create();
    });
    tearDown(() => env.dispose());

    test('round-trips through SQLite', () async {
      await env.settings.save(
        env.settings.current.copyWith(
          syncIntervalSeconds: 30,
          logLevel: LogLevel.debug,
          defaultPrinterKey: 'Office Printer',
        ),
      );

      final reloaded = SettingsRepository(
        dao: SettingsDao(env.database),
        logger: NoopLogger(),
      );
      final loaded = await reloaded.load();

      expect(loaded.syncIntervalSeconds, 30);
      expect(loaded.logLevel, LogLevel.debug);
      expect(loaded.defaultPrinterKey, 'Office Printer');
      await reloaded.dispose();
    });

    test('a field added in a later build defaults instead of resetting the '
        'rest', () async {
      // Simulate an older installation that never stored the newer key.
      await SettingsDao(env.database).writeAll(<String, dynamic>{
        'sync_interval_seconds': 10,
      });

      final repository = SettingsRepository(
        dao: SettingsDao(env.database),
        logger: NoopLogger(),
      );
      final loaded = await repository.load();

      expect(loaded.syncIntervalSeconds, 10);
      expect(loaded.retryMaxAttempts, AppSettings.defaults.retryMaxAttempts);
      await repository.dispose();
    });

    test('a nullable field can be cleared again', () async {
      await env.settings.save(
        env.settings.current.copyWith(defaultPrinterKey: 'Office'),
      );
      expect(env.settings.current.defaultPrinterKey, 'Office');

      await env.settings.save(
        env.settings.current.copyWith(defaultPrinterKey: null),
      );
      expect(env.settings.current.defaultPrinterKey, isNull);
    });

    test('notifies listeners on change', () async {
      final seen = <int>[];
      final subscription = env.settings.changes
          .listen((AppSettings s) => seen.add(s.syncIntervalSeconds));

      await env.settings.save(
        env.settings.current.copyWith(syncIntervalSeconds: 10),
      );
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(seen, contains(10));
    });
  });

  group('offline behaviour', () {
    late TestEnvironment env;
    late FakeDocumentDownloader downloader;
    late FakeJobReporter reporter;
    late JobProcessor processor;

    setUp(() async {
      env = await TestEnvironment.create(
        printers: <DiscoveredPrinter>[discovered('Office Printer')],
      );
      downloader = FakeDocumentDownloader();
      reporter = FakeJobReporter();
      processor = JobProcessor(
        queue: env.queue,
        printers: env.printerManager,
        printerService: env.printerService,
        downloader: downloader,
        reporter: reporter,
        settings: env.settings,
        leaseOwner: 'test',
      );
    });
    tearDown(() => env.dispose());

    test('a network failure keeps the job and schedules a retry', () async {
      downloader.error = const NetworkException();
      final job = buildJob(
        storeId: env.storeId,
        serverJobId: '8001',
        printerKey: 'Office Printer',
      );
      await env.queue.enqueue(job);

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.retryScheduled);
      final stored = await env.queue.byId(job.id);
      expect(stored, isNotNull, reason: 'Local jobs survive an outage');
      expect(stored!.status, PrintJobStatus.queued);
      expect(stored.errorCode, ErrorCodes.network);
      expect(stored.nextAttemptAt, isNotNull);
    });

    test('a job printed while offline is queued for reporting, not lost',
        () async {
      final job = buildJob(
        storeId: env.storeId,
        serverJobId: '8002',
        printerKey: 'Office Printer',
      );
      await env.queue.enqueue(job);
      await processor.process(job);

      // The reporter is faked, so `reported_at` is still null — exactly the
      // state a real agent is left in when the store is unreachable.
      final unreported = await env.queue.unreported();
      expect(unreported.map((PrintJob j) => j.id), contains(job.id));
      expect((await env.queue.byId(job.id))!.status, PrintJobStatus.completed);
    });

    test('the queue keeps working when the store is unreachable', () async {
      for (var i = 0; i < 3; i++) {
        await env.queue.enqueue(
          buildJob(
            storeId: env.storeId,
            id: 'job-$i',
            serverJobId: '900$i',
            printerKey: 'Office Printer',
          ),
        );
      }
      final jobs = await env.queue.activeAndPending();
      expect(jobs, hasLength(3));

      for (final job in jobs) {
        expect(await processor.process(job), JobOutcome.printed);
      }
      expect(env.printerService.printedRequests, hasLength(3));
    });
  });

  group('idempotency keys', () {
    late TestEnvironment env;

    setUp(() async {
      env = await TestEnvironment.create();
    });
    tearDown(() => env.dispose());

    test('are stable for the same job, action and attempt', () {
      String key(int attempt) => IdempotencyDao.buildKey(
            agentId: 'ag_1',
            serverJobId: '42',
            action: 'complete',
            attempt: attempt,
          );
      expect(key(2), key(2));
      expect(key(2), isNot(key(3)));
      expect(key(2), 'ag_1:42:complete:2');
    });

    test('a recorded report is replayed until it is confirmed', () async {
      const key = 'ag_1:42:complete:1';
      await env.idempotencyDao.record(
        PendingReport(
          key: key,
          jobId: 'job-1',
          action: 'complete',
          payload: const <String, dynamic>{'server_job_id': '42'},
          createdAt: DateTime.now(),
        ),
      );

      expect(await env.idempotencyDao.isConfirmed(key), isFalse);
      expect(
        (await env.idempotencyDao.findPending())
            .map((PendingReport r) => r.key),
        contains(key),
      );

      await env.idempotencyDao.confirm(key);

      expect(await env.idempotencyDao.isConfirmed(key), isTrue);
      expect(await env.idempotencyDao.findPending(), isEmpty);
    });
  });
}
