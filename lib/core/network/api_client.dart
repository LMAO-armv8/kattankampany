import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../config/app_info.dart';
import '../errors/app_exception.dart';
import '../logging/app_logger.dart';
import '../logging/log_level.dart';
import '../logging/redaction.dart';
import 'api_endpoints.dart';
import 'api_exception_mapper.dart';

/// Supplies the current bearer token. Returning null means "not paired yet".
typedef TokenProvider = FutureOr<String?> Function();

/// Called when the server rejects the token, so the agent can stop syncing and
/// surface "re-pairing required" rather than hammering a dead endpoint.
typedef UnauthorizedCallback = void Function(AppException error);

/// The HTTP layer.
///
/// Responsibilities kept deliberately narrow: base URL, headers, timeouts,
/// logging, error normalisation. Endpoint knowledge lives in `PrintAgentApi`;
/// retry policy lives in the queue engine and the sync loop, not here — a
/// transparent retry inside the client would defeat the idempotency accounting.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    TokenProvider? tokenProvider,
    AppLogger? logger,
    Duration connectTimeout = const Duration(seconds: 20),
    Duration receiveTimeout = const Duration(seconds: 30),
    Dio? dio,
    this.onUnauthorized,
    this.agentId,
  })  : _logger = logger,
        _tokenProvider = tokenProvider,
        _dio = dio ?? Dio() {
    _dio.options = _dio.options.copyWith(
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: connectTimeout,
      // The client validates every status itself so the mapper produces a typed
      // exception instead of Dio's generic bad-response error.
      validateStatus: (int? status) => status != null && status < 400,
      headers: <String, dynamic>{
        ApiHeaders.apiVersion: '${ApiEndpoints.contractVersion}',
        ApiHeaders.agentVersion: AppInfo.instance.fullVersion,
        ApiHeaders.userAgent:
            '${AppInfo.productName}/${AppInfo.instance.version} '
                '(Windows; ${AppInfo.instance.machineName})',
      },
      responseType: ResponseType.json,
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: _onRequest,
        onResponse: _onResponse,
        onError: _onError,
      ),
    );
  }

  final String baseUrl;
  final AppLogger? _logger;
  final TokenProvider? _tokenProvider;
  final Dio _dio;
  final UnauthorizedCallback? onUnauthorized;

  /// Sent as `X-Agent-Id` once known.
  String? agentId;

  Dio get raw => _dio;

  static final Random _random = Random();

  // -------------------------------------------------------------------------
  // Interceptor hooks
  // -------------------------------------------------------------------------

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final requestId = _newRequestId();
    options.extra['request_id'] = requestId;
    options.extra['started_at'] = DateTime.now();
    options.headers[ApiHeaders.requestId] = requestId;

    if (agentId != null) options.headers[ApiHeaders.agentId] = agentId;

    // Pairing endpoints are intentionally unauthenticated.
    final needsAuth = options.extra['skip_auth'] != true;
    if (needsAuth && _tokenProvider != null) {
      final token = await _tokenProvider();
      if (token != null && token.isNotEmpty) {
        options.headers[ApiHeaders.authorization] = 'Bearer $token';
      }
    }

    _logger?.debug(
      LogCategory.api,
      '→ ${options.method} ${Redaction.url(options.path)}',
      context: <String, Object?>{'request_id': requestId},
    );
    handler.next(options);
  }

  void _onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _logger?.debug(
      LogCategory.api,
      '← ${response.statusCode} ${Redaction.url(response.requestOptions.path)}',
      context: <String, Object?>{
        'request_id': response.requestOptions.extra['request_id'],
        'ms': _elapsedMs(response.requestOptions),
      },
    );
    handler.next(response);
  }

  void _onError(DioException error, ErrorInterceptorHandler handler) {
    final mapped = ApiExceptionMapper.map(error, error.stackTrace);
    _logger?.log(
      mapped is AuthException || mapped is ForbiddenException
          ? LogLevel.warning
          : LogLevel.debug,
      LogCategory.api,
      '✕ ${error.requestOptions.method} '
      '${Redaction.url(error.requestOptions.path)}',
      context: <String, Object?>{
        'request_id': error.requestOptions.extra['request_id'],
        'ms': _elapsedMs(error.requestOptions),
        'code': mapped.code,
        'detail': mapped.technicalDetail,
      },
    );
    if (mapped is AuthException || mapped is ForbiddenException) {
      onUnauthorized?.call(mapped);
    }
    handler.reject(
      DioException(
        requestOptions: error.requestOptions,
        response: error.response,
        type: error.type,
        error: mapped,
        stackTrace: error.stackTrace,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Verbs — each unwraps to an AppException on failure
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
    bool skipAuth = false,
    Duration? timeout,
  }) async =>
      _asMap(
        await _send<dynamic>(
          () => _dio.get<dynamic>(
            path,
            queryParameters: query,
            options: _options(skipAuth: skipAuth, timeout: timeout),
          ),
        ),
      );

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
    String? idempotencyKey,
    Duration? timeout,
  }) async =>
      _asMap(
        await _send<dynamic>(
          () => _dio.post<dynamic>(
            path,
            data: body,
            queryParameters: query,
            options: _options(
              skipAuth: skipAuth,
              idempotencyKey: idempotencyKey,
              timeout: timeout,
            ),
          ),
        ),
      );

  /// Downloads binary content. Returns the bytes and the response content type,
  /// which the document validator cross-checks against the declared type.
  Future<({List<int> bytes, String? contentType, int? statusCode})> getBytes(
    String url, {
    Map<String, dynamic>? query,
    Duration? timeout,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        queryParameters: query,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: timeout ?? const Duration(minutes: 2),
          // Accept 2xx only; anything else becomes a typed exception.
          validateStatus: (int? status) => status != null && status < 400,
        ),
      );
      return (
        bytes: response.data ?? const <int>[],
        contentType: response.headers.value(ApiHeaders.contentType),
        statusCode: response.statusCode,
      );
    } catch (e, st) {
      throw _unwrap(e, st);
    }
  }

  Options _options({
    bool skipAuth = false,
    String? idempotencyKey,
    Duration? timeout,
  }) =>
      Options(
        extra: <String, dynamic>{if (skipAuth) 'skip_auth': true},
        headers: <String, dynamic>{
          if (idempotencyKey != null) ApiHeaders.idempotencyKey: idempotencyKey,
        },
        receiveTimeout: timeout,
      );

  Future<Response<T>> _send<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } catch (e, st) {
      throw _unwrap(e, st);
    }
  }

  AppException _unwrap(Object error, StackTrace stackTrace) {
    if (error is DioException && error.error is AppException) {
      return error.error! as AppException;
    }
    return ApiExceptionMapper.map(error, stackTrace);
  }

  static Map<String, dynamic> _asMap(Response<dynamic> response) {
    final data = response.data;
    if (data == null) return <String, dynamic>{};
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is List) return <String, dynamic>{'items': data};
    if (data is String && data.trim().isEmpty) return <String, dynamic>{};
    throw ApiContractException(
      technicalDetail:
          'Expected a JSON object from ${response.requestOptions.path}, '
          'received ${data.runtimeType}.',
    );
  }

  static int? _elapsedMs(RequestOptions options) {
    final started = options.extra['started_at'];
    if (started is DateTime) {
      return DateTime.now().difference(started).inMilliseconds;
    }
    return null;
  }

  static String _newRequestId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List<String>.generate(
      12,
      (int _) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  void close() => _dio.close(force: true);
}
