import 'dart:async';

import '../../core/config/settings_repository.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/error_codes.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printing/domain/print_request.dart';
import '../printer/printer_manager.dart';
import '../printer/printer_resolver.dart';
import '../printer/printer_service.dart';
import 'document_downloader.dart';
import 'job_reporter.dart';
import 'queue_repository.dart';

/// The outcome of processing one job, for the engine's own bookkeeping.
enum JobOutcome { printed, retryScheduled, failedPermanently, skipped }

/// Runs one job through the pipeline.
///
/// The steps and their ordering are the contract described in
/// `docs/PRINT_PIPELINE.md` §4. Two properties are load-bearing:
///
///  * The status is persisted as `printing` **before** any byte reaches the
///    spooler, so a crash mid-print is always detectable afterwards.
///  * The duplicate guard is re-checked inside the same transaction that makes
///    that transition, so a second worker cannot slip between the check and
///    the print.
class JobProcessor {
  JobProcessor({
    required QueueRepository queue,
    required PrinterManager printers,
    required PrinterService printerService,
    required DocumentDownloader downloader,
    required JobReporter reporter,
    required SettingsRepository settings,
    required String leaseOwner,
    AppLogger? logger,
  })  : _queue = queue,
        _printers = printers,
        _printerService = printerService,
        _downloader = downloader,
        _reporter = reporter,
        _settings = settings,
        _leaseOwner = leaseOwner,
        _logger = logger;

  final QueueRepository _queue;
  final PrinterManager _printers;
  final PrinterService _printerService;
  final DocumentDownloader _downloader;
  final JobReporter _reporter;
  final SettingsRepository _settings;
  final String _leaseOwner;
  final AppLogger? _logger;

