import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

import 'printer_status.dart';

part 'printer_device.freezed.dart';
part 'printer_device.g.dart';

/// What a device can be asked to do. Populated conservatively — the agent only
/// claims a capability it can actually deliver through an installed strategy.
enum PrinterCapability {
  @JsonValue('pdf')
  pdf,
  @JsonValue('image')
  image,
  @JsonValue('text')
  text,
  @JsonValue('html')
  html,
  @JsonValue('raw')
  raw;

  static PrinterCapability? fromWire(String? value) {
    for (final capability in PrinterCapability.values) {
      if (capability.name == value) return capability;
    }
    return null;
  }
}

/// The raw result of a discovery pass, before it is merged with stored
/// configuration. Produced by [PrinterService.discover].
class DiscoveredPrinter {
  const DiscoveredPrinter({
    required this.printerKey,
    required this.displayName,
    this.driverName,
    this.portName,
    this.manufacturer,
    this.model,
    this.isDefault = false,
    this.state = PrinterState.unknown,
    this.rawStatusBits,
    this.queuedJobCount = 0,
    this.paperSizes = const <String>[],
    this.isVirtual = false,
    this.host,
    PrinterConnectionType? connectionType,
  }) : _connectionType = connectionType;

  /// The Windows printer name. This is the stable identifier used everywhere —
  /// in the database, in heartbeats, and as the server's `printer_key`.
  final String printerKey;
  final String displayName;
  final String? driverName;
  final String? portName;
  final String? manufacturer;
  final String? model;
  final bool isDefault;
  final PrinterState state;
  final int? rawStatusBits;
  final int queuedJobCount;
  final List<String> paperSizes;
  final bool isVirtual;

  /// Host or address behind a network port, when the port monitor records one.
  final String? host;

  /// Supplied by the platform layer, which can consult port topology the port
  /// name alone does not reveal (see `PortInspector`).
  final PrinterConnectionType? _connectionType;

  /// The resolved transport. Falls back to the name-only classification when the
  /// platform layer did not supply one — which is what the non-Windows stub and
  /// older callers do.
  PrinterConnectionType get connectionType {
    final supplied = _connectionType;
    if (supplied != null && supplied != PrinterConnectionType.unknown) {
      return supplied;
    }
    final byName = PrinterConnectionType.fromPortName(portName);
    if (byName != PrinterConnectionType.unknown) return byName;
    return isVirtual ? PrinterConnectionType.virtual : byName;
  }
}

/// A printer as the agent knows it: discovery data merged with operator
/// configuration and persisted in SQLite.
@freezed
class PrinterDevice with _$PrinterDevice {
  const factory PrinterDevice({
    required String id,
    required String printerKey,
    required String displayName,
    String? driverName,
    String? portName,
    String? manufacturer,
    String? model,
    /// Host or address behind a network port. Diagnostic only; jobs are always
    /// addressed by [printerKey] through the spooler.
    String? host,
    @Default(PrinterConnectionType.unknown) PrinterConnectionType connectionType,
    @Default(false) bool isDefault,
    @Default(true) bool isEnabled,
    @Default(PrinterState.unknown) PrinterState state,
    DateTime? lastStatusAt,
    @Default(<PrinterCapability>[]) List<PrinterCapability> capabilities,
    @Default(<String>[]) List<String> paperSizes,
    String? defaultProfileId,
    @Default(false) bool isOnline,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _PrinterDevice;

  const PrinterDevice._();

  factory PrinterDevice.fromJson(Map<String, dynamic> json) =>
      _$PrinterDeviceFromJson(json);

  bool get canAcceptJobs => isEnabled && state.canAcceptJobs;

  /// Human description under the printer name in the UI.
  String get subtitle {
    // The host is only added when the port name does not already contain it —
    // a Standard TCP/IP port is usually called `IP_192.168.1.50`, and repeating
    // the address would be noise.
    final showHost = host != null &&
        host!.isNotEmpty &&
        !(portName ?? '').toUpperCase().contains(host!.toUpperCase());

    final parts = <String>[
      if (manufacturer != null && manufacturer!.isNotEmpty) manufacturer!,
      if (model != null && model!.isNotEmpty && model != manufacturer) model!,
      if (portName != null && portName!.isNotEmpty) portName!,
      if (showHost) host!,
    ];
    if (parts.isEmpty && driverName != null) parts.add(driverName!);
    return parts.join(' · ');
  }

  bool supports(PrinterCapability capability) =>
      capabilities.isEmpty || capabilities.contains(capability);

  // ---------------------------------------------------------------------
  // Database mapping
  // ---------------------------------------------------------------------

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'id': id,
        'printer_key': printerKey,
        'display_name': displayName,
        'driver_name': driverName,
        'port_name': portName,
        'manufacturer': manufacturer,
        'model': model,
        'host': host,
        'connection_type': connectionType.name,
        'is_default': isDefault ? 1 : 0,
        'is_enabled': isEnabled ? 1 : 0,
        'last_status': state.wireValue,
        'last_status_at': lastStatusAt?.millisecondsSinceEpoch,
        'capabilities_json':
            jsonEncode(capabilities.map((PrinterCapability c) => c.name).toList()),
        'paper_sizes_json': jsonEncode(paperSizes),
        'default_profile_id': defaultProfileId,
        'created_at':
            (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
        'updated_at':
            (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  static PrinterDevice fromDatabaseRow(Map<String, Object?> row) {
    List<T> decodeList<T>(String? raw, T? Function(String) parse) {
      if (raw == null || raw.isEmpty || raw == '[]') return <T>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return <T>[];
        final result = <T>[];
        for (final item in decoded) {
          final parsed = parse(item.toString());
          if (parsed != null) result.add(parsed);
        }
        return result;
      } catch (_) {
        return <T>[];
      }
    }

    return PrinterDevice(
      id: row['id']! as String,
      printerKey: row['printer_key']! as String,
      displayName: row['display_name']! as String,
      driverName: row['driver_name'] as String?,
      portName: row['port_name'] as String?,
      manufacturer: row['manufacturer'] as String?,
      model: row['model'] as String?,
      host: row['host'] as String?,
      connectionType:
          PrinterConnectionType.fromWire(row['connection_type'] as String?),
      isDefault: (row['is_default'] as int? ?? 0) == 1,
      isEnabled: (row['is_enabled'] as int? ?? 1) == 1,
      state: PrinterState.fromWire(row['last_status'] as String?),
      lastStatusAt: row['last_status_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['last_status_at']! as int),
      capabilities: decodeList<PrinterCapability>(
        row['capabilities_json'] as String?,
        PrinterCapability.fromWire,
      ),
      paperSizes:
          decodeList<String>(row['paper_sizes_json'] as String?, (String s) => s),
      defaultProfileId: row['default_profile_id'] as String?,
      createdAt: row['created_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      updatedAt: row['updated_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
    );
  }

  /// The payload shape sent to the plugin in heartbeats and printer syncs.
  Map<String, dynamic> toHeartbeatPayload() => <String, dynamic>{
        'printer_key': printerKey,
        'name': displayName,
        if (driverName != null) 'driver': driverName,
        if (portName != null) 'port': portName,
        if (manufacturer != null) 'manufacturer': manufacturer,
        if (model != null) 'model': model,
        if (host != null) 'host': host,
        'connection_type': connectionType.name,
        'is_default': isDefault,
        'is_enabled': isEnabled,
        'status': state.wireValue,
        'capabilities':
            capabilities.map((PrinterCapability c) => c.name).toList(),
        'paper_sizes': paperSizes,
      };
}
