import '../../logging/log_level.dart';
import '../../logging/log_record.dart';
import '../database.dart';

class LogDao {
  LogDao(this._database);

  final AppDatabase _database;

  Future<void> insertBatch(List<AppLogRecord> records) async {
    if (records.isEmpty) return;
    final batch = _database.db.batch();
    for (final record in records) {
      batch.insert('logs', record.toDatabaseRow());
    }
    await batch.commit(noResult: true);
  }

  /// Deletes the oldest rows so the table never exceeds [maxRows].
  Future<int> trimTo(int maxRows) async {
    final result = await _database.db.rawDelete(
      '''
      DELETE FROM logs
      WHERE id NOT IN (
        SELECT id FROM logs ORDER BY id DESC LIMIT ?
      )
      ''',
      <Object?>[maxRows],
    );
    return result;
  }

  Future<List<AppLogRecord>> query({
    LogLevel? minimumLevel,
    String? category,
    String? search,
    int limit = 500,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];

    if (minimumLevel != null && minimumLevel != LogLevel.trace) {
      final allowed = LogLevel.values
          .where((LogLevel l) =>
              l != LogLevel.off && l.priority >= minimumLevel.priority,)
          .map((LogLevel l) => l.name)
          .toList();
      where.add('level IN (${List<String>.filled(allowed.length, '?').join(',')})');
      args.addAll(allowed);
    }
    if (category != null && category.isNotEmpty) {
      where.add('category = ?');
      args.add(category);
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(message LIKE ? OR context_json LIKE ? OR error LIKE ?)');
      final pattern = '%${search.trim()}%';
      args..add(pattern)..add(pattern)..add(pattern);
    }

    final rows = await _database.db.query(
      'logs',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(AppLogRecord.fromDatabaseRow).toList(growable: false);
  }

  Future<int> count() async {
    final rows = await _database.db.rawQuery('SELECT COUNT(*) AS c FROM logs');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> clear() async {
    await _database.db.delete('logs');
  }
}
