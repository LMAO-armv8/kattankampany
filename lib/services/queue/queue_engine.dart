import 'dart:async';

import '../../core/config/app_paths.dart';
import '../../core/config/app_settings.dart';
import '../../core/config/settings_repository.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/printer_device.dart';
import '../printer/printer_manager.dart';
import 'job_processor.dart';
import 'queue_repository.dart';

/// Drains the local queue.
///
/// Cooperative, not threaded: each worker is a `Future` loop that yields on
/// every `await`, so the UI keeps rendering while documents spool. Concurrency
/// is bounded by the number of enabled printers × the per-printer limit, which
/// means a slow label printer cannot hold up invoices on a laser printer, and
/// nothing ever runs unbounded.
class QueueEngine {
  QueueEngine({
    required QueueRepository queue,
    required JobProcessor processor,
    required PrinterManager printers,
    required SettingsRepository settings,
    required String leaseOwner,
    AppLogger? logger,
    Duration tickInterval = const Duration(seconds: 1),
    Duration leaseDuration = const Duration(minutes: 5),
  })  : _queue = queue,
        _processor = processor,
        _printers = printers,
        _settings = settings,
        _leaseOwner = leaseOwner,
        _logger = logger,
        _tickInterval = tickInterval,
        _leaseDuration = leaseDuration;

  final QueueRepository _queue;
  final JobProcessor _processor;
  final PrinterManager _printers;
  final SettingsRepository _settings;
  final String _leaseOwner;
  final AppLogger? _logger;
  final Duration _tickInterval;
  final Duration _leaseDuration;

  final Set<String> _inFlight = <String>{};
  final StreamController<QueueEngineState> _stateController =
      StreamController<QueueEngineState>.broadcast();

  Timer? _ticker;
  Timer? _maintenanceTimer;
  bool _running = false;
  bool _paused = false;
  bool _draining = false;

  bool get isRunning => _running;
  bool get isPaused => _paused;
  int get inFlightCount => _inFlight.length;
  Stream<QueueEngineState> get stateChanges => _stateController.stream;

  QueueEngineState get state => QueueEngineState(
        running: _running,
        paused: _paused,
        inFlight: _inFlight.length,
      );

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Recovers anything left over from the previous run, then starts working.
  ///
  /// Recovery never reprints silently: jobs caught mid-print become
  /// `interrupted` and wait for a decision (see [applyRecoveryPolicy]).
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _paused = false;

