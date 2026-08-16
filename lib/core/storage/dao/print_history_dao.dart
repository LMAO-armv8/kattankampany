import '../database.dart';

/// A condensed record of a finished job. Kept separately from the live queue so
/// the queue table stays small and fast no matter how long the agent runs.
class PrintHistoryEntry {
  const PrintHistoryEntry({
    required this.id,
    required this.status,
    required this.createdAt,
    this.storeId,
    this.serverJobId,
    this.orderReference,
    this.documentType,
    this.printerKey,
    this.attemptCount = 0,
    this.errorCode,
    this.errorMessage,
    this.completedAt,
  });

  final String id;
  final String? storeId;
  final String? serverJobId;
  final String? orderReference;
  final String? documentType;
  final String? printerKey;
  final String status;
  final int attemptCount;
  final String? errorCode;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? completedAt;

  bool get succeeded => status == 'completed';

  static PrintHistoryEntry fromDatabaseRow(Map<String, Object?> row) =>
      PrintHistoryEntry(
        id: row['id']! as String,
        storeId: row['store_id'] as String?,
        serverJobId: row['server_job_id'] as String?,
        orderReference: row['order_reference'] as String?,
        documentType: row['document_type'] as String?,
        printerKey: row['printer_key'] as String?,
        status: (row['status'] as String?) ?? 'unknown',
        attemptCount: (row['attempt_count'] as int?) ?? 0,
        errorCode: row['error_code'] as String?,
        errorMessage: row['error_message'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch((row['created_at'] as int?) ?? 0),
        completedAt: row['completed_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['completed_at']! as int),
      );
}

class PrintHistoryDao {
  PrintHistoryDao(this._database);

  final AppDatabase _database;

  Future<List<PrintHistoryEntry>> query({
    String? status,
    String? printerKey,
    String? search,
    DateTime? since,
    int limit = 200,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (status != null && status.isNotEmpty) {
      where.add('status = ?');
      args.add(status);
    }
    if (printerKey != null && printerKey.isNotEmpty) {
      where.add('printer_key = ?');
      args.add(printerKey);
    }
    if (since != null) {
      where.add('COALESCE(completed_at, created_at) >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(order_reference LIKE ? OR server_job_id LIKE ?)');
      final pattern = '%${search.trim()}%';
      args..add(pattern)..add(pattern);
    }

    final rows = await _database.db.query(
      'print_history',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'COALESCE(completed_at, created_at) DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(PrintHistoryEntry.fromDatabaseRow).toList(growable: false);
  }

  Future<int> count() async {
    final rows =
        await _database.db.rawQuery('SELECT COUNT(*) AS c FROM print_history');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Success/failure totals for the last [window], for the dashboard.
  Future<({int completed, int failed})> summary({
    Duration window = const Duration(days: 7),
  }) async {
    final since = DateTime.now().subtract(window).millisecondsSinceEpoch;
    final rows = await _database.db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM print_history '
      'WHERE COALESCE(completed_at, created_at) >= ? GROUP BY status',
      <Object?>[since],
    );
    var completed = 0;
    var failed = 0;
    for (final row in rows) {
      final count = (row['c'] as int?) ?? 0;
      if (row['status'] == 'completed') {
        completed += count;
      } else if (row['status'] == 'failed') {
        failed += count;
      }
    }
    return (completed: completed, failed: failed);
  }

  Future<void> clear() async {
    await _database.db.delete('print_history');
  }
}
