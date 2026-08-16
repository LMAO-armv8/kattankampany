import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/storage/dao/print_history_dao.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';

/// Archived jobs.
///
/// Live jobs live in the queue table; once reported and older than the
/// retention window they are condensed into history, which is what keeps the
/// queue fast on an agent that has been running for a year.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(historyProvider);
    final filter = ref.watch(historyFilterProvider);
    final formatter = DateFormat('d MMM y, HH:mm:ss');

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'History',
          subtitle: 'Completed and failed jobs, oldest pruned automatically.',
          actions: <Widget>[
            SizedBox(
              width: 220,
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Search order or job id',
                  prefixIcon: Icon(Icons.search, size: 18),
                ),
                onSubmitted: (String value) => ref
                    .read(historyFilterProvider.notifier)
                    .update((HistoryFilter f) => f.copyWith(search: value)),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _StatusFilter(current: filter.status),
          ],
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: entriesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (Object error, StackTrace stack) => EmptyState(
              icon: Icons.error_outline,
              title: 'History could not be read',
              message: '$error',
            ),
            data: (List<PrintHistoryEntry> entries) => entries.isEmpty
                ? const EmptyState(
                    icon: Icons.history,
                    title: 'No history yet',
                    message: 'Jobs move here once they have finished and the '
                        'result has been reported to your store.',
                  )
                : _HistoryTable(entries: entries, formatter: formatter),
          ),
        ),
      ],
    );
  }
}

class _StatusFilter extends ConsumerWidget {
  const _StatusFilter({this.current});

  final String? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        width: 160,
        child: DropdownButtonFormField<String?>(
          initialValue: current,
          isDense: true,
          decoration: const InputDecoration(hintText: 'All statuses'),
          items: const <DropdownMenuItem<String?>>[
            DropdownMenuItem<String?>(child: Text('All statuses')),
            DropdownMenuItem<String?>(
              value: 'completed',
              child: Text('Completed'),
            ),
            DropdownMenuItem<String?>(value: 'failed', child: Text('Failed')),
            DropdownMenuItem<String?>(
              value: 'cancelled',
              child: Text('Cancelled'),
            ),
          ],
          onChanged: (String? value) => ref
              .read(historyFilterProvider.notifier)
              .update(
                (HistoryFilter f) => value == null
                    ? f.copyWith(clearStatus: true)
                    : f.copyWith(status: value),
              ),
        ),
      );
}

class _HistoryTable extends StatelessWidget {
  const _HistoryTable({required this.entries, required this.formatter});

  final List<PrintHistoryEntry> entries;
  final DateFormat formatter;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 880),
        child: DataTable(
          headingRowHeight: 38,
          dataRowMinHeight: 40,
          dataRowMaxHeight: 52,
          columns: const <DataColumn>[
            DataColumn(label: Text('ORDER')),
            DataColumn(label: Text('DOCUMENT')),
            DataColumn(label: Text('PRINTER')),
            DataColumn(label: Text('ATTEMPTS')),
            DataColumn(label: Text('FINISHED')),
            DataColumn(label: Text('STATUS')),
          ],
          rows: <DataRow>[
            for (final entry in entries)
              DataRow(
                cells: <DataCell>[
                  DataCell(
                    Text(
                      entry.orderReference ?? entry.serverJobId ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  DataCell(Text(entry.documentType ?? '—')),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        entry.printerKey ?? '—',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  DataCell(Text('${entry.attemptCount}')),
                  DataCell(
                    Text(
                      entry.completedAt == null
                          ? '—'
                          : formatter.format(entry.completedAt!),
                    ),
                  ),
                  DataCell(
                    Tooltip(
                      message: entry.errorMessage ?? '',
                      child: StatusPill(
                        label: _label(entry.status),
                        tone: _tone(entry.status),
                        compact: true,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _label(String status) => switch (status) {
        'completed' => 'Completed',
        'failed' => 'Failed',
        'cancelled' => 'Cancelled',
        _ => status,
      };

  static StatusTone _tone(String status) => switch (status) {
        'completed' => StatusTone.success,
        'failed' => StatusTone.danger,
        _ => StatusTone.neutral,
      };
}
