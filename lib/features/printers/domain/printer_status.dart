import 'package:freezed_annotation/freezed_annotation.dart';

/// Normalised printer state. The Windows implementation maps the
/// `PRINTER_STATUS_*` bit field onto these; other platforms map their own.
enum PrinterState {
  @JsonValue('ready')
  ready,
  @JsonValue('busy')
  busy,
  @JsonValue('paused')
  paused,
  @JsonValue('offline')
  offline,
  @JsonValue('out_of_paper')
  outOfPaper,
  @JsonValue('paper_jam')
  paperJam,
  @JsonValue('door_open')
  doorOpen,
  @JsonValue('toner_low')
  tonerLow,
  @JsonValue('error')
  error,
  @JsonValue('unknown')
  unknown;

  /// Whether the agent is willing to send a job to a printer in this state.
  bool get canAcceptJobs => switch (this) {
        PrinterState.ready || PrinterState.busy || PrinterState.tonerLow => true,
        // `unknown` is permitted: many drivers report no status at all, and
        // refusing to print to them would break perfectly working setups.
        PrinterState.unknown => true,
        _ => false,
      };

  bool get isHealthy =>
      this == PrinterState.ready ||
      this == PrinterState.busy ||
      this == PrinterState.unknown;

  String get label => switch (this) {
        PrinterState.ready => 'Ready',
        PrinterState.busy => 'Printing',
        PrinterState.paused => 'Paused',
        PrinterState.offline => 'Offline',
        PrinterState.outOfPaper => 'Out of paper',
        PrinterState.paperJam => 'Paper jam',
        PrinterState.doorOpen => 'Door open',
        PrinterState.tonerLow => 'Ink or toner low',
        PrinterState.error => 'Error',
        PrinterState.unknown => 'Unknown',
      };

  /// Operator-facing explanation used when a job cannot be printed.
  String get problemMessage => switch (this) {
        PrinterState.offline =>
          'The printer is offline. Check that it is switched on and connected.',
        PrinterState.outOfPaper =>
          'The printer is out of paper. Load media and the job will retry.',
        PrinterState.paperJam =>
          'The printer has a paper jam. Clear it and the job will retry.',
        PrinterState.doorOpen =>
          'A printer door or cover is open. Close it and the job will retry.',
        PrinterState.paused =>
          'The printer is paused in Windows. Resume it to continue printing.',
        PrinterState.error =>
          'The printer reported an error. Check the device for details.',
        _ => 'The printer is not currently available.',
      };

  String get wireValue => switch (this) {
        PrinterState.outOfPaper => 'out_of_paper',
        PrinterState.paperJam => 'paper_jam',
        PrinterState.doorOpen => 'door_open',
        PrinterState.tonerLow => 'toner_low',
        _ => name,
      };

  static PrinterState fromWire(String? value) {
    switch (value?.toLowerCase()) {
      case 'ready':
        return PrinterState.ready;
      case 'busy':
        return PrinterState.busy;
      case 'paused':
        return PrinterState.paused;
      case 'offline':
        return PrinterState.offline;
      case 'out_of_paper':
      case 'outofpaper':
        return PrinterState.outOfPaper;
      case 'paper_jam':
      case 'paperjam':
        return PrinterState.paperJam;
      case 'door_open':
      case 'dooropen':
        return PrinterState.doorOpen;
      case 'toner_low':
      case 'tonerlow':
        return PrinterState.tonerLow;
      case 'error':
        return PrinterState.error;
      default:
        return PrinterState.unknown;
    }
  }
}

enum PrinterConnectionType {
  @JsonValue('usb')
  usb,
  @JsonValue('network')
  network,
  @JsonValue('bluetooth')
  bluetooth,
  @JsonValue('serial')
  serial,
  @JsonValue('parallel')
  parallel,
  @JsonValue('virtual')
  virtual,
  @JsonValue('unknown')
  unknown;

  String get label => switch (this) {
        PrinterConnectionType.usb => 'USB',
        PrinterConnectionType.network => 'Network',
        PrinterConnectionType.bluetooth => 'Bluetooth',
        PrinterConnectionType.serial => 'Serial',
        PrinterConnectionType.parallel => 'Parallel',
        PrinterConnectionType.virtual => 'Virtual',
        PrinterConnectionType.unknown => 'Unknown',
      };

  /// Best-effort classification from the Windows port name.
  /// Port naming is a convention, not a contract, so this is advisory only and
  /// is never used to decide whether a printer can be used.
  static PrinterConnectionType fromPortName(String? port) {
    if (port == null || port.isEmpty) return PrinterConnectionType.unknown;
    final value = port.toUpperCase();
    if (value.startsWith('USB')) return PrinterConnectionType.usb;
    if (value.startsWith('COM')) return PrinterConnectionType.serial;
    if (value.startsWith('LPT')) return PrinterConnectionType.parallel;
    if (value.startsWith('BTH') || value.contains('BLUETOOTH')) {
      return PrinterConnectionType.bluetooth;
    }
    if (value.startsWith('WSD') ||
        value.startsWith('IP_') ||
        value.startsWith('\\\\') ||
        value.contains('TCP') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}').hasMatch(value)) {
      return PrinterConnectionType.network;
    }
    if (value.endsWith(':') || value.contains('PORTPROMPT') ||
        value.contains('NUL') || value.contains('FILE')) {
      return PrinterConnectionType.virtual;
    }
    return PrinterConnectionType.unknown;
  }

  static PrinterConnectionType fromWire(String? value) {
    for (final type in PrinterConnectionType.values) {
      if (type.name == value) return type;
    }
    return PrinterConnectionType.unknown;
  }
}

/// A point-in-time status reading for one device.
class PrinterStatusReading {
  const PrinterStatusReading({
    required this.printerKey,
    required this.state,
    required this.readAt,
    this.rawStatusBits,
    this.queuedJobCount = 0,
    this.detail,
  });

  final String printerKey;
  final PrinterState state;
  final DateTime readAt;

  /// The raw `PRINTER_INFO_2.Status` bit field, for diagnostics only.
  final int? rawStatusBits;
  final int queuedJobCount;
  final String? detail;

  static PrinterStatusReading unknownFor(String printerKey) =>
      PrinterStatusReading(
        printerKey: printerKey,
        state: PrinterState.unknown,
        readAt: DateTime.now(),
      );
}
