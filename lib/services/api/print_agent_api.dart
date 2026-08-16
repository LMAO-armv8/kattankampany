import 'dart:typed_data';

import '../../core/config/app_info.dart';
import '../../core/errors/app_exception.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/security/url_validator.dart';
import '../../features/authentication/domain/agent_credentials.dart';
import 'dto/agent_dto.dart';
import 'dto/pairing_dto.dart';
import 'dto/print_job_dto.dart';

/// Typed access to the WooCommerce Print Management plugin API.
///
/// One instance per store. Every method returns domain/DTO types and throws
/// [AppException] — callers never see HTTP details.
class PrintAgentApi {
  PrintAgentApi({
    required ApiClient client,
    required String storeBaseUrl,
    AppLogger? logger,
  })  : _client = client,
        _storeBaseUrl = storeBaseUrl,
        _logger = logger;

  final ApiClient _client;
  final String _storeBaseUrl;
  final AppLogger? _logger;

  String get storeBaseUrl => _storeBaseUrl;

  set agentId(String? value) => _client.agentId = value;

  // -------------------------------------------------------------------------
  // Pairing — no WordPress username or password is ever involved
  // -------------------------------------------------------------------------

  /// Opens a pairing request. Unauthenticated by design: the agent has no
  /// credentials yet, and the *administrator* supplies the authority by
  /// approving the request inside wp-admin.
  Future<PairingSession> startPairing({
    required String agentName,
    List<String> requestedScopes = const <String>[
      'print_jobs:read',
      'print_jobs:write',
      'printers:write',
    ],
  }) async {
    final info = AppInfo.instance;
    final response = await _client.postJson(
      ApiEndpoints.pairingStart,
      skipAuth: true,
      body: <String, dynamic>{
        'agent_name': agentName,
        'machine_name': info.machineName,
        'os': info.osDescription,
        'app_version': info.fullVersion,
        'requested_scopes': requestedScopes,
      },
    );
    final session = PairingSession.fromJson(response);
    if (session.pairingId.isEmpty || session.pairingCode.isEmpty) {
      throw const PairingException(
        userMessage: 'Your store did not return a valid pairing request. '
            'Check that the Print Management plugin is installed and active.',
        technicalDetail: 'pairing_id or pairing_code missing from response.',
      );
    }
    _logger?.info(
      LogCategory.auth,
      'Pairing request opened',
      context: <String, Object?>{'pairing_id': session.pairingId},
    );
    return session;
  }

  /// Polls the pairing request. Safe to call repeatedly; the server rate-limits.
  Future<PairingStatus> pairingStatus(String pairingId) async {
    final response = await _client.getJson(
      ApiEndpoints.pairingStatus(pairingId),
      skipAuth: true,
    );
    return PairingStatus.fromJson(response);
  }

  /// Exchanges a refresh token for a new access token. Only used when the
  /// server issues expiring tokens.
  Future<AgentCredentials> refreshCredentials(String refreshToken) async {
    final response = await _client.postJson(
      ApiEndpoints.pairingRefresh,
      skipAuth: true,
      body: <String, dynamic>{'refresh_token': refreshToken},
    );
    final credentials = AgentCredentials.fromJson(response);
    if (credentials.token.isEmpty) {
      throw const AuthException(
        technicalDetail: 'Refresh response contained no token.',
      );
    }
    return credentials;
  }

  // -------------------------------------------------------------------------
  // Agent lifecycle
  // -------------------------------------------------------------------------

  Future<ServerAgent> registerAgent({
    required String name,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    final info = AppInfo.instance;
    final response = await _client.postJson(
      ApiEndpoints.agentRegister,
      body: <String, dynamic>{
        'name': name,
        'machine_name': info.machineName,
        'os': info.osDescription,
        'app_version': info.fullVersion,
        'metadata': <String, dynamic>{
          'timezone': DateTime.now().timeZoneName,
          ...metadata,
        },
      },
    );
    return ServerAgent.fromJson(response);
  }

  Future<ServerAgent> getAgent() async {
    final response = await _client.getJson(ApiEndpoints.agentMe);
    return ServerAgent.fromJson(response);
  }

  Future<HeartbeatResponse> heartbeat({
    required String status,
    required Map<String, dynamic> queueCounters,
    required List<Map<String, dynamic>> printers,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    final response = await _client.postJson(
      ApiEndpoints.agentHeartbeat,
      body: <String, dynamic>{
        'status': status,
        'app_version': AppInfo.instance.fullVersion,
        'queue': queueCounters,
        'printers': printers,
        'metadata': metadata,
      },
    );
    return HeartbeatResponse.fromJson(response);
  }

  /// Pushes the printer inventory outside the heartbeat cadence, so the admin
  /// UI updates immediately when a printer is added or removed.
  Future<void> syncPrinters(List<Map<String, dynamic>> printers) async {
    await _client.postJson(
      ApiEndpoints.agentPrinters,
      body: <String, dynamic>{'printers': printers},
    );
  }

  // -------------------------------------------------------------------------
  // Jobs
  // -------------------------------------------------------------------------

  Future<List<RemotePrintJob>> fetchJobs({
    int limit = 10,
    String status = 'queued',
  }) async {
    final response = await _client.getJson(
      ApiEndpoints.printJobs,
      query: <String, dynamic>{'status': status, 'limit': limit},
    );

    final raw = response['jobs'] ?? response['items'] ?? response['data'];
    if (raw is! List) {
      // An empty queue may legitimately return `{}` or `{"jobs": null}`.
      if (raw == null) return const <RemotePrintJob>[];
      throw const ApiContractException(
        technicalDetail: '"jobs" was not a list in the print-jobs response.',
      );
    }

    final jobs = <RemotePrintJob>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        final job = RemotePrintJob.fromJson(item.cast<String, dynamic>());
        if (job.serverJobId.isEmpty) continue;
        jobs.add(job);
      } catch (e) {
        // One malformed job must not block the rest of the queue.
        _logger?.warn(
          LogCategory.api,
          'Skipping a print job the agent could not parse',
          context: <String, Object?>{'error': e.toString()},
        );
      }
    }
    return jobs;
  }

