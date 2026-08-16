import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../../core/errors/error_codes.dart';
import '../../../core/logging/app_logger.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import 'print_strategy.dart';
import 'raw_print_strategy.dart';
import 'text_print_strategy.dart';

/// Builds an ESC/POS command stream and sends it through the RAW spooler path.
///
/// **This strategy is never selected automatically.** Most printers are not
/// ESC/POS devices, and sending ESC/POS to a page printer produces pages of
/// garbage. A print profile — local or server-supplied — must ask for
/// `strategy: escpos` explicitly, which is a deliberate statement by whoever
/// configured that profile that the assigned device speaks ESC/POS.
///
/// Supported inputs:
///  * `raw`   — passed through unchanged (the server already built the stream)
///  * `text`  — encoded as Latin-1 with line feeds
///  * `png` / `jpeg` — converted to a monochrome `GS v 0` raster
class EscPosPrintStrategy implements PrintStrategy {
  EscPosPrintStrategy({
    required RawPrintStrategy rawStrategy,
    AppLogger? logger,
    this.dotsPerInch = 203,
    this.cutAfterPrint = true,
    this.feedLinesBeforeCut = 4,
  })  : _raw = rawStrategy,
        // ignore: unused_field
        _logger = logger;

  final RawPrintStrategy _raw;
  // ignore: unused_field
  final AppLogger? _logger;

  /// Typical thermal head resolution. 203 dpi covers the overwhelming majority;
  /// 300 dpi heads exist and can be configured here.
  final int dotsPerInch;
  final bool cutAfterPrint;
  final int feedLinesBeforeCut;

  @override
  String get name => 'escpos';

  @override
  PrintStrategyType get type => PrintStrategyType.escpos;

  /// Empty on purpose — see the class comment.
  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{};

  @override
  Future<PrintResult> print(PrintRequest request) async {
    try {
      final payload = await buildCommandStream(request);
      return _raw.print(
        request.copyWith(data: payload, documentType: DocumentType.raw),
      );
    } catch (e) {
      return PrintResult.failed(
        errorCode: ErrorCodes.unsupportedDocument,
        errorMessage:
            'This document could not be converted to ESC/POS commands.',
        errorDetail: e.toString(),
        strategyName: name,
      );
    }
  }

  /// Exposed for testing.
  Future<Uint8List> buildCommandStream(PrintRequest request) async {
    // Already a printer-language stream: send it verbatim, adding nothing.
    if (request.documentType == DocumentType.raw) return request.data;

    final builder = EscPosBuilder()..initialise();

    if (request.documentType.isImage) {
      final widthDots = printableWidthDots(request.profile);
      final raster = await _rasterise(request.data, widthDots);
      builder.rasterImage(raster);
    } else {
      builder.text(TextPrintStrategy.decodeText(request.data));
    }

    if (feedLinesBeforeCut > 0) builder.feed(feedLinesBeforeCut);
    if (cutAfterPrint) builder.partialCut();
    return builder.build();
  }

  /// Printable width in dots, rounded down to a whole byte (8 dots).
  int printableWidthDots(PrintProfile profile) {
    final usableMm = profile.orientedSizeMm.widthMm -
        profile.margins.leftMm -
        profile.margins.rightMm;
    final dots = (usableMm / 25.4 * dotsPerInch).floor();
    final bounded = dots.clamp(64, 2048);
    return bounded - (bounded % 8);
  }

  Future<MonochromeRaster> _rasterise(Uint8List bytes, int widthDots) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw StateError('The image could not be decoded.');
    }
    final resized = decoded.width == widthDots
        ? decoded
        : img.copyResize(
            decoded,
            width: widthDots,
            interpolation: img.Interpolation.average,
          );
    final grey = img.grayscale(resized);

    final bytesPerRow = widthDots ~/ 8;
    final height = grey.height;
    final data = Uint8List(bytesPerRow * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < widthDots; x++) {
        final pixel = grey.getPixel(x, y);
        // Luminance of a greyscale pixel is any channel; use red.
        final luminance = pixel.r.toDouble();
        if (luminance < 128) {
          // ESC/POS raster: a set bit prints a black dot.
          final index = y * bytesPerRow + (x >> 3);
          data[index] |= 0x80 >> (x & 0x07);
        }
      }
    }
    return MonochromeRaster(
      widthBytes: bytesPerRow,
      height: height,
      data: data,
    );
  }
}

class MonochromeRaster {
  const MonochromeRaster({
    required this.widthBytes,
    required this.height,
    required this.data,
  });

  final int widthBytes;
  final int height;
  final Uint8List data;
}

/// Minimal ESC/POS command assembler.
///
/// Only the commands the agent actually emits are implemented. Vendor
/// extensions belong in a vendor-specific strategy, not here.
class EscPosBuilder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  static const int _esc = 0x1B;
  static const int _gs = 0x1D;
  static const int _lf = 0x0A;

  /// `ESC @` — reset the printer to its power-on defaults.
  void initialise() => _buffer.add(<int>[_esc, 0x40]);

  /// `ESC a n` — 0 left, 1 centre, 2 right.
  void align(int mode) => _buffer.add(<int>[_esc, 0x61, mode.clamp(0, 2)]);

  void text(String value) {
    final normalised = value.replaceAll('\r\n', '\n');
    for (final rune in normalised.runes) {
      if (rune == 0x0A) {
        _buffer.addByte(_lf);
      } else if (rune >= 0x20 && rune <= 0xFF) {
        _buffer.addByte(rune);
      } else {
        _buffer.addByte(0x3F); // '?'
      }
    }
    _buffer.addByte(_lf);
  }

  /// `ESC d n` — feed n lines.
  void feed(int lines) =>
      _buffer.add(<int>[_esc, 0x64, lines.clamp(0, 255)]);

  /// `GS v 0 m xL xH yL yH d…` — raster bit image.
  void rasterImage(MonochromeRaster raster) {
    // Some controllers limit a single command to 255 rows, so the image is
    // emitted in horizontal bands.
    const int bandHeight = 255;
    var offset = 0;
    var remaining = raster.height;
    while (remaining > 0) {
      final rows = remaining > bandHeight ? bandHeight : remaining;
      _buffer.add(<int>[
        _gs,
        0x76,
        0x30,
        0x00, // mode: normal
        raster.widthBytes & 0xFF,
        (raster.widthBytes >> 8) & 0xFF,
        rows & 0xFF,
        (rows >> 8) & 0xFF,
      ]);
      _buffer.add(
        Uint8List.sublistView(
          raster.data,
          offset,
          offset + rows * raster.widthBytes,
        ),
      );
      offset += rows * raster.widthBytes;
      remaining -= rows;
    }
  }

  /// `GS V 66 n` — partial cut after feeding n dots.
  void partialCut({int feedDots = 0}) =>
      _buffer.add(<int>[_gs, 0x56, 66, feedDots.clamp(0, 255)]);

  /// `GS V 0` — full cut.
  void fullCut() => _buffer.add(<int>[_gs, 0x56, 0x00]);

  Uint8List build() => _buffer.toBytes();
}