  Future<JobOutcome> process(PrintJob job) async {
    final stopwatch = Stopwatch()..start();

    // ---- Guard 1: the job may have been completed or cancelled since it was
    // leased (an operator action, or a replayed report).
    final current = await _queue.byId(job.id);
    if (current == null) return JobOutcome.skipped;
    if (current.status.isTerminal || current.status == PrintJobStatus.interrupted) {
      _logger?.debug(
        LogCategory.queue,
        'Skipping job in terminal state',
        context: <String, Object?>{
          'job_id': job.id,
          'status': current.status.name,
        },
      );
      return JobOutcome.skipped;
    }

    // ---- Guard 2: has this server job already been printed successfully?
    // Belt and braces alongside the UNIQUE index — covers the case where a job
    // was archived and re-offered by the server.
    final alreadyDone = await _queue.dao
        .isAlreadyCompleted(current.storeId, current.serverJobId);
    if (alreadyDone && current.status != PrintJobStatus.completed) {
      _logger?.warn(
        LogCategory.queue,
        'Refusing to print a job that is already recorded as completed',
        context: <String, Object?>{'server_job_id': current.serverJobId},
      );
      await _queue.cancel(
        current.id,
        reason: 'Already printed — duplicate suppressed',
      );
      return JobOutcome.skipped;
    }

    PrinterDevice? printer;

    try {
      // ---- Step 1: resolve the printer *before* downloading, so an
      // unavailable printer does not cost a pointless download.
      final resolution = _printers.resolveFor(current);
      switch (resolution) {
        case UnavailablePrinter(:final errorCode, :final message):
          return _fail(
            current,
            errorCode: errorCode,
            errorMessage: message,
            errorDetail: 'Requested printer: '
                '${current.requestedPrinterKey ?? '(none)'}',
            printerKey: current.requestedPrinterKey,
          );
        case FallbackPrinter(:final device, :final requestedKey):
          printer = device;
          _logger?.warn(
            LogCategory.queue,
            'Printing to the fallback printer — the requested one is '
            'unavailable and this job permits fallback',
            context: <String, Object?>{
              'job_id': current.id,
              'requested': requestedKey,
              'fallback': device.printerKey,
            },
          );
        case ResolvedPrinter(:final device, :final source):
          printer = device;
          _logger?.debug(
            LogCategory.queue,
            'Printer resolved',
            context: <String, Object?>{
              'job_id': current.id,
              'printer': device.printerKey,
              'source': source.name,
            },
          );
      }

      // ---- Step 2: download and validate.
      await _queue.setStatus(current.id, PrintJobStatus.downloading);
      final document = await _downloader.resolve(current);
      await _queue.update(
        current.copyWith(
          localFilePath: document.filePath,
          documentSizeBytes: document.sizeBytes,
        ),
      );

      // ---- Step 3: confirm the printer is still usable now that we are ready.
      final available = await _printerService.isAvailable(printer.printerKey);
      if (!available) {
        final reading = await _printerService.getStatus(printer.printerKey);
        return _fail(
          current,
          errorCode: ErrorCodes.printerOffline,
          errorMessage: 'Printer unavailable — ${reading.state.problemMessage}',
          errorDetail: 'State ${reading.state.name} '
              '(bits ${reading.rawStatusBits}).',
          printerKey: printer.printerKey,
        );
      }

      // ---- Step 4: the point of no return. Persist `printing` and increment
      // the attempt counter atomically; refuse if anything changed underneath.
      final claimed = await _queue.markPrinting(
        jobId: current.id,
        leaseOwner: _leaseOwner,
        resolvedPrinterKey: printer.printerKey,
      );
      if (!claimed) {
        _logger?.warn(
          LogCategory.queue,
          'Job state changed before printing; skipping to avoid a duplicate',
          context: <String, Object?>{'job_id': current.id},
        );
        return JobOutcome.skipped;
      }

      final printing = (await _queue.byId(current.id))!;
      unawaited(_reporter.reportStart(printing, printer.printerKey));

      // ---- Step 5: print.
      final profile = _printers.effectiveProfile(printing, printer);
      final result = await _printerService.print(
        PrintRequest(
          jobId: printing.id,
          printerKey: printer.printerKey,
          documentType: printing.documentType,
          data: document.bytes,
          localFilePath: document.filePath,
          profile: profile,
          documentTitle: _documentTitle(printing),
          copies: printing.copies,
        ),
      );

      if (!result.success) {
        return _fail(
          printing,
          errorCode: result.errorCode ?? ErrorCodes.printerError,
          errorMessage:
              result.errorMessage ?? 'The document could not be printed.',
          errorDetail: result.errorDetail,
          printerKey: printer.printerKey,
        );
      }

      // ---- Step 6: success.
      stopwatch.stop();
      await _queue.markCompleted(
        printing.id,
        spoolerJobId: result.spoolerJobId,
      );
      _logger?.info(
        LogCategory.queue,
        'Job printed',
        context: <String, Object?>{
          'job_id': printing.id,
          'server_job_id': printing.serverJobId,
          'order': printing.orderReference,
          'printer': printer.printerKey,
          'strategy': result.strategyName,
          'attempt': printing.attemptCount,
          'ms': stopwatch.elapsedMilliseconds,
        },
      );

      final completed = (await _queue.byId(printing.id)) ?? printing;

      // History is written here, not left to the retention sweep. The sweep only
      // archives jobs old enough to leave the queue, so a job printed a minute
      // ago produced an empty History screen and looked as though nothing had
      // been recorded at all.
      //
      // The document is deliberately *not* discarded on success: keeping it is
      // what lets an operator open what actually came out of the printer. The
      // retention sweep removes it along with the history row.
      await _queue.recordHistory(completed, printerKey: printer.printerKey);

      unawaited(
        _reporter.reportComplete(
          completed,
          printerKey: printer.printerKey,
          spoolerJobId: result.spoolerJobId,
          duration: stopwatch.elapsed,
        ),
      );

      return JobOutcome.printed;
    } on AppException catch (e, st) {
      _logger?.exception(
        LogCategory.queue,
        'Job failed',
        e,
        st,
        <String, Object?>{'job_id': current.id},
      );
      final latest = (await _queue.byId(current.id)) ?? current;
      return _fail(
        latest,
        errorCode: e.code,
        errorMessage: e.userMessage,
        errorDetail: e.technicalDetail,
        printerKey: printer?.printerKey,
        retryableOverride: e.isRetryable,
      );
    } catch (e, st) {
      _logger?.exception(
        LogCategory.queue,
        'Job failed unexpectedly',
        e,
        st,
        <String, Object?>{'job_id': current.id},
      );
      final latest = (await _queue.byId(current.id)) ?? current;
      return _fail(
        latest,
        errorCode: ErrorCodes.unknown,
        errorMessage: 'Something went wrong while printing this job.',
        errorDetail: e.toString(),
        printerKey: printer?.printerKey,
      );
    } finally {
      await _queue.releaseLease(job.id);
    }
  }

