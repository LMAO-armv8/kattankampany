import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../features/printing/domain/print_document.dart';
import '../errors/app_exception.dart';
import '../errors/error_codes.dart';

/// Checks a downloaded payload before it is allowed anywhere near a printer.
///
/// A print agent is, structurally, a program that fetches remote data and feeds
/// it to a device driver. These checks are what stop that from being a liability:
/// nothing is executed, nothing oversized is buffered, and a payload whose
/// content contradicts its declaration is refused rather than guessed at.
abstract final class DocumentValidator {
  /// Validates [bytes] against what the job said the document would be.
  ///
  /// Throws [DocumentException] on any mismatch.
  static void validate({
    required Uint8List bytes,
    required DocumentType declaredType,
    required int maxSizeBytes,
    String? contentType,
    String? expectedSha256,
    int? declaredSizeBytes,
  }) {
    if (bytes.isEmpty) {
      throw const DocumentException(
        userMessage: 'The document your store supplied was empty.',
        code: ErrorCodes.documentInvalid,
        retryable: true,
      );
    }

    if (bytes.length > maxSizeBytes) {
      throw DocumentException(
        userMessage: 'The document is too large to print '
            '(${_mb(bytes.length)} MB). Increase the limit in Settings if this '
            'is expected.',
        code: ErrorCodes.documentTooLarge,
        technicalDetail:
            '${bytes.length} bytes exceeds the $maxSizeBytes byte cap.',
        retryable: false,
      );
    }

    if (declaredSizeBytes != null &&
        declaredSizeBytes > 0 &&
        declaredSizeBytes != bytes.length) {
      throw DocumentException(
        userMessage:
            'The document was not downloaded completely. It will be retried.',
        code: ErrorCodes.documentDownload,
        technicalDetail: 'Expected $declaredSizeBytes bytes, '
            'received ${bytes.length}.',
      );
    }

    if (contentType != null && contentType.isNotEmpty) {
      final normalised = contentType.split(';').first.trim().toLowerCase();
      final accepted = declaredType.acceptedContentTypes;
      if (!accepted.contains(normalised)) {
        // An HTML error page served where a PDF was expected is the classic
        // symptom of an expired or unauthenticated document link.
        throw DocumentException(
          userMessage: normalised.startsWith('text/html')
              ? 'Your store returned a web page instead of the document. The '
                  'document link may have expired.'
              : 'Your store returned an unexpected file type for this document.',
          code: ErrorCodes.documentInvalid,
          technicalDetail: 'Content-Type "$normalised" does not match declared '
              'type "${declaredType.name}" (accepted: ${accepted.join(', ')}).',
        );
      }
    }

    // Magic-byte cross-check. Only applied to formats with an unambiguous
    // signature; text, HTML and raw printer data legitimately have none.
    final sniffed = DocumentType.sniff(bytes);
    if (sniffed != null &&
        _hasSignature(declaredType) &&
        sniffed != declaredType) {
      throw DocumentException(
        userMessage:
            'The document does not match the file type your store declared.',
        code: ErrorCodes.documentInvalid,
        technicalDetail: 'Declared ${declaredType.name}, '
            'content looks like ${sniffed.name}.',
        retryable: false,
      );
    }
    if (sniffed == null && _hasSignature(declaredType)) {
      throw DocumentException(
        userMessage: 'The document appears to be damaged and cannot be printed.',
        code: ErrorCodes.documentInvalid,
        technicalDetail:
            'No recognisable ${declaredType.name} signature in the payload.',
      );
    }

    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      final actual = sha256.convert(bytes).toString();
      if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
        throw DocumentException(
          userMessage:
              'The document failed its integrity check and was not printed.',
          code: ErrorCodes.documentInvalid,
          technicalDetail:
              'SHA-256 mismatch: expected $expectedSha256, got $actual.',
        );
      }
    }
  }

  /// Formats that carry a reliable magic number.
  static bool _hasSignature(DocumentType type) =>
      type == DocumentType.pdf ||
      type == DocumentType.png ||
      type == DocumentType.jpeg;

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  /// Convenience used by the downloader when the server supplies a checksum.
  static String hash(Uint8List bytes) => sha256.convert(bytes).toString();
}
