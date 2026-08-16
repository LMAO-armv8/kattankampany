import 'dart:convert';
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

/// Lays plain text out on the profile's page size and prints it through the
/// PDF path, so a text job honours the same margins, orientation and paper
/// size as everything else.
///
/// Text is deliberately *not* sent to the spooler with `datatype: TEXT`: only
/// line printers handle that reliably, and a page-oriented printer would
/// produce a blank sheet or a driver error.
class TextPrintStrategy implements PrintStrategy {
  TextPrintStrategy({required PdfPrintStrategy pdfStrategy, AppLogger? logger})
      : _pdf = pdfStrategy,
        _logger = logger;

  final PdfPrintStrategy _pdf;
  // ignore: unused_field
  final AppLogger? _logger;

  @override
  String get name => 'text';

  @override
  PrintStrategyType get type => PrintStrategyType.text;

  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{
        DocumentType.text,
      };

  @override
  Future<PrintResult> print(PrintRequest request) async {
    try {
      final pdfBytes = await buildPdf(request);
      return _pdf.print(
        request.copyWith(
          data: pdfBytes,
          documentType: DocumentType.pdf,
          profile: request.profile.copyWith(scaling: PrintScaling.none),
        ),
      );
    } catch (e) {
      return PrintResult.failed(
        errorCode: ErrorCodes.documentInvalid,
        errorMessage: 'The text document could not be prepared for printing.',
        errorDetail: e.toString(),
        strategyName: name,
      );
    }
  }

  Future<Uint8List> buildPdf(PrintRequest request) async {
    final text = decodeText(request.data);
    final format = PageFormatMapper.fromProfile(request.profile);
    // The bundled Type-1 fonts cover Latin-1 only. Rather than fail on a stray
    // character, unsupported code points are replaced so the page still prints.
    final safeText = _toLatin1Safe(text);

    final document = pw.Document(
      title: request.documentTitle,
      producer: 'WooCommerce Print Agent',
    );
    document.addPage(
      pw.MultiPage(
        pageFormat: format,
        orientation: pw.PageOrientation.natural,
        build: (pw.Context context) => <pw.Widget>[
          pw.Text(
            safeText,
            style: pw.TextStyle(
              font: pw.Font.courier(),
              fontSize: 9,
              lineSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  /// Decodes a payload that may be UTF-8, UTF-8 with BOM, or Latin-1.
  static String decodeText(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    var input = bytes;
    // Strip a UTF-8 BOM.
    if (input.length >= 3 &&
        input[0] == 0xEF &&
        input[1] == 0xBB &&
        input[2] == 0xBF) {
      input = Uint8List.sublistView(input, 3);
    }
    try {
      return const Utf8Decoder(allowMalformed: false).convert(input);
    } catch (_) {
      return const Latin1Decoder(allowInvalid: true).convert(input);
    }
  }

  static String _toLatin1Safe(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune == 0x0A || rune == 0x0D || rune == 0x09) {
        buffer.writeCharCode(rune);
      } else if (rune >= 0x20 && rune <= 0xFF) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('?');
      }
    }
    return buffer.toString();
  }
}
