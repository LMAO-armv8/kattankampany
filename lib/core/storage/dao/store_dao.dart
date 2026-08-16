import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../features/agent/domain/store_connection.dart';
import '../database.dart';

class StoreDao {
  StoreDao(this._database);

  final AppDatabase _database;

  Future<StoreConnection?> findActive() async {
    final rows = await _database.db.query(
      'stores',
      where: 'is_active = 1',
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return StoreConnection.fromDatabaseRow(rows.first);
  }

  Future<StoreConnection?> findById(String id) async {
    final rows = await _database.db
        .query('stores', where: 'id = ?', whereArgs: <Object?>[id], limit: 1);
    if (rows.isEmpty) return null;
    return StoreConnection.fromDatabaseRow(rows.first);
  }

  Future<StoreConnection?> findByBaseUrl(String baseUrl) async {
    final rows = await _database.db.query(
      'stores',
      where: 'base_url = ?',
      whereArgs: <Object?>[baseUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return StoreConnection.fromDatabaseRow(rows.first);
  }

  Future<List<StoreConnection>> findAll() async {
    final rows = await _database.db.query('stores', orderBy: 'created_at');
    return rows.map(StoreConnection.fromDatabaseRow).toList(growable: false);
  }

  Future<void> upsert(StoreConnection store) async {
    await _database.db.insert(
      'stores',
      store.toDatabaseRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Makes [id] the only active store. Multi-store support later relaxes this.
  Future<void> setActive(String id) async {
    await _database.transaction((Transaction txn) async {
      await txn.update('stores', <String, Object?>{'is_active': 0});
      await txn.update(
        'stores',
        <String, Object?>{
          'is_active': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    });
  }

  /// Removes the store and — via ON DELETE CASCADE — its agent and jobs.
  Future<void> delete(String id) async {
    await _database.db
        .delete('stores', where: 'id = ?', whereArgs: <Object?>[id]);
  }
}
