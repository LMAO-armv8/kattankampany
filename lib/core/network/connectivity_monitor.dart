import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../logging/app_logger.dart';
import '../logging/log_level.dart';

enum NetworkStatus {
  /// An interface is up and the store answered.
  online,

  /// No usable interface, or the store did not answer.
  offline,

  /// Not yet determined.
  unknown;

  bool get isOnline => this == NetworkStatus.online;
}

/// Tracks whether the agent can actually reach the paired store.
///
/// An adapter being "connected" is not the same as the store being reachable —
/// captive portals, VPN drops and DNS failures all present as a healthy
/// interface. So the monitor combines the OS signal with a cheap DNS/TCP probe
/// of the store host, and only the combination flips the state to online.
class ConnectivityMonitor {
  ConnectivityMonitor({
    AppLogger? logger,
    Connectivity? connectivity,
    Duration probeInterval = const Duration(seconds: 30),
    Duration probeTimeout = const Duration(seconds: 5),
  })  : _logger = logger,
        _connectivity = connectivity ?? Connectivity(),
        _probeInterval = probeInterval,
        _probeTimeout = probeTimeout;

  final AppLogger? _logger;
  final Connectivity _connectivity;
  final Duration _probeInterval;
  final Duration _probeTimeout;

  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _probeTimer;
  NetworkStatus _status = NetworkStatus.unknown;
  String? _host;
  int? _port;
  DateTime? _lastOnlineAt;
  DateTime? _lastTickAt;

  NetworkStatus get status => _status;
  DateTime? get lastOnlineAt => _lastOnlineAt;
  Stream<NetworkStatus> get changes => _controller.stream;

  /// [storeBaseUrl] is probed; pass null before the agent is paired, in which
  /// case only the OS-level signal is used.
  Future<void> start({String? storeBaseUrl}) async {
    setStore(storeBaseUrl);

    try {
      _subscription = _connectivity.onConnectivityChanged.listen(
        (List<ConnectivityResult> results) {
          final hasInterface = results.any(
            (ConnectivityResult r) => r != ConnectivityResult.none,
          );
          // Verify in *both* directions. This used to trust "no interface" and
          // only probe when an interface came up, which made the OS signal
          // authoritative for going offline and merely advisory for coming
          // back. connectivity_plus on Windows reports `none` spuriously —
          // most often when Windows power-manages the adapter on an idle
          // machine — so the agent announced itself offline while the store was
          // perfectly reachable, stopped beating, and appeared dead in wp-admin
          // until somebody touched the PC.
          //
          // The probe is a single TCP connect to the paired store and is the
          // only thing that actually answers the question being asked.
          if (!hasInterface) {
            _logger?.debug(
              LogCategory.api,
              'OS reports no network interface — verifying before believing it',
            );
          }

          unawaited(probe());
        },
        onError: (Object error) {
          _logger?.debug(
            LogCategory.api,
            'Connectivity stream error',
            context: <String, Object?>{'error': error.toString()},
          );
        },
      );
    } catch (e) {
      // connectivity_plus is unavailable on some hosts; the probe still works.
      _logger?.debug(
        LogCategory.api,
        'Connectivity plugin unavailable; relying on reachability probes',
        context: <String, Object?>{'error': e.toString()},
      );
    }

    _probeTimer?.cancel();
    _lastTickAt = DateTime.now();
    _probeTimer = Timer.periodic(_probeInterval, (Timer _) {
      _noteTick();
      unawaited(probe());
    });
    await probe();
  }

  void setStore(String? storeBaseUrl) {
    if (storeBaseUrl == null || storeBaseUrl.isEmpty) {
      _host = null;
      _port = null;
      return;
    }
    try {
      final uri = Uri.parse(storeBaseUrl);
      _host = uri.host;
      _port = uri.hasPort ? uri.port : (uri.scheme == 'http' ? 80 : 443);
    } catch (_) {
      _host = null;
      _port = null;
    }
  }

  /// Records that the probe timer fired, and says so in the log when far more
  /// wall-clock time passed than the interval allows for.
  ///
  /// A timer that should fire every 30 s but last fired three hours ago means
  /// the process was frozen, which on Windows 11 means the machine went into
  /// Modern Standby. That is worth naming explicitly: without it the log shows
  /// only a long unexplained stretch of "offline", and the obvious reading —
  /// that the agent or the store is at fault — is the wrong one.
  void _noteTick() {
    final previous = _lastTickAt;
    final now = DateTime.now();
    _lastTickAt = now;
    if (previous == null) return;

    final elapsed = now.difference(previous);
    if (elapsed < _probeInterval * 4) return;

    _logger?.info(
      LogCategory.api,
      'This computer was asleep for about ${_describe(elapsed)} — no print '
      'jobs could arrive during that time. Turn on "Keep this computer awake" '
      'in Settings to stop it happening.',
      context: <String, Object?>{'asleep_seconds': elapsed.inSeconds},
    );
  }

  static String _describe(Duration d) {
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  /// One reachability check. Cheap enough to run every 30 s indefinitely.
  Future<NetworkStatus> probe() async {
    final host = _host;
    if (host == null) {
      // Not paired yet: fall back to whether any interface is up.
      try {
        final results = await _connectivity.checkConnectivity();
        final hasInterface = results.any(
          (ConnectivityResult r) => r != ConnectivityResult.none,
        );
        return _update(
          hasInterface ? NetworkStatus.online : NetworkStatus.offline,
        );
      } catch (_) {
        return _update(NetworkStatus.unknown);
      }
    }

    try {
      final socket = await Socket.connect(
        host,
        _port ?? 443,
        timeout: _probeTimeout,
      );
      socket.destroy();
      return _update(NetworkStatus.online);
    } on SocketException catch (e) {
      return _update(NetworkStatus.offline, reason: e.message);
    } catch (e) {
      return _update(NetworkStatus.offline, reason: e.toString());
    }
  }

  /// Called by the API layer when a request succeeds or fails, so the state
  /// reflects reality between scheduled probes.
  void reportSuccess() {
    _update(NetworkStatus.online);
  }

  void reportFailure() {
    // A single failure is not proof of an outage — verify before flipping.
    unawaited(probe());
  }

  NetworkStatus _update(NetworkStatus next, {String? reason}) {
    if (next == NetworkStatus.online) _lastOnlineAt = DateTime.now();
    if (next == _status) return _status;
    final previous = _status;
    _status = next;
    _logger?.info(
      LogCategory.api,
      'Network ${next.name}',
      context: <String, Object?>{
        'from': previous.name,
        if (reason != null) 'reason': reason,
      },
    );
    if (!_controller.isClosed) _controller.add(next);
    return _status;
  }

  Future<void> dispose() async {
    _probeTimer?.cancel();
    _probeTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}
