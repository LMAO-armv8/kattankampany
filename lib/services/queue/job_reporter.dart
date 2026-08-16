import 'dart:async';

import '../../core/errors/app_exception.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/storage/dao/idempotency_dao.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../api/agent_session.dart';
import 'queue_repository.dart';

/// Reports job outcomes to the store, exactly once.
///
/// The order is deliberate and is the whole reason this class exists:
///
///   1. record the intent locally, with an idempotency key
///   2. make the HTTP call
///   3. mark the intent confirmed
///
/// If the process dies between 2 and 3, [replayPending] re-sends the same call
/// with the same key on the next start. The server deduplicates on the key, so
/// the outcome is recorded once — and, crucially, the *document is never
/// reprinted*, because the reprint decision lives in the queue, not here.
class JobReporter {
  JobReporter({
    required AgentSession session,
    required QueueRepository queue,
    required IdempotencyDao idempotency,
    AppLogger? logger,
  })  : _session = session,
        _queue = queue,
        _idempotency = idempotency,
        _logger = logger;

  final AgentSession _session;
  final QueueRepository _queue;
  final IdempotencyDao _idempotency;
  final AppLogger? _logger;

  String _key(PrintJob job, String action) => IdempotencyDao.buildKey(
        agentId: _session.serverAgentId ?? 'unknown',
        serverJobId: job.serverJobId,
        action: action,
        attempt: job.attemptCount,
      );

  // -------------------------------------------------------------------------
  // Individual reports
  // -------------------------------------------------------------------------

  Future<void> reportStart(PrintJob job, String printerKey) async {
    final agentId = _session.serverAgentId;
    if (agentId == null) return;
    final key = _key(job, JobAction.start);
    final payload = <String, dynamic>{
      'printer_key': printerKey,
      'attempt': job.attemptCount,
    };
    await _idempotency.record(
      PendingReport(
        key: key,
        jobId: job.id,
        action: JobAction.start,
        payload: <String, dynamic>{
          ...payload,
          'server_job_id': job.serverJobId,
        },
        createdAt: DateTime.now(),
      ),
    );
    try {
      await _session.api.reportStart(
        serverJobId: job.serverJobId,
        agentId: agentId,
        printerKey: printerKey,
        attempt: job.attemptCount,
        idempotencyKey: key,
      );
      await _idempotency.confirm(key);
    } on AppException catch (e) {
      // A failed "start" notification must not stop the print — the job is
      // already claimed by this agent, and the completion report carries the
      // same information.
      _logger?.debug(
        LogCategory.queue,
        'Start notification failed (non-fatal)',
        context: <String, Object?>{'job_id': job.id, 'code': e.code},
      );
    }
  }

  /// Reports success. Retried on the next sync if the network is down, because
  /// losing this report would leave the order looking unprinted.
  Future<bool> reportComplete(
    PrintJob job, {
    required String printerKey,
    int? spoolerJobId,
    Duration? duration,
  }) async {
    final agentId = _session.serverAgentId;
    if (agentId == null) return false;
    final key = _key(job, JobAction.complete);

    await _idempotency.record(
      PendingReport(
        key: key,
        jobId: job.id,
        action: JobAction.complete,
        payload: <String, dynamic>{
          'server_job_id': job.serverJobId,
          'printer_key': printerKey,
          'attempt': job.attemptCount,
          'spooler_job_id': spoolerJobId,
          'duration_ms': duration?.inMilliseconds,
        },
        createdAt: DateTime.now(),
      ),
    );

    try {
      await _session.api.reportComplete(
        serverJobId: job.serverJobId,
        agentId: agentId,
        printerKey: printerKey,
        attempt: job.attemptCount,
        idempotencyKey: key,
        spoolerJobId: spoolerJobId,
        duration: duration,
      );
      await _idempotency.confirm(key);
      await _queue.markReported(job.id);
      _logger?.info(
        LogCategory.queue,
        'Completion reported',
        context: <String, Object?>{
          'job_id': job.id,
          'server_job_id': job.serverJobId,
        },
      );
      return true;
    } on NotFoundException {
      // The job vanished server-side; nothing more to report.
      await _idempotency.confirm(key);
      await _queue.markReported(job.id);
      return true;
    } on AppException catch (e) {
      _logger?.warn(
        LogCategory.queue,
        'Completion could not be reported yet — it will be retried',
        context: <String, Object?>{'job_id': job.id, 'code': e.code},
      );
      return false;
    }
  }

