import 'dart:async';

import '../../core/config/settings_repository.dart';
import '../../core/errors/app_exception.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/network/connectivity_monitor.dart';
import '../../features/agent/domain/agent.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../api/agent_session.dart';
import '../api/dto/print_job_dto.dart';
import '../queue/job_reporter.dart';
import '../queue/queue_engine.dart';
import '../queue/queue_repository.dart';
import 'job_source.dart';

/// Fetches jobs by polling `GET /print-jobs`.
class PollingJobSource implements JobSource {
  PollingJobSource(this._session);

  final AgentSession _session;

  @override
  String get name => 'HTTP polling';

  @override
  bool get requiresPolling => true;

  @override
  Future<List<RemotePrintJob>> fetch({int limit = 10}) =>
      _session.api.fetchJobs(limit: limit);
}

/// One iteration's result, surfaced on the dashboard.
class SyncResult {
  const SyncResult({
    required this.at,
    this.fetched = 0,
    this.claimed = 0,
    this.duplicatesIgnored = 0,
    this.error,
  });

  final DateTime at;
  final int fetched;
  final int claimed;
  final int duplicatesIgnored;
  final AppException? error;

  bool get succeeded => error == null;
  bool get foundWork => claimed > 0;
}

/// Pulls work from the store into the local queue.
///
/// Deliberately does **not** print anything — it fetches, claims and enqueues,
/// then wakes [QueueEngine]. Keeping the two apart is what lets the polling
/// transport be replaced later, and what stops a slow printer from throttling
/// the sync loop.
///
/// The interval adapts (see `docs/ARCHITECTURE.md` §7): fast while there is
/// work, widening while the queue stays empty, wider still while offline. At
/// the 3-second default an idle agent settles to one request every 30 seconds
/// instead of 1 200 an hour.
class SyncService {
  SyncService({
    required AgentSession session,
    required QueueRepository queue,
    required QueueEngine engine,
    required JobReporter reporter,
    required SettingsRepository settings,
    required ConnectivityMonitor connectivity,
    JobSource? source,
    AppLogger? logger,
  })  : _session = session,
        _queue = queue,
        _engine = engine,
        _reporter = reporter,
        _settings = settings,
        _connectivity = connectivity,
        _logger = logger {
    _source = source ?? PollingJobSource(session);
  }

  final AgentSession _session;
  final QueueRepository _queue;
  final QueueEngine _engine;
  final JobReporter _reporter;
  final SettingsRepository _settings;
  final ConnectivityMonitor _connectivity;
  final AppLogger? _logger;

  late final JobSource _source;

  final StreamController<SyncResult> _results =
      StreamController<SyncResult>.broadcast();

  Timer? _timer;
  bool _running = false;
  bool _paused = false;
  bool _syncing = false;
  int _consecutiveEmptyPolls = 0;
  int _consecutiveFailures = 0;
  Duration _currentInterval = const Duration(seconds: 3);
  SyncResult? _lastResult;
  StreamSubscription<void>? _settingsSubscription;

  bool get isRunning => _running;
  bool get isPaused => _paused;
  Duration get currentInterval => _currentInterval;
  SyncResult? get lastResult => _lastResult;
  DateTime? get lastSuccessfulSyncAt => _session.lastSuccessfulSyncAt;
  String get sourceName => _source.name;
  Stream<SyncResult> get results => _results.stream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _paused = false;
    _currentInterval = _settings.current.syncInterval;
    _consecutiveEmptyPolls = 0;

    _settingsSubscription ??= _settings.changes.listen((_) {
      // A changed interval takes effect on the next tick, not the next hour.
      if (_consecutiveEmptyPolls == 0) {
        _currentInterval = _settings.current.syncInterval;
        _reschedule();
      }
    });

