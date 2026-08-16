import 'dart:async';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/app_paths.dart';
import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import '../logging/log_level.dart';
import 'migrations.dart';

/// Owns the SQLite connection.
///
/// One connection for the whole process. `sqflite_common_ffi` serialises access
/// internally, and every DAO goes through here, so there is no cross-isolate
/// contention to manage.
class AppDatabase {
  AppDatabase({AppLogger? logger}) : _logger = logger;

  final AppLogger? _logger;
  Database? _db;

  bool get isOpen => _db != null;

  Database get db {
    final value = _db;
    if (value == null) {
      throw const StorageException(
        technicalDetail: 'AppDatabase.open() has not been called.',
      );
    }
    return value;
  }

  /// Must be called once, before any DAO is used.
  ///
  /// [path] defaults to the per-user application data folder. Pass
  /// `inMemoryDatabasePath` in tests.
  Future<void> open({String? path}) async {
    if (_db != null) return;
    try {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      final resolvedPath = path ?? AppPaths.instance.databaseFile;
      _logger?.info(LogCategory.storage, 'Opening database',
          context: <String, Object?>{'path': resolvedPath},);

      _db = await databaseFactory.openDatabase(
        resolvedPath,
        options: OpenDatabaseOptions(
          version: latestVersion,
          onConfigure: (Database database) async {
            await database.execute('PRAGMA foreign_keys = ON');
            await database.execute('PRAGMA busy_timeout = 5000');
          },
          onCreate: (Database database, int version) async {
            await applyMigrations(database, from: 0, to: version);
            await _seedBuiltins(database);
          },
          onUpgrade: (Database database, int oldVersion, int newVersion) async {
            _logger?.info(LogCategory.storage,
                'Migrating database $oldVersion → $newVersion',);
            await applyMigrations(database, from: oldVersion, to: newVersion);
          },
          onOpen: (Database database) async {
            // WAL keeps readers (the UI) from blocking the queue engine's writes.
            if (resolvedPath != inMemoryDatabasePath) {
              await database.rawQuery('PRAGMA journal_mode = WAL');
            }
          },
        ),
      );
    } on AppException {
      rethrow;
    } catch (e, st) {
      throw StorageException(
        technicalDetail: 'Failed to open database: $e',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Runs [action] inside a transaction, mapping any driver error to
  /// [StorageException].
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    try {
      return await db.transaction<T>(action);
    } on AppException {
      rethrow;
    } catch (e, st) {
      throw StorageException(
        technicalDetail: 'Transaction failed: $e',
        cause: e,
        stackTrace: st,
      );
    }
  }

  Future<void> close() async {
    final value = _db;
    _db = null;
    await value?.close();
  }

  /// Size of the database file on disk, for the diagnostics screen.
  int fileSizeBytes() {
    try {
      final file = File(AppPaths.instance.databaseFile);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Reclaims space after a large history prune. Safe to call while idle.
  Future<void> vacuum() async {
    try {
      await db.execute('VACUUM');
    } catch (e) {
      _logger?.warn(LogCategory.storage, 'VACUUM failed',
          context: <String, Object?>{'error': e.toString()},);
    }
  }

  /// Built-in, vendor-neutral print profiles. Deliberately generic: paper sizes
  /// and roll widths, never printer model names.
  static Future<void> _seedBuiltins(DatabaseExecutor database) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    Future<void> insert(
      String id,
      String name,
      String paperSize, {
      double? widthMm,
      double? heightMm,
      String orientation = 'portrait',
      String scaling = 'fit',
      double margin = 0,
      String strategy = 'auto',
    }) =>
        database.insert('print_profiles', <String, Object?>{
          'id': id,
          'name': name,
          'paper_size': paperSize,
          'width_mm': widthMm,
          'height_mm': heightMm,
          'orientation': orientation,
          'scaling': scaling,
          'margin_top_mm': margin,
          'margin_right_mm': margin,
          'margin_bottom_mm': margin,
          'margin_left_mm': margin,
          'copies': 1,
          'quality': 'normal',
          'color': 1,
          'duplex': 'simplex',
          'strategy': strategy,
          'is_builtin': 1,
          'created_at': now,
          'updated_at': now,
        });

    await insert('profile_a4', 'A4 Document', 'a4', margin: 10);
    await insert('profile_letter', 'Letter Document', 'letter', margin: 10);
    await insert(
      'profile_label_4x6',
      '4x6 Label',
      'custom',
      widthMm: 101.6,
      heightMm: 152.4,
      scaling: 'fit',
    );
    await insert(
      'profile_receipt_80',
      '80mm Receipt',
      'custom',
      widthMm: 80,
      heightMm: 297,
      scaling: 'fit',
    );
  }
}
