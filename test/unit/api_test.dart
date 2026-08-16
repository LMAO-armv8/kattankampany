import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/config/app_info.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/network/api_client.dart';
import 'package:wc_print_agent/core/network/api_endpoints.dart';
import 'package:wc_print_agent/core/network/api_exception_mapper.dart';
import 'package:wc_print_agent/features/agent/domain/agent.dart';
import 'package:wc_print_agent/features/print_queue/domain/print_job.dart';
import 'package:wc_print_agent/features/printers/domain/print_profile.dart';
import 'package:wc_print_agent/features/printing/domain/print_document.dart';
import 'package:wc_print_agent/services/api/dto/pairing_dto.dart';
import 'package:wc_print_agent/services/api/dto/print_job_dto.dart';
import 'package:wc_print_agent/services/api/print_agent_api.dart';

import '../fakes/fakes.dart';

const String storeUrl = 'https://store.example';
const String apiBase = '$storeUrl/wp-json/wpm/v1';

({PrintAgentApi api, FakeHttpAdapter adapter, ApiClient client}) buildApi({
  String? token,
  void Function(AppException)? onUnauthorized,
}) {
  final adapter = FakeHttpAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final client = ApiClient(
    baseUrl: apiBase,
    dio: dio,
    tokenProvider: () => token,
    onUnauthorized: onUnauthorized,
  );
  return (
    api: PrintAgentApi(client: client, storeBaseUrl: storeUrl),
    adapter: adapter,
    client: client,
  );
}