    _logger?.info(
      LogCategory.sync,
      'Sync started (${_source.name}, '
      'every ${_currentInterval.inSeconds}s)',
    );
    _schedule(Duration.zero);
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _settingsSubscription?.cancel();
    _settingsSubscription = null;
    _logger?.info(LogCategory.sync, 'Sync stopped');
  }

  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
    _logger?.info(LogCategory.sync, 'Sync paused');
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _consecutiveEmptyPolls = 0;
    _currentInterval = _settings.current.syncInterval;
    _logger?.info(LogCategory.sync, 'Sync resumed');
    if (_running) _schedule(Duration.zero);
  }

  /// Immediate sync, resetting the backoff. Used by "Sync now" and after an
  /// operator action that is likely to have produced work.
  Future<SyncResult> syncNow() async {
    _consecutiveEmptyPolls = 0;
    _currentInterval = _settings.current.syncInterval;
    final result = await _runOnce();
    _reschedule();
    return result;
  }

  // -------------------------------------------------------------------------
  // The loop
  // -------------------------------------------------------------------------

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_running || _paused) return;
    if (delay > Duration.zero) _currentInterval = delay;
    _timer = Timer(delay, () async {
      await _runOnce();
      _schedule(_nextInterval());
    });
  }

  void _reschedule() => _schedule(_nextInterval());

  Duration _nextInterval() {
    final settings = _settings.current;

    if (!_connectivity.status.isOnline || _consecutiveFailures > 0) {
      // Offline or erroring: back off hard, but never stop trying.
      final base = settings.offlineRetryInterval;
      final multiplier = _consecutiveFailures.clamp(1, 6);
      final backed = base * multiplier;
      return backed > const Duration(minutes: 5)
          ? const Duration(minutes: 5)
          : backed;
    }

    if (!settings.idleBackoffEnabled ||
        _consecutiveEmptyPolls < settings.idleBackoffAfterEmptyPolls) {
      return settings.syncInterval;
    }

    // Geometric widening, capped. Cuts idle API traffic by an order of
    // magnitude without making a real job wait noticeably longer.
    final steps =
        _consecutiveEmptyPolls - settings.idleBackoffAfterEmptyPolls + 1;
    final widened = Duration(
      milliseconds:
          (settings.syncInterval.inMilliseconds * (1 << steps.clamp(0, 6))),
    );
    return widened > settings.maxIdleInterval
        ? settings.maxIdleInterval
        : widened;
  }

  Future<SyncResult> _runOnce() async {
    if (_syncing) {
      return _lastResult ?? SyncResult(at: DateTime.now());
    }
    if (!_session.isPaired) {
      return _record(SyncResult(at: DateTime.now()));
    }
    if (_session.state == AgentConnectionState.unauthorised) {
      // Nothing to gain from polling with a rejected token.
      return _record(SyncResult(at: DateTime.now()));
    }

    _syncing = true;
    try {
      // Any outcome the store has not acknowledged goes out first, so a
      // completed print is never lost behind a queue of new work.
      await _reporter.replayPending();

      final jobs = await _source.fetch(limit: 10);
      _session.markSyncSuccess();
      _consecutiveFailures = 0;

      if (jobs.isEmpty) {
        _consecutiveEmptyPolls++;
        return _record(SyncResult(at: DateTime.now()));
      }

      _consecutiveEmptyPolls = 0;
      _currentInterval = _settings.current.syncInterval;

      var claimed = 0;
      var duplicates = 0;
      final storeId = _session.store!.id;
      final agentId = _session.serverAgentId;
      final maxAttempts = _settings.current.retryMaxAttempts;

      for (final remote in jobs) {
        // Already known locally? Do not claim it again — this is the first
        // line of duplicate defence, before the database constraint.
        final existing = await _queue.dao
            .findByServerJobId(storeId, remote.serverJobId);
        if (existing != null) {
          duplicates++;
          continue;
        }

        if (agentId != null) {
          final claim = await _session.api.claimJob(
            serverJobId: remote.serverJobId,
            agentId: agentId,
          );
          if (!claim.claimed) {
            _logger?.debug(
              LogCategory.sync,
              'Job claimed by another agent',
              context: <String, Object?>{
                'server_job_id': remote.serverJobId,
                'reason': claim.reason,
              },
            );
            continue;
          }
        }

        final job = (claimIntoJob(remote, storeId, maxAttempts))
            .copyWith(claimedAt: DateTime.now());
        final inserted = await _queue.enqueue(job);
        if (inserted) {
          claimed++;
        } else {
          duplicates++;
        }
      }

      if (claimed > 0) _engine.wake();

      return _record(
        SyncResult(
          at: DateTime.now(),
          fetched: jobs.length,
          claimed: claimed,
          duplicatesIgnored: duplicates,
        ),
      );
    } on AuthException catch (e) {
      _consecutiveFailures++;
      _logger?.warn(
        LogCategory.sync,
        'Sync stopped: the store rejected this agent',
        context: <String, Object?>{'detail': e.technicalDetail},
      );
      return _record(SyncResult(at: DateTime.now(), error: e));
    } on ForbiddenException catch (e) {
      _consecutiveFailures++;
      return _record(SyncResult(at: DateTime.now(), error: e));
    } on RateLimitException catch (e) {
      _consecutiveFailures++;
      if (e.retryAfter != null) {
        _schedule(e.retryAfter!);
      }
      return _record(SyncResult(at: DateTime.now(), error: e));
    } on AppException catch (e) {
      _consecutiveFailures++;
      _session.markOffline();
      _logger?.debug(
        LogCategory.sync,
        'Sync failed',
        context: <String, Object?>{
          'code': e.code,
          'consecutive_failures': _consecutiveFailures,
        },
      );
      return _record(SyncResult(at: DateTime.now(), error: e));
    } catch (e, st) {
      _consecutiveFailures++;
      _logger?.exception(LogCategory.sync, 'Sync failed unexpectedly', e, st);
      return _record(
        SyncResult(at: DateTime.now(), error: asAppException(e, st)),
      );
    } finally {
      _syncing = false;
    }
  }

  /// Converts a remote job into a local one. Extracted so tests can assert the
  /// mapping without a live server.
  static PrintJob claimIntoJob(
    RemotePrintJob remote,
    String storeId,
    int maxAttempts,
  ) =>
      remote.toPrintJob(storeId: storeId, maxAttempts: maxAttempts);

  SyncResult _record(SyncResult result) {
    _lastResult = result;
    if (!_results.isClosed) _results.add(result);
    return result;
  }

  Future<void> dispose() async {
    await stop();
    await _results.close();
  }
}
