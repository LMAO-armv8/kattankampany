import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';
import '../../../../features/printing/domain/print_request.dart';
import '../../../../routing/app_shell.dart';
import '../../domain/print_profile.dart';
import '../../domain/printer_device.dart';
import '../../domain/printer_status.dart';

/// Printer inventory, per-printer configuration and test printing.
///
/// Test Print is the single most useful thing on this screen during an
/// installation: it proves the agent can reach the device before any real order
/// depends on it, and it needs no server involvement at all.
class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});

  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen> {
  /// Null means "all transports".
  PrinterConnectionType? _filter;

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printersProvider).value ?? <PrinterDevice>[];
    final manager = ref.watch(printerManagerProvider);

    // Counts come from the full inventory so a filter chip never reads zero
    // just because another filter is active.
    final counts = <PrinterConnectionType, int>{};
    for (final printer in printers) {
      counts.update(
        printer.connectionType,
        (int value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    final visible = _filter == null
        ? printers
        : printers
            .where((PrinterDevice p) => p.connectionType == _filter)
            .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        SectionCard(
          title: 'Printers',
          subtitle: manager.lastDiscoveryAt == null
              ? 'Discovering printers…'
              : 'Discovered ${formatRelative(manager.lastDiscoveryAt!)}'
                  '${manager.windowsDefaultKey == null ? '' : ' · Windows default: ${manager.windowsDefaultKey}'}',
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => ref.read(lifecycleProvider).refreshPrinters(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
          child: printers.isEmpty
              ? EmptyState(
                  icon: Icons.print_disabled_outlined,
                  title: manager.isSupported
                      ? 'No printers found'
                      : 'Printing is unavailable on this platform',
                  message: manager.isSupported
                      ? 'Windows is not reporting any printers to this agent. '
                          'USB, Bluetooth and network printers all appear here '
                          'once they are installed in Windows. Check that the '
                          'printer is installed and switched on, then choose '
                          'Refresh.'
                      : 'This build prints through the Windows spooler. Run the '
                          'agent on Windows to discover printers.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _ConnectionFilterBar(
                      counts: counts,
                      total: printers.length,
                      selected: _filter,
                      onChanged: (PrinterConnectionType? value) =>
                          setState(() => _filter = value),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.lg,
                        ),
                        child: Text(
                          'No ${_filter!.label.toLowerCase()} printers are '
                          'installed on this computer.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color:
                                    Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      )
                    else
                      for (final printer in visible)
                        _PrinterTile(
                          printer: printer,
                          key: ValueKey<String>(printer.printerKey),
                        ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.md),
        const _ProfilesCard(),
      ],
    );
  }
}

/// Transport filter across the discovered inventory.
///
/// Only transports that are actually present get a chip — a shop floor PC with
/// two USB printers should not be shown four empty categories.
class _ConnectionFilterBar extends StatelessWidget {
  const _ConnectionFilterBar({
    required this.counts,
    required this.total,
    required this.selected,
    required this.onChanged,
  });

  final Map<PrinterConnectionType, int> counts;
  final int total;
  final PrinterConnectionType? selected;
  final ValueChanged<PrinterConnectionType?> onChanged;

  /// Presentation order: the transports an operator is most likely to be
  /// looking for come first.
  static const List<PrinterConnectionType> _order = <PrinterConnectionType>[
    PrinterConnectionType.usb,
    PrinterConnectionType.network,
    PrinterConnectionType.bluetooth,
    PrinterConnectionType.serial,
    PrinterConnectionType.parallel,
    PrinterConnectionType.virtual,
    PrinterConnectionType.unknown,
  ];

  static IconData iconFor(PrinterConnectionType type) => switch (type) {
        PrinterConnectionType.usb => Icons.usb,
        PrinterConnectionType.network => Icons.wifi,
        PrinterConnectionType.bluetooth => Icons.bluetooth,
        PrinterConnectionType.serial => Icons.settings_input_component,
        PrinterConnectionType.parallel => Icons.cable,
        PrinterConnectionType.virtual => Icons.picture_as_pdf_outlined,
        PrinterConnectionType.unknown => Icons.help_outline,
      };

  @override
  Widget build(BuildContext context) {
    final present =
        _order.where((PrinterConnectionType t) => (counts[t] ?? 0) > 0);

    // A single transport means the filter cannot narrow anything.
    if (present.length < 2) return const SizedBox.shrink();

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: <Widget>[
        ChoiceChip(
          selected: selected == null,
          onSelected: (_) => onChanged(null),
          avatar: const Icon(Icons.print_outlined, size: 15),
          label: Text('All ($total)'),
        ),
        for (final type in present)
          ChoiceChip(
            selected: selected == type,
            onSelected: (_) => onChanged(type),
            avatar: Icon(iconFor(type), size: 15),
            label: Text('${type.label} (${counts[type]})'),
          ),
      ],
    );
  }
}

