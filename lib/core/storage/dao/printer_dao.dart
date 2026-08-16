import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printers/domain/printer_device.dart';
import '../../../features/printers/domain/printer_status.dart';
import '../database.dart';

class PrinterDao {
  PrinterDao(this._database);

  final AppDatabase _database;

  Future<List<PrinterDevice>> findAll() async {
    final rows = await _database.db.query('printers', orderBy: 'display_name');
    return rows.map(PrinterDevice.fromDatabaseRow).toList(growable: false);
  }

  Future<List<PrinterDevice>> findEnabled() async {
    final rows = await _database.db.query(
      'printers',
      where: 'is_enabled = 1',
      orderBy: 'display_name',
    );
    return rows.map(PrinterDevice.fromDatabaseRow).toList(growable: false);
  }

  Future<PrinterDevice?> findByKey(String printerKey) async {
    final rows = await _database.db.query(
      'printers',
      where: 'printer_key = ?',
      whereArgs: <Object?>[printerKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PrinterDevice.fromDatabaseRow(rows.first);
  }

  Future<PrinterDevice?> findDefault() async {
    final rows = await _database.db.query(
      'printers',
      where: 'is_default = 1 AND is_enabled = 1',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PrinterDevice.fromDatabaseRow(rows.first);
  }

  Future<void> upsert(PrinterDevice printer) async {
    await _database.db.insert(
      'printers',
      printer.toDatabaseRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Reconciles a discovery pass with what is stored.
  ///
  /// Operator configuration (`is_enabled`, `default_profile_id`) is preserved;
  /// discovery data is refreshed; printers that have disappeared from Windows
  /// are kept but marked offline so job history keeps referring to something.
  Future<void> syncDiscovered(List<PrinterDevice> discovered) async {
    await _database.transaction((Transaction txn) async {
      final existing = await txn.query('printers');
      final existingByKey = <String, Map<String, Object?>>{
        for (final row in existing) row['printer_key']! as String: row,
      };
      final now = DateTime.now().millisecondsSinceEpoch;
      final seen = <String>{};

      for (final printer in discovered) {
        seen.add(printer.printerKey);
        final prior = existingByKey[printer.printerKey];
        final row = printer.toDatabaseRow();
        if (prior != null) {
          row['id'] = prior['id'];
          row['is_enabled'] = prior['is_enabled'];
          row['default_profile_id'] = prior['default_profile_id'];
          row['created_at'] = prior['created_at'];
        }
        row['updated_at'] = now;
        await txn.insert(
          'printers',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final row in existing) {
        final key = row['printer_key']! as String;
        if (seen.contains(key)) continue;
        await txn.update(
          'printers',
          <String, Object?>{
            'last_status': PrinterState.offline.wireValue,
            'last_status_at': now,
            'updated_at': now,
          },
          where: 'printer_key = ?',
          whereArgs: <Object?>[key],
        );
      }
    });
  }

  Future<void> updateStatus(
    String printerKey,
    PrinterState state, {
    DateTime? at,
  }) async {
    final timestamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.db.update(
      'printers',
      <String, Object?>{
        'last_status': state.wireValue,
        'last_status_at': timestamp,
        'updated_at': timestamp,
      },
      where: 'printer_key = ?',
      whereArgs: <Object?>[printerKey],
    );
  }

  Future<void> setEnabled(String printerKey, {required bool enabled}) async {
    await _database.db.update(
      'printers',
      <String, Object?>{
        'is_enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'printer_key = ?',
      whereArgs: <Object?>[printerKey],
    );
  }

  Future<void> setDefaultProfile(String printerKey, String? profileId) async {
    await _database.db.update(
      'printers',
      <String, Object?>{
        'default_profile_id': profileId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'printer_key = ?',
      whereArgs: <Object?>[printerKey],
    );
  }

  Future<void> delete(String printerKey) async {
    await _database.db.delete(
      'printers',
      where: 'printer_key = ?',
      whereArgs: <Object?>[printerKey],
    );
  }
}

class PrintProfileDao {
  PrintProfileDao(this._database);

  final AppDatabase _database;

  Future<List<PrintProfile>> findAll() async {
    final rows = await _database.db.query(
      'print_profiles',
      orderBy: 'is_builtin DESC, name',
    );
    return rows.map(PrintProfile.fromDatabaseRow).toList(growable: false);
  }

  Future<PrintProfile?> findById(String id) async {
    final rows = await _database.db.query(
      'print_profiles',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PrintProfile.fromDatabaseRow(rows.first);
  }

  Future<PrintProfile?> findByName(String name) async {
    final rows = await _database.db.query(
      'print_profiles',
      where: 'name = ?',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PrintProfile.fromDatabaseRow(rows.first);
  }

  Future<void> upsert(PrintProfile profile) async {
    await _database.db.insert(
      'print_profiles',
      profile.toDatabaseRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Built-in profiles cannot be removed — they are the fallback when a job
  /// names a profile that no longer exists.
  Future<bool> delete(String id) async {
    final profile = await findById(id);
    if (profile == null || profile.isBuiltin) return false;
    await _database.db
        .delete('print_profiles', where: 'id = ?', whereArgs: <Object?>[id]);
    return true;
  }
}
