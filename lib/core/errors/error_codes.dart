/// Stable machine-readable error identifiers.
///
/// These strings cross the wire as `error_code` in `POST /print-jobs/{id}/fail`,
/// so they must never be renamed without a server-side migration.
abstract final class ErrorCodes {
  // transport
  static const String network = 'network';
  static const String timeout = 'timeout';
  static const String tls = 'tls';

  // api
  static const String unauthorized = 'unauthorized';
  static const String forbidden = 'forbidden';
  static const String notFound = 'not_found';
  static const String conflict = 'conflict';
  static const String rateLimited = 'rate_limited';
  static const String serverError = 'server_error';
  static const String apiContract = 'api_contract';
  static const String pairingFailed = 'pairing_failed';

  // documents
  static const String documentDownload = 'document_download';
  static const String documentInvalid = 'document_invalid';
  static const String documentExpired = 'document_expired';
  static const String documentTooLarge = 'document_too_large';
  static const String documentUntrustedOrigin = 'document_untrusted_origin';
  static const String unsupportedDocument = 'unsupported_document';

  // printing
  static const String printerNotFound = 'printer_not_found';
  static const String printerOffline = 'printer_offline';
  static const String printerError = 'printer_error';
  static const String spoolerError = 'spooler_error';

  // local
  static const String storageError = 'storage_error';
  static const String securityStore = 'security_store';
  static const String configuration = 'configuration';
  static const String cancelled = 'cancelled';
  static const String unknown = 'unknown';
}
