import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/features/print_queue/domain/print_job.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printers/domain/printer_device.dart';
import 'package:wc_print_agent/features/printers/domain/printer_status.dart';
import 'package:wc_print_agent/features/printing/domain/print_request.dart';
import 'package:wc_print_agent/services/printer/printer_service.dart';
import 'package:wc_print_agent/services/queue/document_downloader.dart';
import 'package:wc_print_agent/services/queue/job_reporter.dart';

/// A printer service backed by an in-memory list.
///
/// Lets the queue tests exercise the real [PrinterManager], the real resolver
/// and the real SQLite layer while controlling exactly what "the hardware"
/// reports.
class FakePrinterService implements PrinterService {
  FakePrinterService({
    List<DiscoveredPrinter>? printers,
    this.defaultPrinterKey,
  }) : printers = printers ?? <DiscoveredPrinter>[];

  List<DiscoveredPrinter> printers;
  String? defaultPrinterKey;

  /// Overrides for [isAvailable], keyed by printer.
  final Map<String, bool> availability = <String, bool>{};

  /// Queue of results returned by [print], oldest first. When empty, prints
  /// succeed.
  final List<PrintResult> scriptedResults = <PrintResult>[];

  final List<PrintRequest> printedRequests = <PrintRequest>[];
  final List<String> testPrinted = <String>[];
  int discoverCallCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<List<DiscoveredPrinter>> discover() async {
    discoverCallCount++;
    return printers;
  }

  @override
  Future<String?> getDefaultPrinterKey() async => defaultPrinterKey;

  @override
  Future<PrinterStatusReading> getStatus(String printerKey) async {
    final match = printers.where(
      (DiscoveredPrinter p) => p.printerKey == printerKey,
    );
    if (match.isEmpty) {
      return PrinterStatusReading(
        printerKey: printerKey,
        state: PrinterState.offline,
        readAt: DateTime.now(),
      );
    }
    return PrinterStatusReading(
      printerKey: printerKey,
      state: match.first.state,
      readAt: DateTime.now(),
    );
  }

  @override
  Future<bool> isAvailable(String printerKey) async {
    final override = availability[printerKey];
    if (override != null) return override;
    final reading = await getStatus(printerKey);
    return reading.state.canAcceptJobs;
  }

  @override
  Future<PrintResult> print(PrintRequest request) async {
    printedRequests.add(request);
    if (scriptedResults.isNotEmpty) return scriptedResults.removeAt(0);
    return const PrintResult.ok(spoolerJobId: 1, strategyName: 'fake');
  }

  @override
  Future<bool> cancel(String printerKey, int spoolerJobId) async => true;

  @override
  Future<PrintResult> testPrint(String printerKey, {PrintProfile? profile}) async {
    testPrinted.add(printerKey);
    return const PrintResult.ok(strategyName: 'fake-test');
  }
}

/// Returns fixed bytes instead of downloading anything.
class FakeDocumentDownloader implements DocumentDownloader {
  FakeDocumentDownloader({Uint8List? bytes, this.error})
      : bytes = bytes ?? Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46]);

  Uint8List bytes;

  /// When set, [resolve] throws this instead of returning.
  AppException? error;

  final List<String> resolved = <String>[];
  final List<String> discarded = <String>[];

  @override
  Future<ResolvedDocument> resolve(PrintJob job, {Uint8List? inlineData}) async {
    if (error != null) throw error!;
    resolved.add(job.id);
    return ResolvedDocument(
      bytes: bytes,
      filePath: 'C:\\fake\\${job.id}.pdf',
      type: job.documentType,
    );
  }

  @override
  Future<void> discard(PrintJob job) async {
    discarded.add(job.id);
  }
}

/// Records what would have been reported to the store.
class FakeJobReporter implements JobReporter {
  final List<String> starts = <String>[];
  final List<String> completions = <String>[];
  final List<({String jobId, String code, bool willRetry})> failures =
      <({String jobId, String code, bool willRetry})>[];
  final List<String> releases = <String>[];
  int replayCount = 0;

  @override
  Future<void> reportStart(PrintJob job, String printerKey) async {
    starts.add(job.id);
  }

  @override
  Future<bool> reportComplete(
    PrintJob job, {
    required String printerKey,
    int? spoolerJobId,
    Duration? duration,
  }) async {
    completions.add(job.id);
    return true;
  }

  @override
  Future<bool> reportFailure(
    PrintJob job, {
    required String errorCode,
    required String errorMessage,
    required bool willRetry,
    String? printerKey,
    DateTime? nextAttemptAt,
  }) async {
    failures.add((jobId: job.id, code: errorCode, willRetry: willRetry));
    return true;
  }

  @override
  Future<void> release(PrintJob job, {String reason = 'agent_shutdown'}) async {
    releases.add(job.id);
  }

  @override
  Future<int> replayPending({int limit = 25}) async {
    replayCount++;
    return 0;
  }
}

/// A scripted HTTP layer for the API client tests.
///
/// Handlers are matched on `METHOD path`; an unmatched request fails the test
/// loudly rather than silently returning an empty body.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter();

  final Map<String, ResponseBody Function(RequestOptions options)> handlers =
      <String, ResponseBody Function(RequestOptions options)>{};

  final List<RequestOptions> requests = <RequestOptions>[];

  void onGet(String path, Map<String, dynamic> body, {int status = 200}) {
    handlers['GET $path'] = (_) => _json(body, status);
  }

  void onPost(String path, Map<String, dynamic> body, {int status = 200}) {
    handlers['POST $path'] = (_) => _json(body, status);
  }

  void onPostSequence(String path, List<Map<String, dynamic>> bodies) {
    var index = 0;
    handlers['POST $path'] = (_) {
      final body = bodies[index < bodies.length ? index : bodies.length - 1];
      index++;
      return _json(body, 200);
    };
  }

  void onGetSequence(String path, List<Map<String, dynamic>> bodies) {
    var index = 0;
    handlers['GET $path'] = (_) {
      final body = bodies[index < bodies.length ? index : bodies.length - 1];
      index++;
      return _json(body, 200);
    };
  }

  void onError(String method, String path, int status,
      {Map<String, dynamic>? body,}) {
    handlers['$method $path'] = (_) => _json(
          body ?? <String, dynamic>{'code': 'error', 'message': 'failed'},
          status,
        );
  }

  static ResponseBody _json(Map<String, dynamic> body, int status) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.path}';
    final handler = handlers[key];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{
          'code': 'not_stubbed',
          'message': 'No stub registered for $key',
        }),
        404,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
