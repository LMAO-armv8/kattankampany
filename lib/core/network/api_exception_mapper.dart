import 'dart:io';

import 'package:dio/dio.dart';

import '../errors/app_exception.dart';
import '../errors/error_codes.dart';
import 'api_endpoints.dart';

/// Converts everything Dio can throw into the application's exception types.
///
/// Nothing above the network layer ever sees a [DioException] — that is what
/// makes the error messages in the UI plain language instead of
/// `SocketException: Connection reset by peer`.
abstract final class ApiExceptionMapper {
  static AppException map(Object error, [StackTrace? stackTrace]) {
    if (error is AppException) return error;
    if (error is! DioException) {
      return UnknownException(
        technicalDetail: error.toString(),
        cause: error,
        stackTrace: stackTrace,
      );
    }

    final response = error.response;
    final detail = _detail(error);

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return RequestTimeoutException(
          technicalDetail: detail,
          cause: error,
          stackTrace: stackTrace,
        );

      case DioExceptionType.badCertificate:
        return TlsValidationException(
          technicalDetail: detail,
          cause: error,
          stackTrace: stackTrace,
        );

      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        final inner = error.error;
        if (inner is HandshakeException || inner is TlsException) {
          return TlsValidationException(
            technicalDetail: detail,
            cause: error,
            stackTrace: stackTrace,
          );
        }
        return NetworkException(
          technicalDetail: detail,
          cause: error,
          stackTrace: stackTrace,
        );

      case DioExceptionType.cancel:
        return ConfigurationException(
          userMessage: 'The request was cancelled.',
          code: ErrorCodes.cancelled,
          technicalDetail: detail,
          cause: error,
          stackTrace: stackTrace,
        );

      case DioExceptionType.badResponse:
        return _fromStatus(
          response?.statusCode ?? 0,
          response: response,
          detail: detail,
          cause: error,
          stackTrace: stackTrace,
        );
    }
  }

  static AppException _fromStatus(
    int status, {
    Response<dynamic>? response,
    String? detail,
    Object? cause,
    StackTrace? stackTrace,
  }) {
    final serverMessage = _serverMessage(response);
    final serverCode = _serverCode(response);

    // The machine-readable code is carried alongside the message because the
    // message is prose: it gets reworded, translated, and is useless for
    // deciding anything. Callers that must distinguish "this agent is revoked"
    // from "that job is not yours" need the code, and so does anyone reading the
    // log afterwards.
    final enriched = <String>[
      if (detail != null && detail.isNotEmpty) detail,
      if (serverCode != null) 'code: $serverCode',
      if (serverMessage != null) 'server: $serverMessage',
    ].join(' | ');

    switch (status) {
      case 400:
      case 422:
        return ApiContractException(
          userMessage: serverMessage ??
              'Your store rejected the request. The print plugin may need '
                  'updating.',
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 401:
        return AuthException(
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 403:
        // Which of the two meanings of 403 this is, decided on the store's
        // error code rather than on its prose so it survives rewording and
        // translation. Anything unrecognised is treated as a refusal of this
        // one request, which is the safe direction: the cost of missing a real
        // revocation is one more rejected request, whereas the cost of a false
        // positive is an agent that stops printing and tells the operator to go
        // and re-enable something that was never disabled.
        if (_agentRevokedCodes.contains(serverCode)) {
          return ForbiddenException.agentDisabled(
            technicalDetail: enriched,
            cause: cause,
            stackTrace: stackTrace,
          );
        }
        return ForbiddenException(
          userMessage: serverMessage ??
              'Your store refused this request. It will be retried; if it '
                  'keeps happening, check the print agent in your store '
                  'settings.',
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 404:
        return NotFoundException(
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 409:
        return ConflictException(
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 410:
        return DocumentException(
          userMessage:
              'This document is no longer available from your store. It may '
              'have expired.',
          code: ErrorCodes.documentExpired,
          technicalDetail: enriched,
          retryable: false,
          cause: cause,
          stackTrace: stackTrace,
        );
      case 429:
        return RateLimitException(
          retryAfter: parseRetryAfter(response),
          technicalDetail: enriched,
          cause: cause,
          stackTrace: stackTrace,
        );
      default:
        if (status >= 500) {
          return ServerException(
            statusCode: status,
            technicalDetail: enriched,
            cause: cause,
            stackTrace: stackTrace,
          );
        }
        return ApiContractException(
          technicalDetail: 'Unexpected HTTP $status. $enriched',
          cause: cause,
          stackTrace: stackTrace,
        );
    }
  }

  /// Store error codes that mean *this agent* is no longer allowed, as opposed
  /// to this one request being refused.
  static const Set<String> _agentRevokedCodes = <String>{
    'wpm_agent_disabled',
    'wpm_agent_revoked',
    'agent_disabled',
    'agent_revoked',
  };

  /// Reads `Retry-After`, which may be seconds or an HTTP date.
  static Duration? parseRetryAfter(Response<dynamic>? response) {
    final raw = response?.headers.value(ApiHeaders.retryAfter);
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 3600));
    try {
      final date = HttpDate.parse(raw);
      final delta = date.difference(DateTime.now());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }

  /// The WordPress REST error envelope is `{ code, message, data: { status } }`.
  /// This reads its `code`, e.g. `wpm_agent_disabled`.
  static String? _serverCode(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map) {
      final code = data['code'];
      if (code is String && code.isNotEmpty) return code;
    }
    return null;
  }

  static String? _serverMessage(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map) {
      final message = data['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return null;
  }

  static String _detail(DioException error) {
    final method = error.requestOptions.method;
    final path = error.requestOptions.path;
    final status = error.response?.statusCode;
    return '$method $path'
        '${status == null ? '' : ' → $status'}'
        ' (${error.type.name})'
        '${error.message == null ? '' : ': ${error.message}'}';
  }
}
