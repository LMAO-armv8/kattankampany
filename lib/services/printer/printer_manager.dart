import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../core/config/settings_repository.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/storage/dao/printer_dao.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printers/domain/print_profile.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printers/domain/printer_status.dart';
import '../../features/printing/domain/print_request.dart';
import 'printer_resolver.dart';
import 'printer_service.dart';

/// Owns the agent's view of the printers attached to this computer.
///
/// [PrinterService] is stateless and platform-specific; this class adds the
/// stateful parts: the cached inventory, persistence, the status poll timer,
/// change notification, and printer resolution for jobs.
class PrinterManager {
  PrinterManager({
    required PrinterService service,
    required PrinterDao dao,
    required PrintProfileDao profileDao,
    required SettingsRepository settings,
    AppLogger? logger,
    PrinterResolver resolver = const PrinterResolver(),
    Uuid uuid = const Uuid(),
  })  : _service = service,
        _dao = dao,
        _profileDao = profileDao,
        _settings = settings,
        _logger = logger,
        _resolver = resolver,
        _uuid = uuid;

  final PrinterService _service;
  final PrinterDao _dao;
  final PrintProfileDao _profileDao;
  final SettingsRepository _settings;
  final AppLogger? _logger;
  final PrinterResolver _resolver;
  final Uuid _uuid;

  final StreamController<List<PrinterDevice>> _printersController =
      StreamController<List<PrinterDevice>>.broadcast();

  List<PrinterDevice> _printers = const <PrinterDevice>[];
  List<PrintProfile> _profiles = const <PrintProfile>[];
  String? _windowsDefaultKey;
  Timer? _statusTimer;
  bool _refreshing = false;
  DateTime? _lastDiscoveryAt;

  List<PrinterDevice> get printers => _printers;
  List<PrinterDevice> get enabledPrinters =>
      _printers.where((PrinterDevice p) => p.isEnabled).toList(growable: false);
  List<PrintProfile> get profiles => _profiles;
  String? get windowsDefaultKey => _windowsDefaultKey;
  DateTime? get lastDiscoveryAt => _lastDiscoveryAt;
  bool get isSupported => _service.isSupported;

  Stream<List<PrinterDevice>> get changes => _printersController.stream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> initialise() async {
    _profiles = await _profileDao.findAll();
    _printers = await _dao.findAll();
    _emit();
    await refresh();
  }

  void startStatusPolling() {
    _statusTimer?.cancel();
    final interval = _settings.current.printerStatusPollInterval;
    _statusTimer = Timer.periodic(interval, (Timer _) {
      unawaited(pollStatuses());
    });
    _logger?.debug(
      LogCategory.printer,
      'Printer status polling every ${interval.inSeconds}s',
    );
  }

  void stopStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  Future<void> dispose() async {
    stopStatusPolling();
    await _printersController.close();
  }

  // -------------------------------------------------------------------------
  // Discovery
  // -------------------------------------------------------------------------

  /// Re-enumerates the system printers and reconciles them with what is stored.
  Future<List<PrinterDevice>> refresh() async {
    if (_refreshing) return _printers;
    _refreshing = true;
    try {
      final discovered = await _service.discover();
      _windowsDefaultKey = await _service.getDefaultPrinterKey();

      final existingByKey = <String, PrinterDevice>{
        for (final printer in _printers) printer.printerKey: printer,
      };

      final merged = <PrinterDevice>[
        for (final device in discovered)
          _merge(device, existingByKey[device.printerKey]),
      ];

      await _dao.syncDiscovered(merged);
      _printers = await _dao.findAll();
      _profiles = await _profileDao.findAll();
      _lastDiscoveryAt = DateTime.now();
      _emit();
      return _printers;
    } catch (e, st) {
      _logger?.exception(LogCategory.printer, 'Printer refresh failed', e, st);
      return _printers;
    } finally {
      _refreshing = false;
    }
  }

  PrinterDevice _merge(DiscoveredPrinter device, PrinterDevice? existing) =>
      PrinterDevice(
        id: existing?.id ?? _uuid.v4(),
        printerKey: device.printerKey,
        displayName: device.displayName,
        driverName: device.driverName,
        portName: device.portName,
        manufacturer: device.manufacturer,
        model: device.model,
        connectionType: device.connectionType,
        isDefault: device.isDefault,
        // Operator configuration survives rediscovery.
        isEnabled: existing?.isEnabled ?? true,
        defaultProfileId: existing?.defaultProfileId,
        state: device.state,
        lastStatusAt: DateTime.now(),
        capabilities: _capabilitiesFor(device),
        paperSizes: device.paperSizes,
        isOnline: device.state.canAcceptJobs,
        createdAt: existing?.createdAt ?? DateTime.now(),
        updatedAt: DateTime.now(),
      );

  /// What the agent is willing to claim it can print on this device.
  ///
  /// Everything goes through the Windows driver, so every device gets the
  /// document capabilities. ESC/POS is deliberately *not* advertised: the agent
  /// cannot detect it, and claiming it would let an administrator assign a
  /// receipt profile to a laser printer.
  List<PrinterCapability> _capabilitiesFor(DiscoveredPrinter device) =>
      const <PrinterCapability>[
        PrinterCapability.pdf,
        PrinterCapability.image,
        PrinterCapability.text,
        PrinterCapability.html,
        PrinterCapability.raw,
      ];

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------

