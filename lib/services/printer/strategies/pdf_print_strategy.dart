import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../../core/errors/error_codes.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/logging/log_level.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import 'page_format.dart';
import 'print_strategy.dart';

/// Renders a PDF with PDFium and hands the rasterised pages to the Windows
/// spooler through the installed printer driver.
///
/// This is the default path for documents, invoices and labels. It goes through
/// the normal Windows driver stack, so whatever the printer supports — duplex,
/// tray selection, media type — is honoured by the driver rather than being
/// re-implemented here.
class PdfPrintStrategy implements PrintStrategy {
  PdfPrintStrategy({AppLogger? logger, DirectPrinter? printer})
      : _logger = logger,
        _printer = printer ?? const _PrintingPackagePrinter();

  final AppLogger? _logger;
  final DirectPrinter _printer;

  @override
  String get name => 'pdf';

  @override
  PrintStrategyType get type => PrintStrategyType.pdf;

  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{
        DocumentType.pdf,
      };

  @override
  Future<PrintResult> print(PrintRequest request) async {
    final stopwatch = Stopwatch()..start();
    final format = PageFormatMapper.fromProfile(request.profile);
    final copies = request.copies < 1 ? 1 : request.copies;

    try {
      for (var copy = 0; copy < copies; copy++) {
        final accepted = await _printer.printPdf(
          printerKey: request.printerKey,
          bytes: request.data,
          documentTitle: copies > 1
              ? '${request.documentTitle} (${copy + 1}/$copies)'
              : request.documentTitle,
          format: format,
          // `none`/`actual` scaling means the document's own page boxes are
          // authoritative, so dynamic layout is disabled and the PDF is sent
          // as-is. `fit`/`fill` let the renderer size pages to the media.
          dynamicLayout: request.profile.scaling == PrintScaling.fit ||
              request.profile.scaling == PrintScaling.fill,
        );
        if (!accepted) {
          stopwatch.stop();
          return PrintResult.failed(
            errorCode: ErrorCodes.spoolerError,
            errorMessage:
                'The printer did not accept the document. Check that it is '
                'online and not paused.',
            errorDetail:
                'directPrintPdf returned false for "${request.printerKey}" '
                '(copy ${copy + 1} of $copies).',
            strategyName: name,
            duration: stopwatch.elapsed,
          );
        }
        if (copy + 1 < copies) await Future<void>.delayed(Duration.zero);
      }

      stopwatch.stop();
      _logger?.info(
        LogCategory.printing,
        'PDF spooled',
        context: <String, Object?>{
          'job_id': request.jobId,
          'printer': request.printerKey,
          'bytes': request.data.length,
          'copies': copies,
          'page_mm':
              '${request.profile.orientedSizeMm.widthMm.toStringAsFixed(1)}×'
                  '${request.profile.orientedSizeMm.heightMm.toStringAsFixed(1)}',
        },
      );
      return PrintResult.ok(
        strategyName: name,
        bytesSent: request.data.length * copies,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return PrintResult.failed(
        errorCode: ErrorCodes.printerError,
        errorMessage:
            'The document could not be printed. The printer may be offline or '
            'its driver may have reported an error.',
        errorDetail: e.toString(),
        strategyName: name,
        duration: stopwatch.elapsed,
      );
    }
  }
}

/// Seam over the platform printing plugin so the strategy can be unit-tested
/// without a real spooler.
abstract class DirectPrinter {
  Future<bool> printPdf({
    required String printerKey,
    required Uint8List bytes,
    required String documentTitle,
    required PdfPageFormat format,
    bool dynamicLayout,
  });
}

class _PrintingPackagePrinter implements DirectPrinter {
  const _PrintingPackagePrinter();

  @override
  Future<bool> printPdf({
    required String printerKey,
    required Uint8List bytes,
    required String documentTitle,
    required PdfPageFormat format,
    bool dynamicLayout = true,
  }) async =>
      // `directPrintPdf` is declared FutureOr<bool>; await normalises it.
      Printing.directPrintPdf(
        printer: Printer(url: printerKey, name: printerKey),
        onLayout: (PdfPageFormat _) async => bytes,
        name: documentTitle,
        format: format,
        dynamicLayout: dynamicLayout,
      );
}
