import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';
import '../../../../routing/app_shell.dart';
import '../../domain/print_job.dart';

/// Live view of the local queue, plus the actions an operator needs when
/// something goes wrong: retry, cancel, and resolving an interrupted job.
class PrintQueueScreen extends ConsumerWidget {
  const PrintQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(queueJobsProvider);
    final engineState = ref.watch(queueEngineStateProvider).value;
    final controller = ref.watch(lifecycleProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'Print queue',
          subtitle: engineState == null
              ? null
              : engineState.paused
                  ? 'Paused — nothing is being sent to printers'
                  : '${engineState.inFlight} job(s) in progress',
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => controller.syncNow(),
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('Sync now'),
            ),
            TextButton.icon(
              onPressed: () => controller.togglePause(),
              icon: Icon(
                (engineState?.paused ?? false)
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                size: 16,
              ),
              label: Text((engineState?.paused ?? false) ? 'Resume' : 'Pause'),
            ),
          ],
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: jobsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: 'The queue could not be read',
              message: '$error',
            ),
            data: (List<PrintJob> jobs) => jobs.isEmpty
                ? const EmptyState(
                    icon: Icons.done_all,
                    title: 'Nothing waiting',
                    message: 'Every job has been printed. New jobs from your '
                        'store will appear here automatically.',
                  )
                : Column(
                    children: <Widget>[
                      for (final job in jobs)
                        _JobCard(job: job, key: ValueKey<String>(job.id)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.job, super.key});

  final PrintJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final queue = ref.watch(queueRepositoryProvider);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.subtleBackground,
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(
          color: job.status.needsAttention
              ? colors.danger.withValues(alpha: 0.28)
              : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        job.displayReference,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    StatusPill.job(job.status),
                    if (job.attemptCount > 1) ...<Widget>[
                      const SizedBox(width: 6),
                      StatusPill(
                        label: 'Attempt ${job.attemptCount}/${job.maxAttempts}',
                        tone: StatusTone.warning,
                        compact: true,
                        showDot: false,
                      ),
                    ],
                  ],
                ),
              ),
              _JobActions(job: job),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: 4,
            children: <Widget>[
              _Meta(
                icon: Icons.description_outlined,
                text: job.documentFilename ?? job.documentType.label,
              ),
              _Meta(
                icon: Icons.print_outlined,
                text: job.resolvedPrinterKey ??
                    job.requestedPrinterKey ??
                    'Printer chosen automatically',
              ),
              _Meta(
                icon: Icons.aspect_ratio,
                text: job.profile.summary,
              ),
              _Meta(
                icon: Icons.schedule,
                text: 'Added ${formatRelative(job.createdAt)}',
              ),
              if (job.nextAttemptAt != null &&
                  job.nextAttemptAt!.isAfter(DateTime.now()))
                _Meta(
                  icon: Icons.replay,
                  text: 'Retrying in '
                      '${job.nextAttemptAt!.difference(DateTime.now()).inSeconds}s',
                ),
            ],
          ),
          if (job.status == PrintJobStatus.interrupted) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            _InterruptedPrompt(job: job),
          ] else if (job.errorMessage != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, size: 15, color: colors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    job.errorMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (job.status == PrintJobStatus.failed) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: () => queue.retryNow(job.id),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Try again'),
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton(
                  onPressed: () => queue.cancel(job.id),
                  child: const Text('Cancel job'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The only place an interrupted job can be resolved.
///
/// Presented as a question rather than an automatic action because the agent
/// genuinely cannot tell whether the page came out of the printer, and getting
/// it wrong means either a missing label or a duplicate one.
class _InterruptedPrompt extends ConsumerWidget {
  const _InterruptedPrompt({required this.job});

  final PrintJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = StatusColors.of(context);
    final queue = ref.watch(queueRepositoryProvider);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: colors.warning.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'The agent stopped while this job was printing. '
            'Did it come out of the printer?',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () => queue.resolveInterrupted(
                  job.id,
                  printedSuccessfully: true,
                ),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Yes — mark as printed'),
              ),
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => queue.resolveInterrupted(
                  job.id,
                  printedSuccessfully: false,
                ),
                icon: const Icon(Icons.print, size: 16),
                label: const Text('No — print it again'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _JobActions extends ConsumerWidget {
  const _JobActions({required this.job});

  final PrintJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueRepositoryProvider);
    return PopupMenuButton<String>(
      tooltip: 'Job actions',
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (String value) async {
        switch (value) {
          case 'retry':
            await queue.retryNow(job.id);
          case 'cancel':
            await queue.cancel(job.id);
          case 'details':
            if (context.mounted) await _showDetails(context, job);
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (!job.status.isTerminal || job.status == PrintJobStatus.failed)
          const PopupMenuItem<String>(value: 'retry', child: Text('Print now')),
        if (!job.status.isTerminal)
          const PopupMenuItem<String>(value: 'cancel', child: Text('Cancel')),
        const PopupMenuItem<String>(value: 'details', child: Text('Details')),
      ],
    );
  }

  Future<void> _showDetails(BuildContext context, PrintJob job) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(job.displayReference),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  DetailRow(label: 'Local job id', value: job.id),
                  DetailRow(label: 'Server job id', value: job.serverJobId),
                  DetailRow(label: 'Status', value: job.status.label),
                  DetailRow(
                    label: 'Document',
                    value: '${job.documentType.label}'
                        '${job.documentFilename == null ? '' : ' · ${job.documentFilename}'}',
                  ),
                  DetailRow(
                    label: 'Requested printer',
                    value: job.requestedPrinterKey ?? '(agent decides)',
                  ),
                  DetailRow(
                    label: 'Printed on',
                    value: job.resolvedPrinterKey ?? '—',
                  ),
                  DetailRow(label: 'Profile', value: job.profile.summary),
                  DetailRow(
                    label: 'Attempts',
                    value: '${job.attemptCount} of ${job.maxAttempts}',
                  ),
                  DetailRow(
                    label: 'Allow fallback printer',
                    value: job.allowFallback ? 'Yes' : 'No',
                  ),
                  DetailRow(
                    label: 'Created',
                    value: job.createdAt.toString().split('.').first,
                  ),
                  if (job.completedAt != null)
                    DetailRow(
                      label: 'Completed',
                      value: job.completedAt.toString().split('.').first,
                    ),
                  if (job.spoolerJobId != null)
                    DetailRow(
                      label: 'Windows spool id',
                      value: '${job.spoolerJobId}',
                    ),
                  if (job.errorCode != null)
                    DetailRow(label: 'Error code', value: job.errorCode!),
                  if (job.errorDetail != null)
                    DetailRow(label: 'Technical detail', value: job.errorDetail!),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
