import 'package:pdf/pdf.dart';

import '../../../features/printers/domain/print_profile.dart';

/// Translates a [PrintProfile] into the PDF page geometry the renderer uses.
///
/// All profile dimensions are millimetres; PDF works in points (1/72 inch).
abstract final class PageFormatMapper {
  static PdfPageFormat fromProfile(PrintProfile profile) {
    final size = profile.orientedSizeMm;
    final width = size.widthMm * PdfPageFormat.mm;
    final height = size.heightMm * PdfPageFormat.mm;
    return PdfPageFormat(
      width,
      height,
      marginTop: profile.margins.topMm * PdfPageFormat.mm,
      marginRight: profile.margins.rightMm * PdfPageFormat.mm,
      marginBottom: profile.margins.bottomMm * PdfPageFormat.mm,
      marginLeft: profile.margins.leftMm * PdfPageFormat.mm,
    );
  }

  /// Page geometry with no margins — used when the content is an image or a
  /// label that must reach the edge of the media.
  static PdfPageFormat borderlessFromProfile(PrintProfile profile) {
    final size = profile.orientedSizeMm;
    return PdfPageFormat(
      size.widthMm * PdfPageFormat.mm,
      size.heightMm * PdfPageFormat.mm,
    );
  }
}
