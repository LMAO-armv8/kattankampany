import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/features/print_queue/domain/print_job.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printing/domain/print_document.dart';

import '../fakes/test_environment.dart';

PrintJob buildJob({
  required String storeId,
  String id = 'job-1',
  String serverJobId = '1001',
  PrintJobStatus status = PrintJobStatus.queued,
  String? printerKey,
  int priority = 0,
  int attemptCount = 0,
  DateTime? nextAttemptAt,
  DateTime? createdAt,
}) =>
    PrintJob(
      id: id,
      storeId: storeId,
      serverJobId: serverJobId,
      orderId: '5591',
      orderReference: '#5591',
      documentType: DocumentType.pdf,
      documentUrl: 'https://store.example/doc/$serverJobId',
      documentFilename: 'invoice-$serverJobId.pdf',
      requestedPrinterKey: printerKey,
      profile: PrintProfile.a4Default,
      status: status,
      priority: priority,
      attemptCount: attemptCount,
      nextAttemptAt: nextAttemptAt,
      createdAt: createdAt ?? DateTime.now(),
    );

void main() {
  late TestEnvironment env;

  setUp(() async {
    env = await TestEnvironment.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('queue persistence', () {
    test('a queued job survives being read back from SQLite intact', () async {
      final job = buildJob(storeId: env.storeId);
      expect(await env.queue.enqueue(job), isTrue);

      final loaded = await env.queue.byId(job.id);
      expect(loaded, isNotNull);
      expect(loaded!.serverJobId, '1001');
      expect(loaded.orderReference, '#5591');
      expect(loaded.documentType, DocumentType.pdf);
      expect(loaded.status, PrintJobStatus.queued);
      expect(loaded.profile.name, PrintProfile.a4Default.name);
      expect(loaded.maxAttempts, 4);
    });

    test('counters aggregate by status', () async {
      await env.queue.enqueue(buildJob(storeId: env.storeId, id: 'a', serverJobId: '1'));
      await env.queue.enqueue(buildJob(storeId: env.storeId, id: 'b', serverJobId: '2'));
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          id: 'c',
          serverJobId: '3',
          status: PrintJobStatus.completed,
        ),
      );

      final counters = await env.queue.counters();
      expect(counters.pending, 2);
      expect(counters.completed, 1);
      expect(counters.failed, 0);
    });

    test('history archiving removes reported terminal jobs and caps the table',
        () async {
      final old = DateTime.now().subtract(const Duration(days: 60));
      final job = buildJob(
        storeId: env.storeId,
        id: 'old',
        serverJobId: '900',
        status: PrintJobStatus.completed,
        createdAt: old,
      ).copyWith(completedAt: old, reportedAt: old);
      await env.queue.enqueue(job);

      final archived = await env.queue.archiveOldJobs(
        retention: const Duration(days: 30),
        maxHistoryRows: 1000,
      );

      expect(archived, 1);
      expect(await env.queue.byId('old'), isNull);
      final history = await env.queue.history();
      expect(history, hasLength(1));
      expect(history.first.serverJobId, '900');
    });

    test('an unreported terminal job is not archived', () async {
      final old = DateTime.now().subtract(const Duration(days: 60));
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          id: 'unreported',
          serverJobId: '901',
          status: PrintJobStatus.completed,
          createdAt: old,
        ).copyWith(completedAt: old),
      );

      final archived = await env.queue.archiveOldJobs(
        retention: const Duration(days: 30),
        maxHistoryRows: 1000,
      );

      expect(
        archived,
        0,
        reason: 'Archiving a job the store has not heard about would lose the '
            'outcome permanently',
      );
      expect(await env.queue.byId('unreported'), isNotNull);
    });
  });

  group('duplicate protection', () {
    test('the same server job id can only be inserted once', () async {
      final first = buildJob(storeId: env.storeId, id: 'a', serverJobId: '2001');
      final second =
          buildJob(storeId: env.storeId, id: 'b', serverJobId: '2001');

      expect(await env.queue.enqueue(first), isTrue);
      expect(
        await env.queue.enqueue(second),
        isFalse,
        reason: 'The UNIQUE(store_id, server_job_id) index must reject it',
      );

      final all = await env.queue.activeAndPending();
      expect(all, hasLength(1));
      expect(all.first.id, 'a');
    });

    test('a re-offered job is still rejected after it has completed', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '2002');
      await env.queue.enqueue(job);
      await env.queue.markCompleted(job.id);

      expect(
        await env.queue.enqueue(
          buildJob(storeId: env.storeId, id: 'dup', serverJobId: '2002'),
        ),
        isFalse,
      );
      expect(
        await env.jobDao.isAlreadyCompleted(env.storeId, '2002'),
        isTrue,
      );
    });

    test('markPrinting refuses a job that is already completed', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '2003');
      await env.queue.enqueue(job);
      await env.queue.markCompleted(job.id);

      final allowed = await env.queue.markPrinting(
        jobId: job.id,
        leaseOwner: 'process-a',
        resolvedPrinterKey: 'Printer',
      );
      expect(allowed, isFalse);
    });

    test('markPrinting refuses when another process holds the lease', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '2004');
      await env.queue.enqueue(job);

      final leased = await env.queue.leaseNext(
        leaseOwner: 'process-a',
        leaseDuration: const Duration(minutes: 5),
      );
      expect(leased, isNotNull);

      expect(
        await env.queue.markPrinting(
          jobId: job.id,
          leaseOwner: 'process-b',
          resolvedPrinterKey: 'Printer',
        ),
        isFalse,
      );
      expect(
        await env.queue.markPrinting(
          jobId: job.id,
          leaseOwner: 'process-a',
          resolvedPrinterKey: 'Printer',
        ),
        isTrue,
      );
    });

    test('markPrinting increments the attempt counter exactly once', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '2005');
      await env.queue.enqueue(job);
      await env.queue.markPrinting(
        jobId: job.id,
        leaseOwner: 'p',
        resolvedPrinterKey: 'Printer',
      );
      final after = await env.queue.byId(job.id);
      expect(after!.attemptCount, 1);
      expect(after.status, PrintJobStatus.printing);
      expect(after.resolvedPrinterKey, 'Printer');
    });
  });

  group('leasing', () {
    test('two workers cannot lease the same job', () async {
      await env.queue.enqueue(buildJob(storeId: env.storeId, serverJobId: '3001'));

      final first = await env.queue.leaseNext(
        leaseOwner: 'w1',
        leaseDuration: const Duration(minutes: 5),
      );
      final second = await env.queue.leaseNext(
        leaseOwner: 'w2',
        leaseDuration: const Duration(minutes: 5),
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('honours priority then age', () async {
      final base = DateTime.now().subtract(const Duration(minutes: 10));
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          id: 'old-normal',
          serverJobId: '1',
          createdAt: base,
        ),
      );
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          id: 'new-urgent',
          serverJobId: '2',
          priority: 10,
          createdAt: base.add(const Duration(minutes: 5)),
        ),
      );

      final leased = await env.queue.leaseNext(
        leaseOwner: 'w',
        leaseDuration: const Duration(minutes: 5),
      );
      expect(leased!.id, 'new-urgent');
    });

    test('a job waiting out a retry delay is not offered', () async {
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          serverJobId: '4001',
          nextAttemptAt: DateTime.now().add(const Duration(minutes: 1)),
        ),
      );
      expect(
        await env.queue.leaseNext(
          leaseOwner: 'w',
          leaseDuration: const Duration(minutes: 5),
        ),
        isNull,
      );
    });

    test('a job whose retry delay has passed is offered', () async {
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          serverJobId: '4002',
          nextAttemptAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );
      expect(
        await env.queue.leaseNext(
          leaseOwner: 'w',
          leaseDuration: const Duration(minutes: 5),
        ),
        isNotNull,
      );
    });

    test('filters by the printers the agent currently has enabled', () async {
      await env.queue.enqueue(
        buildJob(
          storeId: env.storeId,
          id: 'for-thermal',
          serverJobId: '5001',
          printerKey: 'Thermal',
        ),
      );
      final leased = await env.queue.leaseNext(
        leaseOwner: 'w',
        leaseDuration: const Duration(minutes: 5),
        printerKeys: <String>['Office'],
      );
      expect(leased, isNull);

      final leasedCorrect = await env.queue.leaseNext(
        leaseOwner: 'w',
        leaseDuration: const Duration(minutes: 5),
        printerKeys: <String>['Thermal'],
      );
      expect(leasedCorrect!.id, 'for-thermal');
    });
  });

  group('restart recovery', () {
    test('a job caught mid-print becomes interrupted, never reprinted', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '6001');
      await env.queue.enqueue(job);
      await env.queue.markPrinting(
        jobId: job.id,
        leaseOwner: 'dead-process',
        resolvedPrinterKey: 'Printer',
      );

      // A new process starts with a different lease owner.
      final result = await env.queue.recoverAfterRestart('new-process');

      expect(result.interrupted, 1);
      final recovered = await env.queue.byId(job.id);
      expect(recovered!.status, PrintJobStatus.interrupted);
      expect(recovered.leaseOwner, isNull);

      // And it must not be handed out again automatically.
      expect(
        await env.queue.leaseNext(
          leaseOwner: 'new-process',
          leaseDuration: const Duration(minutes: 5),
        ),
        isNull,
      );
    });

    test('a job caught downloading is safe to requeue', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '6002');
      await env.queue.enqueue(job);
      await env.queue.setStatus(job.id, PrintJobStatus.downloading);

      final result = await env.queue.recoverAfterRestart('new-process');

      expect(result.requeued, 1);
      final recovered = await env.queue.byId(job.id);
      expect(recovered!.status, PrintJobStatus.queued);
      expect(
        await env.queue.leaseNext(
          leaseOwner: 'new-process',
          leaseDuration: const Duration(minutes: 5),
        ),
        isNotNull,
      );
    });

    test('resolving an interrupted job as printed completes it', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '6003');
      await env.queue.enqueue(job);
      await env.queue.setStatus(job.id, PrintJobStatus.interrupted);

      await env.queue.resolveInterrupted(job.id, printedSuccessfully: true);
      expect((await env.queue.byId(job.id))!.status, PrintJobStatus.completed);
    });

    test('resolving an interrupted job as not printed requeues it', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '6004');
      await env.queue.enqueue(job);
      await env.queue.setStatus(job.id, PrintJobStatus.interrupted);

      await env.queue.resolveInterrupted(job.id, printedSuccessfully: false);
      expect((await env.queue.byId(job.id))!.status, PrintJobStatus.queued);
    });
  });

  group('failure handling', () {
    test('a retryable failure returns the job to the queue with a delay',
        () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '7001');
      await env.queue.enqueue(job);

      final next = DateTime.now().add(const Duration(seconds: 30));
      await env.queue.markFailed(
        job.id,
        errorCode: 'printer_offline',
        errorMessage: 'Printer unavailable',
        willRetry: true,
        nextAttemptAt: next,
      );

      final after = await env.queue.byId(job.id);
      expect(after!.status, PrintJobStatus.queued);
      expect(after.errorCode, 'printer_offline');
      expect(after.nextAttemptAt, isNotNull);
      expect(after.completedAt, isNull);
    });

    test('a terminal failure stays visible for the operator', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '7002');
      await env.queue.enqueue(job);

      await env.queue.markFailed(
        job.id,
        errorCode: 'printer_offline',
        errorMessage: 'Printer unavailable',
        willRetry: false,
      );

      final after = await env.queue.byId(job.id);
      expect(after!.status, PrintJobStatus.failed);
      expect(after.completedAt, isNotNull);
      expect((await env.queue.activeAndPending()).map((PrintJob j) => j.id),
          contains(job.id),);
    });

    test('an operator retry clears the error and the attempt count', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '7003');
      await env.queue.enqueue(job);
      await env.queue.markPrinting(
        jobId: job.id,
        leaseOwner: 'p',
        resolvedPrinterKey: 'Printer',
      );
      await env.queue.markFailed(
        job.id,
        errorCode: 'printer_error',
        errorMessage: 'boom',
        willRetry: false,
      );

      await env.queue.retryNow(job.id);
      final after = await env.queue.byId(job.id);
      expect(after!.status, PrintJobStatus.queued);
      expect(after.attemptCount, 0);
      expect(after.errorCode, isNull);
      expect(after.nextAttemptAt, isNull);
    });

    test('cancelling a completed job does nothing', () async {
      final job = buildJob(storeId: env.storeId, serverJobId: '7004');
      await env.queue.enqueue(job);
      await env.queue.markCompleted(job.id);
      await env.queue.cancel(job.id);
      expect((await env.queue.byId(job.id))!.status, PrintJobStatus.completed);
    });
  });
}
