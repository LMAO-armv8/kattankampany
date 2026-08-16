import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agent/domain/agent.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/print_profile.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../services/api/agent_session.dart';
import '../../services/background/lifecycle_controller.dart';
import '../../services/background/sync_service.dart';
import '../../services/printer/printer_manager.dart';
import '../../services/queue/queue_engine.dart';
import '../../services/queue/queue_repository.dart';
import '../../services/updater/update_service.dart';
import '../config/app_settings.dart';
import '../config/settings_repository.dart';
import '../logging/app_logger.dart';
import '../logging/log_level.dart';
import '../logging/log_record.dart';
import '../storage/dao/log_dao.dart';
import '../storage/dao/print_history_dao.dart';
import 'service_locator.dart';

/// Riverpod's job here is narrow and consistent: adapt the service layer's
/// streams into something widgets can watch. No business logic lives in a
/// provider, and no service ever reads one — see the note in
/// `service_locator.dart`.

// ---------------------------------------------------------------------------
// Service accessors
// ---------------------------------------------------------------------------

final Provider<LifecycleController> lifecycleProvider =
    Provider<LifecycleController>((Ref ref) => sl<LifecycleController>());

final Provider<AgentSession> agentSessionProvider =
    Provider<AgentSession>((Ref ref) => sl<AgentSession>());

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider<SettingsRepository>((Ref ref) => sl<SettingsRepository>());

final Provider<PrinterManager> printerManagerProvider =
    Provider<PrinterManager>((Ref ref) => sl<PrinterManager>());

final Provider<QueueRepository> queueRepositoryProvider =
    Provider<QueueRepository>((Ref ref) => sl<QueueRepository>());

final Provider<QueueEngine> queueEngineProvider =
    Provider<QueueEngine>((Ref ref) => sl<QueueEngine>());

final Provider<SyncService> syncServiceProvider =
    Provider<SyncService>((Ref ref) => sl<SyncService>());

final Provider<UpdateService> updateServiceProvider =
    Provider<UpdateService>((Ref ref) => sl<UpdateService>());

final Provider<AppLogger> loggerProvider =
    Provider<AppLogger>((Ref ref) => sl<AppLogger>());

final Provider<LogDao> logDaoProvider = Provider<LogDao>((Ref ref) => sl<LogDao>());

// ---------------------------------------------------------------------------
// Reactive state
// ---------------------------------------------------------------------------

/// Current settings. Seeded synchronously so the UI never flashes defaults.
final StreamProvider<AppSettings> settingsProvider =
    StreamProvider<AppSettings>((Ref ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  return _seeded<AppSettings>(repository.current, repository.changes);
});

/// The dashboard's single source of truth.
final StreamProvider<AgentRuntimeStatus> runtimeStatusProvider =
    StreamProvider<AgentRuntimeStatus>((Ref ref) {
  final controller = ref.watch(lifecycleProvider);
  return _seeded<AgentRuntimeStatus>(
    controller.status,
    controller.statusChanges,
  );
});

final StreamProvider<AgentConnectionState> connectionStateProvider =
    StreamProvider<AgentConnectionState>((Ref ref) {
  final session = ref.watch(agentSessionProvider);
  return _seeded<AgentConnectionState>(session.state, session.stateChanges);
});

final StreamProvider<List<PrinterDevice>> printersProvider =
    StreamProvider<List<PrinterDevice>>((Ref ref) {
  final manager = ref.watch(printerManagerProvider);
  return _seeded<List<PrinterDevice>>(manager.printers, manager.changes);
});

final Provider<List<PrintProfile>> printProfilesProvider =
    Provider<List<PrintProfile>>((Ref ref) {
  // Rebuilt whenever the printer manager emits, which it also does after a
  // profile is saved or deleted.
  ref.watch(printersProvider);
  return ref.watch(printerManagerProvider).profiles;
});

/// Jobs currently in the queue or needing attention.
final StreamProvider<List<PrintJob>> queueJobsProvider =
    StreamProvider<List<PrintJob>>((Ref ref) {
  final queue = ref.watch(queueRepositoryProvider);
  return _reload<List<PrintJob>>(
    queue.changes,
    () => queue.activeAndPending(),
  );
});

/// The dashboard's "recent jobs" table.
final StreamProvider<List<PrintJob>> recentJobsProvider =
    StreamProvider<List<PrintJob>>((Ref ref) {
  final queue = ref.watch(queueRepositoryProvider);
  return _reload<List<PrintJob>>(
    queue.changes,
    () => queue.recent(limit: 12),
  );
});

