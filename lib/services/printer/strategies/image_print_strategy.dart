import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../../core/errors/error_codes.dart';
import '../../../core/logging/app_logger.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import 'page_format.dart';
import 'pdf_print_strategy.dart';
import 'print_strategy.dart';

/// Places a PNG or JPEG onto a page sized by the print profile and delegates to
/// [PdfPrintStrategy].
///
/// Going through PDF rather than a bespoke GDI blit means orientation, scaling
/// and margins behave identically for images and documents, which is what makes
/// a single 4×6 label profile work for both.
class ImagePrintStrategy implements PrintStrategy {
  ImagePrintStrategy({required PdfPrintStrategy pdfStrategy, AppLogger? logger})
      : _pdf = pdfStrategy,
        _logger = logger;

  final PdfPrintStrategy _pdf;
  // ignore: unused_field
  final AppLogger? _logger;

  @override
  String get name => 'image';

  @override
  PrintStrategyType get type => PrintStrategyType.image;

  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{
        DocumentType.png,
        DocumentType.jpeg,
      };

  @override
  Future<PrintResult> print(PrintRequest request) async {
    try {
      final pdfBytes = await buildPdf(request);
      return _pdf.print(
        request.copyWith(
          data: pdfBytes,
          documentType: DocumentType.pdf,
          // The page is already exactly the media size, so the PDF strategy
          // must not scale it a second time.
          profile: request.profile.copyWith(scaling: PrintScaling.none),
        ),
      );
    } catch (e) {
      return PrintResult.failed(
        errorCode: ErrorCodes.documentInvalid,
        errorMessage: 'The image could not be prepared for printing.',
        errorDetail: e.toString(),
        strategyName: name,
      );
    }
  }

  /// Exposed for testing: wraps the image bytes in a single-page PDF.
  Future<Uint8List> buildPdf(PrintRequest request) async {
    final profile = request.profile;
    final format = profile.margins.isZero
        ? PageFormatMapper.borderlessFromProfile(profile)
        : PageFormatMapper.fromProfile(profile);

    final image = pw.MemoryImage(request.data);
    final fit = switch (profile.scaling) {
      PrintScaling.fill => pw.BoxFit.cover,
      PrintScaling.none || PrintScaling.actual => pw.BoxFit.none,
      PrintScaling.fit => pw.BoxFit.contain,
    };

    final document = pw.Document(
      title: request.documentTitle,
      producer: 'WooCommerce Print Agent',
    );
    document.addPage(
      pw.Page(
        pageFormat: format,
        // `format` already carries the oriented dimensions (see
        // PageFormatMapper), so the page must not rotate them a second time.
        orientation: pw.PageOrientation.natural,
        build: (pw.Context context) => pw.Center(
          child: pw.Image(image, fit: fit),
        ),
      ),
    );
    return document.save();
  }
}

/// Alias kept for readability at the registration site: an image is printed
/// through the spooler like any other document.
typedef SpoolerImageStrategy = ImagePrintStrategy;

/// Explicit `strategy: spooler` requests map to the PDF path, which is the
/// Windows spooler path. Declared as its own registry entry so a job can pin
/// "use the installed driver" without naming a document format.
class SpoolerPrintStrategy implements PrintStrategy {
  SpoolerPrintStrategy({
    required PdfPrintStrategy pdfStrategy,
    required ImagePrintStrategy imageStrategy,
  })  : _pdf = pdfStrategy,
        _image = imageStrategy;

  final PdfPrintStrategy _pdf;
  final ImagePrintStrategy _image;

  @override
  String get name => 'spooler';

  @override
  PrintStrategyType get type => PrintStrategyType.spooler;

  /// Never auto-selected: `auto` picks the format-specific strategy directly.
  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{};

  @override
  Future<PrintResult> print(PrintRequest request) {
    if (request.documentType.isImage) return _image.print(request);
    return _pdf.print(request);
  }
}