  /// Applies the retry policy, persists the failure and reports it.
  Future<JobOutcome> _fail(
    PrintJob job, {
    required String errorCode,
    required String errorMessage,
    String? errorDetail,
    String? printerKey,
    bool retryableOverride = true,
  }) async {
    final policy = _settings.current.retryPolicy;

    // An attempt that never reached the spooler still counts, otherwise a
    // permanently unavailable printer would retry forever.
    final attempts = job.attemptCount == 0 ? 1 : job.attemptCount;
    final effective = job.copyWith(attemptCount: attempts);

    // Codes that will never come right however many times they are tried.
    //
    // `forbidden` and `conflict` used to be in this set, which is why a job
    // whose server-side claim had lapsed died on its first attempt and only
    // printed when an operator hit retry by hand. Both describe the state of the
    // job at one instant — a claim held elsewhere, a lease being reaped — and
    // both routinely resolve on their own. A 403 that really is about this agent
    // still stops immediately, via `retryableOverride`, because
    // ForbiddenException reports itself unretryable only when the store named an
    // agent-level code.
    final nonRetryable = <String>{
      ErrorCodes.unauthorized,
      ErrorCodes.notFound,
      ErrorCodes.unsupportedDocument,
      ErrorCodes.documentUntrustedOrigin,
      ErrorCodes.documentTooLarge,
      ErrorCodes.cancelled,
    };

    final willRetry = retryableOverride &&
        !nonRetryable.contains(errorCode) &&
        attempts < effective.maxAttempts;

    final nextAttemptAt =
        willRetry ? policy.nextAttemptAt(attempts + 1) : null;

    await _queue.markFailed(
      job.id,
      errorCode: errorCode,
      errorMessage: errorMessage,
      errorDetail: errorDetail,
      willRetry: willRetry,
      nextAttemptAt: nextAttemptAt,
    );

    // Keep the attempt counter in step when the failure happened before
    // markPrinting had a chance to increment it.
    if (job.attemptCount == 0) {
      await _queue.dao.setStatus(
        job.id,
        willRetry ? PrintJobStatus.queued : PrintJobStatus.failed,
        extra: <String, Object?>{'attempt_count': attempts},
      );
    }

    _logger?.warn(
      LogCategory.queue,
      willRetry
          ? 'Job failed — retrying in '
              '${nextAttemptAt!.difference(DateTime.now()).inSeconds}s'
          : 'Job failed permanently',
      context: <String, Object?>{
        'job_id': job.id,
        'server_job_id': job.serverJobId,
        'error_code': errorCode,
        'attempt': attempts,
        'max_attempts': effective.maxAttempts,
        'printer': printerKey,
        if (errorDetail != null) 'detail': errorDetail,
      },
    );

    unawaited(
      _reporter.reportFailure(
        effective,
        errorCode: errorCode,
        errorMessage: errorMessage,
        willRetry: willRetry,
        printerKey: printerKey,
        nextAttemptAt: nextAttemptAt,
      ),
    );

    if (!willRetry) {
      final latest = await _queue.byId(job.id);
      if (latest != null) {
        // A job that has given up belongs in History too — that is where an
        // operator looks to find out what did not print and why.
        await _queue.recordHistory(latest, printerKey: printerKey);
        unawaited(_downloader.discard(latest));
      }
    }

    return willRetry ? JobOutcome.retryScheduled : JobOutcome.failedPermanently;
  }

  /// What appears in the Windows print queue.
  static String _documentTitle(PrintJob job) {
    final reference = job.orderReference ?? job.orderId;
    final name = job.documentFilename;
    if (reference != null && name != null) return '$reference — $name';
    if (reference != null) return 'Order $reference';
    if (name != null) return name;
    return 'Print job ${job.serverJobId}';
  }
}
