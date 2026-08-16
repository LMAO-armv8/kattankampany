import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../../core/config/app_info.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/error_codes.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../features/printers/domain/print_profile.dart';
import '../../features/printers/domain/printer_device.dart';
import '../../features/printers/domain/printer_status.dart';
import '../../features/printing/domain/print_document.dart';
import '../../features/printing/domain/print_request.dart';
import 'printer_service.dart';
import 'strategies/page_format.dart';
import 'strategies/print_strategy.dart';
import 'win32/windows_spooler.dart';

/// The Windows implementation of [PrinterService].
///
/// Discovery and status come straight from the spooler; the actual printing is
/// delegated to a [PrintStrategy] chosen by the registry. This class contains no
/// document handling of its own beyond generating the test page.
class WindowsPrinterService implements PrinterService {
  WindowsPrinterService({
    required WindowsSpooler spooler,
    required PrintStrategyRegistry strategies,
    AppLogger? logger,
  })  : _spooler = spooler,
        _strategies = strategies,
        _logger = logger;

  final WindowsSpooler _spooler;
  final PrintStrategyRegistry _strategies;
  final AppLogger? _logger;

  @override
  bool get isSupported => Platform.isWindows;

  // -------------------------------------------------------------------------
  // Discovery & status
  // -------------------------------------------------------------------------

  @override
  Future<List<DiscoveredPrinter>> discover() async {
    if (!isSupported) return const <DiscoveredPrinter>[];
    try {
      final printers = _spooler.enumeratePrinters();
      _logger?.info(
        LogCategory.printer,
        'Discovered ${printers.length} printer(s)',
        context: <String, Object?>{
          'printers': printers
              .map((DiscoveredPrinter p) => p.printerKey)
              .toList(growable: false),
        },
      );
      return printers;
    } on AppException catch (e, st) {
      _logger?.exception(LogCategory.printer, 'Printer discovery failed', e, st);
      return const <DiscoveredPrinter>[];
    } catch (e, st) {
      _logger?.exception(LogCategory.printer, 'Printer discovery failed', e, st);
      return const <DiscoveredPrinter>[];
    }
  }

  @override
  Future<PrinterStatusReading> getStatus(String printerKey) async {
    if (!isSupported) return PrinterStatusReading.unknownFor(printerKey);
    return _spooler.readStatus(printerKey);
  }

  @override
  Future<String?> getDefaultPrinterKey() async {
    if (!isSupported) return null;
    return _spooler.defaultPrinterName();
  }

  @override
  Future<bool> isAvailable(String printerKey) async {
    if (!isSupported) return false;
    final reading = await getStatus(printerKey);
    return reading.state.canAcceptJobs;
  }

  // -------------------------------------------------------------------------
  // Printing
  // -------------------------------------------------------------------------

  @override
  Future<PrintResult> print(PrintRequest request) async {
    if (!isSupported) {
      return const PrintResult.failed(
        errorCode: 'unsupported_platform',
        errorMessage: 'Printing is only available on Windows.',
      );
    }

    final strategy = _strategies.resolve(
      documentType: request.documentType,
      requested: request.profile.strategy,
    );

    if (strategy == null) {
      return PrintResult.failed(
        errorCode: ErrorCodes.unsupportedDocument,
        errorMessage:
            'This agent cannot print ${request.documentType.label} documents.',
        errorDetail:
            'No strategy registered for ${request.documentType.name} '
            '(requested: ${request.profile.strategy.name}).',
      );
    }

    _logger?.debug(
      LogCategory.printing,
      'Printing with "${strategy.name}" strategy',
      context: <String, Object?>{
        'job_id': request.jobId,
        'printer': request.printerKey,
        'document_type': request.documentType.name,
        'bytes': request.data.length,
      },
    );

    try {
      return await strategy.print(request);
    } catch (e, st) {
      _logger?.exception(
        LogCategory.printing,
        'Print strategy threw',
        e,
        st,
        <String, Object?>{'job_id': request.jobId, 'strategy': strategy.name},
      );
      final app = asAppException(e, st);
      return PrintResult.failed(
        errorCode: app.code,
        errorMessage: app.userMessage,
        errorDetail: app.technicalDetail ?? e.toString(),
        strategyName: strategy.name,
      );
    }
  }

  @override
  Future<bool> cancel(String printerKey, int spoolerJobId) async {
    if (!isSupported) return false;
    final cancelled = _spooler.cancelJob(printerKey, spoolerJobId);
    _logger?.info(
      LogCategory.printing,
      cancelled ? 'Spool job cancelled' : 'Spool job could not be cancelled',
      context: <String, Object?>{
        'printer': printerKey,
        'spooler_job_id': spoolerJobId,
      },
    );
    return cancelled;
  }

  // -------------------------------------------------------------------------
  // Test print
  // -------------------------------------------------------------------------

