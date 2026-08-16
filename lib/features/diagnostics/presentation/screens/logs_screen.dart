import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/config/app_info.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/logging/file_log_sink.dart';
import '../../../../core/logging/log_level.dart';
import '../../../../core/logging/log_record.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';

/// The in-app log viewer.
///
/// The durable log is the rotating file on disk; this reads the bounded SQLite
/// mirror, which is what makes filtering and searching fast. Everything shown
/// here has already been through the redaction filter — there is no path by
/// which a token reaches this screen.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final TextEditingController _search = TextEditingController();
  bool _exporting = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final logger = ref.read(loggerProvider);
      final fileSink = logger.sinkOfType<FileLogSink>();
      final contents = fileSink == null
          ? await _renderFromDatabase()
          : await fileSink.readAll();

      final stamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
      final location = await getSaveLocation(
        suggestedName: 'print-agent-logs-$stamp.txt',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'Text', extensions: <String>['txt', 'log']),
        ],
      );
      if (location == null) return;

      await File(location.path).writeAsString(
        '${_exportHeader()}\n$contents',
        flush: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Logs exported to ${location.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Logs could not be exported: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _exportHeader() {
    final info = AppInfo.instance;
    return <String>[
      '=== ${AppInfo.productName} log export ===',
      'Exported : ${DateTime.now().toIso8601String()}',
      'Version  : ${info.fullVersion}',
      'Machine  : ${info.machineName}',
      'OS       : ${info.osDescription}',
      'Note     : authentication tokens are redacted before logging.',
      '=' * 48,
    ].join('\n');
  }

  Future<String> _renderFromDatabase() async {
    final records = await ref.read(logDaoProvider).query(
          minimumLevel: LogLevel.trace,
          limit: 5000,
        );
    return records.reversed
        .map((AppLogRecord record) => record.toLogLine())
        .join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(logFilterProvider);
    final recordsAsync = ref.watch(logRecordsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'Logs',
          subtitle: 'Connection, authentication, job and printer events. '
              'Tokens are never written to the log.',
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => ref.invalidate(logRecordsProvider),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
            TextButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export logs'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<LogLevel>(
                      initialValue: filter.minimumLevel,
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Level'),
                      items: <DropdownMenuItem<LogLevel>>[
                        for (final level in LogLevel.values)
                          if (level != LogLevel.off)
                            DropdownMenuItem<LogLevel>(
                              value: level,
                              child: Text(level.label),
                            ),
                      ],
                      onChanged: (LogLevel? value) => ref
                          .read(logFilterProvider.notifier)
                          .update((LogFilter f) =>
                              f.copyWith(minimumLevel: value),),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String?>(
                      initialValue: filter.category,
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: <DropdownMenuItem<String?>>[
                        const DropdownMenuItem<String?>(
                          child: Text('All categories'),
                        ),
                        for (final category in LogCategory.all)
                          DropdownMenuItem<String?>(
                            value: category,
                            child: Text(category),
                          ),
                      ],
                      onChanged: (String? value) => ref
                          .read(logFilterProvider.notifier)
                          .update((LogFilter f) => value == null
                              ? f.copyWith(clearCategory: true)
                              : f.copyWith(category: value),),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        hintText: 'Search messages',
                        prefixIcon: Icon(Icons.search, size: 18),
                      ),
                      onSubmitted: (String value) => ref
                          .read(logFilterProvider.notifier)
                          .update((LogFilter f) => f.copyWith(search: value)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 520,
                child: recordsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (Object error, StackTrace stack) => EmptyState(
                    icon: Icons.error_outline,
                    title: 'Logs could not be read',
                    message: '$error',
                  ),
                  data: (List<AppLogRecord> records) => records.isEmpty
                      ? const EmptyState(
                          icon: Icons.article_outlined,
                          title: 'Nothing matches',
                          message: 'Try a lower level or a different category.',
                        )
                      : _LogList(records: records),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.records});

  final List<AppLogRecord> records;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final formatter = DateFormat('HH:mm:ss.SSS');

    return Container(
      decoration: BoxDecoration(
        color: colors.subtleBackground,
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: colors.border),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: records.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (BuildContext context, int index) {
          final record = records[index];
          final color = switch (record.level) {
            LogLevel.error || LogLevel.critical => colors.danger,
            LogLevel.warning => colors.warning,
            LogLevel.info => colors.info,
            _ => colors.neutral,
          };
          return InkWell(
            onTap: () => Clipboard.setData(
              ClipboardData(text: record.toLogLine()),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: 6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 86,
                    child: Text(
                      formatter.format(record.timestamp),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      record.level.label,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 88,
                    child: Text(
                      record.category,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          record.message,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        if (record.context.isNotEmpty)
                          Text(
                            record.contextJson,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        if (record.error != null)
                          Text(
                            record.error!,
                            style: TextStyle(fontSize: 11.5, color: color),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
