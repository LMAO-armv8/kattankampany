import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/errors/error_codes.dart';
import 'package:wc_print_agent/features/print_queue/domain/print_job.dart';
import 'package:wc_print_agent/features/printers/domain/printer_device.dart';
import 'package:wc_print_agent/features/printers/domain/printer_status.dart';
import 'package:wc_print_agent/features/printing/domain/print_request.dart';
import 'package:wc_print_agent/services/queue/job_processor.dart';

import '../fakes/fakes.dart';
import '../fakes/test_environment.dart';
import 'printer_test.dart' show discovered;
import 'queue_persistence_test.dart' show buildJob;

void main() {
  late TestEnvironment env;
  late FakeDocumentDownloader downloader;
  late FakeJobReporter reporter;
  late JobProcessor processor;

  const leaseOwner = 'test-process';

  setUp(() async {
    env = await TestEnvironment.create(
      printers: <DiscoveredPrinter>[
        discovered('Thermal Printer'),
        discovered('Office Printer', isDefault: true),
      ],
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
      leaseOwner: leaseOwner,
    );
  });

  tearDown(() => env.dispose());

  Future<PrintJob> enqueue({
    String id = 'job-1',
    String serverJobId = '1',
    String? printerKey = 'Thermal Printer',
    bool allowFallback = false,
  }) async {
    final job = buildJob(
      storeId: env.storeId,
      id: id,
      serverJobId: serverJobId,
      printerKey: printerKey,
    ).copyWith(allowFallback: allowFallback);
    await env.queue.enqueue(job);
    return job;
  }

  group('print history', () {
    test('a successful print appears in history straight away', () async {
      // History used to be filled only by the retention sweep, which archives
      // jobs old enough to leave the queue. A job printed a minute ago was
      // therefore invisible for thirty days, and a successful print looked as
      // though it had left no record at all.
      final job = await enqueue();

      expect(await env.queue.history(), isEmpty);

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.printed);

      final history = await env.queue.history();
      expect(history, hasLength(1));
      expect(history.single.id, job.id);
      expect(history.single.status, 'completed');
      expect(history.single.succeeded, isTrue);
    });

    test('a job that gives up is recorded too', () async {
      // What did not print, and why, is exactly what an operator opens History
      // to find out. One attempt allowed, so the first failure is terminal
      // rather than scheduling a retry.
      final job = buildJob(
        storeId: env.storeId,
        printerKey: 'No Such Printer',
      ).copyWith(maxAttempts: 1);
      await env.queue.enqueue(job);

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.failedPermanently);

      final history = await env.queue.history();
      expect(history, hasLength(1));
      expect(history.single.status, 'failed');
      expect(history.single.errorCode, ErrorCodes.printerNotFound);
    });

    test('the printed document is kept so it can be opened', () async {
      final job = await enqueue();

      await processor.process(job);

      final history = await env.queue.history();
      expect(
        history.single.documentPath,
        isNotNull,
        reason: 'History offers to open what actually went to the printer',
      );
    });
  });

  group('successful print', () {
    test('runs the pipeline end to end and reports completion', () async {
      final job = await enqueue();

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.printed);
      expect(downloader.resolved, contains(job.id));
      expect(env.printerService.printedRequests, hasLength(1));
      expect(
        env.printerService.printedRequests.first.printerKey,
        'Thermal Printer',
      );

      final stored = await env.queue.byId(job.id);
      expect(stored!.status, PrintJobStatus.completed);
      expect(stored.resolvedPrinterKey, 'Thermal Printer');
      expect(stored.attemptCount, 1);
      expect(stored.completedAt, isNotNull);
      expect(stored.leaseOwner, isNull);

      expect(reporter.starts, contains(job.id));
      expect(reporter.completions, contains(job.id));
    });

    test('passes copies and the document title through to the printer',
        () async {
      final job = (await enqueue()).copyWith(copies: 3);
      await env.queue.update(job);

      await processor.process(job);

      final request = env.printerService.printedRequests.single;
      expect(request.copies, 3);
      expect(request.documentTitle, contains('#5591'));
    });

    test('uses the printer\'s default profile when the job has none', () async {
      await env.printerManager
          .setDefaultProfile('Thermal Printer', 'profile_label_4x6');
      final job = await enqueue();

      await processor.process(job);

      final request = env.printerService.printedRequests.single;
      expect(request.profile.name, '4x6 Label');
      expect(request.profile.effectiveWidthMm, closeTo(101.6, 0.01));
    });
  });

  group('failed print', () {
    test('a spooler failure schedules a retry within the attempt ceiling',
        () async {
      env.printerService.scriptedResults.add(
        const PrintResult.failed(
          errorCode: ErrorCodes.spoolerError,
          errorMessage: 'The printer would not accept the document.',
        ),
      );
      final job = await enqueue();

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.retryScheduled);
      final stored = await env.queue.byId(job.id);
      expect(stored!.status, PrintJobStatus.queued);
      expect(stored.errorCode, ErrorCodes.spoolerError);
      expect(stored.nextAttemptAt, isNotNull);
      expect(stored.nextAttemptAt!.isAfter(DateTime.now()), isTrue);
      expect(reporter.failures.single.willRetry, isTrue);
    });

    test('gives up once the attempt ceiling is reached', () async {
      await env.settings.save(env.settings.current.copyWith(retryMaxAttempts: 1));

      env.printerService.scriptedResults.add(
        const PrintResult.failed(
          errorCode: ErrorCodes.spoolerError,
          errorMessage: 'nope',
        ),
      );
      // maxAttempts is snapshotted at insert time, so build the job after the
      // setting changed.
      final job = buildJob(
        storeId: env.storeId,
        serverJobId: '99',
        printerKey: 'Thermal Printer',
      ).copyWith(maxAttempts: 1);
      await env.queue.enqueue(job);

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.failedPermanently);
      final stored = await env.queue.byId(job.id);
      expect(stored!.status, PrintJobStatus.failed);
      expect(reporter.failures.single.willRetry, isFalse);
    });

    test('a document error fails the job without ever reaching the printer',
        () async {
      downloader.error = const DocumentException(
        userMessage: 'The document failed its integrity check.',
        code: ErrorCodes.documentInvalid,
      );
      final job = await enqueue();

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.retryScheduled);
      expect(env.printerService.printedRequests, isEmpty);
      final stored = await env.queue.byId(job.id);
      expect(stored!.errorCode, ErrorCodes.documentInvalid);
    });

    test('an untrusted document origin is never retried', () async {
      downloader.error = const DocumentException(
        userMessage: 'The document is hosted somewhere other than your store.',
        code: ErrorCodes.documentUntrustedOrigin,
        retryable: false,
      );
      final job = await enqueue();

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.failedPermanently);
      expect(env.printerService.printedRequests, isEmpty);
    });
  });

  group('printer assignment', () {
    test('an unavailable printer fails the job rather than substituting',
        () async {
      final job = await enqueue(printerKey: 'Missing Printer');

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.retryScheduled);
      expect(
        env.printerService.printedRequests,
        isEmpty,
        reason: 'Nothing may be printed on a device the server did not choose',
      );
      final stored = await env.queue.byId(job.id);
      expect(stored!.errorCode, ErrorCodes.printerNotFound);
      expect(stored.errorMessage, contains('Printer unavailable'));
    });

    test('uses the fallback printer when the job permits it', () async {
      await env.settings.save(
        env.settings.current.copyWith(fallbackPrinterKey: 'Office Printer'),
      );
      final job = await enqueue(
        printerKey: 'Missing Printer',
        allowFallback: true,
      );

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.printed);
      expect(
        env.printerService.printedRequests.single.printerKey,
        'Office Printer',
      );
      expect((await env.queue.byId(job.id))!.resolvedPrinterKey,
          'Office Printer',);
    });

    test('a printer that goes offline between resolution and printing fails '
        'the job', () async {
      env.printerService.availability['Thermal Printer'] = false;
      env.printerService.printers = <DiscoveredPrinter>[
        discovered('Thermal Printer', state: PrinterState.outOfPaper),
        discovered('Office Printer', isDefault: true),
      ];
      final job = await enqueue();

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.retryScheduled);
      expect(env.printerService.printedRequests, isEmpty);
      final stored = await env.queue.byId(job.id);
      expect(stored!.errorCode, ErrorCodes.printerOffline);
    });
  });

  group('duplicate protection', () {
    test('a job already recorded as completed is never printed again',
        () async {
      final job = await enqueue();
      await processor.process(job);
      expect(env.printerService.printedRequests, hasLength(1));

      // Simulate the engine picking the same row up a second time.
      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.skipped);
      expect(
        env.printerService.printedRequests,
        hasLength(1),
        reason: 'The completed-state guard must stop a second spool',
      );
    });

    test('the server re-offering a known job does not create a second row',
        () async {
      final job = await enqueue(id: 'first', serverJobId: '777');
      await processor.process(job);

      final reoffered = buildJob(
        storeId: env.storeId,
        id: 'second',
        serverJobId: '777',
        printerKey: 'Thermal Printer',
      );
      expect(await env.queue.enqueue(reoffered), isFalse);
      expect(await env.queue.byId('second'), isNull);
      expect(env.printerService.printedRequests, hasLength(1));
    });

    test('an interrupted job is skipped until the operator decides', () async {
      final job = await enqueue();
      await env.queue.setStatus(job.id, PrintJobStatus.interrupted);

      final outcome = await processor.process(job);

      expect(outcome, JobOutcome.skipped);
      expect(env.printerService.printedRequests, isEmpty);
    });
  });
}
