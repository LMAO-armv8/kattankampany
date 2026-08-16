import 'dart:io';

import '../../core/config/app_info.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/platform/win32_registry.dart';

/// Makes the agent start with Windows.
///
/// Uses the per-user `Run` key rather than a service or a scheduled task,
/// because the agent needs the interactive desktop session: the Windows print
/// spooler resolves per-user printer connections, and a machine-level service
/// cannot see a printer the operator connected as themselves. That is also why
/// no administrator rights are needed to turn this on.
abstract class AutostartService {
  Future<bool> isEnabled();
  Future<bool> setEnabled({required bool enabled, bool startMinimized = true});
  bool get isSupported;

  /// What is currently registered, for the Diagnostics screen.
  Future<String?> registeredCommand();
}

class WindowsAutostartService implements AutostartService {
  WindowsAutostartService({AppLogger? logger, String? executablePath})
      : _logger = logger,
        _executablePathOverride = executablePath;

  static const String _runKey =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  /// The registry value name. Stable across versions so an upgrade replaces the
  /// entry rather than adding a second one.
  static const String valueName = 'WooCommercePrintAgent';

  /// Passed when Windows launches the agent at sign-in, so it can come up in
  /// the tray instead of stealing focus with a window.
  static const String startupFlag = '--startup';

  final AppLogger? _logger;
  final String? _executablePathOverride;

  @override
  bool get isSupported => Platform.isWindows && Win32Registry.isSupported;

  String get _executablePath =>
      _executablePathOverride ?? Platform.resolvedExecutable;

  String _command({required bool startMinimized}) {
    final exe = _executablePath;
    return startMinimized ? '"$exe" $startupFlag' : '"$exe"';
  }

  @override
  Future<String?> registeredCommand() async {
    if (!isSupported) return null;
    return Win32Registry.readString(subKey: _runKey, valueName: valueName);
  }

  @override
  Future<bool> isEnabled() async {
    final existing = await registeredCommand();
    return existing != null && existing.isNotEmpty;
  }

  @override
  Future<bool> setEnabled({
    required bool enabled,
    bool startMinimized = true,
  }) async {
    if (!isSupported) {
      _logger?.debug(
        LogCategory.app,
        'Autostart is not available on this platform',
      );
      return false;
    }

    if (!enabled) {
      final removed =
          Win32Registry.deleteValue(subKey: _runKey, valueName: valueName);
      _logger?.info(
        LogCategory.app,
        removed
            ? 'Removed ${AppInfo.productName} from Windows startup'
            : 'Could not remove the Windows startup entry',
      );
      return removed;
    }

    final command = _command(startMinimized: startMinimized);
    final written = Win32Registry.writeString(
      subKey: _runKey,
      valueName: valueName,
      value: command,
    );
    _logger?.info(
      LogCategory.app,
      written
          ? 'Registered ${AppInfo.productName} to start with Windows'
          : 'Could not write the Windows startup entry',
      context: <String, Object?>{'command': command},
    );
    return written;
  }

  /// Rewrites the entry when the executable has moved — after an in-place
  /// upgrade or a reinstall to a different folder — so autostart does not
  /// silently point at a path that no longer exists.
  Future<void> repairIfStale({bool startMinimized = true}) async {
    if (!isSupported) return;
    final existing = await registeredCommand();
    if (existing == null || existing.isEmpty) return;
    final expected = _command(startMinimized: startMinimized);
    if (existing == expected) return;
    _logger?.info(
      LogCategory.app,
      'Updating the Windows startup entry to the current executable path',
    );
    Win32Registry.writeString(
      subKey: _runKey,
      valueName: valueName,
      value: expected,
    );
  }
}

/// Used on non-Windows hosts so callers need no platform checks.
class NoopAutostartService implements AutostartService {
  const NoopAutostartService();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool> setEnabled({
    required bool enabled,
    bool startMinimized = true,
  }) async =>
      false;

  @override
  Future<String?> registeredCommand() async => null;
}
