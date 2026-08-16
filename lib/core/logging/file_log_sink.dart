import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_paths.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_sink.dart';

/// The durable log: a size-rotated set of plain text files under
/// `%APPDATA%\WooCommercePrintAgent\logs\`.
///
/// Bounded growth is enforced by [maxFileSizeBytes] × [maxFiles]; with the
/// defaults the agent can never use more than ~25 MB of disk for logs no matter
/// how long it runs.
class FileLogSink extends BaseLogSink {
  FileLogSink({
    required this.paths,
    super.minimumLevel = LogLevel.info,
    this.maxFileSizeBytes = 5 * 1024 * 1024,
    this.maxFiles = 5,
    this.flushInterval = const Duration(seconds: 2),
  });

  final AppPaths paths;
  int maxFileSizeBytes;
  int maxFiles;
  final Duration flushInterval;

  final List<String> _buffer = <String>[];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _closed = false;
  int _currentSize = -1;

  @override
  Future<void> write(AppLogRecord record) async {
    if (_closed || !accepts(record)) return;
    _buffer.add(record.toLogLine());
    // Errors go to disk immediately — they are the ones that matter after a crash.
    if (record.level.isAtLeast(LogLevel.error) || _buffer.length >= 200) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(flushInterval, () {
        _flushTimer = null;
        unawaited(flush());
      });
    }
  }

  @override
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    final pending = List<String>.of(_buffer);
    _buffer.clear();
    try {
      final file = File(paths.logFile(0));
      if (_currentSize < 0) {
        _currentSize = file.existsSync() ? file.lengthSync() : 0;
      }
      final payload = '${pending.join('\n')}\n';
      final bytes = utf8.encode(payload);
      if (_currentSize + bytes.length > maxFileSizeBytes) {
        await _rotate();
        _currentSize = 0;
      }
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: false);
      _currentSize += bytes.length;
    } catch (_) {
      // A log sink must never surface an error. Drop the batch and carry on;
      // the console and database sinks still have the records in debug builds.
      _currentSize = -1;
    } finally {
      _flushing = false;
    }
  }

  Future<void> _rotate() async {
    try {
      final oldest = File(paths.logFile(maxFiles - 1));
      if (oldest.existsSync()) await oldest.delete();
      for (var i = maxFiles - 2; i >= 0; i--) {
        final source = File(paths.logFile(i));
        if (source.existsSync()) {
          await source.rename(paths.logFile(i + 1));
        }
      }
    } catch (_) {
      // If rotation fails (file locked by a viewer), truncate instead so the
      // size cap is still honoured.
      try {
        await File(paths.logFile(0)).writeAsBytes(const <int>[]);
      } catch (_) {
        /* give up silently */
      }
    }
  }

  /// Concatenates the rotated set oldest-first for "Export logs".
  /// Truncates from the *front* when the total exceeds [maxBytes], so the most
  /// recent activity — the part support actually needs — is always retained.
  Future<String> readAll({int maxBytes = 8 * 1024 * 1024}) async {
    await flush();
    final chunks = <String>[];
    for (var i = maxFiles - 1; i >= 0; i--) {
      final file = File(paths.logFile(i));
      if (!file.existsSync()) continue;
      try {
        chunks.add(await file.readAsString());
      } catch (_) {
        chunks.add('--- could not read ${file.path} ---\n');
      }
    }
    final combined = chunks.join();
    if (combined.length <= maxBytes) return combined;
    return '--- truncated: showing the most recent ${maxBytes ~/ 1024} KB ---\n'
        '${combined.substring(combined.length - maxBytes)}';
  }

  /// Total bytes currently consumed by log files.
  int currentSizeBytes() {
    var total = 0;
    for (var i = 0; i < maxFiles; i++) {
      final file = File(paths.logFile(i));
      if (file.existsSync()) {
        try {
          total += file.lengthSync();
        } catch (_) {
          /* ignore */
        }
      }
    }
    return total;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }
}