class _PrinterTile extends ConsumerStatefulWidget {
  const _PrinterTile({required this.printer, super.key});

  final PrinterDevice printer;

  @override
  ConsumerState<_PrinterTile> createState() => _PrinterTileState();
}

class _PrinterTileState extends ConsumerState<_PrinterTile> {
  bool _testing = false;
  PrintResult? _lastResult;

  Future<void> _testPrint() async {
    setState(() {
      _testing = true;
      _lastResult = null;
    });
    final manager = ref.read(printerManagerProvider);
    final result = await manager.testPrint(
      widget.printer.printerKey,
      profileId: widget.printer.defaultProfileId,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _lastResult = result;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'Test page sent to ${widget.printer.displayName}'
              : result.errorMessage ?? 'The test page could not be printed.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final printer = widget.printer;
    final profiles = ref.watch(printProfilesProvider);
    final manager = ref.watch(printerManagerProvider);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.subtleBackground,
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
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
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        StatusPill.printer(printer.state, compact: true),
                        if (printer.isDefault) ...<Widget>[
                          const SizedBox(width: 6),
                          const StatusPill(
                            label: 'Windows default',
                            tone: StatusTone.neutral,
                            compact: true,
                            showDot: false,
                          ),
                        ],
                      ],
                    ),
                    if (printer.subtitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        printer.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: printer.isEnabled,
                onChanged: (bool value) => manager.setEnabled(
                  printer.printerKey,
                  enabled: value,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _Meta(
                icon: _ConnectionFilterBar.iconFor(printer.connectionType),
                text: printer.connectionType.label,
              ),
              if (printer.lastStatusAt != null)
                _Meta(
                  icon: Icons.schedule,
                  text: 'Checked ${formatRelative(printer.lastStatusAt!)}',
                ),
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String?>(
                  initialValue: printer.defaultProfileId,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Default print profile',
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      child: Text('Use the job\'s own settings'),
                    ),
                    for (final profile in profiles)
                      DropdownMenuItem<String?>(
                        value: profile.id,
                        child: Text(profile.name),
                      ),
                  ],
                  onChanged: (String? value) =>
                      manager.setDefaultProfile(printer.printerKey, value),
                ),
              ),
              OutlinedButton.icon(
                onPressed: (_testing || !printer.isEnabled) ? null : _testPrint,
                icon: _testing
                    ? const SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.description_outlined, size: 16),
                label: const Text('Test print'),
              ),
            ],
          ),
          if (!printer.state.isHealthy) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              printer.state.problemMessage,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
          ],
          if (_lastResult != null && !_lastResult!.success) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _lastResult!.errorDetail ?? _lastResult!.errorMessage ?? '',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfilesCard extends ConsumerWidget {
  const _ProfilesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(printProfilesProvider);
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Print profiles',
      subtitle: 'Generic page setups. A job can name one, or a printer can use '
          'one by default.',
      child: Column(
        children: <Widget>[
          for (final profile in profiles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: Text(
                      profile.name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      profile.summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      profile.strategy == PrintStrategyType.auto
                          ? 'Automatic'
                          : profile.strategy.name,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (profile.isBuiltin)
                    const StatusPill(
                      label: 'Built-in',
                      tone: StatusTone.neutral,
                      compact: true,
                      showDot: false,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
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