    final recovered = await _queue.recoverAfterRestart(_leaseOwner);
    if (recovered.interrupted > 0) {
      await applyRecoveryPolicy();
    }

    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (Timer _) {
      unawaited(_drain());
    });

    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer.periodic(
      const Duration(hours: 6),
      (Timer _) => unawaited(runMaintenance()),
    );

    _emit();
    _logger?.info(LogCategory.queue, 'Queue engine started');
    unawaited(_drain());
  }

  Future<void> stop() async {
    _running = false;
    _ticker?.cancel();
    _ticker = null;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _emit();
    _logger?.info(LogCategory.queue, 'Queue engine stopped');
  }

  void pause() {
    if (_paused) return;
    _paused = true;
    _emit();
    _logger?.info(LogCategory.queue, 'Printing paused');
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _emit();
    _logger?.info(LogCategory.queue, 'Printing resumed');
    unawaited(_drain());
  }

  /// Nudges the engine — called after a sync inserts new jobs, and by the tray
  /// "print now" action, so a fresh job does not wait for the next tick.
  void wake() {
    if (_running && !_paused) unawaited(_drain());
  }

  // -------------------------------------------------------------------------
  // Draining
  // -------------------------------------------------------------------------

  Future<void> _drain() async {
    if (!_running || _paused || _draining) return;
    _draining = true;
    try {
      while (_running && !_paused && _inFlight.length < _capacity) {
        final printerKeys = _printers.enabledPrinters
            .map((PrinterDevice p) => p.printerKey)
            .toList(growable: false);

        final job = await _queue.leaseNext(
          leaseOwner: _leaseOwner,
          leaseDuration: _leaseDuration,
          // Null means "any printer" — the resolver decides. Passing the
          // enabled list lets the DB skip jobs bound to a disabled device.
          printerKeys: printerKeys.isEmpty ? null : printerKeys,
          excludeJobIds: _inFlight,
        );
        if (job == null) break;
        if (_inFlight.contains(job.id)) break;

        _inFlight.add(job.id);
        _emit();
        // Fire and track: the loop continues so other printers stay busy.
        unawaited(_runJob(job));
      }
    } catch (e, st) {
      _logger?.exception(LogCategory.queue, 'Queue drain failed', e, st);
    } finally {
      _draining = false;
    }
  }

  Future<void> _runJob(PrintJob job) async {
    try {
      final outcome = await _processor.process(job);
      if (outcome == JobOutcome.printed) {
        // Another job may now be printable on the freed printer.
        unawaited(Future<void>.microtask(_drain));
      }
    } catch (e, st) {
      _logger?.exception(
        LogCategory.queue,
        'Unhandled error while processing a job',
        e,
        st,
        <String, Object?>{'job_id': job.id},
      );
    } finally {
      _inFlight.remove(job.id);
      _emit();
    }
  }

  int get _capacity {
    final printerCount = _printers.enabledPrinters.length;
    final perPrinter = _settings.current.maxConcurrentJobsPerPrinter;
    final capacity = (printerCount == 0 ? 1 : printerCount) * perPrinter;
    return capacity.clamp(1, 32);
  }

  // -------------------------------------------------------------------------
  // Recovery
  // -------------------------------------------------------------------------

  /// Applies the configured behaviour to jobs left `interrupted` by a crash.
  ///
  /// The default (`ask`) does nothing here: the jobs stay visible on the Print
  /// Queue screen with "Mark as printed" / "Print again" actions, because the
  /// agent genuinely cannot know whether the paper came out, and guessing is
  /// how duplicate shipping labels happen.
  Future<void> applyRecoveryPolicy() async {
    final behaviour = _settings.current.recoveryBehaviour;
    final interrupted = await _queue.byStatus(
      <PrintJobStatus>[PrintJobStatus.interrupted],
    );
    if (interrupted.isEmpty) return;

    switch (behaviour) {
      case JobRecoveryBehaviour.ask:
        _logger?.warn(
          LogCategory.queue,
          '${interrupted.length} job(s) need a decision after the agent '
          'stopped mid-print',
        );
      case JobRecoveryBehaviour.markPrinted:
        for (final job in interrupted) {
          await _queue.resolveInterrupted(job.id, printedSuccessfully: true);
        }
      case JobRecoveryBehaviour.reprint:
        for (final job in interrupted) {
          await _queue.resolveInterrupted(job.id, printedSuccessfully: false);
        }
    }
  }

  // -------------------------------------------------------------------------
  // Maintenance
  // -------------------------------------------------------------------------

  /// Bounded-growth housekeeping. Cheap, and only runs while idle.
  Future<void> runMaintenance() async {
    try {
      final settings = _settings.current;
      await _queue.archiveOldJobs(
        retention: Duration(days: settings.historyRetentionDays),
        maxHistoryRows: settings.maxHistoryRows,
      );
      final pruned = await AppPaths.instance.pruneDocuments();
      if (pruned > 0) {
        _logger?.debug(
          LogCategory.queue,
          'Removed $pruned stale document file(s)',
        );
      }
    } catch (e, st) {
      _logger?.exception(LogCategory.queue, 'Maintenance pass failed', e, st);
    }
  }

  void _emit() {
    if (!_stateController.isClosed) _stateController.add(state);
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
  }
}

class QueueEngineState {
  const QueueEngineState({
    required this.running,
    required this.paused,
    required this.inFlight,
  });

  final bool running;
  final bool paused;
  final int inFlight;
}
