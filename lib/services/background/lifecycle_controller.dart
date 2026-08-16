import 'dart:async';

import '../../core/config/app_settings.dart';
import '../../core/config/settings_repository.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/network/connectivity_monitor.dart';
import '../../features/agent/domain/agent.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../api/agent_session.dart';
import '../api/dto/agent_dto.dart';
import '../printer/printer_manager.dart';
import '../queue/job_reporter.dart';
import '../queue/queue_engine.dart';
import '../queue/queue_repository.dart';
import '../updater/update_service.dart';
import 'autostart_service.dart';
import 'heartbeat_service.dart';
import 'sync_service.dart';
import 'tray_service.dart';

/// A snapshot of everything the dashboard and the tray need.
class AgentRuntimeStatus {
  const AgentRuntimeStatus({
    required this.connection,
    required this.network,
    required this.paused,
    required this.counters,
    this.storeName,
    this.storeUrl,
    this.agentName,
    this.lastSyncAt,
    this.lastHeartbeatAt,
    this.syncIntervalSeconds,
    this.lastError,
  });

  final AgentConnectionState connection;
  final NetworkStatus network;
  final bool paused;
  final QueueCounters counters;
  final String? storeName;
  final String? storeUrl;
  final String? agentName;
  final DateTime? lastSyncAt;
  final DateTime? lastHeartbeatAt;
  final int? syncIntervalSeconds;
  final String? lastError;

  /// What the dashboard badge shows.
  AgentConnectionState get effectiveConnection {
    if (paused) return AgentConnectionState.paused;
    if (connection == AgentConnectionState.connected &&
        network == NetworkStatus.offline) {
      return AgentConnectionState.offline;
    }
    return connection;
  }

  static const AgentRuntimeStatus initial = AgentRuntimeStatus(
    connection: AgentConnectionState.disconnected,
    network: NetworkStatus.unknown,
    paused: false,
    counters: QueueCounters.empty,
  );
}

/// Starts, stops and coordinates every long-lived service.
///
/// This is the only object that owns lifetimes. The UI, the tray menu and the
/// server's push commands all route through it, which is why closing the window
/// cannot leave a half-running agent and why "pause" means the same thing
/// whichever surface triggered it.
class LifecycleController {
  LifecycleController({
    required AgentSession session,
    required SettingsRepository settings,
    required PrinterManager printers,
    required QueueRepository queue,
    required QueueEngine engine,
    required SyncService sync,
    required HeartbeatService heartbeat,
    required JobReporter reporter,
    required ConnectivityMonitor connectivity,
    required AutostartService autostart,
    required UpdateService updater,
    TrayService? tray,
    AppLogger? logger,
  })  : _session = session,
        _settings = settings,
        _printers = printers,
        _queue = queue,
        _engine = engine,
        _sync = sync,
        _heartbeat = heartbeat,
        _reporter = reporter,
        _connectivity = connectivity,
        _autostart = autostart,
        _updater = updater,
        _tray = tray,
        _logger = logger;

  final AgentSession _session;
  final SettingsRepository _settings;
  final PrinterManager _printers;
  final QueueRepository _queue;
  final QueueEngine _engine;
  final SyncService _sync;
  final HeartbeatService _heartbeat;
  final JobReporter _reporter;
  final ConnectivityMonitor _connectivity;
  final AutostartService _autostart;
  final UpdateService _updater;
  final TrayService? _tray;
  final AppLogger? _logger;

  final StreamController<AgentRuntimeStatus> _statusController =
      StreamController<AgentRuntimeStatus>.broadcast();

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  AgentRuntimeStatus _status = AgentRuntimeStatus.initial;
  bool _paused = false;
  bool _started = false;
  Timer? _statusTimer;

  AgentRuntimeStatus get status => _status;
  bool get isPaused => _paused;
  bool get isRunning => _started;
  Stream<AgentRuntimeStatus> get statusChanges => _statusController.stream;

  AgentSession get session => _session;
  PrinterManager get printers => _printers;
  QueueRepository get queue => _queue;
  QueueEngine get engine => _engine;
  SyncService get sync => _sync;
  UpdateService get updater => _updater;
  AutostartService get autostart => _autostart;

