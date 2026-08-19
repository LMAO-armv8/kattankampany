import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_info.dart';
import '../core/di/providers.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/status_pill.dart';
import '../features/agent/domain/agent.dart';
import '../services/background/lifecycle_controller.dart';
import 'app_router.dart';

/// The persistent chrome: a fixed sidebar and a status header.
///
/// Both are always visible because the two questions an operator asks all day —
/// "is it connected?" and "is anything stuck?" — should never require
/// navigating anywhere.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, required this.location, super.key});

  final Widget child;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(runtimeStatusProvider).value ??
        AgentRuntimeStatus.initial;

    return Scaffold(
      body: Row(
        children: <Widget>[
          _Sidebar(location: location, status: status),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: <Widget>[
                _StatusHeader(status: status),
                const Divider(height: 1),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.location, required this.status});

  final String location;
  final AgentRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);

    return Container(
      width: AppSpacing.sidebarWidth,
      color: colors.cardBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.print_rounded,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Print Agent',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                      Text(
                        'WooCommerce',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              children: <Widget>[
                for (final item in AppRoutes.navigation)
                  _NavTile(
                    spec: item,
                    selected: _isSelected(item.route),
                    badge: _badgeFor(item.route),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  status.agentName ?? 'Not connected',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'v${AppInfo.instance.version}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isSelected(String route) {
    if (route == AppRoutes.dashboard) return location == AppRoutes.dashboard;
    return location.startsWith(route);
  }

  int? _badgeFor(String route) {
    if (route != AppRoutes.queue) return null;
    final count = status.counters.pending +
        status.counters.printing +
        status.counters.failed +
        status.counters.interrupted;
    return count > 0 ? count : null;
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.spec, required this.selected, this.badge});

  final NavigationDestinationSpec spec;
  final bool selected;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          onTap: () => context.go(spec.route),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(selected ? spec.selectedIcon : spec.icon, size: 19, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    spec.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected ? theme.colorScheme.primary : null,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends ConsumerWidget {
  const _StatusHeader({required this.status});

  final AgentRuntimeStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.watch(lifecycleProvider);
    final connection = status.effectiveConnection;

    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      color: StatusColors.of(context).cardBackground,
      child: Row(
        children: <Widget>[
          StatusPill.connection(connection),
          const SizedBox(width: AppSpacing.md),
          if (status.storeName != null)
            Flexible(
              child: Text(
                status.storeName!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          if (connection == AgentConnectionState.unauthorised)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: TextButton.icon(
                onPressed: () => context.go(AppRoutes.setup),
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Reconnect'),
              ),
            ),
          IconButton(
            tooltip: status.paused ? 'Resume printing' : 'Pause printing',
            onPressed: () => controller.togglePause(),
            icon: Icon(
              status.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            ),
          ),
          IconButton(
            tooltip: 'Sync now',
            onPressed: () => controller.syncNow(),
            icon: const Icon(Icons.sync),
          ),
          // Quitting must be reachable from the window. The close button hides
          // to the notification area so printing survives, which is right — but
          // Windows collapses tray icons into an overflow flyout by default, so
          // for an operator who cannot find the icon there was no way to stop
          // the agent at all short of Task Manager.
          IconButton(
            tooltip: 'Quit the print agent',
            onPressed: () => _confirmExit(context, controller),
            icon: const Icon(Icons.power_settings_new_rounded),
          ),
          const SizedBox(width: AppSpacing.sm),
          _LastSyncLabel(lastSyncAt: status.lastSyncAt),
        ],
      ),
    );
  }
}

class _LastSyncLabel extends StatelessWidget {
  const _LastSyncLabel({this.lastSyncAt});

  final DateTime? lastSyncAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      lastSyncAt == null
          ? 'Not synchronised yet'
          : 'Synced ${formatRelative(lastSyncAt!)}',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// "2 seconds ago" style formatting used across the UI.
String formatRelative(DateTime timestamp) {
  final delta = DateTime.now().difference(timestamp);
  if (delta.inSeconds < 2) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds} seconds ago';
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes} minute${delta.inMinutes == 1 ? '' : 's'} ago';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
  }
  return '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago';
}

/// Confirms before quitting, because quitting stops printing.
///
/// The queue survives — anything already claimed is handed back to the store on
/// a clean shutdown and re-offered — but orders placed while the agent is off
/// will simply wait, and an operator who quits by accident should be told that
/// rather than discovering it from a customer.
Future<void> _confirmExit(
  BuildContext context,
  LifecycleController controller,
) async {
  final quit = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Quit the print agent?'),
      content: const Text(
        'Nothing will print until you start it again. Orders keep queueing in '
        'your store and will print when the agent next runs.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep running'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Quit'),
        ),
      ],
    ),
  );

  if (quit ?? false) await controller.onExitRequested?.call();
}