void main() {
  setUpAll(() {
    AppInfo.debugOverride(AppInfo.forTesting());
  });

  group('authentication headers', () {
    test('sends the bearer token, agent id and version on an authed call',
        () async {
      final env = buildApi(token: 'wpm_at_secret_token_value');
      env.client.agentId = 'ag_123';
      env.adapter.onGet(ApiEndpoints.agentMe, <String, dynamic>{
        'id': 'ag_123',
        'name': 'Warehouse PC',
        'status': 'active',
      });

      await env.api.getAgent();

      final request = env.adapter.requests.single;
      expect(
        request.headers[ApiHeaders.authorization],
        'Bearer wpm_at_secret_token_value',
      );
      expect(request.headers[ApiHeaders.agentId], 'ag_123');
      expect(request.headers[ApiHeaders.apiVersion], '1');
      expect(request.headers[ApiHeaders.agentVersion], isNotNull);
      expect(request.headers[ApiHeaders.requestId], isNotNull);
    });

    test('pairing calls are unauthenticated by design', () async {
      final env = buildApi(token: 'should-not-be-sent');
      env.adapter.onPost(ApiEndpoints.pairingStart, <String, dynamic>{
        'pairing_id': 'pr_1',
        'pairing_code': 'K3F-92H-QD7',
      });

      await env.api.startPairing(agentName: 'Warehouse PC');

      expect(
        env.adapter.requests.single.headers[ApiHeaders.authorization],
        isNull,
      );
    });

    test('a 401 notifies the unauthorised callback exactly once', () async {
      var calls = 0;
      final env = buildApi(
        token: 'expired',
        onUnauthorized: (_) => calls++,
      );
      env.adapter.onError('GET', ApiEndpoints.agentMe, 401);

      await expectLater(env.api.getAgent(), throwsA(isA<AuthException>()));
      expect(calls, 1);
    });
  });

  group('agent registration', () {
    test('registers with machine identity and returns the server record',
        () async {
      final env = buildApi(token: 't');
      env.adapter.onPost(ApiEndpoints.agentRegister, <String, dynamic>{
        'id': 'ag_999',
        'name': 'Warehouse PC',
        'status': 'active',
        'store_name': 'Test Store',
      });

      final agent = await env.api.registerAgent(name: 'Warehouse PC');

      expect(agent.id, 'ag_999');
      expect(agent.status, AgentStatus.active);
      expect(agent.storeName, 'Test Store');

      final body = env.adapter.requests.single.data! as Map<String, dynamic>;
      expect(body['name'], 'Warehouse PC');
      expect(body['machine_name'], 'TEST-PC');
      expect(body['app_version'], isNotNull);
      expect(
        body.containsKey('password'),
        isFalse,
        reason: 'The agent must never transmit a WordPress password',
      );
    });

    test('reads the server-suggested settings without being bound by them',
        () async {
      final env = buildApi(token: 't');
      env.adapter.onGet(ApiEndpoints.agentMe, <String, dynamic>{
        'id': 'ag_1',
        'name': 'PC',
        'status': 'active',
        'settings': <String, dynamic>{
          'poll_interval_seconds': 10,
          'max_claim_batch': 5,
        },
      });

      final agent = await env.api.getAgent();
      expect(agent.suggestedPollIntervalSeconds, 10);
      expect(agent.suggestedClaimBatch, 5);
    });

    test('a disabled agent is reported as such rather than as an error',
        () async {
      final env = buildApi(token: 't');
      env.adapter.onGet(ApiEndpoints.agentMe, <String, dynamic>{
        'id': 'ag_1',
        'name': 'PC',
        'status': 'disabled',
      });

      final agent = await env.api.getAgent();
      expect(agent.status, AgentStatus.disabled);
      expect(agent.status.canSync, isFalse);
    });
  });

  group('pairing', () {
    test('parses a pairing session', () async {
      final env = buildApi();
      env.adapter.onPost(ApiEndpoints.pairingStart, <String, dynamic>{
        'pairing_id': 'pr_9f2c',
        'pairing_code': 'K3F-92H-QD7',
        'verification_url': '$storeUrl/wp-admin/admin.php?page=wpm-agents',
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
        'poll_interval_seconds': 2,
      });

      final session = await env.api.startPairing(agentName: 'PC');

      expect(session.pairingId, 'pr_9f2c');
      expect(session.pairingCode, 'K3F-92H-QD7');
      expect(session.pollInterval, const Duration(seconds: 2));
      expect(session.isExpired, isFalse);
    });

    test('rejects a response with no pairing code', () async {
      final env = buildApi();
      env.adapter.onPost(ApiEndpoints.pairingStart, <String, dynamic>{'ok': true});

      await expectLater(
        env.api.startPairing(agentName: 'PC'),
        throwsA(isA<PairingException>()),
      );
    });

    test('an approved status carries usable credentials', () async {
      final env = buildApi();
      env.adapter.onGet(ApiEndpoints.pairingStatus('pr_1'), <String, dynamic>{
        'status': 'approved',
        'agent': <String, dynamic>{
          'id': 'ag_1',
          'name': 'Warehouse PC',
          'store_name': 'Test Store',
          'store_url': storeUrl,
        },
        'credentials': <String, dynamic>{
          'token': 'wpm_at_abc',
          'token_type': 'Bearer',
        },
      });

      final status = await env.api.pairingStatus('pr_1');

      expect(status.state, PairingState.approved);
      expect(status.isApproved, isTrue);
      expect(status.credentials!.token, 'wpm_at_abc');
      expect(status.credentials!.authorizationHeader, 'Bearer wpm_at_abc');
      expect(status.serverAgentId, 'ag_1');
    });

    test('a pending status is not terminal; denied and expired are', () {
      expect(PairingState.pending.isTerminal, isFalse);
      expect(PairingState.denied.isTerminal, isTrue);
      expect(PairingState.expired.isTerminal, isTrue);
    });

    test('credentials never leak through toString', () {
      final status = PairingStatus.fromJson(<String, dynamic>{
        'status': 'approved',
        'credentials': <String, dynamic>{'token': 'wpm_at_supersecret'},
      });
      expect(
        status.credentials.toString(),
        isNot(contains('wpm_at_supersecret')),
      );
    });
  });

  group('job listing and claiming', () {
    test('maps a full job payload into the local model', () async {
      final env = buildApi(token: 't');
      env.adapter.onGet(ApiEndpoints.printJobs, <String, dynamic>{
        'jobs': <dynamic>[
          <String, dynamic>{
            'id': 10482,
            'order_id': 5591,
            'document': <String, dynamic>{
              'type': 'pdf',
              'url': '$apiBase/print-jobs/10482/document',
              'filename': 'invoice-5591.pdf',
              'sha256': 'abc',
              'size_bytes': 84213,
            },
            'printer': <String, dynamic>{
              'printer_key': 'Thermal Printer',
              'allow_fallback': true,
            },
            'profile': <String, dynamic>{
              'name': '4x6 Shipping Label',
              'paper_size': '4x6',
              'orientation': 'portrait',
              'scaling': 'fit',
              'copies': 2,
              'strategy': 'pdf',
            },
            'priority': 5,
            'metadata': <String, dynamic>{'document_kind': 'shipping_label'},
          },
        ],
      });

      final jobs = await env.api.fetchJobs();
      expect(jobs, hasLength(1));

      final job = jobs.single.toPrintJob(storeId: 'store', maxAttempts: 4);
      expect(job.serverJobId, '10482');
      expect(job.orderReference, '#5591');
      expect(job.documentType, DocumentType.pdf);
      expect(job.requestedPrinterKey, 'Thermal Printer');
      expect(job.allowFallback, isTrue);
      expect(job.copies, 2);
      expect(job.priority, 5);
      expect(job.maxAttempts, 4);
      expect(job.status, PrintJobStatus.queued);
      expect(job.profile.paperSize, PaperSize.label4x6);
      expect(job.profile.strategy, PrintStrategyType.pdf);
      expect(job.metadata['document_kind'], 'shipping_label');
    });

    test('a minimal job payload still produces a printable job', () async {
      final remote = RemotePrintJob.fromJson(<String, dynamic>{'id': 7});
      final job = remote.toPrintJob(storeId: 'store', maxAttempts: 4);
      expect(job.serverJobId, '7');
      expect(job.documentType, DocumentType.pdf);
      expect(job.requestedPrinterKey, isNull);
      expect(job.allowFallback, isFalse);
      expect(job.copies, 1);
      expect(job.profile.name, PrintProfile.a4Default.name);
    });

    test('an empty queue is not an error', () async {
      final env = buildApi(token: 't');
      env.adapter.onGet(ApiEndpoints.printJobs, <String, dynamic>{'jobs': null});
      expect(await env.api.fetchJobs(), isEmpty);
    });

    test('one malformed job does not block the rest of the queue', () async {
      final env = buildApi(token: 't');
      env.adapter.onGet(ApiEndpoints.printJobs, <String, dynamic>{
        'jobs': <dynamic>[
          'not-an-object',
          <String, dynamic>{'id': 2},
        ],
      });
      final jobs = await env.api.fetchJobs();
      expect(jobs, hasLength(1));
      expect(jobs.single.serverJobId, '2');
    });

    test('a 409 on claim is a value, not an exception', () async {
      final env = buildApi(token: 't');
      env.adapter.onError('POST', ApiEndpoints.printJobClaim('42'), 409);

      final result = await env.api.claimJob(serverJobId: '42', agentId: 'ag');

      expect(result.claimed, isFalse);
      expect(result.reason, isNotNull);
    });

    test('a claim sends an idempotency key', () async {
      final env = buildApi(token: 't');
      env.adapter.onPost(
        ApiEndpoints.printJobClaim('42'),
        <String, dynamic>{'id': 42},
      );

      await env.api.claimJob(serverJobId: '42', agentId: 'ag_7');

      expect(
        env.adapter.requests.single.headers[ApiHeaders.idempotencyKey],
        'ag_7:42:claim:1',
      );
    });

    test('completion reports carry the idempotency key they were given',
        () async {
      final env = buildApi(token: 't');
      env.adapter.onPost(
        ApiEndpoints.printJobComplete('42'),
        <String, dynamic>{'ok': true},
      );

      await env.api.reportComplete(
        serverJobId: '42',
        agentId: 'ag_7',
        printerKey: 'Thermal',
        attempt: 2,
        idempotencyKey: 'ag_7:42:complete:2',
        spoolerJobId: 11,
        duration: const Duration(milliseconds: 5120),
      );

      final request = env.adapter.requests.single;
      expect(
        request.headers[ApiHeaders.idempotencyKey],
        'ag_7:42:complete:2',
      );
      final body = request.data! as Map<String, dynamic>;
      expect(body['spooler_job_id'], 11);
      expect(body['duration_ms'], 5120);
      expect(body['attempt'], 2);
    });
  });

  group('document download safety', () {
    test('refuses a document hosted off the paired origin', () async {
      final env = buildApi(token: 't');
      await expectLater(
        env.api.downloadDocument(url: 'https://evil.example/x.pdf'),
        throwsA(isA<DocumentException>()),
      );
      expect(
        env.adapter.requests,
        isEmpty,
        reason: 'The request must not be issued at all',
      );
    });
  });

  group('error mapping', () {
    test('maps HTTP status codes to typed, user-safe exceptions', () async {
      Future<void> check(int status, Matcher matcher) async {
        final env = buildApi(token: 't');
        env.adapter.onError('GET', ApiEndpoints.agentMe, status);
        await expectLater(env.api.getAgent(), throwsA(matcher));
      }

      await check(400, isA<ApiContractException>());
      await check(401, isA<AuthException>());
      await check(403, isA<ForbiddenException>());
      await check(404, isA<NotFoundException>());
      await check(409, isA<ConflictException>());
      await check(429, isA<RateLimitException>());
      await check(500, isA<ServerException>());
      await check(503, isA<ServerException>());
    });

    test('every exception carries a plain-language message', () async {
      final env = buildApi(token: 't');
      env.adapter.onError('GET', ApiEndpoints.agentMe, 500);
      try {
        await env.api.getAgent();
        fail('should have thrown');
      } on AppException catch (e) {
        expect(e.userMessage, isNotEmpty);
        expect(e.userMessage, isNot(contains('SocketException')));
        expect(e.userMessage, isNot(contains('DioException')));
      }
    });

    test('retryability follows the documented policy', () {
      expect(const NetworkException().isRetryable, isTrue);
      expect(const RequestTimeoutException().isRetryable, isTrue);
      expect(const ServerException().isRetryable, isTrue);
      expect(const RateLimitException().isRetryable, isTrue);
      expect(const AuthException().isRetryable, isFalse);
      expect(const ForbiddenException().isRetryable, isFalse);
      expect(const NotFoundException().isRetryable, isFalse);
      expect(const ConflictException().isRetryable, isFalse);
      expect(const TlsValidationException().isRetryable, isFalse);
    });

    test('offline transport errors become NetworkException, not raw sockets',
        () {
      final mapped = ApiExceptionMapper.map(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
          message: 'Connection reset by peer',
        ),
      );
      expect(mapped, isA<NetworkException>());
      expect(mapped.userMessage, contains('Unable to connect'));
      expect(mapped.userMessage, contains('retry'));
      expect(mapped.technicalDetail, contains('Connection reset by peer'));
    });

    test('a timeout is retryable and phrased for an operator', () {
      final mapped = ApiExceptionMapper.map(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.receiveTimeout,
        ),
      );
      expect(mapped, isA<RequestTimeoutException>());
      expect(mapped.isRetryable, isTrue);
    });

    test('honours Retry-After on a 429', () {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 429,
        headers: Headers.fromMap(<String, List<String>>{
          'retry-after': <String>['42'],
        }),
      );
      expect(
        ApiExceptionMapper.parseRetryAfter(response),
        const Duration(seconds: 42),
      );
    });
  });
}
