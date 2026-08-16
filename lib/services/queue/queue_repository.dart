import 'dart:async';

import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/storage/dao/print_history_dao.dart';
import '../../core/storage/dao/print_job_dao.dart';
import '../../features/print_queue/domain/print_job.dart';

/// The queue as the rest of the application sees it.
///
/// Wraps [PrintJobDao] and adds a change stream, so the UI can be a pure
/// projection of the database without polling it. Every mutation funnels
/// through here and emits exactly one change event.
class QueueRepository {
  QueueRepository({
    required PrintJobDao dao,
    required PrintHistoryDao historyDao,
    AppLogger? logger,
  })  : _dao = dao,
        _historyDao = historyDao,
        _logger = logger;

  final PrintJobDao _dao;
  final PrintHistoryDao _historyDao;
  final AppLogger? _logger;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Emits whenever any job row changes. Deliberately payload-free: listeners
  /// re-read what they need, which keeps a single event correct for every view.
  Stream<void> get changes => _changes.stream;

  PrintJobDao get dao => _dao;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Future<List<PrintJob>> activeAndPending({int limit = 500}) =>
      _dao.findActiveAndPending(limit: limit);

  Future<List<PrintJob>> recent({int limit = 20}) => _dao.findRecent(limit: limit);

  Future<QueueCounters> counters() => _dao.counters();

  Future<PrintJob?> byId(String id) => _dao.findById(id);

  Future<List<PrintJob>> byStatus(
    List<PrintJobStatus> statuses, {
    int limit = 200,
  }) =>
      _dao.findByStatuses(statuses, limit: limit);

  Future<List<PrintJob>> unreported({int limit = 50}) =>
      _dao.findUnreportedTerminal(limit: limit);

  Future<List<PrintHistoryEntry>> history({
    String? status,
    String? printerKey,
    String? search,
    int limit = 200,
    int offset = 0,
  }) =>
      _historyDao.query(
        status: status,
        printerKey: printerKey,
        search: search,
        limit: limit,
        offset: offset,
      );

  Future<({int completed, int failed})> historySummary({
    Duration window = const Duration(days: 7),
  }) =>
      _historyDao.summary(window: window);

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  /// Inserts a job unless `(storeId, serverJobId)` is already present.
  ///
  /// Returns true only when a new row was created. Callers use the false case
  /// to skip re-claiming work the agent already owns.
  Future<bool> enqueue(PrintJob job) async {
    final inserted = await _dao.insertIfAbsent(job);
    if (inserted) {
      _logger?.info(
        LogCategory.queue,
        'Job queued',
        context: <String, Object?>{
          'job_id': job.id,
          'server_job_id': job.serverJobId,
          'order': job.orderReference,
          'document_type': job.documentType.name,
          'printer': job.requestedPrinterKey,
        },
      );
      _notify();
    } else {
      _logger?.debug(
        LogCategory.queue,
        'Duplicate job ignored — already in the local queue',
        context: <String, Object?>{'server_job_id': job.serverJobId},
      );
    }
    return inserted;
  }

  Future<PrintJob?> leaseNext({
    required String leaseOwner,
    required Duration leaseDuration,
    List<String>? printerKeys,
    Set<String> excludeJobIds = const <String>{},
  }) =>
      _dao.leaseNextReady(
        leaseOwner: leaseOwner,
        leaseDuration: leaseDuration,
        printerKeys: printerKeys,
        excludeJobIds: excludeJobIds,
      );

  Future<void> extendLease(String jobId, String owner, Duration duration) =>
      _dao.extendLease(jobId, owner, duration);

  Future<void> releaseLease(String jobId) async {
    await _dao.releaseLease(jobId);
    _notify();
  }

  Future<void> update(PrintJob job) async {
    await _dao.update(job);
    _notify();
  }

  Future<void> setStatus(
    String jobId,
    PrintJobStatus status, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    await _dao.setStatus(jobId, status, extra: extra);
    _notify();
  }

  Future<bool> markPrinting({
    required String jobId,
    required String leaseOwner,
    required String resolvedPrinterKey,
  }) async {
    final ok = await _dao.markPrinting(
      jobId: jobId,
      leaseOwner: leaseOwner,
      resolvedPrinterKey: resolvedPrinterKey,
    );
    if (ok) _notify();
    return ok;
  }

  Future<void> markCompleted(
    String jobId, {
    int? spoolerJobId,
    DateTime? at,
  }) async {
    await _dao.markCompleted(jobId, spoolerJobId: spoolerJobId, at: at);
    _notify();
  }

  Future<void> markFailed(
    String jobId, {
    required String errorCode,
    required String errorMessage,
    String? errorDetail,
    required bool willRetry,
    DateTime? nextAttemptAt,
  }) async {
    await _dao.markFailed(
      jobId,
      errorCode: errorCode,
      errorMessage: errorMessage,
      errorDetail: errorDetail,
      willRetry: willRetry,
      nextAttemptAt: nextAttemptAt,
    );
    _notify();
  }

  Future<void> markReported(String jobId) async {
    await _dao.markReported(jobId);
    _notify();
  }

  Future<void> cancel(String jobId, {String reason = 'Cancelled by operator'}) async {
    await _dao.cancel(jobId, reason: reason);
    _logger?.info(
      LogCategory.queue,
      'Job cancelled',
      context: <String, Object?>{'job_id': jobId, 'reason': reason},
    );
    _notify();
  }

  Future<void> retryNow(String jobId, {bool resetAttempts = true}) async {
    await _dao.requeue(jobId, resetAttempts: resetAttempts);
    _logger?.info(
      LogCategory.queue,
      'Job requeued by operator',
      context: <String, Object?>{'job_id': jobId},
    );
    _notify();
  }

  /// Resolves an `interrupted` job. This is the only path that can turn an
  /// interrupted job back into printable work, and it is always an explicit
  /// decision — never automatic unless the operator configured it to be.
  Future<void> resolveInterrupted(
    String jobId, {
    required bool printedSuccessfully,
  }) async {
    await _dao.resolveInterrupted(
      jobId,
      printedSuccessfully: printedSuccessfully,
    );
    _logger?.info(
      LogCategory.queue,
      printedSuccessfully
          ? 'Interrupted job marked as printed'
          : 'Interrupted job requeued for reprinting',
      context: <String, Object?>{'job_id': jobId},
    );
    _notify();
  }

  Future<({int interrupted, int requeued})> recoverAfterRestart(
    String leaseOwner,
  ) async {
    final result = await _dao.recoverAfterRestart(currentLeaseOwner: leaseOwner);
    if (result.interrupted > 0 || result.requeued > 0) {
      _logger?.warn(
        LogCategory.queue,
        'Recovered jobs after restart',
        context: <String, Object?>{
          'interrupted': result.interrupted,
          'requeued': result.requeued,
        },
      );
      _notify();
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // Maintenance
  // -------------------------------------------------------------------------

  Future<int> archiveOldJobs({
    required Duration retention,
    required int maxHistoryRows,
  }) async {
    final archived = await _dao.archiveOldTerminalJobs(
      retention: retention,
      maxHistoryRows: maxHistoryRows,
    );
    if (archived > 0) {
      _logger?.info(
        LogCategory.queue,
        'Archived $archived completed job(s) to history',
      );
      _notify();
    }
    return archived;
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