  /// Set by the UI layer so tray navigation can change the visible route.
  void Function(String route)? onNavigate;

  /// Set by the UI layer so the tray "Open" action can restore the window.
  Future<void> Function()? onShowWindow;

  /// Set by [main] so "Exit" can shut the process down cleanly.
  Future<void> Function()? onExitRequested;

  // -------------------------------------------------------------------------
  // Start / stop
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _logger?.info(LogCategory.app, 'Starting agent services');

    await _printers.initialise();
    _printers.startStatusPolling();

    _subscriptions.add(
      _printers.changes.listen((_) {
        unawaited(_heartbeat.syncPrintersIfChanged());
        unawaited(_refreshStatus());
      }),
    );
    _subscriptions.add(
      _queue.changes.listen((_) => unawaited(_refreshStatus())),
    );
    _subscriptions.add(
      _session.stateChanges.listen((_) => unawaited(_refreshStatus())),
    );
    _subscriptions.add(
      _connectivity.changes.listen((NetworkStatus next) {
        unawaited(_refreshStatus());
        if (next == NetworkStatus.online) {
          // Reconnected: push anything the store has not heard about, then
          // resume the fast poll cadence.
          unawaited(_onReconnected());
        }
      }),
    );
    _subscriptions.add(
      _settings.changes.listen((AppSettings next) {
        unawaited(_applySettings(next));
      }),
    );
    _subscriptions.add(_engine.stateChanges.listen((_) => unawaited(_refreshStatus())));
    _subscriptions.add(_sync.results.listen((_) => unawaited(_refreshStatus())));

    _heartbeat.onCommand = _handleServerCommand;

    await _connectivity.start(storeBaseUrl: _session.store?.baseUrl);
    await _engine.start();

    if (_session.isPaired) {
      await _session.verify();
      unawaited(_reporter.replayPending());
      await _sync.start();
      _heartbeat.start();
    } else {
      _logger?.info(
        LogCategory.app,
        'Not paired with a store yet — sync and heartbeat are idle',
      );
    }

    await _applySettings(_settings.current);

