import '../../features/printers/domain/print_profile.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printers/domain/printer_status.dart';
import '../../features/printing/domain/print_request.dart';

/// The platform boundary for printing.
///
/// Everything above this interface — the queue engine, the UI, the API layer —
/// is platform-independent. `WindowsPrinterService` is the shipped
/// implementation; a macOS or Linux port adds a sibling without touching
/// anything else.
abstract class PrinterService {
  /// Enumerates every printer this Windows session can see, including
  /// connections to shared/network printers.
  Future<List<DiscoveredPrinter>> discover();

  /// Reads the current state of one device.
  Future<PrinterStatusReading> getStatus(String printerKey);

  /// The Windows default printer, or null if none is set.
  Future<String?> getDefaultPrinterKey();

  /// True when the printer exists and its state permits new jobs.
  Future<bool> isAvailable(String printerKey);

  /// Spools one document. Never throws — failures come back as
  /// `PrintResult.failed` so the queue engine can classify and retry them.
  Future<PrintResult> print(PrintRequest request);

  /// Cancels a job already in the Windows spool queue.
  Future<bool> cancel(String printerKey, int spoolerJobId);

  /// Prints a generated diagnostic page. Requires no server support, so it works
  /// during installation before the agent is paired.
  Future<PrintResult> testPrint(String printerKey, {PrintProfile? profile});

  /// Whether this implementation can do anything on the current host.
  bool get isSupported;
}

/// Answers on hosts where no printing backend exists (macOS/Linux development,
/// CI). Keeps `Platform.isWindows` checks out of the rest of the codebase.
class UnsupportedPrinterService implements PrinterService {
  const UnsupportedPrinterService({this.reason = 'Printing requires Windows.'});

  final String reason;

  @override
  bool get isSupported => false;

  @override
  Future<List<DiscoveredPrinter>> discover() async => const <DiscoveredPrinter>[];

  @override
  Future<PrinterStatusReading> getStatus(String printerKey) async =>
      PrinterStatusReading.unknownFor(printerKey);

  @override
  Future<String?> getDefaultPrinterKey() async => null;

  @override
  Future<bool> isAvailable(String printerKey) async => false;

  @override
  Future<PrintResult> print(PrintRequest request) async => PrintResult.failed(
        errorCode: 'unsupported_platform',
        errorMessage: reason,
      );

  @override
  Future<bool> cancel(String printerKey, int spoolerJobId) async => false;

  @override
  Future<PrintResult> testPrint(String printerKey, {PrintProfile? profile}) async =>
      PrintResult.failed(
        errorCode: 'unsupported_platform',
        errorMessage: reason,
      );
}
