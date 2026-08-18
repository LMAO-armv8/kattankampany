import 'dart:async';

import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../features/printers/domain/print_profile.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printers/domain/printer_status.dart';
import '../../features/printing/domain/print_request.dart';
import 'network/network_printer_service.dart';
import 'printer_service.dart';

/// Presents the Windows spooler and directly-addressed network printers as one
/// printer list.
///
/// Keeping these behind a single [PrinterService] means the queue engine, the
/// heartbeat and the UI stay unaware that two entirely different transports
/// exist. Routing is by key: anything starting with `net://` belongs to the
/// network service, everything else to the platform service.
///
/// The two are genuinely independent, which is the point. A machine whose Print
/// Spooler is stopped or disabled — common on hardened and corporate-managed
/// PCs — still prints to network devices, because that path never touches
/// Windows printing at all.
class CompositePrinterService implements PrinterService {
  CompositePrinterService({
    required PrinterService platform,
    required NetworkPrinterService network,
    AppLogger? logger,
  })  : _platform = platform,
        _network = network,
        _logger = logger;

  final PrinterService _platform;
  final NetworkPrinterService _network;
  final AppLogger? _logger;

  /// True when *either* transport can do something here.
  @override
  bool get isSupported => _platform.isSupported || _network.isSupported;

  PrinterService _serviceFor(String printerKey) =>
      NetworkPrinterService.owns(printerKey) ? _network : _platform;

  @override
  Future<List<DiscoveredPrinter>> discover() async {
    // Both sides are asked even when one is expected to fail, and a failure in
    // one must not empty the other's list: losing every network printer because
    // the spooler is stopped is exactly the coupling this class removes.
    final results = await Future.wait<List<DiscoveredPrinter>>(<Future<List<DiscoveredPrinter>>>[
      _safeDiscover(_platform, 'windows'),
      _safeDiscover(_network, 'network'),
    ]);

    final merged = <DiscoveredPrinter>[];
    final seen = <String>{};

    for (final list in results) {
      for (final printer in list) {
        if (seen.add(printer.printerKey)) merged.add(printer);
      }
    }

    return merged;
  }

  Future<List<DiscoveredPrinter>> _safeDiscover(
    PrinterService service,
    String label,
  ) async {
    try {
      return await service.discover();
    } catch (e, st) {
      _logger?.exception(
        LogCategory.printer,
        'Discovery failed for the $label printer source',
        e,
        st,
      );
      return const <DiscoveredPrinter>[];
    }
  }

  @override
  Future<PrinterStatusReading> getStatus(String printerKey) =>
      _serviceFor(printerKey).getStatus(printerKey);

  /// Only the platform has a notion of a system default printer.
  @override
  Future<String?> getDefaultPrinterKey() => _platform.getDefaultPrinterKey();

  @override
  Future<bool> isAvailable(String printerKey) =>
      _serviceFor(printerKey).isAvailable(printerKey);

  @override
  Future<PrintResult> print(PrintRequest request) =>
      _serviceFor(request.printerKey).print(request);

  @override
  Future<bool> cancel(String printerKey, int spoolerJobId) =>
      _serviceFor(printerKey).cancel(printerKey, spoolerJobId);

  @override
  Future<PrintResult> testPrint(String printerKey, {PrintProfile? profile}) =>
      _serviceFor(printerKey).testPrint(printerKey, profile: profile);
}
