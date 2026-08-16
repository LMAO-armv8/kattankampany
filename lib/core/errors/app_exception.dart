/// The single exception hierarchy used across the application.
///
/// Rules:
///  * The data layer never lets a raw `DioException`, `SocketException`,
///    `SqliteException` or Win32 error code escape. Everything is mapped to one of
///    these types first.
///  * [userMessage] is plain language and safe to render in the UI.
///  * [technicalDetail] is for logs and the diagnostics screen only.
///  * [code] is a stable machine string reported to the server as `error_code`.
library;

import 'error_codes.dart';

sealed class AppException implements Exception {
  const AppException({
    required this.code,
    required this.userMessage,
    this.technicalDetail,
    this.cause,
    this.stackTrace,
  });

  /// Stable machine-readable identifier. See [ErrorCodes].
  final String code;

  /// Plain-language message safe to show to an operator.
  final String userMessage;

  /// Technical detail — logs and diagnostics only, never the main UI.
  final String? technicalDetail;

  final Object? cause;
  final StackTrace? stackTrace;

  /// Whether the queue engine may retry an operation that failed this way.
  bool get isRetryable;

  @override
  String toString() =>
      '$runtimeType(code: $code, message: $userMessage'
      '${technicalDetail == null ? '' : ', detail: $technicalDetail'})';
}

// ---------------------------------------------------------------------------
// Network / transport
// ---------------------------------------------------------------------------

class NetworkException extends AppException {
  const NetworkException({
    super.code = ErrorCodes.network,
    super.userMessage =
        "Unable to connect to your WooCommerce store. We'll automatically retry.",
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => true;
}

class RequestTimeoutException extends AppException {
  const RequestTimeoutException({
    super.code = ErrorCodes.timeout,
    super.userMessage =
        "Your store took too long to respond. We'll automatically retry.",
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => true;
}

class TlsValidationException extends AppException {
  const TlsValidationException({
    super.code = ErrorCodes.tls,
    super.userMessage =
        'The secure connection to your store could not be verified. '
        'Check the store\'s SSL certificate.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

// ---------------------------------------------------------------------------
// API / authorisation
// ---------------------------------------------------------------------------

class AuthException extends AppException {
  const AuthException({
    super.code = ErrorCodes.unauthorized,
    super.userMessage =
        'This agent is no longer authorised. Please pair it with your store again.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

class ForbiddenException extends AppException {
  const ForbiddenException({
    super.code = ErrorCodes.forbidden,
    super.userMessage =
        'This agent has been disabled in your store. Ask an administrator to re-enable it.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

class NotFoundException extends AppException {
  const NotFoundException({
    super.code = ErrorCodes.notFound,
    super.userMessage = 'The requested item no longer exists on your store.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

/// HTTP 409 — another agent claimed the job first. Expected in multi-agent
/// installations and deliberately *not* treated as an error condition.
class ConflictException extends AppException {
  const ConflictException({
    super.code = ErrorCodes.conflict,
    super.userMessage = 'This job was already taken by another print agent.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

class RateLimitException extends AppException {
  const RateLimitException({
    this.retryAfter,
    super.code = ErrorCodes.rateLimited,
    super.userMessage =
        "Your store is limiting requests. We'll slow down and try again shortly.",
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  final Duration? retryAfter;

  @override
  bool get isRetryable => true;
}

class ServerException extends AppException {
  const ServerException({
    this.statusCode,
    super.code = ErrorCodes.serverError,
    super.userMessage =
        "Your store reported an internal error. We'll automatically retry.",
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  final int? statusCode;

  @override
  bool get isRetryable => true;
}

class ApiContractException extends AppException {
  const ApiContractException({
    super.code = ErrorCodes.apiContract,
    super.userMessage =
        'Your store returned an unexpected response. The print plugin may need updating.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

class PairingException extends AppException {
  const PairingException({
    required super.userMessage,
    super.code = ErrorCodes.pairingFailed,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

class DocumentException extends AppException {
  const DocumentException({
    required super.userMessage,
    super.code = ErrorCodes.documentInvalid,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
    this.retryable = true,
  });

  final bool retryable;

  @override
  bool get isRetryable => retryable;
}

// ---------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------

class PrinterException extends AppException {
  const PrinterException({
    required super.userMessage,
    super.code = ErrorCodes.printerError,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
    this.printerKey,
    this.retryable = true,
  });

  final String? printerKey;
  final bool retryable;

  @override
  bool get isRetryable => retryable;
}

class PrinterUnavailableException extends PrinterException {
  const PrinterUnavailableException({
    required super.userMessage,
    super.code = ErrorCodes.printerOffline,
    super.technicalDetail,
    super.printerKey,
    super.cause,
    super.stackTrace,
  }) : super(retryable: true);
}

class UnsupportedDocumentException extends AppException {
  const UnsupportedDocumentException({
    required super.userMessage,
    super.code = ErrorCodes.unsupportedDocument,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

// ---------------------------------------------------------------------------
// Local infrastructure
// ---------------------------------------------------------------------------

class StorageException extends AppException {
  const StorageException({
    super.code = ErrorCodes.storageError,
    super.userMessage =
        'The agent could not read or write its local database. '
        'Check disk space and folder permissions.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

class SecurityStoreException extends AppException {
  const SecurityStoreException({
    super.code = ErrorCodes.securityStore,
    super.userMessage =
        'The agent could not access its secure credential storage. '
        'You may need to pair with your store again.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

class ConfigurationException extends AppException {
  const ConfigurationException({
    required super.userMessage,
    super.code = ErrorCodes.configuration,
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => false;
}

/// Last-resort wrapper so no raw error ever reaches the UI.
class UnknownException extends AppException {
  const UnknownException({
    super.code = ErrorCodes.unknown,
    super.userMessage = 'Something went wrong. The details were written to the log.',
    super.technicalDetail,
    super.cause,
    super.stackTrace,
  });

  @override
  bool get isRetryable => true;
}

/// Normalises any thrown object into an [AppException].
AppException asAppException(Object error, [StackTrace? stackTrace]) {
  if (error is AppException) return error;
  return UnknownException(
    technicalDetail: error.toString(),
    cause: error,
    stackTrace: stackTrace,
  );
}
