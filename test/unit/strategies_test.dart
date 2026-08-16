import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printing/domain/print_document.dart';
import 'package:wc_print_agent/features/printing/domain/print_request.dart';
import 'package:wc_print_agent/services/printer/strategies/escpos_print_strategy.dart';
import 'package:wc_print_agent/services/printer/strategies/html_print_strategy.dart';
import 'package:wc_print_agent/services/printer/strategies/page_format.dart';
import 'package:wc_print_agent/services/printer/strategies/pdf_print_strategy.dart';
import 'package:wc_print_agent/services/printer/strategies/print_strategy.dart';
import 'package:wc_print_agent/services/printer/strategies/raw_print_strategy.dart';
import 'package:wc_print_agent/services/printer/strategies/text_print_strategy.dart';
import 'package:wc_print_agent/services/printer/win32/windows_spooler.dart';

PrintRequest request({
  DocumentType type = DocumentType.raw,
  PrintProfile? profile,
  Uint8List? data,
}) =>
    PrintRequest(
      jobId: 'job',
      printerKey: 'Printer',
      documentType: type,
      data: data ?? Uint8List.fromList(<int>[1, 2, 3]),
      profile: profile ?? PrintProfile.a4Default,
      documentTitle: 'Test',
    );

void main() {
  group('PrintStrategyRegistry', () {
    final spooler = WindowsSpooler();
    final pdf = PdfPrintStrategy();
    final text = TextPrintStrategy(pdfStrategy: pdf);
    final raw = RawPrintStrategy(spooler: spooler);
    final html = HtmlPrintStrategy(pdfStrategy: pdf, textStrategy: text);
    final escpos = EscPosPrintStrategy(rawStrategy: raw);
    final registry = PrintStrategyRegistry(<PrintStrategy>[
      pdf,
      text,
      html,
      raw,
      escpos,
    ]);

    test('auto picks the strategy for the document type', () {
      expect(
        registry.resolve(
          documentType: DocumentType.pdf,
          requested: PrintStrategyType.auto,
        ),
        same(pdf),
      );
      expect(
        registry.resolve(
          documentType: DocumentType.text,
          requested: PrintStrategyType.auto,
        ),
        same(text),
      );
      expect(
        registry.resolve(
          documentType: DocumentType.html,
          requested: PrintStrategyType.auto,
        ),
        same(html),
      );
      expect(
        registry.resolve(
          documentType: DocumentType.raw,
          requested: PrintStrategyType.auto,
        ),
        same(raw),
      );
    });

    test('ESC/POS is never selected automatically', () {
      // Sending ESC/POS to a page printer produces pages of garbage, so a
      // profile has to ask for it explicitly.
      expect(escpos.autoSelectableFor, isEmpty);
      for (final type in DocumentType.values) {
        final resolved = registry.resolve(
          documentType: type,
          requested: PrintStrategyType.auto,
        );
        expect(resolved, isNot(same(escpos)));
      }
    });

    test('an explicit request wins over automatic selection', () {
      expect(
        registry.resolve(
          documentType: DocumentType.png,
          requested: PrintStrategyType.escpos,
        ),
        same(escpos),
      );
    });

    test('an unhandled document type resolves to nothing rather than guessing',
        () {
      final bare = PrintStrategyRegistry(<PrintStrategy>[raw]);
      expect(
        bare.resolve(
          documentType: DocumentType.pdf,
          requested: PrintStrategyType.auto,
        ),
        isNull,
      );
    });
  });

  group('PageFormatMapper', () {
    test('converts millimetres to PDF points', () {
      const profile = PrintProfile(
        id: 'p',
        name: 'A4',
        paperSize: PaperSize.a4,
        margins: PageMargins(topMm: 10, rightMm: 10, bottomMm: 10, leftMm: 10),
      );
      final format = PageFormatMapper.fromProfile(profile);
      expect(format.width, closeTo(210 * PdfPageFormat.mm, 0.01));
      expect(format.height, closeTo(297 * PdfPageFormat.mm, 0.01));
      expect(format.marginTop, closeTo(10 * PdfPageFormat.mm, 0.01));
    });

    test('landscape swaps the page dimensions exactly once', () {
      const profile = PrintProfile(
        id: 'p',
        name: 'A4 landscape',
        paperSize: PaperSize.a4,
        orientation: PageOrientation.landscape,
      );
      final format = PageFormatMapper.fromProfile(profile);
      expect(format.width, closeTo(297 * PdfPageFormat.mm, 0.01));
      expect(format.height, closeTo(210 * PdfPageFormat.mm, 0.01));
    });

    test('a custom label size is honoured', () {
      const profile = PrintProfile(
        id: 'p',
        name: '4x6',
        paperSize: PaperSize.custom,
        widthMm: 101.6,
        heightMm: 152.4,
      );
      expect(profile.effectiveWidthMm, closeTo(101.6, 0.001));
      expect(profile.effectiveHeightMm, closeTo(152.4, 0.001));
    });
  });

  group('PrintProfile from a server payload', () {
    test('applies every supplied field', () {
      final profile = PrintProfile.fromServerPayload(<String, dynamic>{
        'name': '4x6 Shipping Label',
        'paper_size': '4x6',
        'orientation': 'landscape',
        'scaling': 'fill',
        'margins_mm': <String, dynamic>{
          'top': 1,
          'right': 2,
          'bottom': 3,
          'left': 4,
        },
        'copies': 2,
        'quality': 'high',
        'color': false,
        'duplex': 'long_edge',
        'strategy': 'pdf',
      });

      expect(profile.name, '4x6 Shipping Label');
      expect(profile.paperSize, PaperSize.label4x6);
      expect(profile.orientation, PageOrientation.landscape);
      expect(profile.scaling, PrintScaling.fill);
      expect(profile.margins.leftMm, 4);
      expect(profile.copies, 2);
      expect(profile.quality, PrintQuality.high);
      expect(profile.color, isFalse);
      expect(profile.duplex, DuplexMode.longEdge);
      expect(profile.strategy, PrintStrategyType.pdf);
    });

    test('an absent payload falls back to the base profile', () {
      final profile = PrintProfile.fromServerPayload(null);
      expect(profile.name, PrintProfile.a4Default.name);
      expect(profile.paperSize, PaperSize.a4);
    });

    test('unknown values degrade to safe defaults instead of throwing', () {
      final profile = PrintProfile.fromServerPayload(<String, dynamic>{
        'paper_size': 'something-new',
        'orientation': 'diagonal',
        'scaling': 'squish',
        'strategy': 'quantum',
      });
      expect(profile.paperSize, PaperSize.custom);
      expect(profile.orientation, PageOrientation.portrait);
      expect(profile.scaling, PrintScaling.fit);
      expect(profile.strategy, PrintStrategyType.auto);
    });
  });

  group('EscPosBuilder', () {
    test('emits an init sequence and a cut', () {
      final builder = EscPosBuilder()
        ..initialise()
        ..text('Hello')
        ..feed(2)
        ..partialCut();
      final bytes = builder.build();

      expect(bytes.sublist(0, 2), <int>[0x1B, 0x40]);
      expect(bytes, containsAllInOrder(<int>[0x48, 0x65, 0x6C, 0x6C, 0x6F]));
      expect(bytes, containsAllInOrder(<int>[0x1D, 0x56, 66]));
    });

    test('replaces characters the printer cannot render', () {
      final bytes = (EscPosBuilder()..text('café 中')).build();
      // The multibyte CJK character becomes '?'; Latin-1 accented text survives.
      expect(bytes, contains(0x3F));
      expect(bytes, contains(0xE9));
    });

    test('raw documents pass through the ESC/POS strategy untouched', () async {
      final strategy = EscPosPrintStrategy(
        rawStrategy: RawPrintStrategy(spooler: WindowsSpooler()),
      );
      final payload = Uint8List.fromList(<int>[0x1B, 0x40, 0x41, 0x42]);
      final built = await strategy.buildCommandStream(
        request(type: DocumentType.raw, data: payload),
      );
      expect(built, payload);
    });

    test('printable width is rounded down to a whole byte', () {
      final strategy = EscPosPrintStrategy(
        rawStrategy: RawPrintStrategy(spooler: WindowsSpooler()),
      );
      const profile = PrintProfile(
        id: 'r',
        name: '80mm',
        paperSize: PaperSize.roll80mm,
      );
      final dots = strategy.printableWidthDots(profile);
      expect(dots % 8, 0);
      expect(dots, greaterThan(500));
      expect(dots, lessThan(700));
    });
  });

  group('text decoding', () {
    test('handles UTF-8, a BOM, and invalid bytes without throwing', () {
      expect(
        TextPrintStrategy.decodeText(
          Uint8List.fromList(utf8.encode('Café')),
        ),
        'Café',
      );
      expect(
        TextPrintStrategy.decodeText(
          Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode('Hi')]),
        ),
        'Hi',
      );
      expect(
        TextPrintStrategy.decodeText(Uint8List.fromList(<int>[0xFF, 0xFE, 0x41])),
        isNotEmpty,
      );
    });
  });

  group('HTML degradation', () {
    test('strips markup and scripts when no renderer is available', () {
      final text = HtmlPrintStrategy.stripHtml(
        Uint8List.fromList(
          utf8.encode(
            '<html><head><style>b{}</style></head>'
            '<body><h1>Invoice</h1><script>alert(1)</script>'
            '<p>Total&nbsp;&amp;&nbsp;tax</p></body></html>',
          ),
        ),
      );
      expect(text, contains('Invoice'));
      expect(text, contains('Total & tax'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('<')));
    });
  });

  group('document type detection', () {
    test('sniffs the formats that have signatures', () {
      expect(
        DocumentType.sniff(Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46])),
        DocumentType.pdf,
      );
      expect(
        DocumentType.sniff(Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47])),
        DocumentType.png,
      );
      expect(
        DocumentType.sniff(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
        DocumentType.jpeg,
      );
      expect(
        DocumentType.sniff(Uint8List.fromList(<int>[0x41, 0x42, 0x43, 0x44])),
        isNull,
      );
    });

    test('a server-supplied filename cannot escape the documents folder', () {
      const document = PrintDocument(
        type: DocumentType.pdf,
        filename: r'..\..\Windows\System32\evil.exe',
      );
      expect(document.safeFilename, isNot(contains('..')));
      expect(document.safeFilename, isNot(contains(r'\')));
      expect(document.safeFilename, isNot(contains('/')));
    });
  });
}
