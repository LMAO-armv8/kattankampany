import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';
import '../../../core/logging/log_level.dart';
import '../../../features/printers/domain/network_printer.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printers/domain/printer_device.dart';
import '../../../features/printers/domain/printer_status.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import '../printer_service.dart';

/// Prints to network devices over a raw TCP socket, bypassing Windows entirely.
///
/// This exists because the Windows path has two hard prerequisites the shop
/// floor does not always meet: the Print Spooler service must be running, and
/// the printer must already be installed with a driver. A hardened or
/// corporate-managed PC frequently has the spooler disabled outright, and a
/// network printer often has no driver installed at all.
///
/// The protocol is the raw/JetDirect convention on port 9100 — connect, write
/// the bytes, close. No driver, no spooler, no rendering. That last point is the
/// real constraint and is not hidden: whatever arrives is what the device
/// receives, so the document must already be in a language it understands
/// (ESC/POS, ZPL, PCL, PostScript). A PDF sent to a thermal receipt printer
/// prints as gibberish, and that is a configuration error rather than something
/// the agent can paper over.
class NetworkPrinterService implements PrinterService {
  NetworkPrinterService({
    required Future<List<NetworkPrinter>> Function() printers,
    AppLogger? logger,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration writeTimeout = const Duration(seconds: 60),
  })  : _printers = printers,
        _logger = logger,
        _connectTimeout = connectTimeout,
        _writeTimeout = writeTimeout;

  /// Identifies keys this service owns.
  static const String keyPrefix = 'net://';

  static const String strategyName = 'network-raw';

  final Future<List<NetworkPrinter>> Function() _printers;
  final AppLogger? _logger;
  final Duration _connectTimeout;
  final Duration _writeTimeout;

  /// Raw sockets exist on every platform the agent runs on, so unlike the
  /// Windows service this is never unsupported.
  @override
  bool get isSupported => true;

  /// Whether the given key belongs to a network printer.
  static bool owns(String printerKey) => printerKey.startsWith(keyPrefix);

