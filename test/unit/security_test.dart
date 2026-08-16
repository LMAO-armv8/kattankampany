import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wc_print_agent/core/errors/app_exception.dart';
import 'package:wc_print_agent/core/errors/error_codes.dart';
import 'package:wc_print_agent/core/logging/redaction.dart';
import 'package:wc_print_agent/core/security/document_validator.dart';
import 'package:wc_print_agent/core/security/url_validator.dart';
import 'package:wc_print_agent/features/printing/domain/print_document.dart';

void main() {
  group('UrlValidator.normaliseStoreUrl', () {
    test('adds https to a bare host', () {
      expect(
        UrlValidator.normaliseStoreUrl('example.com'),
        'https://example.com',
      );
    });

    test('keeps a subdirectory install but drops the admin tail', () {
      expect(
        UrlValidator.normaliseStoreUrl(
          'https://example.com/shop/wp-admin/admin.php?page=wpm',
        ),
        'https://example.com/shop',
      );
    });

    test('strips trailing slashes, fragments and query strings', () {
      expect(
        UrlValidator.normaliseStoreUrl('https://Example.COM/?utm=1#top'),
        'https://example.com',
      );
    });

    test('rejects plain http for a public host', () {
      expect(UrlValidator.normaliseStoreUrl('http://example.com'), isNull);
    });

    test('permits http for loopback development hosts', () {
      expect(
        UrlValidator.normaliseStoreUrl('http://localhost:8080'),
        'http://localhost:8080',
      );
    });

    test('rejects nonsense', () {
      expect(UrlValidator.normaliseStoreUrl(''), isNull);
      expect(UrlValidator.normaliseStoreUrl('mystore'), isNull);
      expect(UrlValidator.normaliseStoreUrl('ftp://example.com'), isNull);
    });
  });

  group('UrlValidator document origin', () {
    const store = 'https://store.example';

    test('accepts a document on the paired origin', () {
      expect(
        () => UrlValidator.assertAllowedDocumentUrl(
          url: '$store/wp-json/wpm/v1/print-jobs/1/document',
          storeBaseUrl: store,
        ),
        returnsNormally,
      );
    });

    test('refuses a document hosted somewhere else', () {
      expect(
        () => UrlValidator.assertAllowedDocumentUrl(
          url: 'https://evil.example/payload.pdf',
          storeBaseUrl: store,
        ),
        throwsA(
          isA<DocumentException>().having(
            (DocumentException e) => e.code,
            'code',
            ErrorCodes.documentUntrustedOrigin,
          ),
        ),
      );
    });

    test('refuses a subdomain of the paired store', () {
      expect(
        () => UrlValidator.assertAllowedDocumentUrl(
          url: 'https://cdn.store.example/doc.pdf',
          storeBaseUrl: store,
        ),
        throwsA(isA<DocumentException>()),
      );
    });

    test('accepts an explicitly approved additional origin', () {
      expect(
        () => UrlValidator.assertAllowedDocumentUrl(
          url: 'https://cdn.store.example/doc.pdf',
          storeBaseUrl: store,
          additionalAllowedOrigins: const <String>['https://cdn.store.example'],
        ),
        returnsNormally,
      );
    });

    test('refuses plain http', () {
      expect(
        () => UrlValidator.assertAllowedDocumentUrl(
          url: 'http://store.example/doc.pdf',
          storeBaseUrl: 'http://store.example',
        ),
        throwsA(isA<DocumentException>()),
      );
    });
  });

  group('DocumentValidator', () {
    final pdf = Uint8List.fromList(<int>[
      0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0x00,
    ]);
    final png = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00,
    ]);

    test('accepts a well-formed PDF', () {
      expect(
        () => DocumentValidator.validate(
          bytes: pdf,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
          contentType: 'application/pdf',
        ),
        returnsNormally,
      );
    });

    test('rejects an empty payload', () {
      expect(
        () => DocumentValidator.validate(
          bytes: Uint8List(0),
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
        ),
        throwsA(isA<DocumentException>()),
      );
    });

    test('rejects a payload above the size cap without retrying', () {
      expect(
        () => DocumentValidator.validate(
          bytes: Uint8List(2048),
          declaredType: DocumentType.raw,
          maxSizeBytes: 1024,
        ),
        throwsA(
          isA<DocumentException>()
              .having((DocumentException e) => e.code, 'code',
                  ErrorCodes.documentTooLarge,)
              .having((DocumentException e) => e.isRetryable, 'retryable', false),
        ),
      );
    });

    test('rejects an HTML error page served in place of a PDF', () {
      expect(
        () => DocumentValidator.validate(
          bytes: pdf,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
          contentType: 'text/html; charset=UTF-8',
        ),
        throwsA(
          isA<DocumentException>().having(
            (DocumentException e) => e.userMessage,
            'message',
            contains('web page'),
          ),
        ),
      );
    });

    test('rejects content whose magic bytes contradict the declared type', () {
      expect(
        () => DocumentValidator.validate(
          bytes: png,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
        ),
        throwsA(isA<DocumentException>()),
      );
    });

    test('rejects a truncated download', () {
      expect(
        () => DocumentValidator.validate(
          bytes: pdf,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
          declaredSizeBytes: 99999,
        ),
        throwsA(isA<DocumentException>()),
      );
    });

    test('enforces a supplied SHA-256', () {
      final correct = sha256.convert(pdf).toString();
      expect(
        () => DocumentValidator.validate(
          bytes: pdf,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
          expectedSha256: correct,
        ),
        returnsNormally,
      );
      expect(
        () => DocumentValidator.validate(
          bytes: pdf,
          declaredType: DocumentType.pdf,
          maxSizeBytes: 1024,
          expectedSha256: 'deadbeef',
        ),
        throwsA(isA<DocumentException>()),
      );
    });

    test('allows signature-free formats through', () {
      expect(
        () => DocumentValidator.validate(
          bytes: Uint8List.fromList(utf8.encode('Hello world')),
          declaredType: DocumentType.text,
          maxSizeBytes: 1024,
          contentType: 'text/plain',
        ),
        returnsNormally,
      );
    });
  });

  group('Redaction', () {
    test('masks bearer tokens', () {
      final result = Redaction.text('Authorization: Bearer abc123DEF456ghi789');
      expect(result, contains(Redaction.mask));
      expect(result, isNot(contains('abc123DEF456ghi789')));
    });

    test('masks plugin-issued tokens anywhere in a line', () {
      final result =
          Redaction.text('stored credentials wpm_at_9f2c8b1d4e6a for agent');
      expect(result, isNot(contains('wpm_at_9f2c8b1d4e6a')));
    });

    test('masks pairing codes', () {
      expect(Redaction.text('code is K3F-92H-QD7'), isNot(contains('K3F-92H')));
    });

    test('masks sensitive context keys wholesale', () {
      final result = Redaction.map(<String, Object?>{
        'agent': 'Warehouse PC',
        'token': 'super-secret-value',
        'nested': <String, Object?>{'refresh_token': 'another-secret'},
      });
      expect(result['agent'], 'Warehouse PC');
      expect(result['token'], Redaction.mask);
      expect(
        (result['nested']! as Map<String, Object?>)['refresh_token'],
        Redaction.mask,
      );
    });

    test('strips credentials and secret query values from URLs', () {
      final result = Redaction.url(
        'https://user:pass@store.example/doc?token=abcdef123456&page=2',
      );
      expect(result, isNot(contains('pass')));
      expect(result, isNot(contains('abcdef123456')));
      expect(result, contains('page=2'));
    });
  });
}