  Future<void> pollStatuses() async {
    if (_printers.isEmpty) return;
    var changed = false;
    final updated = <PrinterDevice>[];

    for (final printer in _printers) {
      if (!printer.isEnabled) {
        updated.add(printer);
        continue;
      }
      try {
        final reading = await _service.getStatus(printer.printerKey);
        if (reading.state != printer.state) {
          changed = true;
          await _dao.updateStatus(printer.printerKey, reading.state,
              at: reading.readAt,);
          _logger?.info(
            LogCategory.printer,
            'Printer state changed',
            context: <String, Object?>{
              'printer': printer.printerKey,
              'from': printer.state.name,
              'to': reading.state.name,
            },
          );
        }
        updated.add(
          printer.copyWith(
            state: reading.state,
            lastStatusAt: reading.readAt,
            isOnline: reading.state.canAcceptJobs,
          ),
        );
      } catch (e) {
        updated.add(printer);
        _logger?.debug(
          LogCategory.printer,
          'Status read failed',
          context: <String, Object?>{
            'printer': printer.printerKey,
            'error': e.toString(),
          },
        );
      }
    }

    _printers = updated;
    if (changed) _emit();
  }

  Future<PrinterStatusReading> readStatus(String printerKey) =>
      _service.getStatus(printerKey);

  // -------------------------------------------------------------------------
  // Resolution
  // -------------------------------------------------------------------------

  /// Decides which device [job] should print on. See [PrinterResolver].
  PrinterResolution resolveFor(PrintJob job) => _resolver.resolve(
        job: job,
        printers: _printers,
        settings: _settings.current,
        windowsDefaultKey: _windowsDefaultKey,
      );

  /// The effective profile for a job: the server's profile takes precedence,
  /// then the printer's configured default profile, then the built-in default.
  PrintProfile effectiveProfile(PrintJob job, PrinterDevice printer) {
    if (job.profile.id != PrintProfile.a4Default.id) return job.profile;
    final printerProfileId = printer.defaultProfileId;
    if (printerProfileId != null) {
      for (final profile in _profiles) {
        if (profile.id == printerProfileId) {
          // Copies always come from the job, never from the profile.
          return profile.copyWith(copies: job.copies);
        }
      }
    }
    return job.profile;
  }

  PrinterDevice? byKey(String? printerKey) {
    if (printerKey == null) return null;
    for (final printer in _printers) {
      if (printer.printerKey == printerKey) return printer;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Operator actions
  // -------------------------------------------------------------------------

  Future<void> setEnabled(String printerKey, {required bool enabled}) async {
    await _dao.setEnabled(printerKey, enabled: enabled);
    _printers = await _dao.findAll();
    _emit();
    _logger?.info(
      LogCategory.printer,
      enabled ? 'Printer enabled' : 'Printer disabled',
      context: <String, Object?>{'printer': printerKey},
    );
  }

  Future<void> setDefaultProfile(String printerKey, String? profileId) async {
    await _dao.setDefaultProfile(printerKey, profileId);
    _printers = await _dao.findAll();
    _emit();
  }

  Future<PrintResult> testPrint(String printerKey, {String? profileId}) async {
    PrintProfile? profile;
    if (profileId != null) {
      profile = await _profileDao.findById(profileId);
    }
    profile ??= await _profileForPrinter(printerKey);
    final result = await _service.testPrint(printerKey, profile: profile);
    _logger?.info(
      LogCategory.printer,
      result.success ? 'Test print succeeded' : 'Test print failed',
      context: <String, Object?>{
        'printer': printerKey,
        'profile': profile?.name,
        if (!result.success) 'error': result.errorMessage,
      },
    );
    return result;
  }

  Future<PrintProfile?> _profileForPrinter(String printerKey) async {
    final printer = byKey(printerKey);
    final profileId = printer?.defaultProfileId;
    if (profileId == null) return null;
    return _profileDao.findById(profileId);
  }

  // -------------------------------------------------------------------------
  // Profiles
  // -------------------------------------------------------------------------

  Future<List<PrintProfile>> reloadProfiles() async {
    _profiles = await _profileDao.findAll();
    _emit();
    return _profiles;
  }

  Future<void> saveProfile(PrintProfile profile) async {
    await _profileDao.upsert(profile);
    await reloadProfiles();
  }

  Future<bool> deleteProfile(String profileId) async {
    final deleted = await _profileDao.delete(profileId);
    if (deleted) await reloadProfiles();
    return deleted;
  }

  /// The inventory payload sent to the plugin in heartbeats.
  List<Map<String, dynamic>> heartbeatPayload() => _printers
      .map((PrinterDevice p) => p.toHeartbeatPayload())
      .toList(growable: false);

  void _emit() {
    if (!_printersController.isClosed) {
      _printersController.add(_printers);
    }
  }
}
