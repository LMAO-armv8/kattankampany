import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/di/service_locator.dart';
import '../../../../core/errors/app_exception.dart';
import '../../../../core/logging/log_level.dart';
import '../../../../core/network/connectivity_monitor.dart';
import '../../../../core/security/secure_credential_store.dart';
import '../../../../services/printer/strategies/html_print_strategy.dart';
import '../../../printers/domain/printer_device.dart';
import '../../domain/diagnostic_check.dart';

/// Runs the "Run diagnostics" sequence.
///
/// Each check is deliberately independent and ordered from cheapest to most
/// invasive, so a support call can stop as soon as something fails. The last
/// check — an actual test print — is opt-in, because it consumes paper.
class DiagnosticsController extends StateNotifier<DiagnosticsReport> {
  DiagnosticsController(this._ref) : super(DiagnosticsReport.empty());

  final Ref _ref;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> run({String? testPrintPrinterKey}) async {
    if (_running) return;
    _running = true;

    final logger = _ref.read(loggerProvider);
    logger.info(LogCategory.diagnostics, 'Diagnostics run started');

    final checks = <DiagnosticCheck>[
      DiagnosticCheck.pending('storage', 'Local database'),
      DiagnosticCheck.pending('credentials', 'Credential storage'),
      DiagnosticCheck.pending('internet', 'Internet connection'),
      DiagnosticCheck.pending('api', 'Store API reachable'),
      DiagnosticCheck.pending('auth', 'Agent authorisation'),
      DiagnosticCheck.pending('printers', 'Printer discovery'),
      DiagnosticCheck.pending('renderer', 'Document renderers'),
      if (testPrintPrinterKey != null)
        DiagnosticCheck.pending('testprint', 'Test print'),
    ];

    state = DiagnosticsReport(checks: checks, startedAt: DateTime.now());

    await _run('storage', _checkStorage);
    await _run('credentials', _checkCredentials);
    await _run('internet', _checkInternet);
    await _run('api', _checkApi);
    await _run('auth', _checkAuth);
    await _run('printers', _checkPrinters);
    await _run('renderer', _checkRenderers);
    if (testPrintPrinterKey != null) {
      await _run('testprint', () => _checkTestPrint(testPrintPrinterKey));
    }

    state = DiagnosticsReport(
      checks: state.checks,
      startedAt: state.startedAt,
      finishedAt: DateTime.now(),
    );
    _running = false;

    logger.info(
      LogCategory.diagnostics,
      'Diagnostics run finished',
      context: <String, Object?>{
        'failures': state.checks
            .where((DiagnosticCheck c) => c.outcome == DiagnosticOutcome.fail)
            .length,
        'warnings': state.checks
            .where((DiagnosticCheck c) => c.outcome == DiagnosticOutcome.warn)
            .length,
      },
    );
  }

  Future<void> _run(
    String id,
    Future<DiagnosticCheck> Function() check,
  ) async {
    final stopwatch = Stopwatch()..start();
    DiagnosticCheck result;
    try {
      result = await check();
    } catch (e) {
      final existing = _find(id);
      result = DiagnosticCheck(
        id: id,
        title: existing?.title ?? id,
        outcome: DiagnosticOutcome.fail,
        detail: e.toString(),
      );
    }
    stopwatch.stop();
    _replace(result.copyWith(durationMs: stopwatch.elapsedMilliseconds));
  }

  DiagnosticCheck? _find(String id) {
    for (final check in state.checks) {
      if (check.id == id) return check;
    }
    return null;
  }

  void _replace(DiagnosticCheck updated) {
    state = DiagnosticsReport(
      checks: <DiagnosticCheck>[
        for (final check in state.checks)
          if (check.id == updated.id) updated else check,
      ],
      startedAt: state.startedAt,
      finishedAt: state.finishedAt,
    );
  }

  // -------------------------------------------------------------------------
  // Checks
  // -------------------------------------------------------------------------

  Future<DiagnosticCheck> _checkStorage() async {
    final queue = _ref.read(queueRepositoryProvider);
    final counters = await queue.counters();
    return DiagnosticCheck(
      id: 'storage',
      title: 'Local database',
      outcome: DiagnosticOutcome.pass,
      detail: 'Readable. ${counters.total} job record(s) stored.',
    );
  }

  Future<DiagnosticCheck> _checkCredentials() async {
    final store = sl<SecureCredentialStore>();
    if (!store.isEncrypted) {
      return DiagnosticCheck(
        id: 'credentials',
        title: 'Credential storage',
        outcome: DiagnosticOutcome.warn,
        detail: store.description,
        remedy: 'Windows credential protection is unavailable on this host. '
            'Do not use this configuration in production.',
      );
    }
    return DiagnosticCheck(
      id: 'credentials',
      title: 'Credential storage',
      outcome: DiagnosticOutcome.pass,
      detail: store.description,
    );
  }

  Future<DiagnosticCheck> _checkInternet() async {
    final monitor = sl<ConnectivityMonitor>();
    final status = await monitor.probe();
    return switch (status) {
      NetworkStatus.online => const DiagnosticCheck(
          id: 'internet',
          title: 'Internet connection',
          outcome: DiagnosticOutcome.pass,
          detail: 'The store host is reachable.',
        ),
      NetworkStatus.offline => const DiagnosticCheck(
          id: 'internet',
          title: 'Internet connection',
          outcome: DiagnosticOutcome.fail,
          detail: 'The store host could not be reached.',
          remedy: 'Check this computer\'s network connection, and that no '
              'firewall is blocking outbound HTTPS.',
        ),
      NetworkStatus.unknown => const DiagnosticCheck(
          id: 'internet',
          title: 'Internet connection',
          outcome: DiagnosticOutcome.warn,
          detail: 'Connection state could not be determined.',
        ),
    };
  }

