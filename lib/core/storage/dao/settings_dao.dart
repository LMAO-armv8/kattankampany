import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database.dart';

/// Key/value persistence for [AppSettings] and any other small scalar state.
///
/// Settings are stored one field per row (key = the snake_case JSON name,
/// value = JSON-encoded), so adding a field to [AppSettings] does not reset the
/// operator's existing configuration.
class SettingsDao {
  SettingsDao(this._database);

  final AppDatabase _database;

  Future<Map<String, dynamic>> readAll() async {
    final rows = await _database.db.query('settings');
    final result = <String, dynamic>{};
    for (final row in rows) {
      final key = row['key'] as String?;
      final raw = row['value'] as String?;
      if (key == null || raw == null) continue;
      try {
        result[key] = jsonDecode(raw);
      } catch (_) {
        result[key] = raw;
      }
    }
    return result;
  }

  Future<void> writeAll(Map<String, dynamic> values) async {
    if (values.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _database.db.batch();
    values.forEach((String key, dynamic value) {
      batch.insert(
        'settings',
        <String, Object?>{
          'key': key,
          'value': jsonEncode(value),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  Future<T?> read<T>(String key) async {
    final rows = await _database.db.query(
      'settings',
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['value'] as String?;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is T ? decoded : null;
    } catch (_) {
      return raw is T ? raw as T : null;
    }
  }

  Future<void> write(String key, Object? value) =>
      writeAll(<String, dynamic>{key: value});

  Future<void> delete(String key) async {
    await _database.db
        .delete('settings', where: 'key = ?', whereArgs: <Object?>[key]);
  }

  Future<void> clear() async {
    await _database.db.delete('settings');
  }
}
