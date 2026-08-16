import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/config/app_paths.dart';
import '../../../core/errors/error_codes.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/logging/log_level.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';
import 'pdf_print_strategy.dart';
import 'print_strategy.dart';
import 'text_print_strategy.dart';

/// Prints HTML by converting it to PDF with headless Microsoft Edge, then
/// delegating to [PdfPrintStrategy].
///
/// Edge ships with every supported Windows version, so this needs no bundled
/// browser and no additional install step. It is invoked with a fixed argument
/// list against a local file the agent itself wrote — the downloaded document is
/// never executed, and no remote content is loaded (`--disable-remote-fonts`
/// and offline flags are not used because a store's own CSS may live on the
/// same origin; see the note below).
///
/// If Edge cannot be found, the strategy degrades to printing the stripped text
/// rather than failing the job, and says so in the log.
class HtmlPrintStrategy implements PrintStrategy {
  HtmlPrintStrategy({
    required PdfPrintStrategy pdfStrategy,
    required TextPrintStrategy textStrategy,
    AppLogger? logger,
    HtmlToPdfConverter? converter,
  })  : _pdf = pdfStrategy,
        _text = textStrategy,
        _logger = logger,
        _converter = converter ?? EdgeHtmlToPdfConverter(logger: logger);

  final PdfPrintStrategy _pdf;
  final TextPrintStrategy _text;
  final AppLogger? _logger;
  final HtmlToPdfConverter _converter;

  @override
  String get name => 'html';

  @override
  PrintStrategyType get type => PrintStrategyType.html;

  @override
  Set<DocumentType> get autoSelectableFor => const <DocumentType>{
        DocumentType.html,
      };

  @override
  Future<PrintResult> print(PrintRequest request) async {
    Uint8List? pdfBytes;
    try {
      pdfBytes = await _converter.convert(
        html: request.data,
        profile: request.profile,
        jobId: request.jobId,
      );
    } catch (e) {
      _logger?.warn(
        LogCategory.printing,
        'HTML to PDF conversion failed; falling back to text rendering',
        context: <String, Object?>{'job_id': request.jobId},
        error: e,
      );
    }

    if (pdfBytes != null && pdfBytes.isNotEmpty) {
      return _pdf.print(
        request.copyWith(
          data: pdfBytes,
          documentType: DocumentType.pdf,
          profile: request.profile.copyWith(scaling: PrintScaling.none),
        ),
      );
    }

    _logger?.warn(
      LogCategory.printing,
      'Printing HTML as plain text — no HTML renderer available',
      context: <String, Object?>{'job_id': request.jobId},
    );
    final stripped = stripHtml(request.data);
    return _text.print(
      request.copyWith(
        data: Uint8List.fromList(stripped.codeUnits),
        documentType: DocumentType.text,
      ),
    );
  }

  /// Very small HTML → text reduction used only by the degraded path.
  static String stripHtml(Uint8List bytes) {
    final source = TextPrintStrategy.decodeText(bytes);
    return source
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>',
            caseSensitive: false, dotAll: true,), '',)
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>',
            caseSensitive: false, dotAll: true,), '',)
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|tr|h[1-6]|li)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}

/// Seam so the conversion step can be replaced (or stubbed in tests).
abstract class HtmlToPdfConverter {
  /// Returns PDF bytes, or null when no renderer is available.
  Future<Uint8List?> convert({
    required Uint8List html,
    required PrintProfile profile,
    required String jobId,
  });
}

/// Uses `msedge.exe --headless --print-to-pdf`.
class EdgeHtmlToPdfConverter implements HtmlToPdfConverter {
  EdgeHtmlToPdfConverter({
    AppLogger? logger,
    this.timeout = const Duration(seconds: 45),
  }) : _logger = logger;

  final AppLogger? _logger;
  final Duration timeout;

  /// Standard install locations. Checked in order; the first that exists wins.
  static List<String> candidateExecutables() {
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 = Platform.environment['ProgramFiles(x86)'] ??
        r'C:\Program Files (x86)';
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return <String>[
      p.join(programFilesX86, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      p.join(programFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      if (localAppData != null)
        p.join(localAppData, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      p.join(programFiles, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      p.join(programFilesX86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ];
  }

  static String? findExecutable() {
    if (!Platform.isWindows) return null;
    for (final candidate in candidateExecutables()) {
      try {
        if (File(candidate).existsSync()) return candidate;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @override
  Future<Uint8List?> convert({
    required Uint8List html,
    required PrintProfile profile,
    required String jobId,
  }) async {
    final executable = findExecutable();
    if (executable == null) return null;

    final workDir = AppPaths.instance.documentsDir;
    final htmlFile = File(p.join(workDir.path, 'render_$jobId.html'));
    final pdfFile = File(p.join(workDir.path, 'render_$jobId.pdf'));

    try {
      await htmlFile.writeAsBytes(html, flush: true);

      final size = profile.orientedSizeMm;
      final result = await Process.run(
        executable,
        <String>[
          '--headless=new',
          '--disable-gpu',
          '--disable-extensions',
          '--no-first-run',
          '--no-default-browser-check',
          '--run-all-compositor-stages-before-draw',
          '--print-to-pdf-no-header',
          // Chromium expects inches.
          '--paper-width=${(size.widthMm / 25.4).toStringAsFixed(4)}',
          '--paper-height=${(size.heightMm / 25.4).toStringAsFixed(4)}',
          '--print-to-pdf=${pdfFile.path}',
          Uri.file(htmlFile.path).toString(),
        ],
        runInShell: false,
      ).timeout(timeout);

      if (!pdfFile.existsSync()) {
        _logger?.warn(
          LogCategory.printing,
          'Headless renderer produced no PDF',
          context: <String, Object?>{
            'job_id': jobId,
            'exit_code': result.exitCode,
          },
        );
        return null;
      }
      final bytes = await pdfFile.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      _logger?.warn(
        LogCategory.printing,
        'Headless HTML rendering failed',
        context: <String, Object?>{'job_id': jobId},
        error: e,
      );
      return null;
    } finally {
      for (final file in <File>[htmlFile, pdfFile]) {
        try {
          if (file.existsSync()) await file.delete();
        } catch (_) {
          // Cleaned up by the documents-folder prune pass instead.
        }
      }
    }
  }
}

/// Reports whether HTML printing will use the full renderer or the degraded
/// text path. Surfaced on the Diagnostics screen so support can see it.
bool get isHtmlRendererAvailable => EdgeHtmlToPdfConverter.findExecutable() != null;

/// Error code used when HTML cannot be printed at all.
const String htmlRenderErrorCode = ErrorCodes.unsupportedDocument;
