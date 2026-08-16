/// Paths under the plugin's REST namespace (`/wp-json/wpm/v1`).
///
/// Kept in one place so a namespace or version change is a single edit, and so
/// the contract in `docs/API_INTEGRATION.md` has an exact counterpart in code.
abstract final class ApiEndpoints {
  /// Namespace segment. The full base URL is built by [StoreConnection].
  static const String defaultNamespace = 'wpm/v1';

  /// Sent as `X-Agent-Api-Version`; the server may use it to shape responses.
  static const int contractVersion = 1;

  // --- pairing (unauthenticated) --------------------------------------------
  static const String pairingStart = '/pairing/start';
  static String pairingStatus(String pairingId) => '/pairing/$pairingId';
  static const String pairingRefresh = '/pairing/refresh';

  // --- agent ----------------------------------------------------------------
  static const String agentRegister = '/agents/register';
  static const String agentMe = '/agents/me';
  static const String agentHeartbeat = '/agents/heartbeat';
  static const String agentPrinters = '/agents/printers';

  // --- print jobs -----------------------------------------------------------
  static const String printJobs = '/print-jobs';
  static const String printJobTest = '/print-jobs/test';
  static String printJobClaim(String jobId) => '/print-jobs/$jobId/claim';
  static String printJobStart(String jobId) => '/print-jobs/$jobId/start';
  static String printJobComplete(String jobId) => '/print-jobs/$jobId/complete';
  static String printJobFail(String jobId) => '/print-jobs/$jobId/fail';
  static String printJobRelease(String jobId) => '/print-jobs/$jobId/release';
  static String printJobDocument(String jobId) => '/print-jobs/$jobId/document';
}

/// Header names used on the wire.
abstract final class ApiHeaders {
  static const String authorization = 'Authorization';
  static const String agentId = 'X-Agent-Id';
  static const String agentVersion = 'X-Agent-Version';
  static const String apiVersion = 'X-Agent-Api-Version';
  static const String requestId = 'X-Request-Id';
  static const String idempotencyKey = 'Idempotency-Key';
  static const String retryAfter = 'Retry-After';
  static const String userAgent = 'User-Agent';
  static const String contentType = 'Content-Type';
}

/// Job actions reported to the server. Also used as the `action` component of
/// the idempotency key.
abstract final class JobAction {
  static const String claim = 'claim';
  static const String start = 'start';
  static const String complete = 'complete';
  static const String fail = 'fail';
  static const String release = 'release';
}
