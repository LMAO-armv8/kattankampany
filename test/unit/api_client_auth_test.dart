import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/config/app_info.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/network/api_client.dart';

/// A stand-in store that answers with a chosen status and error envelope.
class _FakeStore {
  _FakeStore._(this._server);

  final HttpServer _server;

  int status = 403;
  String code = 'wpm_document_not_owned';
  String message = 'This print job belongs to another agent.';

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeStore> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final store = _FakeStore._(server);

    server.listen((HttpRequest request) async {
      request.response
        ..statusCode = store.status
        ..headers.contentType = ContentType.json
        ..write('{"code":"${store.code}","message":"${store.message}",'
            '"data":{"status":${store.status}}}');
      await request.response.close();
    });

    return store;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  setUpAll(() => AppInfo.debugOverride(AppInfo.forTesting()));

  late _FakeStore store;
  late List<AppException> escalations;
  late ApiClient client;

  setUp(() async {
    store = await _FakeStore.start();
    escalations = <AppException>[];
    client = ApiClient(
      baseUrl: store.baseUrl,
      tokenProvider: () async => 'wpm_at_token',
      onUnauthorized: escalations.add,
      connectTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    client.close();
    await store.stop();
  });

  group('a 403 about a resource', () {
    test('does not tear down the session', () async {
      // The exact failure seen in production: one job's document belonged to
      // another agent, and the agent responded by wiping its credentials and
      // reporting itself disabled.
      store
        ..status = 403
        ..code = 'wpm_document_not_owned'
        ..message = 'This print job belongs to another agent.';

      await expectLater(
        client.getJson('/print-jobs/14/document'),
        throwsA(isA<ForbiddenException>()),
      );

      expect(
        escalations,
        isEmpty,
        reason: 'a per-request refusal must not invalidate the credentials',
      );
    });

    test('still surfaces the server code for diagnosis', () async {
      store
        ..status = 403
        ..code = 'wpm_document_not_owned'
        ..message = 'This print job belongs to another agent.';

      try {
        await client.getJson('/print-jobs/14/document');
        fail('expected a ForbiddenException');
      } on ForbiddenException catch (e) {
        expect(e.technicalDetail, contains('wpm_document_not_owned'));
      }
    });

    test('does not tell the operator the agent was disabled', () async {
      // The message the operator actually reads. Escalation and wording are
      // separate failures: stopping the teardown still left the agent claiming
      // it had been switched off in a store that had done no such thing.
      store
        ..status = 403
        ..code = 'wpm_document_not_owned'
        ..message = 'This print job belongs to another agent.';

      try {
        await client.getJson('/print-jobs/14/document');
        fail('expected a ForbiddenException');
      } on ForbiddenException catch (e) {
        expect(e.agentRevoked, isFalse);
        expect(e.userMessage, isNot(contains('disabled')));
        expect(
          e.userMessage,
          'This print job belongs to another agent.',
          reason: "the store's own message is clearer than a generic one",
        );
      }
    });
  });

  group('a 403 about the agent', () {
    test('does tear down the session', () async {
      store
        ..status = 403
        ..code = 'wpm_agent_disabled'
        ..message = 'This agent is disabled.';

      await expectLater(
        client.getJson('/agents/me'),
        throwsA(
          isA<ForbiddenException>()
              .having((ForbiddenException e) => e.agentRevoked, 'agentRevoked',
                  isTrue,)
              .having((ForbiddenException e) => e.userMessage, 'userMessage',
                  contains('disabled'),),
        ),
      );

      expect(
        escalations,
        hasLength(1),
        reason: 'a genuine revocation must still require re-pairing',
      );
    });
  });

  group('a 401', () {
    test('always tears down the session', () async {
      store
        ..status = 401
        ..code = 'wpm_invalid_token'
        ..message = 'The supplied agent token is invalid.';

      await expectLater(
        client.getJson('/agents/me'),
        throwsA(isA<AuthException>()),
      );

      expect(escalations, hasLength(1));
    });
  });

  group('other failures', () {
    test('a 409 conflict does not escalate', () async {
      store
        ..status = 409
        ..code = 'wpm_job_not_claimable'
        ..message = 'Another agent claimed this job first.';

      await expectLater(
        client.getJson('/print-jobs/14/claim'),
        throwsA(isA<ConflictException>()),
      );

      expect(escalations, isEmpty);
    });

    test('a 500 does not escalate', () async {
      store
        ..status = 500
        ..code = 'internal_error'
        ..message = 'Something broke.';

      await expectLater(
        client.getJson('/print-jobs'),
        throwsA(isA<AppException>()),
      );

      expect(escalations, isEmpty);
    });
  });
}
