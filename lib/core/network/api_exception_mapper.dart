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
    final enriched =
        serverMessage == null ? detail : '$detail | server: $serverMessage';

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
        return ForbiddenException(
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

  /// The WordPress REST error envelope: `{ code, message, data: { status } }`.
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
