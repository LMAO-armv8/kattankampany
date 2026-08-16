import 'dart:async';

import '../storage/dao/log_dao.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_sink.dart';

/// A bounded mirror of the log in SQLite so the in-app viewer can filter and
/// page without parsing files. Writes are batched to keep the event loop free.
class DatabaseLogSink extends BaseLogSink {
  DatabaseLogSink({
    required this.dao,
    super.minimumLevel = LogLevel.debug,
    this.flushInterval = const Duration(seconds: 2),
    this.batchSize = 100,
    this.maxRows = 5000,
  });

  final LogDao dao;
  final Duration flushInterval;
  final int batchSize;
  int maxRows;

  final List<AppLogRecord> _buffer = <AppLogRecord>[];
  final StreamController<AppLogRecord> _live =
      StreamController<AppLogRecord>.broadcast();
  Timer? _timer;
  bool _flushing = false;
  bool _closed = false;
  int _writesSinceTrim = 0;

  /// Live tail for the log viewer. Broadcast, no replay buffer.
  Stream<AppLogRecord> get stream => _live.stream;

  @override
  Future<void> write(AppLogRecord record) async {
    if (_closed || !accepts(record)) return;
    _buffer.add(record);
    if (_live.hasListener) _live.add(record);
    if (_buffer.length >= batchSize ||
        record.level.isAtLeast(LogLevel.error)) {
      unawaited(flush());
    } else {
      _timer ??= Timer(flushInterval, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  @override
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    final pending = List<AppLogRecord>.of(_buffer);
    _buffer.clear();
    try {
      await dao.insertBatch(pending);
      _writesSinceTrim += pending.length;
      // Trim occasionally rather than on every insert — the cap is a ceiling,
      // not a precise limit, and DELETE with a subquery is comparatively costly.
      if (_writesSinceTrim >= 250) {
        _writesSinceTrim = 0;
        await dao.trimTo(maxRows);
      }
    } catch (_) {
      // Never surface a logging failure.
    } finally {
      _flushing = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await flush();
    await _live.close();
  }
}
