import 'dart:async';

import '../../core/config/settings_repository.dart';
import '../../core/errors/app_exception.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/storage/dao/agent_dao.dart';
import '../api/agent_session.dart';
import '../api/dto/agent_dto.dart';
import '../printer/printer_manager.dart';
import '../queue/queue_repository.dart';

/// Handles a command pushed down on a heartbeat response.
typedef ServerCommandHandler = Future<void> Function(ServerCommand command);

/// Tells the store this agent is alive, and carries the printer inventory and
/// queue counters with it.
///
/// The heartbeat is what makes the wp-admin device list useful: it is where the
/// printer dropdown gets its options, and where "last seen" comes from. It also
/// doubles as a command channel, so an administrator can trigger a sync, a
/// pause or a test print without the agent needing a socket connection.
class HeartbeatService {
  HeartbeatService({
    required AgentSession session,
    required PrinterManager printers,
    required QueueRepository queue,
    required SettingsRepository settings,
    required AgentDao agentDao,
    AppLogger? logger,
    this.onCommand,
  })  : _session = session,
        _printers = printers,
        _queue = queue,
        _settings = settings,
        _agentDao = agentDao,
        _logger = logger;

  final AgentSession _session;
  final PrinterManager _printers;
  final QueueRepository _queue;
  final SettingsRepository _settings;
  final AgentDao _agentDao;
  final AppLogger? _logger;

  ServerCommandHandler? onCommand;

  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  bool _paused = false;
  DateTime? _lastSuccessAt;
  String? _lastPrinterFingerprint;

  bool get isRunning => _running;
  DateTime? get lastSuccessAt => _lastSuccessAt;

  void start() {
    if (_running) return;
    _running = true;
    final interval = _settings.current.heartbeatInterval;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (Timer _) => unawaited(beat()));
    _logger?.info(
      LogCategory.agent,
      'Heartbeat every ${interval.inSeconds}s',
    );
    unawaited(beat());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void setPaused({required bool paused}) => _paused = paused;

  /// Sends one heartbeat. Never throws — a missed beat is not an incident.
  Future<bool> beat() async {
    if (_inFlight || !_session.isPaired) return false;
    _inFlight = true;
    try {
      final counters = await _queue.counters();
      final printers = _printers.heartbeatPayload();

      final response = await _session.api.heartbeat(
        status: _paused ? 'paused' : 'online',
        queueCounters: counters.toJson(),
        printers: printers,
        metadata: <String, dynamic>{
          'printer_count': printers.length,
          'sync_source': 'polling',
        },
      );

      _lastSuccessAt = DateTime.now();
      final agent = _session.agent;
      if (agent != null) {
        unawaited(_agentDao.touchHeartbeat(agent.id, _lastSuccessAt!));
      }
      _session.markSyncSuccess();

      // Remember what we last sent so a printer change can be pushed
      // immediately rather than waiting for the next beat.
      _lastPrinterFingerprint = _fingerprint(printers);

      for (final command in response.commands) {
        await _dispatch(command);
      }
      return true;
    } on AuthException {
      // AgentSession has already flipped to "unauthorised"; stop beating.
      stop();
      return false;
    } on AppException catch (e) {
      _logger?.debug(
        LogCategory.agent,
        'Heartbeat failed',
        context: <String, Object?>{'code': e.code},
      );
      _session.markOffline();
      return false;
    } catch (e, st) {
      _logger?.exception(LogCategory.agent, 'Heartbeat failed', e, st);
      return false;
    } finally {
      _inFlight = false;
    }
  }

  /// Pushes the printer list out of band when discovery finds a change.
  Future<void> syncPrintersIfChanged() async {
    if (!_session.isPaired) return;
    final payload = _printers.heartbeatPayload();
    final fingerprint = _fingerprint(payload);
    if (fingerprint == _lastPrinterFingerprint) return;
    try {
      await _session.api.syncPrinters(payload);
      _lastPrinterFingerprint = fingerprint;
      _logger?.info(
        LogCategory.printer,
        'Printer inventory pushed to the store',
        context: <String, Object?>{'count': payload.length},
      );
    } on AppException catch (e) {
      _logger?.debug(
        LogCategory.printer,
        'Printer sync deferred',
        context: <String, Object?>{'code': e.code},
      );
    }
  }

  Future<void> _dispatch(ServerCommand command) async {
    _logger?.info(
      LogCategory.agent,
      'Server command received',
      context: <String, Object?>{'type': command.type},
    );
    final handler = onCommand;
    if (handler == null) return;
    try {
      await handler(command);
    } catch (e, st) {
      _logger?.exception(
        LogCategory.agent,
        'Server command failed',
        e,
        st,
        <String, Object?>{'type': command.type},
      );
    }
  }

  static String _fingerprint(List<Map<String, dynamic>> printers) => printers
      .map((Map<String, dynamic> p) =>
          '${p['printer_key']}|${p['status']}|${p['is_enabled']}',)
      .join(';');

  void dispose() => stop();
}
