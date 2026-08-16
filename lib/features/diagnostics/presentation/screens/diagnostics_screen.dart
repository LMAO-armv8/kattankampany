import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/app_info.dart';
import '../../../../core/config/app_paths.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/di/service_locator.dart';
import '../../../../core/security/secure_credential_store.dart';
import '../../../../core/storage/database.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';
import '../../../../routing/app_router.dart';
import '../../../../routing/app_shell.dart';
import '../../../../services/background/lifecycle_controller.dart';
import '../../../printers/domain/printer_device.dart';
import '../../domain/diagnostic_check.dart';
import '../controllers/diagnostics_controller.dart';

/// Everything a support call needs on one screen, plus a one-click test suite.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  String? _testPrinterKey;
  bool _includeTestPrint = false;

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(runtimeStatusProvider).value ?? AgentRuntimeStatus.initial;
    final session = ref.watch(agentSessionProvider);
    final printers = ref.watch(printersProvider).value ?? <PrinterDevice>[];
    final report = ref.watch(diagnosticsControllerProvider);
    final controller = ref.watch(diagnosticsControllerProvider.notifier);
    final sync = ref.watch(syncServiceProvider);
    final updater = ref.watch(updateServiceProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'Run diagnostics',
          subtitle: 'Checks the connection, authorisation, printers and '
              'renderers, in that order.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: controller.isRunning
                        ? null
                        : () => controller.run(
                              testPrintPrinterKey:
                                  _includeTestPrint ? _testPrinterKey : null,
                            ),
                    icon: controller.isRunning
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Run diagnostics'),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Checkbox(
                    value: _includeTestPrint,
                    onChanged: (bool? value) => setState(() {
                      _includeTestPrint = value ?? false;
                      _testPrinterKey ??= printers
                          .where((PrinterDevice p) => p.isEnabled)
                          .map((PrinterDevice p) => p.printerKey)
                          .firstOrNull;
                    }),
                  ),
                  const Text('Include a test print'),
                  const SizedBox(width: AppSpacing.md),
                  if (_includeTestPrint)
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<String>(
                        initialValue: _testPrinterKey,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: 'Printer',
                        ),
                        items: <DropdownMenuItem<String>>[
                          for (final printer
                              in printers.where((PrinterDevice p) => p.isEnabled))
                            DropdownMenuItem<String>(
                              value: printer.printerKey,
                              child: Text(
                                printer.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (String? value) =>
                            setState(() => _testPrinterKey = value),
                      ),
                    ),
                ],
              ),
              if (report.checks.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                const Divider(),
                for (final check in report.checks) _CheckRow(check: check),
                if (report.isComplete) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    report.hasFailures
                        ? 'One or more checks failed. See the remedies above.'
                        : report.hasWarnings
                            ? 'Everything essential is working, with warnings.'
                            : 'All checks passed.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Agent',
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => context.go(AppRoutes.logs),
              icon: const Icon(Icons.article_outlined, size: 16),
              label: const Text('View logs'),
            ),
          ],
          child: Column(
            children: <Widget>[
              DetailRow(
                label: 'Connection',
                value: '',
                valueWidget:
                    StatusPill.connection(status.effectiveConnection),
              ),
              DetailRow(label: 'Store', value: status.storeName ?? '—'),
              DetailRow(label: 'Store URL', value: status.storeUrl ?? '—'),
              DetailRow(label: 'Agent name', value: status.agentName ?? '—'),
              DetailRow(
                label: 'Agent id (store)',
                value: session.serverAgentId ?? '—',
              ),
              DetailRow(
                label: 'Agent id (local)',
                value: session.agent?.id ?? '—',
              ),
              DetailRow(
                label: 'Agent status',
                value: session.agent?.status.label ?? '—',
              ),
              DetailRow(
                label: 'Last successful sync',
                value: status.lastSyncAt == null
                    ? 'Never'
                    : '${formatRelative(status.lastSyncAt!)} '
                        '(${status.lastSyncAt})',
              ),
              DetailRow(
                label: 'Last heartbeat',
                value: status.lastHeartbeatAt == null
                    ? 'Never'
                    : formatRelative(status.lastHeartbeatAt!),
              ),
              DetailRow(
                label: 'Job source',
                value: sync.sourceName,
              ),
              DetailRow(
                label: 'Current poll interval',
                value: '${sync.currentInterval.inSeconds}s',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Queue',
          child: Column(
            children: <Widget>[
              DetailRow(label: 'Pending', value: '${status.counters.pending}'),
              DetailRow(label: 'Printing', value: '${status.counters.printing}'),
              DetailRow(
                label: 'Completed',
                value: '${status.counters.completed}',
              ),
              DetailRow(label: 'Failed', value: '${status.counters.failed}'),
              DetailRow(
                label: 'Needs review',
                value: '${status.counters.interrupted}',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Printers',
          child: printers.isEmpty
              ? const EmptyState(
                  icon: Icons.print_disabled_outlined,
                  title: 'No printers discovered',
                )
              : Column(
                  children: <Widget>[
                    for (final printer in printers)
                      DetailRow(
                        label: printer.displayName,
                        value: '',
                        labelWidth: 260,
                        valueWidget: Row(
                          children: <Widget>[
                            StatusPill.printer(printer.state, compact: true),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                '${printer.connectionType.label}'
                                '${printer.subtitle.isEmpty ? '' : ' · ${printer.subtitle}'}'
                                '${printer.isEnabled ? '' : ' · disabled'}',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Environment',
          child: Column(
            children: <Widget>[
              DetailRow(
                label: 'Application version',
                value: AppInfo.instance.fullVersion,
              ),
              DetailRow(
                label: 'API contract version',
                value: '${AppInfo.apiMajorVersion}',
              ),
              DetailRow(
                label: 'Machine',
                value: AppInfo.instance.machineName,
              ),
              DetailRow(
                label: 'Operating system',
                value: AppInfo.instance.osDescription,
              ),
              DetailRow(
                label: 'Data folder',
                value: AppPaths.instance.root.path,
              ),
              DetailRow(
                label: 'Database size',
                value: _bytes(sl<AppDatabase>().fileSizeBytes()),
              ),
              DetailRow(
                label: 'Credential storage',
                value: sl<SecureCredentialStore>().description,
              ),
              DetailRow(
                label: 'Updates',
                value: updater.sourceDescription,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final DiagnosticCheck check;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);

    final (IconData icon, Color color) = switch (check.outcome) {
      DiagnosticOutcome.pass => (Icons.check_circle, colors.success),
      DiagnosticOutcome.warn => (Icons.warning_amber_rounded, colors.warning),
      DiagnosticOutcome.fail => (Icons.cancel, colors.danger),
      DiagnosticOutcome.skipped => (Icons.remove_circle_outline, colors.neutral),
      DiagnosticOutcome.running => (Icons.hourglass_empty, colors.info),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (check.outcome == DiagnosticOutcome.running)
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      check.title,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (check.durationMs != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        '${check.durationMs} ms',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                if (check.detail != null)
                  Text(
                    check.detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (check.remedy != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      check.remedy!,
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
