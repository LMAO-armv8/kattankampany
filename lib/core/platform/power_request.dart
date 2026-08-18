import 'dart:ffi';
import 'dart:io';

import '../logging/app_logger.dart';
import '../logging/log_level.dart';

typedef _SetThreadExecutionStateNative = Uint32 Function(Uint32 esFlags);
typedef _SetThreadExecutionStateDart = int Function(int esFlags);

/// Asks Windows not to put the computer to sleep while the agent is running.
///
/// Without this the agent is only online while somebody is at the keyboard.
/// Windows 11 uses Modern Standby: after a few minutes idle the machine enters
/// a low-power state that powers down the network adapter, so DNS lookups start
/// failing, the heartbeat stops arriving, and the store lists the machine as
/// offline. Touch the mouse and everything recovers within seconds — which is
/// exactly the "it only works when I'm looking at it" symptom, and it is the
/// operating system doing it, not the agent.
///
/// A print agent has the same claim to staying awake as a media player or a
/// backup job: orders arrive at any hour and the whole point is that nobody has
/// to be present. The request is advisory and cooperative — Windows still
/// honours the lid, the power button, and an explicit Sleep — and it is dropped
/// the moment the process exits, so it cannot leave a machine stuck awake.
///
/// Visible to the operator as `powercfg /requests` under SYSTEM.
class PowerRequest {
  PowerRequest({AppLogger? logger}) : _logger = logger;

  final AppLogger? _logger;

  /// Informs the system that the state being set should remain in effect until
  /// the next call that uses [_esContinuous] and one of the other flags is
  /// cleared.
  static const int _esContinuous = 0x80000000;

  /// Forces the system to be in the working state.
  static const int _esSystemRequired = 0x00000001;

  bool _held = false;

  bool get isHeld => _held;

  /// Whether the platform can honour a request at all.
  static bool get isSupported => Platform.isWindows;

  /// Starts keeping the machine awake. Safe to call repeatedly.
  void acquire() {
    if (_held || !isSupported) return;
    // ES_DISPLAY_REQUIRED is deliberately absent: the agent needs the machine
    // running, not the screen lit. Keeping a monitor on all night to receive
    // print jobs would be a rude thing to do to somebody's electricity bill.
    if (_apply(_esContinuous | _esSystemRequired)) {
      _held = true;
      _logger?.info(
        LogCategory.app,
        'Asked Windows to keep this computer awake while the agent runs',
      );
    }
  }

  /// Releases the request, letting the machine sleep on its normal schedule.
  void release() {
    if (!_held || !isSupported) return;
    // ES_CONTINUOUS on its own clears every previously requested flag.
    if (_apply(_esContinuous)) {
      _held = false;
      _logger?.info(
        LogCategory.app,
        'Released the keep-awake request; normal sleep settings apply again',
      );
    }
  }

  void setEnabled({required bool enabled}) =>
      enabled ? acquire() : release();

  bool _apply(int flags) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final setThreadExecutionState = kernel32.lookupFunction<
          _SetThreadExecutionStateNative,
          _SetThreadExecutionStateDart>('SetThreadExecutionState');

      // Returns the previous state, or 0 on failure. A failure here is not
      // worth interrupting startup over — the agent simply behaves as it did
      // before, going quiet whenever the machine sleeps.
      if (setThreadExecutionState(flags) == 0) {
        _logger?.warn(
          LogCategory.app,
          'Windows refused the keep-awake request; the computer may still '
          'sleep and appear offline in your store',
        );
        return false;
      }
      return true;
    } catch (e) {
      _logger?.debug(
        LogCategory.app,
        'Keep-awake unavailable',
        context: <String, Object?>{'error': e.toString()},
      );
      return false;
    }
  }

  void dispose() => release();
}
