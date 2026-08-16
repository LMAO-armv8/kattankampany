import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/authentication/presentation/screens/connect_store_screen.dart';
import '../features/dashboard/presentation/screens/dashboard_screen.dart';
import '../features/diagnostics/presentation/screens/diagnostics_screen.dart';
import '../features/diagnostics/presentation/screens/logs_screen.dart';
import '../features/history/presentation/screens/history_screen.dart';
import '../features/print_queue/presentation/screens/print_queue_screen.dart';
import '../features/printers/presentation/screens/printers_screen.dart';
import '../features/settings/presentation/screens/settings_screen.dart';
import 'app_shell.dart';

abstract final class AppRoutes {
  static const String setup = '/setup';
  static const String dashboard = '/';
  static const String queue = '/queue';
  static const String printers = '/printers';
  static const String history = '/history';
  static const String diagnostics = '/diagnostics';
  static const String logs = '/logs';
  static const String settings = '/settings';

  /// Order in the sidebar.
  static const List<NavigationDestinationSpec> navigation =
      <NavigationDestinationSpec>[
    NavigationDestinationSpec(
      route: dashboard,
      label: 'Dashboard',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
    ),
    NavigationDestinationSpec(
      route: queue,
      label: 'Print queue',
      icon: Icons.queue_outlined,
      selectedIcon: Icons.queue,
    ),
    NavigationDestinationSpec(
      route: printers,
      label: 'Printers',
      icon: Icons.print_outlined,
      selectedIcon: Icons.print,
    ),
    NavigationDestinationSpec(
      route: history,
      label: 'History',
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
    ),
    NavigationDestinationSpec(
      route: diagnostics,
      label: 'Diagnostics',
      icon: Icons.monitor_heart_outlined,
      selectedIcon: Icons.monitor_heart,
    ),
    NavigationDestinationSpec(
      route: settings,
      label: 'Settings',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];
}

class NavigationDestinationSpec {
  const NavigationDestinationSpec({
    required this.route,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String route;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Builds the router.
///
/// [isPaired] decides the initial location: an unpaired install goes straight
/// to "Connect your store" with no shell chrome, because none of the other
/// screens have anything to show yet.
GoRouter createRouter({
  required bool isPaired,
  required GlobalKey<NavigatorState> navigatorKey,
}) {
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: isPaired ? AppRoutes.dashboard : AppRoutes.setup,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.setup,
        name: 'setup',
        builder: (BuildContext context, GoRouterState state) =>
            const ConnectStoreScreen(),
      ),
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(location: state.uri.path, child: child),
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.dashboard,
            name: 'dashboard',
            pageBuilder: _fadePage(const DashboardScreen()),
          ),
          GoRoute(
            path: AppRoutes.queue,
            name: 'queue',
            pageBuilder: _fadePage(const PrintQueueScreen()),
          ),
          GoRoute(
            path: AppRoutes.printers,
            name: 'printers',
            pageBuilder: _fadePage(const PrintersScreen()),
          ),
          GoRoute(
            path: AppRoutes.history,
            name: 'history',
            pageBuilder: _fadePage(const HistoryScreen()),
          ),
          GoRoute(
            path: AppRoutes.diagnostics,
            name: 'diagnostics',
            pageBuilder: _fadePage(const DiagnosticsScreen()),
          ),
          GoRoute(
            path: AppRoutes.logs,
            name: 'logs',
            pageBuilder: _fadePage(const LogsScreen()),
          ),
          GoRoute(
            path: AppRoutes.settings,
            name: 'settings',
            pageBuilder: _fadePage(const SettingsScreen()),
          ),
        ],
      ),
    ],
    errorBuilder: (BuildContext context, GoRouterState state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('That screen does not exist: ${state.uri}'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.go(AppRoutes.dashboard),
              child: const Text('Back to dashboard'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Desktop navigation should not slide; a cross-fade reads as instant.
GoRouterPageBuilder _fadePage(Widget child) =>
    (BuildContext context, GoRouterState state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: child,
          transitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (
            BuildContext context,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
            Widget child,
          ) =>
              FadeTransition(opacity: animation, child: child),
        );
