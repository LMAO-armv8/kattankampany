import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../features/print_queue/domain/print_job.dart';
import '../database.dart';

/// All SQL for the local print queue.
///
/// The duplicate-print guarantees live here and in the schema:
///  * [insertIfAbsent] uses `INSERT OR IGNORE` against the
///    `(store_id, server_job_id)` unique index.
///  * [leaseNextReady] selects and leases in a single transaction, so two
///    workers can never pick up the same row.
///  * [markPrinting] refuses to move a row that is already terminal.
class PrintJobDao {
  PrintJobDao(this._database);

  final AppDatabase _database;

  static const String _table = 'print_jobs';

  // -------------------------------------------------------------------------
  // Insert
  // -------------------------------------------------------------------------

  /// Inserts [job] unless `(store_id, server_job_id)` already exists.
  ///
  /// Returns `true` if a new row was created. A `false` result is the normal,
  /// expected outcome when the server re-lists a job the agent already knows,
  /// and is not an error.
  Future<bool> insertIfAbsent(PrintJob job) async {
    final id = await _database.db.insert(
      _table,
      job.toDatabaseRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // sqflite returns 0 when the row was ignored.
    return id != 0;
  }

  // -------------------------------------------------------------------------
  // Read
  // -------------------------------------------------------------------------

  Future<PrintJob?> findById(String id) async {
    final rows = await _database.db
        .query(_table, where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    if (rows.isEmpty) return null;
    return PrintJob.fromDatabaseRow(rows.first);
  }

  Future<PrintJob?> findByServerJobId(String storeId, String serverJobId) async {
    final rows = await _database.db.query(
      _table,
      where: 'store_id = ? AND server_job_id = ?',
      whereArgs: <Object?>[storeId, serverJobId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PrintJob.fromDatabaseRow(rows.first);
  }

  /// True when this job has already been printed successfully. Checked before
  /// every spool operation and before inserting a job the server re-offers.
  Future<bool> isAlreadyCompleted(String storeId, String serverJobId) async {
    final rows = await _database.db.rawQuery(
      'SELECT 1 FROM $_table WHERE store_id = ? AND server_job_id = ? '
      "AND status = 'completed' LIMIT 1",
      <Object?>[storeId, serverJobId],
    );
    return rows.isNotEmpty;
  }

  Future<List<PrintJob>> findByStatuses(
    List<PrintJobStatus> statuses, {
    int limit = 200,
    int offset = 0,
    String orderBy = 'priority DESC, created_at ASC',
  }) async {
    if (statuses.isEmpty) return const <PrintJob>[];
    final placeholders = List<String>.filled(statuses.length, '?').join(',');
    final rows = await _database.db.query(
      _table,
      where: 'status IN ($placeholders)',
      whereArgs: statuses.map((PrintJobStatus s) => s.name).toList(),
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    return rows.map(PrintJob.fromDatabaseRow).toList(growable: false);
  }

  /// Everything the Print Queue screen shows: not-yet-terminal plus anything
  /// needing operator attention.
  Future<List<PrintJob>> findActiveAndPending({int limit = 500}) =>
      findByStatuses(
        <PrintJobStatus>[
          PrintJobStatus.queued,
          PrintJobStatus.claimed,
          PrintJobStatus.downloading,
          PrintJobStatus.printing,
          PrintJobStatus.failed,
          PrintJobStatus.interrupted,
        ],
        limit: limit,
      );

  Future<List<PrintJob>> findRecent({int limit = 20}) async {
    final rows = await _database.db.query(
      _table,
      orderBy: 'COALESCE(completed_at, started_at, created_at) DESC',
      limit: limit,
    );
    return rows.map(PrintJob.fromDatabaseRow).toList(growable: false);
  }

  Future<QueueCounters> counters() async {
    final rows = await _database.db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM $_table GROUP BY status',
    );
    var pending = 0;
    var printing = 0;
    var completed = 0;
    var failed = 0;
    var interrupted = 0;
    for (final row in rows) {
      final count = (row['c'] as int?) ?? 0;
      switch (PrintJobStatus.fromWire(row['status'] as String?)) {
        case PrintJobStatus.queued:
        case PrintJobStatus.claimed:
          pending += count;
        case PrintJobStatus.downloading:
        case PrintJobStatus.printing:
          printing += count;
        case PrintJobStatus.completed:
          completed += count;
        case PrintJobStatus.failed:
          failed += count;
        case PrintJobStatus.interrupted:
          interrupted += count;
        case PrintJobStatus.cancelled:
          break;
      }
    }
    return QueueCounters(
      pending: pending,
      printing: printing,
      completed: completed,
      failed: failed,
      interrupted: interrupted,
    );
  }

  /// Terminal jobs whose outcome has not yet reached the server. Replayed on
  /// reconnect so a network failure after printing cannot lose the report.
  Future<List<PrintJob>> findUnreportedTerminal({int limit = 50}) async {
    final rows = await _database.db.query(
      _table,
      where: "reported_at IS NULL AND status IN ('completed','failed','cancelled')",
      orderBy: 'completed_at ASC',
      limit: limit,
    );
    return rows.map(PrintJob.fromDatabaseRow).toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Lease / claim
  // -------------------------------------------------------------------------

  /// Atomically selects the highest-priority ready job and leases it to
  /// [leaseOwner]. Returns null when nothing is ready.
  ///
  /// Runs inside a transaction so two workers polling simultaneously cannot
  /// both take the same row.
  Future<PrintJob?> leaseNextReady({
    required String leaseOwner,
    required Duration leaseDuration,
    List<String>? printerKeys,
    Set<String> excludeJobIds = const <String>{},
  }) async {
    return _database.transaction<PrintJob?>((Transaction txn) async {
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;

      final where = StringBuffer(
        "status IN ('queued','claimed') "
        'AND (next_attempt_at IS NULL OR next_attempt_at <= ?) '
        'AND (lease_expires_at IS NULL OR lease_expires_at <= ?)',
      );
      final args = <Object?>[nowMs, nowMs];

      if (printerKeys != null && printerKeys.isNotEmpty) {
        // Take jobs for these printers, plus jobs with no printer assigned.
        final placeholders = List<String>.filled(printerKeys.length, '?').join(',');
        where.write(
          ' AND (requested_printer_key IS NULL '
          'OR requested_printer_key IN ($placeholders))',
        );
        args.addAll(printerKeys);
      }
      if (excludeJobIds.isNotEmpty) {
        final placeholders =
            List<String>.filled(excludeJobIds.length, '?').join(',');
        where.write(' AND id NOT IN ($placeholders)');
        args.addAll(excludeJobIds);
      }

      final rows = await txn.query(
        _table,
        where: where.toString(),
        whereArgs: args,
        orderBy: 'priority DESC, created_at ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final job = PrintJob.fromDatabaseRow(rows.first);
      final expiry = now.add(leaseDuration);
      await txn.update(
        _table,
        <String, Object?>{
          'lease_owner': leaseOwner,
          'lease_expires_at': expiry.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: <Object?>[job.id],
      );
      return job.copyWith(leaseOwner: leaseOwner, leaseExpiresAt: expiry);
    });
  }

  Future<void> extendLease(
    String jobId,
    String leaseOwner,
    Duration duration,
  ) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'lease_expires_at':
            DateTime.now().add(duration).millisecondsSinceEpoch,
      },
      where: 'id = ? AND lease_owner = ?',
      whereArgs: <Object?>[jobId, leaseOwner],
    );
  }

  Future<void> releaseLease(String jobId) async {
    await _database.db.update(
      _table,
      <String, Object?>{'lease_owner': null, 'lease_expires_at': null},
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  // -------------------------------------------------------------------------
  // State transitions
  // -------------------------------------------------------------------------

  Future<void> update(PrintJob job) async {
    await _database.db.update(
      _table,
      job.toDatabaseRow(),
      where: 'id = ?',
      whereArgs: <Object?>[job.id],
    );
  }

  Future<void> setStatus(
    String jobId,
    PrintJobStatus status, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) async {
    await _database.db.update(
      _table,
      <String, Object?>{'status': status.name, ...extra},
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  /// Moves a job into `printing` — the last gate before bytes reach the spooler.
  ///
  /// Fails (returns false) if the row has been completed or cancelled in the
  /// meantime, or if the lease is held by someone else. This is duplicate guard
  /// number two; the unique index is number one.
  Future<bool> markPrinting({
    required String jobId,
    required String leaseOwner,
    required String resolvedPrinterKey,
  }) async {
    return _database.transaction<bool>((Transaction txn) async {
      final rows = await txn.query(
        _table,
        where: 'id = ?',
        whereArgs: <Object?>[jobId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final job = PrintJob.fromDatabaseRow(rows.first);
      if (job.status.isTerminal) return false;
      if (job.leaseOwner != null && job.leaseOwner != leaseOwner) return false;

      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        _table,
        <String, Object?>{
          'status': PrintJobStatus.printing.name,
          'resolved_printer_key': resolvedPrinterKey,
          'started_at': now,
          'attempt_count': job.attemptCount + 1,
          'lease_owner': leaseOwner,
        },
        where: 'id = ?',
        whereArgs: <Object?>[jobId],
      );
      return true;
    });
  }

  Future<void> markCompleted(
    String jobId, {
    int? spoolerJobId,
    DateTime? at,
  }) async {
    final now = (at ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.db.update(
      _table,
      <String, Object?>{
        'status': PrintJobStatus.completed.name,
        'completed_at': now,
        'spooler_job_id': spoolerJobId,
        'error_code': null,
        'error_message': null,
        'error_detail': null,
        'lease_owner': null,
        'lease_expires_at': null,
        'next_attempt_at': null,
      },
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  Future<void> markFailed(
    String jobId, {
    required String errorCode,
    required String errorMessage,
    String? errorDetail,
    required bool willRetry,
    DateTime? nextAttemptAt,
  }) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'status':
            willRetry ? PrintJobStatus.queued.name : PrintJobStatus.failed.name,
        'error_code': errorCode,
        'error_message': errorMessage,
        'error_detail': errorDetail,
        'next_attempt_at': nextAttemptAt?.millisecondsSinceEpoch,
        'completed_at': willRetry
            ? null
            : DateTime.now().millisecondsSinceEpoch,
        'lease_owner': null,
        'lease_expires_at': null,
      },
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  Future<void> markReported(String jobId, {DateTime? at}) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'reported_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  Future<void> cancel(String jobId, {String reason = 'Cancelled'}) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'status': PrintJobStatus.cancelled.name,
        'error_message': reason,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'lease_owner': null,
        'lease_expires_at': null,
        'next_attempt_at': null,
      },
      where: 'id = ? AND status NOT IN (?, ?)',
      whereArgs: <Object?>[
        jobId,
        PrintJobStatus.completed.name,
        PrintJobStatus.cancelled.name,
      ],
    );
  }

  /// Requeues a job for an immediate attempt, resetting its error state but
  /// **not** its attempt counter — so a manual retry still respects the ceiling
  /// unless [resetAttempts] is set.
  Future<void> requeue(String jobId, {bool resetAttempts = false}) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'status': PrintJobStatus.queued.name,
        'next_attempt_at': null,
        'error_code': null,
        'error_message': null,
        'error_detail': null,
        'completed_at': null,
        'started_at': null,
        'lease_owner': null,
        'lease_expires_at': null,
        if (resetAttempts) 'attempt_count': 0,
      },
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  // -------------------------------------------------------------------------
  // Crash recovery
  // -------------------------------------------------------------------------

  /// Called once at startup.
  ///
  /// Any row still in `printing` belongs to a process that no longer exists, so
  /// the agent cannot know whether the paper came out. Those rows become
  /// `interrupted` and wait for a decision — they are never reprinted silently.
  /// Rows in `downloading` never touched the spooler, so they are safe to requeue.
  Future<({int interrupted, int requeued})> recoverAfterRestart({
    required String currentLeaseOwner,
  }) async {
    return _database.transaction<({int interrupted, int requeued})>(
      (Transaction txn) async {
        final now = DateTime.now().millisecondsSinceEpoch;

        final interrupted = await txn.update(
          _table,
          <String, Object?>{
            'status': PrintJobStatus.interrupted.name,
            'error_code': 'interrupted',
            'error_message':
                'The agent stopped while this job was printing. '
                    'Confirm whether it printed.',
            'lease_owner': null,
            'lease_expires_at': null,
          },
          where: 'status = ? AND (lease_owner IS NULL OR lease_owner != ?)',
          whereArgs: <Object?>[PrintJobStatus.printing.name, currentLeaseOwner],
        );

        final requeued = await txn.update(
          _table,
          <String, Object?>{
            'status': PrintJobStatus.queued.name,
            'next_attempt_at': now,
            'lease_owner': null,
            'lease_expires_at': null,
          },
          where: 'status IN (?, ?)',
          whereArgs: <Object?>[
            PrintJobStatus.downloading.name,
            PrintJobStatus.claimed.name,
          ],
        );

        return (interrupted: interrupted, requeued: requeued);
      },
    );
  }

  /// Resolves an `interrupted` job the way the operator (or the configured
  /// recovery behaviour) decided.
  Future<void> resolveInterrupted(
    String jobId, {
    required bool printedSuccessfully,
  }) async {
    if (printedSuccessfully) {
      await markCompleted(jobId);
    } else {
      await requeue(jobId);
    }
  }

  // -------------------------------------------------------------------------
  // Maintenance
  // -------------------------------------------------------------------------

  /// Moves terminal jobs older than [retention] into `print_history` and deletes
  /// them from the queue. Returns the number of rows archived.
  Future<int> archiveOldTerminalJobs({
    required Duration retention,
    required int maxHistoryRows,
    int batchSize = 500,
  }) async {
    final cutoff =
        DateTime.now().subtract(retention).millisecondsSinceEpoch;

    return _database.transaction<int>((Transaction txn) async {
      final rows = await txn.query(
        _table,
        where: "status IN ('completed','failed','cancelled') "
            'AND COALESCE(completed_at, created_at) < ? '
            'AND reported_at IS NOT NULL',
        whereArgs: <Object?>[cutoff],
        limit: batchSize,
      );
      if (rows.isEmpty) return 0;

      for (final row in rows) {
        await txn.insert(
          'print_history',
          <String, Object?>{
            'id': row['id'],
            'store_id': row['store_id'],
            'server_job_id': row['server_job_id'],
            'order_reference': row['order_reference'],
            'document_type': row['document_type'],
            'printer_key': row['resolved_printer_key'] ??
                row['requested_printer_key'],
            'status': row['status'],
            'attempt_count': row['attempt_count'],
            'error_code': row['error_code'],
            'error_message': row['error_message'],
            'created_at': row['created_at'],
            'completed_at': row['completed_at'],
            'document_path': row['local_file_path'],
            'document_filename': row['document_filename'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.delete(_table, where: 'id = ?', whereArgs: <Object?>[row['id']]);
      }

      // Enforce the history ceiling so the table cannot grow without bound.
      await txn.rawDelete(
        '''
        DELETE FROM print_history
        WHERE id NOT IN (
          SELECT id FROM print_history
          ORDER BY COALESCE(completed_at, created_at) DESC
          LIMIT ?
        )
        ''',
        <Object?>[maxHistoryRows],
      );

      return rows.length;
    });
  }

  /// Local file paths of archived/terminal jobs, so the downloader can clean up.
  Future<List<String>> orphanedFilePaths() async {
    final rows = await _database.db.rawQuery(
      'SELECT local_file_path FROM $_table '
      "WHERE local_file_path IS NOT NULL AND status IN ('completed','cancelled')",
    );
    return rows
        .map((Map<String, Object?> r) => r['local_file_path'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }

  Future<void> clearLocalFilePath(String jobId) async {
    await _database.db.update(
      _table,
      <String, Object?>{'local_file_path': null},
      where: 'id = ?',
      whereArgs: <Object?>[jobId],
    );
  }

  Future<void> deleteAllForStore(String storeId) async {
    await _database.db
        .delete(_table, where: 'store_id = ?', whereArgs: <Object?>[storeId]);
  }
}