  @override
  Future<PrintResult> testPrint(
    String printerKey, {
    PrintProfile? profile,
  }) async {
    final effectiveProfile = profile ?? PrintProfile.defaultProfile();
    _logger?.info(
      LogCategory.printer,
      'Test print requested',
      context: <String, Object?>{
        'printer': printerKey,
        'profile': effectiveProfile.name,
      },
    );

    // An ESC/POS profile must produce an ESC/POS test page, otherwise the test
    // would exercise a completely different code path from real jobs.
    if (effectiveProfile.strategy == PrintStrategyType.escpos) {
      return _printTestPage(
        printerKey: printerKey,
        profile: effectiveProfile,
        documentType: DocumentType.text,
        data: Uint8List.fromList(
          buildTestPageText(printerKey, effectiveProfile).codeUnits,
        ),
      );
    }

    final pdf = await buildTestPagePdf(printerKey, effectiveProfile);
    return _printTestPage(
      printerKey: printerKey,
      profile: effectiveProfile,
      documentType: DocumentType.pdf,
      data: pdf,
    );
  }

  Future<PrintResult> _printTestPage({
    required String printerKey,
    required PrintProfile profile,
    required DocumentType documentType,
    required Uint8List data,
  }) =>
      print(
        PrintRequest(
          jobId: 'test-${DateTime.now().millisecondsSinceEpoch}',
          printerKey: printerKey,
          documentType: documentType,
          data: data,
          profile: profile.copyWith(copies: 1),
          documentTitle: '${AppInfo.productName} — test page',
        ),
      );

  /// Plain-text test page, used for receipt/label devices.
  static String buildTestPageText(String printerKey, PrintProfile profile) {
    final info = AppInfo.instance;
    final size = profile.orientedSizeMm;
    return <String>[
      AppInfo.productName,
      'Test page',
      '',
      'Printer : $printerKey',
      'Profile : ${profile.name}',
      'Media   : ${size.widthMm.toStringAsFixed(1)} x '
          '${size.heightMm.toStringAsFixed(1)} mm',
      'Agent   : ${info.machineName}',
      'Version : ${info.fullVersion}',
      'Time    : ${DateTime.now().toIso8601String()}',
      '',
      'If you can read this, the agent can reach this printer.',
    ].join('\n');
  }

  /// A one-page PDF test sheet. Generated locally, so Test Print works during
  /// installation before the agent has ever been paired with a store.
  static Future<Uint8List> buildTestPagePdf(
    String printerKey,
    PrintProfile profile,
  ) async {
    final info = AppInfo.instance;
    final size = profile.orientedSizeMm;
    final format = PageFormatMapper.fromProfile(profile);
    final isSmallMedia = size.widthMm < 120;

    final document = pw.Document(
      title: '${AppInfo.productName} test page',
      producer: AppInfo.productName,
    );

    document.addPage(
      pw.Page(
        pageFormat: format,
        orientation: pw.PageOrientation.natural,
        build: (pw.Context context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisSize: pw.MainAxisSize.min,
          children: <pw.Widget>[
            pw.Text(
              AppInfo.productName,
              style: pw.TextStyle(
                fontSize: isSmallMedia ? 11 : 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Test page',
              style: pw.TextStyle(fontSize: isSmallMedia ? 9 : 13),
            ),
            pw.SizedBox(height: isSmallMedia ? 6 : 14),
            _row('Printer', printerKey, isSmallMedia),
            _row('Profile', profile.name, isSmallMedia),
            _row(
              'Media',
              '${size.widthMm.toStringAsFixed(1)} × '
                  '${size.heightMm.toStringAsFixed(1)} mm '
                  '(${profile.orientation.name})',
              isSmallMedia,
            ),
            _row('Scaling', profile.scaling.name, isSmallMedia),
            _row('Agent', info.machineName, isSmallMedia),
            _row('Version', info.fullVersion, isSmallMedia),
            _row('Printed', DateTime.now().toString().split('.').first,
                isSmallMedia,),
            pw.SizedBox(height: isSmallMedia ? 6 : 14),
            // A visible frame makes clipping and scaling problems obvious at a
            // glance, which is the point of a test page.
            pw.Container(
              width: double.infinity,
              height: isSmallMedia ? 18 : 36,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 0.8),
              ),
              alignment: pw.Alignment.center,
              child: pw.Text(
                'Alignment frame — all four edges should be visible',
                style: pw.TextStyle(fontSize: isSmallMedia ? 6 : 9),
                textAlign: pw.TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );

    return document.save();
  }

  static pw.Widget _row(String label, String value, bool compact) => pw.Padding(
        padding: pw.EdgeInsets.only(bottom: compact ? 1.5 : 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.SizedBox(
              width: compact ? 44 : 70,
              child: pw.Text(
                label,
                style: pw.TextStyle(
                  fontSize: compact ? 7 : 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Expanded(
              child: pw.Text(
                value,
                style: pw.TextStyle(fontSize: compact ? 7 : 10),
              ),
            ),
          ],
        ),
      );
}
