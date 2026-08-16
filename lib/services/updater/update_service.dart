import 'dart:async';

import '../../core/config/app_info.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';

/// A version available from an update source.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.isNewer,
    this.releaseNotes,
    this.downloadUrl,
    this.publishedAt,
    this.mandatory = false,
    this.sha256,
    this.sizeBytes,
  });

  final String version;
  final bool isNewer;
  final String? releaseNotes;
  final String? downloadUrl;
  final DateTime? publishedAt;
  final bool mandatory;
  final String? sha256;
  final int? sizeBytes;
}

enum UpdateCheckOutcome { upToDate, updateAvailable, failed, notConfigured }

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.outcome,
    required this.checkedAt,
    this.info,
    this.message,
  });

  final UpdateCheckOutcome outcome;
  final DateTime checkedAt;
  final UpdateInfo? info;
  final String? message;

  bool get hasUpdate => outcome == UpdateCheckOutcome.updateAvailable;
}

/// The update abstraction.
///
/// Intentionally an interface with a no-op implementation shipped: this build
/// contains no update server, no download logic and no installer execution,
/// because a half-built auto-updater that fetches and runs binaries is a
/// liability, not a feature. What is here is the seam — a real implementation
/// (MSI/Squirrel/custom feed) is added by implementing this interface and
/// registering it, with no other change to the application.
///
/// A future implementation MUST:
///  * fetch metadata over HTTPS with certificate validation on;
///  * verify a signature or checksum before doing anything with a download;
///  * hand the installer to Windows rather than executing arbitrary payloads;
///  * never auto-apply an update while a job is printing.
abstract class UpdateService {
  /// Whether an update source is configured for this build.
  bool get isConfigured;

  /// Human description shown on the Diagnostics screen.
  String get sourceDescription;

  String get currentVersion;

  Future<UpdateCheckResult> checkForUpdates();

  /// Downloads and stages an update. Implementations must verify integrity
  /// before returning true.
  Future<bool> downloadUpdate(UpdateInfo info);

  /// Hands over to the platform installer. Should be refused while the queue is
  /// busy — see [UpdateService] contract notes.
  Future<bool> installUpdate(UpdateInfo info);

  Stream<UpdateCheckResult> get results;
}

/// The implementation shipped today: reports "up to date" and does nothing else.
class NoopUpdateService implements UpdateService {
  NoopUpdateService({AppLogger? logger}) : _logger = logger;

  final AppLogger? _logger;
  final StreamController<UpdateCheckResult> _controller =
      StreamController<UpdateCheckResult>.broadcast();

  @override
  bool get isConfigured => false;

  @override
  String get sourceDescription =>
      'No update source configured for this build. '
      'Updates are installed manually.';

  @override
  String get currentVersion => AppInfo.instance.fullVersion;

  @override
  Stream<UpdateCheckResult> get results => _controller.stream;

  @override
  Future<UpdateCheckResult> checkForUpdates() async {
    _logger?.info(
      LogCategory.updater,
      'Update check requested, but no update source is configured',
    );
    final result = UpdateCheckResult(
      outcome: UpdateCheckOutcome.notConfigured,
      checkedAt: DateTime.now(),
      message: 'This build has no update source configured. '
          'Install new versions using the official installer.',
    );
    if (!_controller.isClosed) _controller.add(result);
    return result;
  }

  @override
  Future<bool> downloadUpdate(UpdateInfo info) async => false;

  @override
  Future<bool> installUpdate(UpdateInfo info) async => false;

  Future<void> dispose() async => _controller.close();
}

/// Compares dotted semantic versions, ignoring any `+build` suffix.
/// Returns a negative number when [a] is older than [b].
int compareVersions(String a, String b) {
  List<int> parts(String value) => value
      .split('+')
      .first
      .split('-')
      .first
      .split('.')
      .map((String p) => int.tryParse(p.trim()) ?? 0)
      .toList(growable: false);

  final left = parts(a);
  final right = parts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l - r;
  }
  return 0;
}
