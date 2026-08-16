import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database.dart';

/// A state-changing API call that has been *decided* but not yet *confirmed*.
///
/// The pattern is: record the intent, make the call, mark it confirmed. If the
/// process dies between the call and the confirmation, the record is replayed on
/// the next start with the same `Idempotency-Key`, so the server sees the report
/// exactly once — and the document is never printed a second time.
class PendingReport {
  const PendingReport({
    required this.key,
    required this.jobId,
    required this.action,
    required this.payload,
    required this.createdAt,
    this.confirmedAt,
  });

  final String key;
  final String jobId;

  /// `start`, `complete`, `fail` or `release`.
  final String action;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final DateTime? confirmedAt;

  bool get isConfirmed => confirmedAt != null;

  static PendingReport fromDatabaseRow(Map<String, Object?> row) {
    Map<String, dynamic> payload = <String, dynamic>{};
    final raw = row['payload_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        payload = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        payload = <String, dynamic>{};
      }
    }
    return PendingReport(
      key: row['key']! as String,
      jobId: row['job_id']! as String,
      action: row['action']! as String,
      payload: payload,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((row['created_at'] as int?) ?? 0),
      confirmedAt: row['confirmed_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['confirmed_at']! as int),
    );
  }
}

class IdempotencyDao {
  IdempotencyDao(this._database);

  final AppDatabase _database;

  static const String _table = 'idempotency_keys';

  /// Builds the key sent as the `Idempotency-Key` header.
  static String buildKey({
    required String agentId,
    required String serverJobId,
    required String action,
    required int attempt,
  }) =>
      '$agentId:$serverJobId:$action:$attempt';

  Future<void> record(PendingReport report) async {
    await _database.db.insert(
      _table,
      <String, Object?>{
        'key': report.key,
        'job_id': report.jobId,
        'action': report.action,
        'payload_json': jsonEncode(report.payload),
        'created_at': report.createdAt.millisecondsSinceEpoch,
        'confirmed_at': report.confirmedAt?.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> confirm(String key, {DateTime? at}) async {
    await _database.db.update(
      _table,
      <String, Object?>{
        'confirmed_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      },
      where: 'key = ?',
      whereArgs: <Object?>[key],
    );
  }

  Future<bool> isConfirmed(String key) async {
    final rows = await _database.db.query(
      _table,
      columns: <String>['confirmed_at'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return rows.first['confirmed_at'] != null;
  }

  Future<List<PendingReport>> findPending({int limit = 100}) async {
    final rows = await _database.db.query(
      _table,
      where: 'confirmed_at IS NULL',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(PendingReport.fromDatabaseRow).toList(growable: false);
  }

  /// Confirmed keys are only useful as a short-lived replay guard.
  Future<int> pruneConfirmed({
    Duration retention = const Duration(days: 2),
  }) async {
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    return _database.db.delete(
      _table,
      where: 'confirmed_at IS NOT NULL AND confirmed_at < ?',
      whereArgs: <Object?>[cutoff],
    );
  }

  Future<void> deleteForJob(String jobId) async {
    await _database.db
        .delete(_table, where: 'job_id = ?', whereArgs: <Object?>[jobId]);
  }
}