  /// Claims a job. A 409 means another agent got there first, which is expected
  /// in multi-agent installations and is returned as a value rather than thrown.
  Future<ClaimResult> claimJob({
    required String serverJobId,
    required String agentId,
  }) async {
    try {
      final response = await _client.postJson(
        ApiEndpoints.printJobClaim(serverJobId),
        body: <String, dynamic>{'agent_id': agentId},
        idempotencyKey: '$agentId:$serverJobId:${JobAction.claim}:1',
      );
      // Some plugins echo the job, some return only an acknowledgement.
      if (response.isEmpty || response['id'] == null) {
        return const ClaimResult(claimed: true);
      }
      return ClaimResult.fromJson(response);
    } on ConflictException {
      return ClaimResult.takenByAnotherAgent;
    } on NotFoundException {
      return const ClaimResult(
        claimed: false,
        reason: 'The job no longer exists on the store',
      );
    }
  }

  Future<void> reportStart({
    required String serverJobId,
    required String agentId,
    required String printerKey,
    required int attempt,
    required String idempotencyKey,
  }) async {
    await _client.postJson(
      ApiEndpoints.printJobStart(serverJobId),
      idempotencyKey: idempotencyKey,
      body: <String, dynamic>{
        'agent_id': agentId,
        'printer_key': printerKey,
        'attempt': attempt,
      },
    );
  }

  Future<void> reportComplete({
    required String serverJobId,
    required String agentId,
    required String printerKey,
    required int attempt,
    required String idempotencyKey,
    int? spoolerJobId,
    Duration? duration,
    DateTime? completedAt,
  }) async {
    await _client.postJson(
      ApiEndpoints.printJobComplete(serverJobId),
      idempotencyKey: idempotencyKey,
      body: <String, dynamic>{
        'agent_id': agentId,
        'printer_key': printerKey,
        'attempt': attempt,
        if (spoolerJobId != null) 'spooler_job_id': spoolerJobId,
        if (duration != null) 'duration_ms': duration.inMilliseconds,
        'completed_at':
            (completedAt ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );
  }

  Future<void> reportFailure({
    required String serverJobId,
    required String agentId,
    required int attempt,
    required String errorCode,
    required String errorMessage,
    required bool willRetry,
    required String idempotencyKey,
    String? printerKey,
    DateTime? nextAttemptAt,
  }) async {
    await _client.postJson(
      ApiEndpoints.printJobFail(serverJobId),
      idempotencyKey: idempotencyKey,
      body: <String, dynamic>{
        'agent_id': agentId,
        'attempt': attempt,
        'error_code': errorCode,
        'error_message': errorMessage,
        'will_retry': willRetry,
        if (printerKey != null) 'printer_key': printerKey,
        if (nextAttemptAt != null)
          'next_attempt_at': nextAttemptAt.toUtc().toIso8601String(),
      },
    );
  }

  /// Returns a claimed job to the pool — used on a clean shutdown so another
  /// agent can pick it up instead of waiting for the claim to expire.
  Future<void> releaseJob({
    required String serverJobId,
    required String agentId,
    String reason = 'agent_shutdown',
  }) async {
    await _client.postJson(
      ApiEndpoints.printJobRelease(serverJobId),
      idempotencyKey: '$agentId:$serverJobId:${JobAction.release}:1',
      body: <String, dynamic>{'agent_id': agentId, 'reason': reason},
    );
  }

  // -------------------------------------------------------------------------
  // Documents
  // -------------------------------------------------------------------------

  /// Downloads a print document.
  ///
  /// The URL is checked against the paired store's origin *before* the request
  /// is made — a job pointing at an arbitrary host is refused, never followed.
  Future<({Uint8List bytes, String? contentType})> downloadDocument({
    required String url,
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    UrlValidator.assertAllowedDocumentUrl(
      url: url,
      storeBaseUrl: _storeBaseUrl,
    );
    final result = await _client.getBytes(
      url,
      timeout: timeout,
      onProgress: onProgress,
    );
    return (
      bytes: Uint8List.fromList(result.bytes),
      contentType: result.contentType,
    );
  }

  /// Asks the server to enqueue a test job. Optional: if the plugin does not
  /// implement it, the agent falls back to its own locally-generated test page.
  Future<RemotePrintJob?> requestServerTestPrint(String printerKey) async {
    try {
      final response = await _client.postJson(
        ApiEndpoints.printJobTest,
        body: <String, dynamic>{'printer_key': printerKey},
      );
      if (response.isEmpty) return null;
      return RemotePrintJob.fromJson(response);
    } on NotFoundException {
      return null;
    } on ApiContractException {
      return null;
    }
  }

  /// Cheap authenticated round-trip used by Diagnostics.
  Future<bool> ping() async {
    try {
      await getAgent();
      return true;
    } on AppException {
      rethrow;
    }
  }
}
