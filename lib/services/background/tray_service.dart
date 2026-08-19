import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/config/app_info.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../features/agent/domain/agent.dart';
import '../../features/print_queue/domain/print_job.dart';

/// Actions the tray menu can raise. The tray knows nothing about how they are
/// carried out — [LifecycleController] wires them up.
enum TrayAction {
  open,
  pausePrinting,
  resumePrinting,
  printQueue,
  printers,
  settings,
  diagnostics,
  syncNow,
  checkForUpdates,
  exit,
}

typedef TrayActionHandler = void Function(TrayAction action);

/// The Windows notification-area presence.
///
/// The agent's normal state is "running with no window". The tray icon is the
/// only always-visible surface, so it carries the connection state, the queue
/// counts and every action an operator needs day to day.
class TrayService with TrayListener, WindowListener {
  TrayService({
    required TrayActionHandler onAction,
    AppLogger? logger,
    this.iconPath = 'assets/icons/tray.ico',
  })  : _onAction = onAction,
        _logger = logger;

  final TrayActionHandler _onAction;
  final AppLogger? _logger;
  final String iconPath;

  bool _initialised = false;
  bool _paused = false;
  bool _closeToTray = true;
  AgentConnectionState _connection = AgentConnectionState.disconnected;
  QueueCounters _counters = QueueCounters.empty;
  String? _storeLabel;

  bool get isInitialised => _initialised;

  /// Whether the window's close button hides to the tray instead of quitting.
  set closeToTray(bool value) => _closeToTray = value;


  Future<void> initialise() async {
    if (_initialised) return;
    if (!_supportsTray) {
      _logger?.debug(LogCategory.tray, 'Tray not supported on this platform');
      return;
    }

    try {
      trayManager.addListener(this);
      windowManager.addListener(this);
      await trayManager.setIcon(iconPath);
      await _refreshTooltip();
      await rebuildMenu();
      _initialised = true;
      _logger?.info(LogCategory.tray, 'System tray icon created');
    } catch (e, st) {
      // A missing icon or a locked shell must not prevent the agent running.
      _logger?.exception(
        LogCategory.tray,
        'Could not create the tray icon; the agent will run without it',
        e,
        st,
      );
    }
  }

  bool get _supportsTray =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  Future<void> update({
    AgentConnectionState? connection,
    QueueCounters? counters,
    bool? paused,
    String? storeLabel,
  }) async {
    var changed = false;
    if (connection != null && connection != _connection) {
      _connection = connection;
      changed = true;
    }
    if (counters != null) {
      _counters = counters;
      changed = true;
    }
    if (paused != null && paused != _paused) {
      _paused = paused;
      changed = true;
    }
    if (storeLabel != null && storeLabel != _storeLabel) {
      _storeLabel = storeLabel;
      changed = true;
    }
    if (!changed || !_initialised) return;
    await _refreshTooltip();
    await rebuildMenu();
  }

  Future<void> _refreshTooltip() async {
    final lines = <String>[
      AppInfo.productName,
      if (_storeLabel != null) _storeLabel!,
      _paused ? 'Printing paused' : _connection.label,
      'Pending ${_counters.pending} · Printing ${_counters.printing} · '
          'Failed ${_counters.failed}',
    ];
    try {
      // Windows tooltips are limited to 127 characters.
      final tooltip = lines.join('\n');
      await trayManager.setToolTip(
        tooltip.length > 127 ? tooltip.substring(0, 127) : tooltip,
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  Future<void> rebuildMenu() async {
    if (!_supportsTray) return;
    final statusLabel = _paused
        ? 'Paused — not printing'
        : '${_connection.label}'
            '${_storeLabel == null ? '' : ' · $_storeLabel'}';

    final menu = Menu(
      items: <MenuItem>[
        MenuItem(key: 'status', label: statusLabel, disabled: true),
        MenuItem.separator(),
        MenuItem(key: TrayAction.open.name, label: 'Open'),
        if (_paused)
          MenuItem(key: TrayAction.resumePrinting.name, label: 'Resume printing')
        else
          MenuItem(key: TrayAction.pausePrinting.name, label: 'Pause printing'),
        MenuItem.separator(),
        MenuItem(
          key: TrayAction.printQueue.name,
          label: 'Print queue (${_counters.pending + _counters.printing})',
        ),
        MenuItem(key: TrayAction.printers.name, label: 'Printers'),
        MenuItem(key: TrayAction.syncNow.name, label: 'Sync now'),
        MenuItem.separator(),
        MenuItem(key: TrayAction.settings.name, label: 'Settings'),
        MenuItem(key: TrayAction.diagnostics.name, label: 'Diagnostics'),
        MenuItem(
          key: TrayAction.checkForUpdates.name,
          label: 'Check for updates',
        ),
        MenuItem.separator(),
        MenuItem(key: TrayAction.exit.name, label: 'Exit'),
      ],
    );

    try {
      await trayManager.setContextMenu(menu);
    } catch (e) {
      _logger?.debug(
        LogCategory.tray,
        'Could not update the tray menu',
        context: <String, Object?>{'error': e.toString()},
      );
    }
  }

  // -------------------------------------------------------------------------
  // Window helpers
  // -------------------------------------------------------------------------

  Future<void> showWindow() async {
    try {
      // Put the taskbar button back before showing, so the window the operator
      // just asked for arrives with somewhere to click next time.
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
    } catch (e) {
      _logger?.debug(
        LogCategory.tray,
        'Could not show the window',
        context: <String, Object?>{'error': e.toString()},
      );
    }
  }

  Future<void> hideWindow() async {
    try {
      await windowManager.hide();
      // Without this the taskbar button survives the hide on Windows. Clicking
      // it then does nothing, because the window it points at is hidden — so the
      // agent looks like an application that refuses to close, and the operator
      // ends up killing it from Task Manager.
      await windowManager.setSkipTaskbar(true);
    } catch (_) {
      /* non-fatal */
    }
  }

  // -------------------------------------------------------------------------
  // TrayListener
  // -------------------------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    _onAction(TrayAction.open);
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null || key == 'status') return;
    for (final action in TrayAction.values) {
      if (action.name == key) {
        _logger?.debug(
          LogCategory.tray,
          'Tray action',
          context: <String, Object?>{'action': action.name},
        );
        _onAction(action);
        return;
      }
    }
  }

  // -------------------------------------------------------------------------
  // WindowListener — closing hides to the tray so printing continues
  // -------------------------------------------------------------------------

  @override
  void onWindowClose() {
    if (_closeToTray) {
      _logger?.info(
        LogCategory.tray,
        'Window closed — the agent keeps running in the notification area',
      );
      unawaited(hideWindow());
    } else {
      _onAction(TrayAction.exit);
    }
  }


  @override
  void onWindowMinimize() {
    // Minimise-to-tray is handled by the lifecycle controller, which knows the
    // current setting; the tray itself stays passive here.
  }

  Future<void> dispose() async {
    if (!_initialised) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      /* ignore */
    }
    _initialised = false;
  }
}
