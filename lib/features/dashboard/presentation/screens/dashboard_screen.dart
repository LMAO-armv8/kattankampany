import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';
import '../../../../routing/app_router.dart';
import '../../../../routing/app_shell.dart';
import '../../../../services/background/lifecycle_controller.dart';
import '../../../agent/domain/agent.dart';
import '../../../print_queue/domain/print_job.dart';
import '../../../printers/domain/printer_device.dart';
import '../widgets/stat_tile.dart';

/// The screen an operator leaves open all day.
///
/// Answers three questions without scrolling: is the agent connected, are the
/// printers healthy, and is anything stuck.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(runtimeStatusProvider).value ?? AgentRuntimeStatus.initial;
    final printers = ref.watch(printersProvider).value ?? <PrinterDevice>[];
    final recent = ref.watch(recentJobsProvider).value ?? <PrintJob>[];

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        _ConnectionCard(status: status),
        const SizedBox(height: AppSpacing.md),
        _QueueSummary(counters: status.counters),
        const SizedBox(height: AppSpacing.md),
        _PrintersCard(printers: printers),
        const SizedBox(height: AppSpacing.md),
        _RecentJobsCard(jobs: recent),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.status});

  final AgentRuntimeStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connection = status.effectiveConnection;

    return SectionCard(
      title: 'Connection',
      actions: <Widget>[StatusPill.connection(connection)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (connection == AgentConnectionState.unauthorised)
            _Notice(
              tone: StatusTone.danger,
              icon: Icons.link_off,
              message: 'This agent is no longer authorised by your store. '
                  'Reconnect it to resume printing.',
              action: TextButton(
                onPressed: () => context.go(AppRoutes.setup),
                child: const Text('Reconnect'),
              ),
            )
          else if (connection == AgentConnectionState.offline)
            const _Notice(
              tone: StatusTone.warning,
              icon: Icons.cloud_off,
              message: 'No connection to your store. Queued jobs are safe and '
                  'will print automatically when the connection returns.',
            )
          else if (connection == AgentConnectionState.paused)
            _Notice(
              tone: StatusTone.warning,
              icon: Icons.pause_circle_outline,
              message: 'Printing is paused. Jobs will keep arriving but nothing '
                  'will be sent to a printer.',
              action: TextButton(
                onPressed: () => ref.read(lifecycleProvider).resumePrinting(),
                child: const Text('Resume'),
              ),
            ),
          if (connection != AgentConnectionState.connected)
            const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              _Field(label: 'Store', value: status.storeName ?? '—'),
              _Field(label: 'Address', value: _host(status.storeUrl)),
              _Field(label: 'Agent', value: status.agentName ?? '—'),
              _Field(
                label: 'Last synchronisation',
                value: status.lastSyncAt == null
                    ? 'Never'
                    : formatRelative(status.lastSyncAt!),
              ),
              _Field(
                label: 'Polling every',
                value: status.syncIntervalSeconds == null
                    ? '—'
                    : '${status.syncIntervalSeconds}s',
              ),
            ],
          ),
          if (status.lastError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Text(
              status.lastError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: StatusColors.of(context).warning,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _host(String? url) {
    if (url == null) return '—';
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}

class _QueueSummary extends StatelessWidget {
  const _QueueSummary({required this.counters});

  final QueueCounters counters;

  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Queue',
        actions: <Widget>[
          TextButton(
            onPressed: () => context.go(AppRoutes.queue),
            child: const Text('Open queue'),
          ),
        ],
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final tiles = <Widget>[
              StatTile(
                label: 'Pending',
                value: counters.pending,
                tone: StatusTone.neutral,
                icon: Icons.schedule,
                onTap: () => context.go(AppRoutes.queue),
              ),
              StatTile(
                label: 'Printing',
                value: counters.printing,
                tone: StatusTone.info,
                icon: Icons.print,
                onTap: () => context.go(AppRoutes.queue),
              ),
              StatTile(
                label: 'Completed',
                value: counters.completed,
                tone: StatusTone.success,
                icon: Icons.check_circle_outline,
                onTap: () => context.go(AppRoutes.history),
              ),
              StatTile(
                label: 'Failed',
                value: counters.failed,
                tone: StatusTone.danger,
                icon: Icons.error_outline,
                onTap: () => context.go(AppRoutes.queue),
              ),
              if (counters.interrupted > 0)
                StatTile(
                  label: 'Needs review',
                  value: counters.interrupted,
                  tone: StatusTone.warning,
                  icon: Icons.help_outline,
                  onTap: () => context.go(AppRoutes.queue),
                ),
            ];
            final columns = constraints.maxWidth > 860 ? tiles.length : 2;
            return GridView.count(
              crossAxisCount: columns < 1 ? 1 : columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              childAspectRatio: 2.5,
              children: tiles,
            );
          },
        ),
      );
}

