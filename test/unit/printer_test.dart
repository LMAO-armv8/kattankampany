import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/config/app_settings.dart';
import 'package:wc_print_agent/core/errors/error_codes.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printers/domain/printer_device.dart';
import 'package:wc_print_agent/features/printers/domain/printer_status.dart';
import 'package:wc_print_agent/services/printer/printer_resolver.dart';
import 'package:wc_print_agent/services/printer/win32/windows_spooler.dart';
import 'package:wc_print_agent/services/printer/win32/winspool_ffi.dart';

import '../fakes/test_environment.dart';
import 'queue_persistence_test.dart' show buildJob;

DiscoveredPrinter discovered(
  String name, {
  PrinterState state = PrinterState.ready,
  bool isDefault = false,
  String? port,
  String? driver,
}) =>
    DiscoveredPrinter(
      printerKey: name,
      displayName: name,
      state: state,
      isDefault: isDefault,
      portName: port,
      driverName: driver,
    );

PrinterDevice device(
  String key, {
  PrinterState state = PrinterState.ready,
  bool enabled = true,
  bool isDefault = false,
}) =>
    PrinterDevice(
      id: key,
      printerKey: key,
      displayName: key,
      state: state,
      isEnabled: enabled,
      isDefault: isDefault,
    );

void main() {
  group('Win32 status mapping', () {
    test('a clear status word means ready', () {
      expect(WindowsSpooler.mapStatus(0), PrinterState.ready);
    });

    test('offline wins over everything else', () {
      expect(
        WindowsSpooler.mapStatus(
          PrinterStatusFlags.offline | PrinterStatusFlags.busy,
        ),
        PrinterState.offline,
      );
    });

    test('the work-offline attribute is treated as offline', () {
      expect(
        WindowsSpooler.mapStatus(
          0,
          attributes: PrinterAttributeFlags.workOffline,
        ),
        PrinterState.offline,
      );
    });

    test('actionable paper conditions are surfaced specifically', () {
      expect(
        WindowsSpooler.mapStatus(PrinterStatusFlags.paperOut),
        PrinterState.outOfPaper,
      );
      expect(
        WindowsSpooler.mapStatus(PrinterStatusFlags.paperJam),
        PrinterState.paperJam,
      );
      expect(
        WindowsSpooler.mapStatus(PrinterStatusFlags.doorOpen),
        PrinterState.doorOpen,
      );
    });

    test('queued jobs read as busy', () {
      expect(WindowsSpooler.mapStatus(0, queuedJobs: 3), PrinterState.busy);
    });

    test('toner low is a warning, not a blocker', () {
      final state = WindowsSpooler.mapStatus(PrinterStatusFlags.tonerLow);
      expect(state, PrinterState.tonerLow);
      expect(state.canAcceptJobs, isTrue);
    });

    test('an unknown state still accepts jobs', () {
      // Many drivers report nothing at all; refusing to print to them would
      // break working installations.
      expect(PrinterState.unknown.canAcceptJobs, isTrue);
      expect(PrinterState.offline.canAcceptJobs, isFalse);
    });
  });

  group('connection type inference', () {
    test('classifies common Windows port names', () {
      expect(
        PrinterConnectionType.fromPortName('USB001'),
        PrinterConnectionType.usb,
      );
      expect(
        PrinterConnectionType.fromPortName('COM3'),
        PrinterConnectionType.serial,
      );
      expect(
        PrinterConnectionType.fromPortName('192.168.1.50'),
        PrinterConnectionType.network,
      );
      expect(
        PrinterConnectionType.fromPortName('WSD-abc'),
        PrinterConnectionType.network,
      );
      expect(
        PrinterConnectionType.fromPortName('PORTPROMPT:'),
        PrinterConnectionType.virtual,
      );
      expect(
        PrinterConnectionType.fromPortName(null),
        PrinterConnectionType.unknown,
      );
    });
  });

  group('printer discovery', () {
    late TestEnvironment env;

    setUp(() async {
      env = await TestEnvironment.create(
        printers: <DiscoveredPrinter>[
          discovered('Thermal Printer', port: 'USB001'),
          discovered('Office Printer', isDefault: true, port: '192.168.1.9'),
        ],
      );
    });

    tearDown(() => env.dispose());

    test('discovers and persists printers with no hard-coded names', () async {
      final printers = env.printerManager.printers;
      expect(printers, hasLength(2));
      expect(
        printers.map((PrinterDevice p) => p.printerKey),
        containsAll(<String>['Thermal Printer', 'Office Printer']),
      );
      expect(
        printers
            .firstWhere((PrinterDevice p) => p.printerKey == 'Office Printer')
            .isDefault,
        isTrue,
      );
    });

    test('rediscovery preserves operator configuration', () async {
      await env.printerManager
          .setEnabled('Thermal Printer', enabled: false);
      await env.printerManager
          .setDefaultProfile('Thermal Printer', 'profile_label_4x6');

      await env.printerManager.refresh();

      final thermal = env.printerManager.byKey('Thermal Printer')!;
      expect(thermal.isEnabled, isFalse);
      expect(thermal.defaultProfileId, 'profile_label_4x6');
    });

    test('a printer that disappears is kept but marked offline', () async {
      env.printerService.printers = <DiscoveredPrinter>[
        discovered('Office Printer', isDefault: true),
      ];
      await env.printerManager.refresh();

      final thermal = env.printerManager.byKey('Thermal Printer');
      expect(thermal, isNotNull, reason: 'History still references it');
      expect(thermal!.state, PrinterState.offline);
    });

    test('built-in print profiles are seeded and generic', () async {
      final names =
          env.printerManager.profiles.map((PrintProfile p) => p.name).toList();
      expect(
        names,
        containsAll(<String>[
          'A4 Document',
          'Letter Document',
          '4x6 Label',
          '80mm Receipt',
        ]),
      );
      // Nothing vendor-specific may be seeded into a distributable build.
      for (final name in names) {
        expect(name.toLowerCase(), isNot(contains('epson')));
        expect(name.toLowerCase(), isNot(contains('helett')));
      }
    });

    test('test printing goes to the requested device', () async {
      await env.printerManager.testPrint('Thermal Printer');
      expect(env.printerService.testPrinted, <String>['Thermal Printer']);
    });
  });

  group('PrinterResolver', () {
    const resolver = PrinterResolver();
    const settings = AppSettings.defaults;

    test('uses the printer the server asked for', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's', printerKey: 'Thermal'),
        printers: <PrinterDevice>[device('Thermal'), device('Office')],
        settings: settings,
      );
      expect(result, isA<ResolvedPrinter>());
      expect(result.printer!.printerKey, 'Thermal');
      expect(
        (result as ResolvedPrinter).source,
        PrinterResolutionSource.requested,
      );
    });

    test('refuses to substitute when the requested printer is missing', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's', printerKey: 'Thermal'),
        printers: <PrinterDevice>[device('Office')],
        settings: settings.copyWith(defaultPrinterKey: 'Office'),
      );
      expect(
        result,
        isA<UnavailablePrinter>(),
        reason: 'Silently printing a shipping label on the office laser is '
            'exactly the failure mode this rule prevents',
      );
      expect(
        (result as UnavailablePrinter).errorCode,
        ErrorCodes.printerNotFound,
      );
      expect(result.message, contains('Printer unavailable'));
    });

    test('refuses when the requested printer is offline', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's', printerKey: 'Thermal'),
        printers: <PrinterDevice>[
          device('Thermal', state: PrinterState.offline),
        ],
        settings: settings,
      );
      expect(result, isA<UnavailablePrinter>());
      expect(
        (result as UnavailablePrinter).errorCode,
        ErrorCodes.printerOffline,
      );
    });

    test('refuses when the requested printer is disabled by the operator', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's', printerKey: 'Thermal'),
        printers: <PrinterDevice>[device('Thermal', enabled: false)],
        settings: settings,
      );
      expect(result, isA<UnavailablePrinter>());
    });

    test('falls back only when the job explicitly allows it', () {
      final job = buildJob(storeId: 's', printerKey: 'Thermal')
          .copyWith(allowFallback: true);
      final result = resolver.resolve(
        job: job,
        printers: <PrinterDevice>[device('Office')],
        settings: settings.copyWith(fallbackPrinterKey: 'Office'),
      );
      expect(result, isA<FallbackPrinter>());
      expect((result as FallbackPrinter).requestedKey, 'Thermal');
      expect(result.device.printerKey, 'Office');
    });

    test('fallback is still refused when no fallback printer is configured', () {
      final job = buildJob(storeId: 's', printerKey: 'Thermal')
          .copyWith(allowFallback: true);
      final result = resolver.resolve(
        job: job,
        printers: <PrinterDevice>[device('Office')],
        settings: settings,
      );
      expect(result, isA<UnavailablePrinter>());
    });

    test('uses the agent default when the server names no printer', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's'),
        printers: <PrinterDevice>[device('Office'), device('Thermal')],
        settings: settings.copyWith(defaultPrinterKey: 'Thermal'),
      );
      expect(
        (result as ResolvedPrinter).source,
        PrinterResolutionSource.agentDefault,
      );
      expect(result.device.printerKey, 'Thermal');
    });

    test('falls through to the Windows default', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's'),
        printers: <PrinterDevice>[device('Office', isDefault: true)],
        settings: settings,
        windowsDefaultKey: 'Office',
      );
      expect(
        (result as ResolvedPrinter).source,
        PrinterResolutionSource.windowsDefault,
      );
    });

    test('reports a clear message when nothing is usable', () {
      final result = resolver.resolve(
        job: buildJob(storeId: 's'),
        printers: const <PrinterDevice>[],
        settings: settings,
      );
      expect(result, isA<UnavailablePrinter>());
      expect(
        (result as UnavailablePrinter).message,
        contains('No printer is available'),
      );
    });

    test('routes different jobs to different printers on one computer', () {
      final printers = <PrinterDevice>[
        device('Thermal'),
        device('Office'),
        device('Laser'),
      ];
      final labels = resolver.resolve(
        job: buildJob(storeId: 's', id: 'l', serverJobId: '1', printerKey: 'Thermal'),
        printers: printers,
        settings: settings,
      );
      final invoices = resolver.resolve(
        job: buildJob(storeId: 's', id: 'i', serverJobId: '2', printerKey: 'Office'),
        printers: printers,
        settings: settings,
      );
      final slips = resolver.resolve(
        job: buildJob(storeId: 's', id: 'p', serverJobId: '3', printerKey: 'Laser'),
        printers: printers,
        settings: settings,
      );
      expect(labels.printer!.printerKey, 'Thermal');
      expect(invoices.printer!.printerKey, 'Office');
      expect(slips.printer!.printerKey, 'Laser');
    });
  });
}
