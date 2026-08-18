import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/app_settings.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/logging/log_level.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../routing/app_router.dart';
import '../../../../services/updater/update_service.dart';
import '../../../printers/domain/printer_device.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final settings = settingsAsync.value ?? AppSettings.defaults;
    final repository = ref.watch(settingsRepositoryProvider);
    final printers = ref.watch(printersProvider).value ?? <PrinterDevice>[];

    Future<void> save(AppSettings next) => repository.save(next);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'General',
          child: Column(
            children: <Widget>[
              _SwitchRow(
                label: 'Start Print Agent with Windows',
                description: 'The agent signs in with you and starts printing '
                    'without anyone having to launch it.',
                value: settings.startWithWindows,
                onChanged: (bool value) =>
                    save(settings.copyWith(startWithWindows: value)),
              ),
              _SwitchRow(
                label: 'Start minimised to the notification area',
                description: 'No window appears at sign-in.',
                value: settings.startMinimized,
                onChanged: (bool value) =>
                    save(settings.copyWith(startMinimized: value)),
              ),
              _SwitchRow(
                label: 'Minimise to the notification area',
                description: 'Minimising hides the window instead of leaving it '
                    'on the taskbar.',
                value: settings.minimizeToTray,
                onChanged: (bool value) =>
                    save(settings.copyWith(minimizeToTray: value)),
              ),
              _SwitchRow(
                label: 'Keep running when the window is closed',
                description: 'Recommended. With this off, closing the window '
                    'stops printing entirely.',
                value: settings.closeToTray,
                onChanged: (bool value) =>
                    save(settings.copyWith(closeToTray: value)),
              ),
              _SwitchRow(
                label: 'Keep this computer awake',
                description: 'Recommended. Windows sleeps an idle computer '
                    'within minutes, which takes the agent offline until '
                    'somebody touches the keyboard. Turn this off on a laptop '
                    'that should sleep on battery.',
                value: settings.keepComputerAwake,
                onChanged: (bool value) =>
                    save(settings.copyWith(keepComputerAwake: value)),
              ),
              _DropdownRow<AppThemeMode>(
                label: 'Appearance',
                value: settings.themeMode,
                items: <DropdownMenuItem<AppThemeMode>>[
                  for (final mode in AppThemeMode.values)
                    DropdownMenuItem<AppThemeMode>(
                      value: mode,
                      child: Text(mode.label),
                    ),
                ],
                onChanged: (AppThemeMode? value) => value == null
                    ? null
                    : save(settings.copyWith(themeMode: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Connection',
          subtitle: 'The agent widens the interval automatically while the '
              'queue is empty, so a fast setting does not mean constant traffic.',
          child: Column(
            children: <Widget>[
              _DropdownRow<int>(
                label: 'Check for new jobs every',
                value: AppSettings.syncIntervalPresets
                        .contains(settings.syncIntervalSeconds)
                    ? settings.syncIntervalSeconds
                    : AppSettings.syncIntervalPresets.first,
                items: <DropdownMenuItem<int>>[
                  for (final seconds in AppSettings.syncIntervalPresets)
                    DropdownMenuItem<int>(
                      value: seconds,
                      child: Text('$seconds seconds'),
                    ),
                ],
                onChanged: (int? value) => value == null
                    ? null
                    : save(settings.copyWith(syncIntervalSeconds: value)),
              ),
              _SwitchRow(
                label: 'Slow down while there is nothing to print',
                description: 'Reduces network traffic on an idle agent.',
                value: settings.idleBackoffEnabled,
                onChanged: (bool value) =>
                    save(settings.copyWith(idleBackoffEnabled: value)),
              ),
              _NumberRow(
                label: 'Connection timeout',
                suffix: 'seconds',
                value: settings.connectionTimeoutSeconds,
                min: 5,
                max: 300,
                onChanged: (int value) =>
                    save(settings.copyWith(connectionTimeoutSeconds: value)),
              ),
              _NumberRow(
                label: 'Heartbeat interval',
                suffix: 'seconds',
                value: settings.heartbeatIntervalSeconds,
                min: 15,
                max: 3600,
                onChanged: (int value) =>
                    save(settings.copyWith(heartbeatIntervalSeconds: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Printing',
          child: Column(
            children: <Widget>[
              _NumberRow(
                label: 'Attempts per job',
                suffix: 'attempts',
                value: settings.retryMaxAttempts,
                min: 1,
                max: 20,
                onChanged: (int value) =>
                    save(settings.copyWith(retryMaxAttempts: value)),
              ),
              _RetryDelaysRow(
                settings: settings,
                onChanged: (List<int> delays) =>
                    save(settings.copyWith(retryDelaysSeconds: delays)),
              ),
              _PrinterPickerRow(
                label: 'Default printer',
                description: 'Used when a job does not name a printer.',
                printers: printers,
                value: settings.defaultPrinterKey,
                // Freezed's copyWith distinguishes "not supplied" from an
                // explicit null, so clearing the selection really clears it.
                onChanged: (String? value) =>
                    save(settings.copyWith(defaultPrinterKey: value)),
              ),
              _PrinterPickerRow(
                label: 'Fallback printer',
                description: 'Only ever used when the job itself allows a '
                    'fallback. The agent never substitutes a printer silently.',
                printers: printers,
                value: settings.fallbackPrinterKey,
                onChanged: (String? value) =>
                    save(settings.copyWith(fallbackPrinterKey: value)),
              ),
              _DropdownRow<JobRecoveryBehaviour>(
                label: 'After an unexpected shutdown',
                description: settings.recoveryBehaviour.description,
                value: settings.recoveryBehaviour,
                items: <DropdownMenuItem<JobRecoveryBehaviour>>[
                  for (final behaviour in JobRecoveryBehaviour.values)
                    DropdownMenuItem<JobRecoveryBehaviour>(
                      value: behaviour,
                      child: Text(behaviour.label),
                    ),
                ],
                onChanged: (JobRecoveryBehaviour? value) => value == null
                    ? null
                    : save(settings.copyWith(recoveryBehaviour: value)),
              ),
              _NumberRow(
                label: 'Maximum document size',
                suffix: 'MB',
                value: settings.maxDocumentSizeBytes ~/ (1024 * 1024),
                min: 1,
                max: 512,
                onChanged: (int value) => save(
                  settings.copyWith(maxDocumentSizeBytes: value * 1024 * 1024),
                ),
              ),
              _NumberRow(
                label: 'Printer status check interval',
                suffix: 'seconds',
                value: settings.printerStatusPollSeconds,
                min: 5,
                max: 3600,
                onChanged: (int value) =>
                    save(settings.copyWith(printerStatusPollSeconds: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          title: 'Logs and history',
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => context.go(AppRoutes.logs),
              icon: const Icon(Icons.article_outlined, size: 16),
              label: const Text('View logs'),
            ),
          ],
          child: Column(
            children: <Widget>[
              _DropdownRow<LogLevel>(
                label: 'Log level',
                description: 'Debug and trace produce large logs; use them only '
                    'while investigating a problem.',
                value: settings.logLevel,
                items: <DropdownMenuItem<LogLevel>>[
                  for (final level in LogLevel.values)
                    DropdownMenuItem<LogLevel>(
                      value: level,
                      child: Text(level.label),
                    ),
                ],
                onChanged: (LogLevel? value) =>
                    value == null ? null : save(settings.copyWith(logLevel: value)),
              ),
              _NumberRow(
                label: 'Maximum log file size',
                suffix: 'MB',
                value: settings.maxLogFileSizeBytes ~/ (1024 * 1024),
                min: 1,
                max: 128,
                onChanged: (int value) => save(
                  settings.copyWith(maxLogFileSizeBytes: value * 1024 * 1024),
                ),
              ),
              _NumberRow(
                label: 'Log files kept',
                suffix: 'files',
                value: settings.maxLogFiles,
                min: 1,
                max: 50,
                onChanged: (int value) =>
                    save(settings.copyWith(maxLogFiles: value)),
              ),
              _NumberRow(
                label: 'Keep job history for',
                suffix: 'days',
                value: settings.historyRetentionDays,
                min: 1,
                max: 3650,
                onChanged: (int value) =>
                    save(settings.copyWith(historyRetentionDays: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const _UpdatesCard(),
        const SizedBox(height: AppSpacing.md),
        const _DangerZone(),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _UpdatesCard extends ConsumerStatefulWidget {
  const _UpdatesCard();

  @override
  ConsumerState<_UpdatesCard> createState() => _UpdatesCardState();
}

class _UpdatesCardState extends ConsumerState<_UpdatesCard> {
  UpdateCheckResult? _lastResult;
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final updater = ref.watch(updateServiceProvider);
    final settings = ref.watch(settingsProvider).value ?? AppSettings.defaults;
    final repository = ref.watch(settingsRepositoryProvider);

    return SectionCard(
      title: 'Updates',
      subtitle: updater.sourceDescription,
      child: Column(
        children: <Widget>[
          _SwitchRow(
            label: 'Install updates automatically',
            description: updater.isConfigured
                ? 'Updates are applied when the queue is idle.'
                : 'No update source is configured in this build.',
            value: settings.automaticUpdates && updater.isConfigured,
            onChanged: updater.isConfigured
                ? (bool value) =>
                    repository.save(settings.copyWith(automaticUpdates: value))
                : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _checking
                  ? null
                  : () async {
                      setState(() => _checking = true);
                      final result = await updater.checkForUpdates();
                      if (!mounted) return;
                      setState(() {
                        _checking = false;
                        _lastResult = result;
                      });
                    },
              icon: _checking
                  ? const SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt, size: 16),
              label: const Text('Check for updates'),
            ),
          ),
          if (_lastResult != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _lastResult!.message ??
                    (_lastResult!.hasUpdate
                        ? 'Version ${_lastResult!.info?.version} is available.'
                        : 'You are running the latest version.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          DetailRow(label: 'Installed version', value: updater.currentVersion),
        ],
      ),
    );
  }
}

class _DangerZone extends ConsumerWidget {
  const _DangerZone();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = StatusColors.of(context);
    final session = ref.watch(agentSessionProvider);

    return SectionCard(
      title: 'Disconnect',
      subtitle: 'Removes this computer\'s credentials. Job history is kept.',
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.danger,
            side: BorderSide(color: colors.danger.withValues(alpha: 0.5)),
          ),
          onPressed: !session.isPaired
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (BuildContext context) => AlertDialog(
                      title: const Text('Disconnect from store?'),
                      content: const Text(
                        'This computer will stop receiving print jobs until it '
                        'is paired again. Stored credentials are deleted; job '
                        'history is kept.',
                      ),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await ref.read(lifecycleProvider).stop();
                  await session.unpair();
                  if (context.mounted) context.go(AppRoutes.setup);
                },
          icon: const Icon(Icons.link_off, size: 16),
          label: const Text('Disconnect this computer'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row widgets
// ---------------------------------------------------------------------------

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: theme.textTheme.bodyMedium),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 24),
                    child: Text(
                      description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.description,
    super.key,
  });

  final String label;
  final String? description;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: theme.textTheme.bodyMedium),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 24),
                    child: Text(
                      description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<T>(
              initialValue: value,
              isDense: true,
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    this.suffix,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          SizedBox(
            width: 240,
            child: Row(
              children: <Widget>[
                IconButton(
                  onPressed:
                      value <= min ? null : () => onChanged(value - _step()),
                  icon: const Icon(Icons.remove, size: 16),
                ),
                Expanded(
                  child: Text(
                    '$value${suffix == null ? '' : ' $suffix'}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed:
                      value >= max ? null : () => onChanged(value + _step()),
                  icon: const Icon(Icons.add, size: 16),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _step() {
    if (max - min > 600) return 30;
    if (max - min > 100) return 5;
    return 1;
  }
}

class _RetryDelaysRow extends StatelessWidget {
  const _RetryDelaysRow({required this.settings, required this.onChanged});

  final AppSettings settings;
  final ValueChanged<List<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Retry delays', style: theme.textTheme.bodyMedium),
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 24),
                  child: Text(
                    'Waiting time before each retry: '
                    '${settings.retryPolicy.summary}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String>(
              initialValue: _presetKey(settings.retryDelaysSeconds),
              isDense: true,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: 'fast',
                  child: Text('Fast — 5s, 15s, 60s'),
                ),
                DropdownMenuItem<String>(
                  value: 'standard',
                  child: Text('Standard — 10s, 30s, 2m'),
                ),
                DropdownMenuItem<String>(
                  value: 'patient',
                  child: Text('Patient — 30s, 2m, 10m'),
                ),
              ],
              onChanged: (String? value) {
                switch (value) {
                  case 'fast':
                    onChanged(const <int>[5, 15, 60]);
                  case 'patient':
                    onChanged(const <int>[30, 120, 600]);
                  case _:
                    onChanged(const <int>[10, 30, 120]);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _presetKey(List<int> delays) {
    if (_matches(delays, const <int>[5, 15, 60])) return 'fast';
    if (_matches(delays, const <int>[30, 120, 600])) return 'patient';
    return 'standard';
  }

  static bool _matches(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _PrinterPickerRow extends StatelessWidget {
  const _PrinterPickerRow({
    required this.label,
    required this.printers,
    required this.value,
    required this.onChanged,
    this.description,
  });

  final String label;
  final String? description;
  final List<PrinterDevice> printers;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = printers.any((PrinterDevice p) => p.printerKey == value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: theme.textTheme.bodyMedium),
                if (description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 24),
                    child: Text(
                      description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String?>(
              initialValue: known ? value : null,
              isDense: true,
              decoration: const InputDecoration(hintText: 'Not set'),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(child: Text('Not set')),
                for (final printer in printers)
                  DropdownMenuItem<String?>(
                    value: printer.printerKey,
                    child: Text(
                      printer.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