final StreamProvider<QueueCounters> queueCountersProvider =
    StreamProvider<QueueCounters>((Ref ref) {
  final queue = ref.watch(queueRepositoryProvider);
  return _reload<QueueCounters>(queue.changes, queue.counters);
});

final StreamProvider<QueueEngineState> queueEngineStateProvider =
    StreamProvider<QueueEngineState>((Ref ref) {
  final engine = ref.watch(queueEngineProvider);
  return _seeded<QueueEngineState>(engine.state, engine.stateChanges);
});

/// Filter state for the History screen.
class HistoryFilter {
  const HistoryFilter({this.status, this.printerKey, this.search});

  final String? status;
  final String? printerKey;
  final String? search;

  HistoryFilter copyWith({
    String? status,
    String? printerKey,
    String? search,
    bool clearStatus = false,
    bool clearPrinter = false,
  }) =>
      HistoryFilter(
        status: clearStatus ? null : (status ?? this.status),
        printerKey: clearPrinter ? null : (printerKey ?? this.printerKey),
        search: search ?? this.search,
      );
}

final StateProvider<HistoryFilter> historyFilterProvider =
    StateProvider<HistoryFilter>((Ref ref) => const HistoryFilter());

final FutureProvider<List<PrintHistoryEntry>> historyProvider =
    FutureProvider<List<PrintHistoryEntry>>((Ref ref) async {
  final queue = ref.watch(queueRepositoryProvider);
  final filter = ref.watch(historyFilterProvider);
  // Re-run when the queue archives new rows.
  ref.watch(queueCountersProvider);
  return queue.history(
    status: filter.status,
    printerKey: filter.printerKey,
    search: filter.search,
    limit: 300,
  );
});

/// Filter state for the Logs view.
class LogFilter {
  const LogFilter({
    this.minimumLevel = LogLevel.info,
    this.category,
    this.search,
  });

  final LogLevel minimumLevel;
  final String? category;
  final String? search;

  LogFilter copyWith({
    LogLevel? minimumLevel,
    String? category,
    String? search,
    bool clearCategory = false,
  }) =>
      LogFilter(
        minimumLevel: minimumLevel ?? this.minimumLevel,
        category: clearCategory ? null : (category ?? this.category),
        search: search ?? this.search,
      );
}

final StateProvider<LogFilter> logFilterProvider =
    StateProvider<LogFilter>((Ref ref) => const LogFilter());

/// Log records for the viewer. Refreshed on demand rather than tailing live, so
/// scrolling through history is not fighting a stream of new lines.
final FutureProvider<List<AppLogRecord>> logRecordsProvider =
    FutureProvider<List<AppLogRecord>>((Ref ref) async {
  final dao = ref.watch(logDaoProvider);
  final filter = ref.watch(logFilterProvider);
  return dao.query(
    minimumLevel: filter.minimumLevel,
    category: filter.category,
    search: filter.search,
    limit: 500,
  );
});

// ---------------------------------------------------------------------------
// Stream helpers
// ---------------------------------------------------------------------------

/// Emits [initial] immediately, then everything from [stream].
Stream<T> _seeded<T>(T initial, Stream<T> stream) async* {
  yield initial;
  yield* stream;
}

/// Runs [load] once, then again after every event on [trigger].
///
/// Events are coalesced with a microtask-level guard so a burst of queue
/// changes produces one reload, not twenty.
Stream<T> _reload<T>(Stream<void> trigger, Future<T> Function() load) {
  // The controller's lifetime is the returned stream's; the trigger
  // subscription is released in onCancel, so there is nothing to close here.
  // ignore: close_sinks
  late StreamController<T> controller;
  StreamSubscription<void>? subscription;
  var loading = false;
  var pending = false;

  Future<void> run() async {
    if (loading) {
      pending = true;
      return;
    }
    loading = true;
    try {
      final value = await load();
      if (!controller.isClosed) controller.add(value);
    } catch (e, st) {
      if (!controller.isClosed) controller.addError(e, st);
    } finally {
      loading = false;
      if (pending) {
        pending = false;
        unawaited(run());
      }
    }
  }

  controller = StreamController<T>(
    onListen: () {
      unawaited(run());
      subscription = trigger.listen((_) => unawaited(run()));
    },
    onCancel: () async {
      await subscription?.cancel();
      subscription = null;
    },
  );
  return controller.stream;
}
