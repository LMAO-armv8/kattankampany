import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/features/printers/domain/network_printer.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printers/domain/printer_status.dart';
import 'package:wc_print_agent/features/printing/domain/print_document.dart';
import 'package:wc_print_agent/features/printing/domain/print_request.dart';
import 'package:wc_print_agent/services/printer/network/network_printer_service.dart';

/// A stand-in raw printer, the same shape as `tool/fake_printer.dart`.
///
/// Bound to port 0 so the OS picks a free one — a fixed port would make the
/// suite fail on any machine that already has something on 9100, which is
/// exactly what a print agent developer's machine tends to look like.
class _FakePrinter {
  _FakePrinter._(this._server);

  final ServerSocket _server;
  final List<List<int>> jobs = <List<int>>[];

  int get port => _server.port;

  static Future<_FakePrinter> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final printer = _FakePrinter._(server);

    server.listen((Socket socket) async {
      final chunks = <int>[];
      await socket.forEach(chunks.addAll);
      if (chunks.isNotEmpty) printer.jobs.add(chunks);
      socket.destroy();
    });

    return printer;
  }

  Future<void> stop() => _server.close();
}

void main() {
  group('NetworkPrinter parsing', () {
    test('accepts a bare address and assumes the raw port', () {
      final printer = NetworkPrinter.parse('192.168.1.50');

      expect(printer, isNotNull);
      expect(printer!.host, '192.168.1.50');
      expect(printer.port, 9100);
    });

    test('accepts host:port', () {
      final printer = NetworkPrinter.parse('192.168.1.50:9101');

      expect(printer!.host, '192.168.1.50');
      expect(printer.port, 9101);
    });

    test('accepts the net:// form it produces itself', () {
      final printer = NetworkPrinter.parse('net://printer.local:9100');

      expect(printer!.host, 'printer.local');
      expect(printer.port, 9100);
    });

    test('accepts bracketed IPv6', () {
      final printer = NetworkPrinter.parse('[fe80::1]:9100');

      expect(printer!.host, 'fe80::1');
      expect(printer.port, 9100);
    });

    test('rejects empty input', () {
      expect(NetworkPrinter.parse('   '), isNull);
    });

    test('key is derived from the address, so renaming keeps routing intact', () {
      const a = NetworkPrinter(name: 'Old name', host: '10.0.0.5');
      const b = NetworkPrinter(name: 'New name', host: '10.0.0.5');

      expect(a.printerKey, b.printerKey);
      expect(a.printerKey, 'net://10.0.0.5:9100');
    });

    test('survives a JSON round trip', () {
      const original = NetworkPrinter(
        name: 'Label printer',
        host: '10.0.0.5',
        port: 9101,
        enabled: false,
      );

      final restored = NetworkPrinter.fromJson(original.toJson());

      expect(restored!.name, original.name);
      expect(restored.host, original.host);
      expect(restored.port, original.port);
      expect(restored.enabled, isFalse);
    });
  });

  group('NetworkPrinterService against a real socket', () {
    late _FakePrinter fake;
    late NetworkPrinter printer;
    late NetworkPrinterService service;

    setUp(() async {
      fake = await _FakePrinter.start();
      printer = NetworkPrinter(
        name: 'Fake printer',
        host: '127.0.0.1',
        port: fake.port,
      );
      service = NetworkPrinterService(
        printers: () async => <NetworkPrinter>[printer],
        connectTimeout: const Duration(seconds: 2),
      );
    });

    tearDown(() async => fake.stop());

    test('discovers a reachable printer as ready', () async {
      final discovered = await service.discover();

      expect(discovered, hasLength(1));
      expect(discovered.single.printerKey, printer.printerKey);
      expect(discovered.single.state, PrinterState.ready);
      expect(discovered.single.connectionType, PrinterConnectionType.network);
      expect(discovered.single.host, '127.0.0.1');
    });

    test('delivers the document bytes verbatim', () async {
      final payload = Uint8List.fromList('HELLO PRINTER'.codeUnits);

      final result = await service.print(
        PrintRequest(
          jobId: 'job-1',
          printerKey: printer.printerKey,
          documentType: DocumentType.text,
          data: payload,
          profile: PrintProfile.defaultProfile(),
          documentTitle: 'Test',
        ),
      );

      expect(result.success, isTrue);
      expect(result.bytesSent, payload.length);

      // The bytes must arrive unaltered — there is no driver to translate them.
      await _settle();
      expect(fake.jobs, hasLength(1));
      expect(String.fromCharCodes(fake.jobs.single), 'HELLO PRINTER');
    });

    test('sends each copy as its own job', () async {
      await service.print(
        PrintRequest(
          jobId: 'job-2',
          printerKey: printer.printerKey,
          documentType: DocumentType.text,
          data: Uint8List.fromList('COPY'.codeUnits),
          profile: PrintProfile.defaultProfile(),
          documentTitle: 'Test',
          copies: 3,
        ),
      );

      await _settle();
      expect(fake.jobs, hasLength(3));
    });

    test('test print reaches the device', () async {
      final result = await service.testPrint(printer.printerKey);

      expect(result.success, isTrue);

      await _settle();
      expect(
        String.fromCharCodes(fake.jobs.single),
        contains('PRINT AGENT TEST PAGE'),
      );
    });

    test('reports an empty document rather than sending nothing', () async {
      final result = await service.print(
        PrintRequest(
          jobId: 'job-3',
          printerKey: printer.printerKey,
          documentType: DocumentType.text,
          data: Uint8List(0),
          profile: PrintProfile.defaultProfile(),
          documentTitle: 'Test',
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, 'document_invalid');
    });

    test('an unknown key is a clear failure, not a crash', () async {
      final result = await service.print(
        PrintRequest(
          jobId: 'job-4',
          printerKey: 'net://10.255.255.1:9100',
          documentType: DocumentType.text,
          data: Uint8List.fromList('x'.codeUnits),
          profile: PrintProfile.defaultProfile(),
          documentTitle: 'Test',
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, 'printer_not_found');
    });
  });

  group('NetworkPrinterService when the printer is gone', () {
    test('reports offline rather than ready', () async {
      // Bind and immediately release, so the port is almost certainly dead.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final service = NetworkPrinterService(
        printers: () async => <NetworkPrinter>[
          NetworkPrinter(name: 'Gone', host: '127.0.0.1', port: deadPort),
        ],
        connectTimeout: const Duration(milliseconds: 500),
      );

      final discovered = await service.discover();

      expect(discovered.single.state, PrinterState.offline);
      expect(await service.isAvailable('net://127.0.0.1:$deadPort'), isFalse);
    });

    test('a disabled printer is paused, and is never contacted', () async {
      final fake = await _FakePrinter.start();
      addTearDown(fake.stop);

      final service = NetworkPrinterService(
        printers: () async => <NetworkPrinter>[
          NetworkPrinter(
            name: 'Switched off',
            host: '127.0.0.1',
            port: fake.port,
            enabled: false,
          ),
        ],
      );

      final discovered = await service.discover();

      expect(discovered.single.state, PrinterState.paused);

      final result = await service.print(
        PrintRequest(
          jobId: 'job-5',
          printerKey: 'net://127.0.0.1:${fake.port}',
          documentType: DocumentType.text,
          data: Uint8List.fromList('x'.codeUnits),
          profile: PrintProfile.defaultProfile(),
          documentTitle: 'Test',
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorCode, 'printer_offline');
      expect(fake.jobs, isEmpty);
    });
  });

  group('key ownership', () {
    test('only net:// keys belong to the network service', () {
      expect(NetworkPrinterService.owns('net://10.0.0.5:9100'), isTrue);
      expect(NetworkPrinterService.owns('EPSON TM-T82'), isFalse);
      expect(NetworkPrinterService.owns(r'\\SERVER\Printer'), isFalse);
    });
  });
}

/// Lets the fake printer's socket callbacks run before assertions.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));