class _PrintersCard extends ConsumerWidget {
  const _PrintersCard({required this.printers});

  final List<PrinterDevice> printers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled =
        printers.where((PrinterDevice p) => p.isEnabled).toList(growable: false);

    return SectionCard(
      title: 'Printers',
      subtitle: enabled.isEmpty
          ? null
          : '${enabled.length} available on this computer',
      actions: <Widget>[
        TextButton(
          onPressed: () => ref.read(lifecycleProvider).refreshPrinters(),
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => context.go(AppRoutes.printers),
          child: const Text('Manage'),
        ),
      ],
      child: enabled.isEmpty
          ? const EmptyState(
              icon: Icons.print_disabled_outlined,
              title: 'No printers found',
              message: 'Windows is not reporting any printers to this agent. '
                  'Check that a printer is installed and switched on, then '
                  'choose Refresh.',
            )
          : Column(
              children: <Widget>[
                for (final printer in enabled.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Flexible(
                                    child: Text(
                                      printer.displayName,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                  if (printer.isDefault) ...<Widget>[
                                    const SizedBox(width: 8),
                                    const StatusPill(
                                      label: 'Default',
                                      tone: StatusTone.neutral,
                                      compact: true,
                                      showDot: false,
                                    ),
                                  ],
                                ],
                              ),
                              if (printer.subtitle.isNotEmpty)
                                Text(
                                  printer.subtitle,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        StatusPill.printer(printer.state, compact: true),
                      ],
                    ),
                  ),
                if (enabled.length > 6)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '+ ${enabled.length - 6} more',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RecentJobsCard extends StatelessWidget {
  const _RecentJobsCard({required this.jobs});

  final List<PrintJob> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Recent jobs',
      actions: <Widget>[
        TextButton(
          onPressed: () => context.go(AppRoutes.history),
          child: const Text('Full history'),
        ),
      ],
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: jobs.isEmpty
          ? const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No jobs yet',
              message: 'Print jobs sent from your store will appear here.',
            )
          : Column(
              children: <Widget>[
                _JobRow.header(theme),
                const Divider(height: 12),
                for (final job in jobs) _JobRow(job: job),
              ],
            ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job}) : _isHeader = false, _theme = null;

  const _JobRow.header(ThemeData theme)
      : job = null,
        _isHeader = true,
        _theme = theme;

  final PrintJob? job;
  final bool _isHeader;
  final ThemeData? _theme;

  @override
  Widget build(BuildContext context) {
    final theme = _theme ?? Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );

    if (_isHeader) {
      return Row(
        children: <Widget>[
          Expanded(flex: 3, child: Text('ORDER', style: labelStyle)),
          Expanded(flex: 4, child: Text('DOCUMENT', style: labelStyle)),
          Expanded(flex: 4, child: Text('PRINTER', style: labelStyle)),
          SizedBox(width: 110, child: Text('STATUS', style: labelStyle)),
        ],
      );
    }

    final value = job!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Text(
              value.displayReference,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              value.documentFilename ?? value.documentType.label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              value.resolvedPrinterKey ?? value.requestedPrinterKey ?? '—',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          SizedBox(
            width: 110,
            child: Align(
              alignment: Alignment.centerLeft,
              child: StatusPill.job(value.status),
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.tone,
    required this.icon,
    required this.message,
    this.action,
  });

  final StatusTone tone;
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final color = switch (tone) {
      StatusTone.success => colors.success,
      StatusTone.warning => colors.warning,
      StatusTone.danger => colors.danger,
      StatusTone.info => colors.info,
      StatusTone.neutral => colors.neutral,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm + 2),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}
