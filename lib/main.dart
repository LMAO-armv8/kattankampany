import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'core/config/app_info.dart';
import 'core/di/service_locator.dart';
import 'core/logging/log_level.dart';
import 'core/platform/single_instance.dart';
import 'services/background/lifecycle_controller.dart';
import 'services/background/tray_service.dart';

/// Passed by the Windows `Run` registry entry so a sign-in launch comes up in
/// the notification area instead of stealing focus.
const String kStartupFlag = '--startup';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---- Single instance --------------------------------------------------
  // Two agents on one machine would both claim jobs from the same store and
  // send them to the same printer. That is precisely the duplicate-print
  // scenario the whole design exists to avoid, so a second instance simply
  // exits.
  final guard = SingleInstanceGuard();
  if (!guard.acquire()) {
    debugPrint('${AppInfo.productName} is already running.');
    exit(0);
  }

  final startMinimisedFromArgs = arguments.contains(kStartupFlag);

  // ---- Window -----------------------------------------------------------
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1180, 800),
    minimumSize: Size(940, 640),
    center: true,
    title: AppInfo.productName,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.normal,
  );

  // ---- Application ------------------------------------------------------
  BootstrapResult result;
  try {
    result = await bootstrap();
  } catch (error, stackTrace) {
    // Bootstrap failing means no logger and no database. Show the operator
    // something actionable rather than a blank window.
    runApp(_FatalErrorApp(error: error, stackTrace: stackTrace));
    return;
  }

  final logger = result.logger;

  // Route framework and zone errors into the application log so a crash on a
  // warehouse PC is diagnosable after the fact.
  FlutterError.onError = (FlutterErrorDetails details) {
    logger.critical(
      LogCategory.app,
      'Unhandled Flutter error',
      error: details.exception,
      stackTrace: details.stack,
    );
    if (kDebugMode) FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError =
      (Object error, StackTrace stack) {
    logger.critical(
      LogCategory.app,
      'Unhandled error',
      error: error,
      stackTrace: stack,
    );
    return true;
  };

  final controller = sl<LifecycleController>();
  final tray = sl<TrayService>();
  final settings = result.settings;

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // Closing the window hides the agent rather than stopping it; the process is
  // only ended from the tray "Exit" item or when close-to-tray is off.
  await windowManager.setPreventClose(settings.closeToTray);

  // Exiting must always work, first time. A graceful shutdown waits on network
  // calls, printer polling and a database close, any of which can hang — and
  // when it did, pressing Exit appeared to do nothing and the operator pressed
  // it again, stacking another shutdown behind the stuck one. So the tidy path
  // gets a deadline, and the process ends either way.
  var exiting = false;

  Future<void> forceExit() async {
    try {
      guard.release();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      // Nothing left worth reporting; the exit below is unconditional.
    }
    exit(0);
  }

  controller
    ..onShowWindow = showWindow
    ..onExitRequested = () async {
      // A second press while the first is still unwinding must not start over.
      if (exiting) {
        logger.info(LogCategory.app, 'Exit already in progress');
        return;
      }
      exiting = true;

      logger.info(LogCategory.app, 'Exit requested');

      try {
        await Future.any(<Future<void>>[
          () async {
            await controller.stop();
            await tray.dispose();
            await disposeDependencies();
          }(),
          Future<void>.delayed(const Duration(seconds: 5)),
        ]);
      } catch (e, st) {
        logger.exception(LogCategory.app, 'Error during shutdown', e, st);
      }

      await forceExit();
    };

  await tray.initialise();
  tray.closeToTray = settings.closeToTray;

  runApp(
    ProviderScope(
      child: PrintAgentApp(
        isPaired: result.isPaired,
        onShowWindow: showWindow,
      ),
    ),
  );

  // Services start after the first frame so the window paints immediately.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    unawaited(controller.start());

    final startMinimised = startMinimisedFromArgs || settings.startMinimized;
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (startMinimised) {
        logger.info(
          LogCategory.app,
          'Started minimised to the notification area',
        );
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  });
}

/// Shown when startup itself failed — a corrupt database, a read-only
/// %APPDATA%, or a missing sqlite3 library.
class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      '${AppInfo.productName} could not start',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'The agent could not open its local data folder or '
                      'database. Check that the application data folder is '
                      'writable and that there is free disk space, then start '
                      'the agent again.',
                    ),
                    const SizedBox(height: 20),
                    SelectableText(
                      '$error',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