  @override
  Future<List<DiscoveredPrinter>> discover() async {
    final configured = await _printers();
    if (configured.isEmpty) return const <DiscoveredPrinter>[];

    // Probed concurrently: a rack of printers with one powered off should not
    // make discovery take the timeout multiplied by the printer count.
    final states = await Future.wait(
      configured.map((NetworkPrinter printer) async {
        final state =
            printer.enabled ? await _probe(printer) : PrinterState.paused;
        return MapEntry<NetworkPrinter, PrinterState>(printer, state);
      }),
    );

    return states
        .map(
          (MapEntry<NetworkPrinter, PrinterState> entry) => DiscoveredPrinter(
            printerKey: entry.key.printerKey,
            displayName: entry.key.name,
            driverName: 'Raw TCP/IP (port ${entry.key.port})',
            portName: '${entry.key.host}:${entry.key.port}',
            host: entry.key.host,
            connectionType: PrinterConnectionType.network,
            state: entry.value,
            // With no driver in the path the agent can only pass bytes through,
            // so it advertises nothing it cannot actually deliver.
            paperSizes: const <String>[],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<PrinterStatusReading> getStatus(String printerKey) async {
    final printer = await _find(printerKey);

    if (printer == null) {
      return PrinterStatusReading.unknownFor(printerKey);
    }

    final state = printer.enabled ? await _probe(printer) : PrinterState.paused;

    return PrinterStatusReading(
      printerKey: printerKey,
      state: state,
      readAt: DateTime.now(),
      detail: state == PrinterState.offline
          ? 'No answer from ${printer.host}:${printer.port}'
          : null,
    );
  }

  /// "Default printer" is a spooler concept; a raw address has no such notion.
  @override
  Future<String?> getDefaultPrinterKey() async => null;

  @override
  Future<bool> isAvailable(String printerKey) async {
    final printer = await _find(printerKey);
    if (printer == null || !printer.enabled) return false;

    return await _probe(printer) == PrinterState.ready;
  }

  @override
  Future<PrintResult> print(PrintRequest request) async {
    final started = DateTime.now();
    final printer = await _find(request.printerKey);

    if (printer == null) {
      return PrintResult.failed(
        errorCode: 'printer_not_found',
        errorMessage:
            'No network printer is configured at ${request.printerKey}.',
        strategyName: strategyName,
      );
    }

    if (!printer.enabled) {
      return PrintResult.failed(
        errorCode: 'printer_offline',
        errorMessage: '${printer.name} is switched off in the agent.',
        strategyName: strategyName,
      );
    }

    if (request.data.isEmpty) {
      return PrintResult.failed(
        errorCode: 'document_invalid',
        errorMessage: 'The document was empty.',
        strategyName: strategyName,
      );
    }

    var sent = 0;

    // Each copy is a separate connection rather than one concatenated stream,
    // so a device that resets between documents still separates them.
    for (var copy = 1; copy <= request.copies; copy++) {
      final failure = await _send(printer, request.data);

      if (failure != null) {
        return PrintResult.failed(
          errorCode: failure.code,
          errorMessage: failure.message,
          errorDetail: 'copy $copy of ${request.copies}',
          strategyName: strategyName,
          duration: DateTime.now().difference(started),
        );
      }

      sent += request.data.length;
    }

    _logger?.info(
      LogCategory.printer,
      'Sent $sent bytes to ${printer.host}:${printer.port}',
      context: <String, Object?>{
        'printer': printer.printerKey,
        'copies': request.copies,
        'job': request.jobId,
      },
    );

    return PrintResult.ok(
      strategyName: strategyName,
      bytesSent: sent,
      duration: DateTime.now().difference(started),
    );
  }

  /// A raw socket has no queue to cancel from — the bytes are gone the moment
  /// they are written.
  @override
  Future<bool> cancel(String printerKey, int spoolerJobId) async => false;

  @override
  Future<PrintResult> testPrint(
    String printerKey, {
    PrintProfile? profile,
  }) async {
    final printer = await _find(printerKey);

    if (printer == null) {
      return PrintResult.failed(
        errorCode: 'printer_not_found',
        errorMessage: 'No network printer is configured at $printerKey.',
        strategyName: strategyName,
      );
    }

    return print(
      PrintRequest(
        jobId: 'test-${DateTime.now().millisecondsSinceEpoch}',
        printerKey: printerKey,
        documentType: DocumentType.text,
        data: Uint8List.fromList(_testPage(printer).codeUnits),
        profile: profile ?? PrintProfile.defaultProfile(),
        documentTitle: 'Print Agent test page',
      ),
    );
  }

  Future<NetworkPrinter?> _find(String printerKey) async {
    for (final printer in await _printers()) {
      if (printer.printerKey == printerKey) return printer;
    }
    return null;
  }

  /// A TCP connect is the only status signal a raw port offers.
  ///
  /// It answers the question that actually matters — will a job get through
  /// right now — without pretending to know about paper or toner, which this
  /// protocol cannot report.
  Future<PrinterState> _probe(NetworkPrinter printer) async {
    try {
      final socket = await Socket.connect(
        printer.host,
        printer.port,
        timeout: _connectTimeout,
      );
      socket.destroy();
      return PrinterState.ready;
    } on SocketException {
      return PrinterState.offline;
    } catch (_) {
      return PrinterState.unknown;
    }
  }

  Future<_SendFailure?> _send(NetworkPrinter printer, Uint8List data) async {
    Socket? socket;

    try {
      socket = await Socket.connect(
        printer.host,
        printer.port,
        timeout: _connectTimeout,
      );

      socket.add(data);
      await socket.flush().timeout(_writeTimeout);

      // Closing is part of the protocol, not just cleanup: many raw printers
      // only begin printing once the sending side closes the connection.
      await socket.close().timeout(_writeTimeout);

      return null;
    } on SocketException catch (e) {
      return _SendFailure(
        'printer_offline',
        'Could not reach ${printer.name} at ${printer.host}:${printer.port}. '
            '${e.message}',
      );
    } on TimeoutException {
      return _SendFailure(
        'printer_error',
        '${printer.name} accepted the connection but stopped responding.',
      );
    } catch (e) {
      return _SendFailure(
        'printer_error',
        'Sending to ${printer.name} failed: $e',
      );
    } finally {
      socket?.destroy();
    }
  }

  String _testPage(NetworkPrinter printer) {
    final rule = '=' * 40;

    return <String>[
      rule,
      '        PRINT AGENT TEST PAGE',
      rule,
      '',
      'Printer : ${printer.name}',
      'Address : ${printer.host}:${printer.port}',
      'Sent    : ${DateTime.now().toIso8601String()}',
      'Path    : raw TCP, no Windows spooler',
      '',
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      'abcdefghijklmnopqrstuvwxyz',
      '0123456789',
      '',
      rule,
      'If you can read this, the agent reached',
      'this printer and sent it data.',
      rule,
      '',
      '',
      '',
    ].join('\r\n');
  }
}

class _SendFailure {
  const _SendFailure(this.code, this.message);

  final String code;
  final String message;
}