  Future<DiagnosticCheck> _checkApi() async {
    final session = _ref.read(agentSessionProvider);
    if (!session.isPaired) {
      return const DiagnosticCheck(
        id: 'api',
        title: 'Store API reachable',
        outcome: DiagnosticOutcome.skipped,
        detail: 'This computer is not connected to a store yet.',
      );
    }
    try {
      await session.api.getAgent();
      return DiagnosticCheck(
        id: 'api',
        title: 'Store API reachable',
        outcome: DiagnosticOutcome.pass,
        detail: '${session.store!.apiBaseUrl} responded.',
      );
    } on AuthException {
      // Reached the API — authorisation is a separate check.
      return DiagnosticCheck(
        id: 'api',
        title: 'Store API reachable',
        outcome: DiagnosticOutcome.pass,
        detail: '${session.store!.apiBaseUrl} responded (unauthorised).',
      );
    } on AppException catch (e) {
      return DiagnosticCheck(
        id: 'api',
        title: 'Store API reachable',
        outcome: DiagnosticOutcome.fail,
        detail: e.userMessage,
        remedy: e.technicalDetail,
      );
    }
  }

  Future<DiagnosticCheck> _checkAuth() async {
    final session = _ref.read(agentSessionProvider);
    if (!session.isPaired) {
      return const DiagnosticCheck(
        id: 'auth',
        title: 'Agent authorisation',
        outcome: DiagnosticOutcome.skipped,
        detail: 'Not paired.',
      );
    }
    final ok = await session.verify();
    if (ok) {
      return DiagnosticCheck(
        id: 'auth',
        title: 'Agent authorisation',
        outcome: DiagnosticOutcome.pass,
        detail: 'Authorised as "${session.agent!.name}".',
      );
    }
    return const DiagnosticCheck(
      id: 'auth',
      title: 'Agent authorisation',
      outcome: DiagnosticOutcome.fail,
      detail: 'The store did not accept this agent.',
      remedy: 'Reconnect the agent from the Connect screen, or re-enable it in '
          'WooCommerce → Print Management → Agents.',
    );
  }

  Future<DiagnosticCheck> _checkPrinters() async {
    final manager = _ref.read(printerManagerProvider);
    if (!manager.isSupported) {
      return const DiagnosticCheck(
        id: 'printers',
        title: 'Printer discovery',
        outcome: DiagnosticOutcome.warn,
        detail: 'Printing is only available on Windows.',
      );
    }
    final printers = await manager.refresh();
    if (printers.isEmpty) {
      return const DiagnosticCheck(
        id: 'printers',
        title: 'Printer discovery',
        outcome: DiagnosticOutcome.fail,
        detail: 'Windows reported no printers.',
        remedy: 'Install a printer in Windows Settings, then run diagnostics '
            'again.',
      );
    }
    final unhealthy = printers
        .where((PrinterDevice p) => p.isEnabled && !p.state.isHealthy)
        .toList(growable: false);
    if (unhealthy.isNotEmpty) {
      return DiagnosticCheck(
        id: 'printers',
        title: 'Printer discovery',
        outcome: DiagnosticOutcome.warn,
        detail: '${printers.length} printer(s) found; '
            '${unhealthy.length} not ready: '
            '${unhealthy.map((PrinterDevice p) => '${p.displayName} (${p.state.label})').join(', ')}',
        remedy: unhealthy.first.state.problemMessage,
      );
    }
    return DiagnosticCheck(
      id: 'printers',
      title: 'Printer discovery',
      outcome: DiagnosticOutcome.pass,
      detail: '${printers.length} printer(s) found and ready.',
    );
  }

  Future<DiagnosticCheck> _checkRenderers() async {
    final htmlAvailable = isHtmlRendererAvailable;
    if (!Platform.isWindows) {
      return const DiagnosticCheck(
        id: 'renderer',
        title: 'Document renderers',
        outcome: DiagnosticOutcome.skipped,
        detail: 'Windows only.',
      );
    }
    if (!htmlAvailable) {
      return const DiagnosticCheck(
        id: 'renderer',
        title: 'Document renderers',
        outcome: DiagnosticOutcome.warn,
        detail: 'PDF, image and text rendering available. '
            'No HTML renderer found.',
        remedy: 'HTML documents will be printed as plain text. Install '
            'Microsoft Edge to render them fully.',
      );
    }
    return const DiagnosticCheck(
      id: 'renderer',
      title: 'Document renderers',
      outcome: DiagnosticOutcome.pass,
      detail: 'PDF, image, text and HTML rendering available.',
    );
  }

  Future<DiagnosticCheck> _checkTestPrint(String printerKey) async {
    final manager = _ref.read(printerManagerProvider);
    final result = await manager.testPrint(printerKey);
    if (result.success) {
      return DiagnosticCheck(
        id: 'testprint',
        title: 'Test print',
        outcome: DiagnosticOutcome.pass,
        detail: 'A test page was sent to "$printerKey".',
      );
    }
    return DiagnosticCheck(
      id: 'testprint',
      title: 'Test print',
      outcome: DiagnosticOutcome.fail,
      detail: result.errorMessage ?? 'The test page could not be printed.',
      remedy: result.errorDetail,
    );
  }
}

final StateNotifierProvider<DiagnosticsController, DiagnosticsReport>
    diagnosticsControllerProvider =
    StateNotifierProvider<DiagnosticsController, DiagnosticsReport>(
  (Ref ref) => DiagnosticsController(ref),
);
