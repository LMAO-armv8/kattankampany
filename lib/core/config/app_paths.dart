import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves and creates every directory the agent writes to.
///
/// Everything lives under a single root so an uninstaller can remove it cleanly:
///   %APPDATA%\WooCommercePrintAgent\
///     ├── agent.db
///     ├── credentials\
///     ├── logs\
///     └── documents\        (transient print payloads, pruned aggressively)
class AppPaths {
  AppPaths._(this.root);

  static const String folderName = 'WooCommercePrintAgent';

  final Directory root;

  static AppPaths? _instance;

  static AppPaths get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppPaths.initialize() must be called during bootstrap.');
    }
    return value;
  }

  static Future<AppPaths> initialize({Directory? overrideRoot}) async {
    if (_instance != null && overrideRoot == null) return _instance!;

    Directory base;
    if (overrideRoot != null) {
      base = overrideRoot;
    } else {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        base = Directory(p.join(appData, folderName));
      } else {
        final support = await getApplicationSupportDirectory();
        base = Directory(p.join(support.path, folderName));
      }
    }

    final paths = AppPaths._(base);
    await paths._ensureDirectories();
    _instance = paths;
    return paths;
  }

  /// Test seam.
  static void debugOverride(AppPaths paths) => _instance = paths;

  String get databaseFile => p.join(root.path, 'agent.db');
  Directory get credentialsDir => Directory(p.join(root.path, 'credentials'));
  Directory get logsDir => Directory(p.join(root.path, 'logs'));
  Directory get documentsDir => Directory(p.join(root.path, 'documents'));

  String logFile(int index) =>
      p.join(logsDir.path, index == 0 ? 'agent.log' : 'agent.$index.log');

  Future<void> _ensureDirectories() async {
    for (final dir in <Directory>[
      root,
      credentialsDir,
      logsDir,
      documentsDir,
    ]) {
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    }
  }

  /// Deletes transient print payloads older than [maxAge]. Called by the
  /// maintenance pass so the documents folder cannot grow without bound.
  Future<int> pruneDocuments({Duration maxAge = const Duration(hours: 24)}) async {
    var removed = 0;
    if (!documentsDir.existsSync()) return removed;
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in documentsDir.list()) {
      if (entity is! File) continue;
      try {
        if (entity.statSync().modified.isBefore(cutoff)) {
          await entity.delete();
          removed++;
        }
      } catch (_) {
        // A file still held open by the spooler will be removed on a later pass.
      }
    }
    return removed;
  }
}