    // A slow tick keeps relative timestamps ("2 seconds ago") honest without
    // the UI polling the database.
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (Timer _) => unawaited(_refreshStatus()),
    );

    await _refreshStatus();
    _logger?.info(LogCategory.app, 'Agent services started');
  }

  /// Called after pairing completes so the services pick up the new identity
  /// without restarting the application.
  Future<void> onPaired() async {
    _connectivity.setStore(_session.store?.baseUrl);
    await _session.verify();
    await _sync.start();
    _heartbeat.start();
    unawaited(_heartbeat.syncPrintersIfChanged());
    await _refreshStatus();
  }

  Future<void> _onReconnected() async {
    if (!_session.isPaired) return;
    _logger?.info(LogCategory.app, 'Connection restored — resynchronising');
    await _session.verify();
    await _reporter.replayPending();
    await _sync.syncNow();
    _engine.wake();
  }

  Future<void> stop({bool releaseClaimedJobs = true}) async {
    if (!_started) return;
    _logger?.info(LogCategory.app, 'Stopping agent services');
    _statusTimer?.cancel();
    _statusTimer = null;

    await _sync.stop();
    _heartbeat.stop();
    await _engine.stop();
    _printers.stopStatusPolling();

    if (releaseClaimedJobs && _session.isPaired) {
      // Hand back work this agent will not finish, so another agent (or this
      // one after a restart) can pick it up immediately.
      final claimed = await _queue.byStatus(
        <PrintJobStatus>[PrintJobStatus.claimed],
        limit: 50,
      );
      for (final job in claimed) {
        await _reporter.release(job);
      }
      await _reporter.replayPending();
    }

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _started = false;
  }

  // -------------------------------------------------------------------------
  // Pause / resume
  // -------------------------------------------------------------------------

  Future<void> pausePrinting() async {
    if (_paused) return;
    _paused = true;
    _engine.pause();
    _heartbeat.setPaused(paused: true);
    _session.markPaused(paused: true);
    await _refreshStatus();
  }

  Future<void> resumePrinting() async {
    if (!_paused) return;
    _paused = false;
    _engine.resume();
    _heartbeat.setPaused(paused: false);
    _session.markPaused(paused: false);
    unawaited(_sync.syncNow());
    await _refreshStatus();
  }

  Future<void> togglePause() =>
      _paused ? resumePrinting() : pausePrinting();

  Future<void> syncNow() async {
    await _sync.syncNow();
    _engine.wake();
    await _refreshStatus();
  }

  Future<void> refreshPrinters() async {
    await _printers.refresh();
    await _heartbeat.syncPrintersIfChanged();
  }

  // -------------------------------------------------------------------------
  // Tray + server commands
  // -------------------------------------------------------------------------

  Future<void> handleTrayAction(TrayAction action) async {
    switch (action) {
      case TrayAction.open:
        await onShowWindow?.call();
      case TrayAction.pausePrinting:
        await pausePrinting();
      case TrayAction.resumePrinting:
        await resumePrinting();
      case TrayAction.printQueue:
        await onShowWindow?.call();
        onNavigate?.call('/queue');
      case TrayAction.printers:
        await onShowWindow?.call();
        onNavigate?.call('/printers');
      case TrayAction.settings:
        await onShowWindow?.call();
        onNavigate?.call('/settings');
      case TrayAction.diagnostics:
        await onShowWindow?.call();
        onNavigate?.call('/diagnostics');
      case TrayAction.syncNow:
        await syncNow();
      case TrayAction.checkForUpdates:
        await onShowWindow?.call();
        onNavigate?.call('/settings');
        await _updater.checkForUpdates();
      case TrayAction.exit:
        await onExitRequested?.call();
    }
  }

  Future<void> _handleServerCommand(ServerCommand command) async {
    switch (command.type) {
      case ServerCommand.syncNow:
        await syncNow();
      case ServerCommand.pause:
        await pausePrinting();
      case ServerCommand.resume:
        await resumePrinting();
      case ServerCommand.refreshPrinters:
        await refreshPrinters();
      case ServerCommand.testPrint:
        final key = command.printerKey;
        if (key != null) await _printers.testPrint(key);
      default:
        // Unknown commands from a newer plugin are ignored, not treated as
        // errors — forward compatibility is deliberate.
        _logger?.debug(
          LogCategory.agent,
          'Ignoring unknown server command',
          context: <String, Object?>{'type': command.type},
        );
    }
  }

  // -------------------------------------------------------------------------
  // Settings
  // -------------------------------------------------------------------------

  Future<void> _applySettings(AppSettings settings) async {
    _logger?.minimumLevel = settings.logLevel;
    _tray?.closeToTray = settings.closeToTray;

    if (_autostart.isSupported) {
      final enabled = await _autostart.isEnabled();
      if (enabled != settings.startWithWindows) {
        await _autostart.setEnabled(
          enabled: settings.startWithWindows,
          startMinimized: settings.startMinimized,
        );
      } else if (settings.startWithWindows &&
          _autostart is WindowsAutostartService) {
        await _autostart.repairIfStale(
          startMinimized: settings.startMinimized,
        );
      }
    }

    _printers
      ..stopStatusPolling()
      ..startStatusPolling();
  }

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------

  Future<void> _refreshStatus() async {
    try {
      final counters = await _queue.counters();
      final next = AgentRuntimeStatus(
        connection: _session.state,
        network: _connectivity.status,
        paused: _paused,
        counters: counters,
        storeName: _session.store?.displayName,
        storeUrl: _session.store?.baseUrl,
        agentName: _session.agent?.name,
        lastSyncAt: _session.lastSuccessfulSyncAt,
        lastHeartbeatAt: _heartbeat.lastSuccessAt,
        syncIntervalSeconds: _sync.currentInterval.inSeconds,
        lastError: _sync.lastResult?.error?.userMessage,
      );
      _status = next;
      if (!_statusController.isClosed) _statusController.add(next);

      await _tray?.update(
        connection: next.effectiveConnection,
        counters: counters,
        paused: _paused,
        storeLabel: next.storeName,
      );
    } catch (e, st) {
      _logger?.exception(LogCategory.app, 'Status refresh failed', e, st);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
  }
}
