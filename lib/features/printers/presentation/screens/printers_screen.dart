import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/section_card.dart';
import '../../../../core/widgets/status_pill.dart';
import '../../../../features/printing/domain/print_request.dart';
import '../../../../routing/app_shell.dart';
import '../../domain/network_printer.dart';
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

  /// Adds a printer addressed directly over TCP, without Windows.
  ///
  /// This is the escape hatch for the two cases the spooler cannot serve: a
  /// machine whose Print Spooler is stopped or disabled, and a network printer
  /// nobody has installed a driver for.
  Future<void> _addNetworkPrinter() async {
    final printer = await showDialog<NetworkPrinter>(
      context: context,
      builder: (BuildContext context) => const _AddNetworkPrinterDialog(),
    );

    if (printer == null || !mounted) return;

    await ref.read(networkPrinterStoreProvider).save(printer);
    await ref.read(lifecycleProvider).refreshPrinters();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${printer.name} at ${printer.host}:${printer.port}'),
      ),
    );
  }

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
              onPressed: _addNetworkPrinter,
              icon: const Icon(Icons.lan_outlined, size: 16),
              label: const Text('Add network printer'),
            ),
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
                      // Naming the spooler matters. Windows reporting nothing
                      // at all usually means the Print Spooler service is
                      // stopped or disabled — common on hardened and corporate
                      // machines — and no amount of re-checking the cable will
                      // fix that. The network option below needs neither.
                      ? 'Windows is not reporting any printers to this agent. '
                          'USB and Bluetooth printers appear here once they are '
                          'installed in Windows and the Print Spooler service '
                          'is running.\n\n'
                          'If Windows shows no printers either, check that the '
                          'Print Spooler service is running. A network printer '
                          'can be added directly instead — that path does not '
                          'use Windows printing at all.'
                      : 'This build uses the Windows spooler for local printers. '
                          'You can still add a network printer, which the agent '
                          'talks to directly.',
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

/// Collects the address of a printer the agent will speak to directly.
///
/// Deliberately asks for an address rather than offering a scan. Sweeping a
/// subnet for open port 9100 is slow, looks like a port scan to any competent
/// network monitor, and on a corporate network is a good way to get the agent
/// blocked. An operator reading the address off the printer's own configuration
/// page is faster and less alarming.
class _AddNetworkPrinterDialog extends StatefulWidget {
  const _AddNetworkPrinterDialog();

  @override
  State<_AddNetworkPrinterDialog> createState() =>
      _AddNetworkPrinterDialogState();
}

class _AddNetworkPrinterDialogState extends State<_AddNetworkPrinterDialog> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _name = TextEditingController();

  String? _error;
  bool _testing = false;
  String? _testResult;
  bool _testPassed = false;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  NetworkPrinter? _parsed() => NetworkPrinter.parse(
        _address.text,
        name: _name.text.isEmpty ? null : _name.text,
      );

  /// Connects before saving. Discovering the address is wrong at save time is
  /// far kinder than discovering it when the first real order fails to print.
  Future<void> _test() async {
    final printer = _parsed();

    if (printer == null || !printer.isValid) {
      setState(() => _error = 'Enter an address such as 192.168.1.50 or 192.168.1.50:9100');
      return;
    }

    setState(() {
      _testing = true;
      _error = null;
      _testResult = null;
    });

    String message;
    var passed = false;

    try {
      final socket = await Socket.connect(
        printer.host,
        printer.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      message = 'Connected to ${printer.host}:${printer.port}.';
      passed = true;
    } on SocketException catch (e) {
      message = 'No answer from ${printer.host}:${printer.port}. ${e.message}';
    } catch (e) {
      message = 'Could not reach ${printer.host}:${printer.port}. $e';
    }

    if (!mounted) return;

    setState(() {
      _testing = false;
      _testResult = message;
      _testPassed = passed;
    });
  }

  void _save() {
    final printer = _parsed();

    if (printer == null || !printer.isValid) {
      setState(() => _error = 'Enter an address such as 192.168.1.50 or 192.168.1.50:9100');
      return;
    }

    Navigator.of(context).pop(printer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Add a network printer'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'The agent will send documents straight to this address over the '
              'network. It does not use Windows printing, so this works even '
              'when the Print Spooler is disabled.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.50  or  192.168.1.50:9100',
                helperText: 'Port 9100 is assumed if you do not give one.',
              ),
              onChanged: (_) => setState(() {
                _error = null;
                _testResult = null;
              }),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'Warehouse label printer',
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (_testResult != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    _testPassed ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: _testPassed
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_testResult!, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'The document is sent exactly as produced, with no driver to '
              'translate it. Make sure your print rules send this printer a '
              'format it understands.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7)),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? 'Testing…' : 'Test connection'),
        ),
        FilledButton(onPressed: _save, child: const Text('Add')),
      ],
    );
  }
}
