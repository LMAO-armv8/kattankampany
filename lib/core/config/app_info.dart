import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Static facts about this installation: version, machine, OS.
/// Populated once during bootstrap and then read synchronously everywhere.
class AppInfo {
  AppInfo._({
    required this.appName,
    required this.version,
    required this.buildNumber,
    required this.machineName,
    required this.osDescription,
    required this.userName,
  });

  static const String productName = 'WooCommerce Print Agent';

  /// The REST API contract major version this build speaks.
  static const int apiMajorVersion = 1;

  final String appName;
  final String version;
  final String buildNumber;
  final String machineName;
  final String osDescription;
  final String userName;

  String get fullVersion => '$version+$buildNumber';

  static AppInfo? _instance;

  /// Available only after [initialize].
  static AppInfo get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppInfo.initialize() must be called during bootstrap.');
    }
    return value;
  }

  static Future<AppInfo> initialize() async {
    if (_instance != null) return _instance!;

    String version = '1.0.0';
    String buildNumber = '1';
    String appName = productName;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) version = info.version;
      if (info.buildNumber.isNotEmpty) buildNumber = info.buildNumber;
      if (info.appName.isNotEmpty) appName = info.appName;
    } catch (_) {
      // package_info_plus can fail in a bare test host; fall back to defaults.
    }

    final env = Platform.environment;
    final machineName = env['COMPUTERNAME'] ??
        env['HOSTNAME'] ??
        Platform.localHostname;
    final userName = env['USERNAME'] ?? env['USER'] ?? 'unknown';

    _instance = AppInfo._(
      appName: appName,
      version: version,
      buildNumber: buildNumber,
      machineName: machineName,
      osDescription: _describeOs(),
      userName: userName,
    );
    return _instance!;
  }

  /// Test seam — lets unit tests provide deterministic values.
  static void debugOverride(AppInfo info) => _instance = info;

  static AppInfo forTesting({
    String appName = productName,
    String version = '1.0.0',
    String buildNumber = '1',
    String machineName = 'TEST-PC',
    String osDescription = 'Test OS',
    String userName = 'tester',
  }) =>
      AppInfo._(
        appName: appName,
        version: version,
        buildNumber: buildNumber,
        machineName: machineName,
        osDescription: osDescription,
        userName: userName,
      );

  static String _describeOs() {
    try {
      if (Platform.isWindows) {
        final edition = Platform.environment['OS'] ?? 'Windows';
        return '$edition (${Platform.operatingSystemVersion})';
      }
      return '${Platform.operatingSystem} (${Platform.operatingSystemVersion})';
    } catch (_) {
      return Platform.operatingSystem;
    }
  }
}
