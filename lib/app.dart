import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_info.dart';
import 'core/config/app_settings.dart';
import 'core/di/providers.dart';
import 'core/theme/app_theme.dart';
import 'routing/app_router.dart';

/// The application widget.
///
/// Its only jobs are theme selection and wiring the tray/lifecycle callbacks to
/// the router, so a tray click can change the visible screen.
class PrintAgentApp extends ConsumerStatefulWidget {
  const PrintAgentApp({
    required this.isPaired,
    required this.onShowWindow,
    super.key,
  });

  final bool isPaired;
  final Future<void> Function() onShowWindow;

  @override
  ConsumerState<PrintAgentApp> createState() => _PrintAgentAppState();
}

class _PrintAgentAppState extends ConsumerState<PrintAgentApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = createRouter(
      isPaired: widget.isPaired,
      navigatorKey: _navigatorKey,
    );

    final controller = ref.read(lifecycleProvider);
    // Note the block body: with an arrow body the following `..` would be
    // parsed as a cascade on the closure's result rather than on `controller`.
    controller
      ..onNavigate = (String route) {
        _router.go(route);
      }
      ..onShowWindow = widget.onShowWindow;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? AppSettings.defaults;

    return MaterialApp.router(
      title: AppInfo.productName,
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (settings.themeMode) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.system => ThemeMode.system,
      },
      // The agent runs on shop-floor machines where the display scale is often
      // turned up; clamp so the layout never breaks.
      builder: (BuildContext context, Widget? child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.9,
        maxScaleFactor: 1.3,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
