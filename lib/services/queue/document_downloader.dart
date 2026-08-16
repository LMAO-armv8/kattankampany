import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/config/app_paths.dart';
import '../../core/config/settings_repository.dart';
import '../../core/errors/app_exception.dart';
import '../../core/errors/error_codes.dart';
import '../../core/logging/app_logger.dart';
import '../../core/logging/log_level.dart';
import '../../core/security/document_validator.dart';
import '../../features/print_queue/domain/print_job.dart';
import '../../features/printing/domain/print_document.dart';
import '../api/agent_session.dart';

/// The bytes of a job's document, plus where they were written on disk.
class ResolvedDocument {
  const ResolvedDocument({
    required this.bytes,
    required this.filePath,
    required this.type,
  });

  final Uint8List bytes;
  final String filePath;
  final DocumentType type;

  int get sizeBytes => bytes.length;
}

/// Fetches and validates the document for a job.
///
/// Every path into this class ends with [DocumentValidator.validate]. Nothing
/// reaches a printer that has not passed an origin check, a size cap, a
/// content-type check, a magic-byte check, and — when the server supplies one —
/// a SHA-256 comparison.
class DocumentDownloader {
  DocumentDownloader({
    required AgentSession session,
    required SettingsRepository settings,
    required AppPaths paths,
    AppLogger? logger,
  })  : _session = session,
        _settings = settings,
        _paths = paths,
        _logger = logger;

  final AgentSession _session;
  final SettingsRepository _settings;
  final AppPaths _paths;
  final AppLogger? _logger;

  Future<ResolvedDocument> resolve(
    PrintJob job, {
    Uint8List? inlineData,
  }) async {
    final maxSize = _settings.current.maxDocumentSizeBytes;

    if (job.documentExpiresAt != null &&
        DateTime.now().isAfter(job.documentExpiresAt!)) {
      throw const DocumentException(
        userMessage: 'The document link from your store has expired. '
            'The job will be requested again.',
        code: ErrorCodes.documentExpired,
      );
    }

    // 1 — an already-downloaded copy from a previous attempt.
    final cachedPath = job.localFilePath;
    if (cachedPath != null && File(cachedPath).existsSync()) {
      try {
        final bytes = await File(cachedPath).readAsBytes();
        DocumentValidator.validate(
          bytes: bytes,
          declaredType: job.documentType,
          maxSizeBytes: maxSize,
          expectedSha256: job.documentSha256,
        );
        _logger?.debug(
          LogCategory.document,
          'Reusing previously downloaded document',
          context: <String, Object?>{'job_id': job.id, 'bytes': bytes.length},
        );
        return ResolvedDocument(
          bytes: bytes,
          filePath: cachedPath,
          type: job.documentType,
        );
      } catch (_) {
        // A bad cache entry is not a job failure — fall through and re-fetch.
        try {
          await File(cachedPath).delete();
        } catch (_) {/* ignore */}
      }
    }

    // 2 — the listing carried the payload inline.
    if (inlineData != null && inlineData.isNotEmpty) {
      DocumentValidator.validate(
        bytes: inlineData,
        declaredType: job.documentType,
        maxSizeBytes: maxSize,
        expectedSha256: job.documentSha256,
        declaredSizeBytes: job.documentSizeBytes,
      );
      final path = await _write(job, inlineData);
      _logger?.info(
        LogCategory.document,
        'Using inline document payload',
        context: <String, Object?>{
          'job_id': job.id,
          'bytes': inlineData.length,
        },
      );
      return ResolvedDocument(
        bytes: inlineData,
        filePath: path,
        type: job.documentType,
      );
    }

    // 3 — download from the store.
    final url = job.documentUrl;
    if (url == null || url.isEmpty) {
      throw const DocumentException(
        userMessage:
            'Your store did not provide a document for this job to print.',
        code: ErrorCodes.documentInvalid,
        retryable: false,
      );
    }

    final started = DateTime.now();
    final result = await _session.api.downloadDocument(url: url);

    DocumentValidator.validate(
      bytes: result.bytes,
      declaredType: job.documentType,
      maxSizeBytes: maxSize,
      contentType: result.contentType,
      expectedSha256: job.documentSha256,
      declaredSizeBytes: job.documentSizeBytes,
    );

    final path = await _write(job, result.bytes);
    _logger?.info(
      LogCategory.document,
      'Document downloaded',
      context: <String, Object?>{
        'job_id': job.id,
        'bytes': result.bytes.length,
        'content_type': result.contentType,
        'ms': DateTime.now().difference(started).inMilliseconds,
      },
    );

    return ResolvedDocument(
      bytes: result.bytes,
      filePath: path,
      type: job.documentType,
    );
  }

  /// Writes the payload into the transient documents folder.
  ///
  /// The filename is derived from the job id, never from the server-supplied
  /// name, so a hostile `../../` filename cannot escape the folder. The
  /// server's name is only ever used as the spooler's document title.
  Future<String> _write(PrintJob job, Uint8List bytes) async {
    final filename = '${job.id}.${job.documentType.fileExtension}';
    final file = File(p.join(_paths.documentsDir.path, filename));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Removes a job's temporary file once it is no longer needed.
  Future<void> discard(PrintJob job) async {
    final path = job.localFilePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      _logger?.debug(
        LogCategory.document,
        'Could not delete temporary document',
        context: <String, Object?>{'job_id': job.id, 'error': e.toString()},
      );
    }
  }
}