  Future<bool> reportFailure(
    PrintJob job, {
    required String errorCode,
    required String errorMessage,
    required bool willRetry,
    String? printerKey,
    DateTime? nextAttemptAt,
  }) async {
    final agentId = _session.serverAgentId;
    if (agentId == null) return false;
    final key = _key(job, JobAction.fail);

    await _idempotency.record(
      PendingReport(
        key: key,
        jobId: job.id,
        action: JobAction.fail,
        payload: <String, dynamic>{
          'server_job_id': job.serverJobId,
          'attempt': job.attemptCount,
          'error_code': errorCode,
          'error_message': errorMessage,
          'will_retry': willRetry,
          'printer_key': printerKey,
          'next_attempt_at': nextAttemptAt?.toIso8601String(),
        },
        createdAt: DateTime.now(),
      ),
    );

    try {
      await _session.api.reportFailure(
        serverJobId: job.serverJobId,
        agentId: agentId,
        attempt: job.attemptCount,
        errorCode: errorCode,
        errorMessage: errorMessage,
        willRetry: willRetry,
        idempotencyKey: key,
        printerKey: printerKey,
        nextAttemptAt: nextAttemptAt,
      );
      await _idempotency.confirm(key);
      if (!willRetry) await _queue.markReported(job.id);
      return true;
    } on NotFoundException {
      await _idempotency.confirm(key);
      if (!willRetry) await _queue.markReported(job.id);
      return true;
    } on AppException catch (e) {
      _logger?.debug(
        LogCategory.queue,
        'Failure report deferred',
        context: <String, Object?>{'job_id': job.id, 'code': e.code},
      );
      return false;
    }
  }

  /// Hands a claimed job back so another agent can take it. Used on shutdown.
  Future<void> release(PrintJob job, {String reason = 'agent_shutdown'}) async {
    final agentId = _session.serverAgentId;
    if (agentId == null) return;
    try {
      await _session.api.releaseJob(
        serverJobId: job.serverJobId,
        agentId: agentId,
        reason: reason,
      );
    } on AppException {
      // Best effort — the server expires stale claims anyway.
    }
  }

  // -------------------------------------------------------------------------
  // Replay
  // -------------------------------------------------------------------------

  /// Re-sends terminal outcomes the server has not acknowledged.
  ///
  /// Called on startup and after every reconnection. This is what makes
  /// "printed, then the network died" safe.
  Future<int> replayPending({int limit = 25}) async {
    if (!_session.isPaired) return 0;
    var sent = 0;

    final unreported = await _queue.unreported(limit: limit);
    for (final job in unreported) {
      final ok = switch (job.status) {
        PrintJobStatus.completed => await reportComplete(
            job,
            printerKey: job.resolvedPrinterKey ?? '',
            spoolerJobId: job.spoolerJobId,
            duration: job.printDuration,
          ),
        PrintJobStatus.failed => await reportFailure(
            job,
            errorCode: job.errorCode ?? 'unknown',
            errorMessage: job.errorMessage ?? 'The job failed.',
            willRetry: false,
            printerKey: job.resolvedPrinterKey,
          ),
        PrintJobStatus.cancelled => await reportFailure(
            job,
            errorCode: 'cancelled',
            errorMessage: job.errorMessage ?? 'Cancelled on the agent.',
            willRetry: false,
            printerKey: job.resolvedPrinterKey,
          ),
        _ => true,
      };
      if (ok) sent++;
    }

    if (sent > 0) {
      _logger?.info(
        LogCategory.queue,
        'Replayed $sent pending job report(s) to the store',
      );
    }
    // Housekeeping: confirmed keys are only a short-lived replay guard.
    unawaited(_idempotency.pruneConfirmed());
    return sent;
  }
}
