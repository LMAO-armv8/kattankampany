import 'package:uuid/uuid.dart';

import '../../../features/print_queue/domain/print_job.dart';
import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';

/// A job as delivered by `GET /print-jobs`.
///
/// Every field except `id` is optional — the agent has to cope with a plugin
/// that sends the bare minimum, and with a newer plugin that sends more than
/// this build knows about.
class RemotePrintJob {
  const RemotePrintJob({
    required this.serverJobId,
    required this.document,
    this.orderId,
    this.orderReference,
    this.requestedPrinterKey,
    this.allowFallback = false,
    this.profilePayload,
    this.priority = 0,
    this.copies = 1,
    this.createdAt,
    this.metadata = const <String, dynamic>{},
  });

  final String serverJobId;
  final String? orderId;
  final String? orderReference;
  final PrintDocument document;
  final String? requestedPrinterKey;
  final bool allowFallback;
  final Map<String, dynamic>? profilePayload;
  final int priority;
  final int copies;
  final DateTime? createdAt;
  final Map<String, dynamic> metadata;

  static RemotePrintJob fromJson(Map<String, dynamic> json) {
    final documentRaw = json['document'];
    final printerRaw = json['printer'];
    final profileRaw = json['profile'];
    final metadataRaw = json['metadata'];

    final document = documentRaw is Map
        ? PrintDocument.fromJson(documentRaw.cast<String, dynamic>())
        : const PrintDocument(type: DocumentType.pdf);

    final profileMap =
        profileRaw is Map ? profileRaw.cast<String, dynamic>() : null;

    return RemotePrintJob(
      serverJobId: (json['id'] ?? json['job_id'] ?? '').toString(),
      orderId: json['order_id']?.toString(),
      orderReference: json['order_reference'] as String? ??
          (json['order_id'] == null ? null : '#${json['order_id']}'),
      document: document,
      requestedPrinterKey: printerRaw is Map
          ? printerRaw['printer_key'] as String?
          : json['printer_key'] as String?,
      allowFallback: printerRaw is Map
          ? printerRaw['allow_fallback'] == true
          : json['allow_fallback'] == true,
      profilePayload: profileMap,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      copies: ((profileMap?['copies'] as num?)?.toInt() ??
              (json['copies'] as num?)?.toInt() ??
              1)
          .clamp(1, 100),
      createdAt: _parseTimestamp(json['created_at']),
      metadata: metadataRaw is Map
          ? metadataRaw.cast<String, dynamic>()
          : const <String, dynamic>{},
    );
  }

  /// Parses a server timestamp, rejecting the Unix epoch.
  ///
  /// A store whose schema defaults an unset datetime column to
  /// `1970-01-01 00:00:00` serialises that as a real timestamp, and taking it at
  /// face value made freshly queued jobs read as decades old. No print job is
  /// legitimately older than the software, so anything at or before 1971 is
  /// treated as absent and the local clock is used instead.
  static DateTime? _parseTimestamp(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    if (parsed.isBefore(DateTime.utc(1971))) return null;
    return parsed.toLocal();
  }

  /// Converts to the local queue representation.
  ///
  /// [maxAttempts] is snapshotted at insert time so changing the retry setting
  /// later does not retroactively rewrite the ceiling of jobs already queued.
  PrintJob toPrintJob({
    required String storeId,
    required int maxAttempts,
    PrintProfile? baseProfile,
    Uuid uuid = const Uuid(),
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final profile = PrintProfile.fromServerPayload(
      profilePayload,
      base: baseProfile,
    );
    return PrintJob(
      id: uuid.v4(),
      storeId: storeId,
      serverJobId: serverJobId,
      orderId: orderId,
      orderReference: orderReference,
      documentType: document.type,
      documentUrl: document.url,
      documentFilename: document.filename,
      documentSha256: document.sha256,
      documentSizeBytes: document.sizeBytes,
      documentExpiresAt: document.expiresAt,
      requestedPrinterKey: requestedPrinterKey,
      allowFallback: allowFallback,
      profile: profile.copyWith(copies: copies),
      copies: copies,
      priority: priority,
      status: PrintJobStatus.queued,
      maxAttempts: maxAttempts,
      createdAt: createdAt ?? timestamp,
      metadata: metadata,
    );
  }

  /// True when the listing carried the payload inline, so no second request is
  /// needed to fetch the document.
  bool get hasInlineDocument => document.hasInlineData;
}

/// Response to `POST /print-jobs/{id}/claim`.
class ClaimResult {
  const ClaimResult({
    required this.claimed,
    this.job,
    this.claimedUntil,
    this.reason,
  });

  final bool claimed;
  final RemotePrintJob? job;
  final DateTime? claimedUntil;

  /// Populated when [claimed] is false — usually "already claimed".
  final String? reason;

  static ClaimResult fromJson(Map<String, dynamic> json) => ClaimResult(
        claimed: true,
        job: RemotePrintJob.fromJson(json),
        claimedUntil: json['claimed_until'] == null
            ? null
            : DateTime.tryParse(json['claimed_until'] as String)?.toLocal(),
      );

  static const ClaimResult takenByAnotherAgent = ClaimResult(
    claimed: false,
    reason: 'Already claimed by another agent',
  );
}
