import '../../../core/errors/app_exception.dart';
import '../../../core/errors/error_codes.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/logging/log_level.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import '../win32/windows_spooler.dart';
import 'print_strategy.dart';

/// Passes bytes to the device untouched via `StartDocPrinter(datatype: RAW)`.
///
/// Used for documents the server has already rendered into a printer language
/// (ESC/POS, ZPL, PCL, PostScript). The agent makes no assumption about which
/// language that is — it is the server's responsibility to send a payload the
/// assigned printer understands.
class RawPrintStrategy implements PrintStrategy {
  RawPrintStrategy({required WindowsSpooler spooler, AppLogger? logger})
      : _spooler = spooler,
        _logger = logger;

  final WindowsSpooler _spooler;
  final AppLogger? _logger;

  @override
  String get name => 'raw';

  @override
  PrintStrategyType get type => PrintStrategyType.raw;

  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{
        DocumentType.raw,
      };

  @override
  Future<PrintResult> print(PrintRequest request) async {
    final stopwatch = Stopwatch()..start();
    try {
      int? lastJobId;
      final copies = request.copies < 1 ? 1 : request.copies;
      for (var copy = 0; copy < copies; copy++) {
        lastJobId = _spooler.printRaw(
          printerKey: request.printerKey,
          data: request.data,
          documentTitle: copies > 1
              ? '${request.documentTitle} (${copy + 1}/$copies)'
              : request.documentTitle,
        );
        // Yield between copies so a long multi-copy job cannot starve the
        // event loop and freeze the UI.
        if (copy + 1 < copies) await Future<void>.delayed(Duration.zero);
      }
      stopwatch.stop();
      _logger?.info(
        LogCategory.printing,
        'Raw document spooled',
        context: <String, Object?>{
          'job_id': request.jobId,
          'printer': request.printerKey,
          'bytes': request.data.length,
          'copies': copies,
          'spooler_job_id': lastJobId,
        },
      );
      return PrintResult.ok(
        spoolerJobId: lastJobId,
        strategyName: name,
        bytesSent: request.data.length * copies,
        duration: stopwatch.elapsed,
      );
    } on AppException catch (e) {
      stopwatch.stop();
      return PrintResult.failed(
        errorCode: e.code,
        errorMessage: e.userMessage,
        errorDetail: e.technicalDetail,
        strategyName: name,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return PrintResult.failed(
        errorCode: ErrorCodes.spoolerError,
        errorMessage: 'The document could not be sent to the printer.',
        errorDetail: e.toString(),
        strategyName: name,
        duration: stopwatch.elapsed,
      );
    }
  }
}
