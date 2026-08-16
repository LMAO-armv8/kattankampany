import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../features/agent/domain/agent.dart';
import '../database.dart';

class AgentDao {
  AgentDao(this._database);

  final AppDatabase _database;

  Future<Agent?> findByStore(String storeId) async {
    final rows = await _database.db.query(
      'agents',
      where: 'store_id = ?',
      whereArgs: <Object?>[storeId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Agent.fromDatabaseRow(rows.first);
  }

  Future<Agent?> findById(String id) async {
    final rows = await _database.db
        .query('agents', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    if (rows.isEmpty) return null;
    return Agent.fromDatabaseRow(rows.first);
  }

  Future<void> upsert(Agent agent) async {
    await _database.db.insert(
      'agents',
      agent.toDatabaseRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchSync(String agentId, DateTime at) async {
    await _database.db.update(
      'agents',
      <String, Object?>{
        'last_sync_at': at.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[agentId],
    );
  }

  Future<void> touchHeartbeat(String agentId, DateTime at) async {
    await _database.db.update(
      'agents',
      <String, Object?>{
        'last_heartbeat_at': at.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[agentId],
    );
  }

  Future<void> updateStatus(String agentId, AgentStatus status) async {
    await _database.db.update(
      'agents',
      <String, Object?>{
        'status': status.name,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[agentId],
    );
  }

  Future<void> delete(String id) async {
    await _database.db
        .delete('agents', where: 'id = ?', whereArgs: <Object?>[id]);
  }
}
