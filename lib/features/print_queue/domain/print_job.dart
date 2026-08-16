import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';

import '../../printers/domain/print_profile.dart';
import '../../printing/domain/print_document.dart';

part 'print_job.freezed.dart';
part 'print_job.g.dart';

/// Local lifecycle of a job. See `docs/DATABASE_SCHEMA.md` for the state machine.
enum PrintJobStatus {
  /// Known locally, waiting to be picked up (or waiting out a retry delay).
  @JsonValue('queued')
  queued,

  /// Claimed on the server; this agent owns it.
  @JsonValue('claimed')
  claimed,

  /// Fetching and validating the document.
  @JsonValue('downloading')
  downloading,

  /// Handed to the spooler. A lease is held while in this state.
  @JsonValue('printing')
  printing,

  @JsonValue('completed')
  completed,

  @JsonValue('failed')
  failed,

  @JsonValue('cancelled')
  cancelled,

  /// Was `printing` when the process stopped. Requires an operator decision so
  /// the agent never reprints a document that may already be on paper.
  @JsonValue('interrupted')
  interrupted;

  bool get isTerminal =>
      this == PrintJobStatus.completed ||
      this == PrintJobStatus.cancelled ||
      this == PrintJobStatus.failed;

  bool get isActive =>
      this == PrintJobStatus.claimed ||
      this == PrintJobStatus.downloading ||
      this == PrintJobStatus.printing;

  bool get needsAttention =>
      this == PrintJobStatus.failed || this == PrintJobStatus.interrupted;

  String get label => switch (this) {
        PrintJobStatus.queued => 'Queued',
        PrintJobStatus.claimed => 'Claimed',
        PrintJobStatus.downloading => 'Downloading',
        PrintJobStatus.printing => 'Printing',
        PrintJobStatus.completed => 'Completed',
        PrintJobStatus.failed => 'Failed',
        PrintJobStatus.cancelled => 'Cancelled',
        PrintJobStatus.interrupted => 'Needs review',
      };

  static PrintJobStatus fromWire(String? value) {
    for (final status in PrintJobStatus.values) {
      if (status.name == value) return status;
    }
    return PrintJobStatus.queued;
  }
}

/// One unit of work in the local queue. Persisted; survives restarts.
@freezed
class PrintJob with _$PrintJob {
  const factory PrintJob({
    /// Local UUID.
    required String id,

    required String storeId,

    /// The server's job identifier. `(storeId, serverJobId)` is UNIQUE — this
    /// is the primary duplicate-print guard.
    required String serverJobId,

    String? orderId,
    String? orderReference,

    @Default(DocumentType.pdf) DocumentType documentType,
    String? documentUrl,
    String? documentFilename,
    String? documentSha256,
    int? documentSizeBytes,
    DateTime? documentExpiresAt,
    String? localFilePath,

    /// What the server asked for. Null means "agent decides".
    String? requestedPrinterKey,

    /// What the agent actually used.
    String? resolvedPrinterKey,

    /// Whether the server permits printing to a different device when the
    /// requested one is unavailable. Defaults to false: never substitute.
    @Default(false) bool allowFallback,

    @Default(PrintProfile.a4Default) PrintProfile profile,
    @Default(1) int copies,
    @Default(0) int priority,
    @Default(PrintJobStatus.queued) PrintJobStatus status,
    @Default(0) int attemptCount,
    @Default(4) int maxAttempts,
    DateTime? nextAttemptAt,
    String? leaseOwner,
    DateTime? leaseExpiresAt,
    int? spoolerJobId,
    String? errorCode,
    String? errorMessage,
    String? errorDetail,
    required DateTime createdAt,
    DateTime? claimedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    DateTime? reportedAt,
    @Default(<String, dynamic>{}) Map<String, dynamic> metadata,
  }) = _PrintJob;

  const PrintJob._();

  factory PrintJob.fromJson(Map<String, dynamic> json) =>
      _$PrintJobFromJson(json);

  bool get hasAttemptsRemaining => attemptCount < maxAttempts;

  bool get isReady =>
      (status == PrintJobStatus.queued || status == PrintJobStatus.claimed) &&
      (nextAttemptAt == null || !nextAttemptAt!.isAfter(DateTime.now()));

  bool get hasLiveLease =>
      leaseExpiresAt != null && leaseExpiresAt!.isAfter(DateTime.now());

  Duration? get printDuration => (startedAt != null && completedAt != null)
      ? completedAt!.difference(startedAt!)
      : null;

  String get displayReference =>
      orderReference ?? (orderId != null ? '#$orderId' : 'Job $serverJobId');

  /// Reconstructs the document descriptor. Inline payloads are not persisted —
  /// once downloaded, [localFilePath] is the source of truth.
  PrintDocument get document => PrintDocument(
        type: documentType,
        url: documentUrl,
        filename: documentFilename,
        sha256: documentSha256,
        sizeBytes: documentSizeBytes,
        expiresAt: documentExpiresAt,
      );

  // ---------------------------------------------------------------------
  // Database mapping
  // ---------------------------------------------------------------------

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'id': id,
        'store_id': storeId,
        'server_job_id': serverJobId,
        'order_id': orderId,
        'order_reference': orderReference,
        'document_type': documentType.name,
        'document_url': documentUrl,
        'document_filename': documentFilename,
        'document_sha256': documentSha256,
        'document_size_bytes': documentSizeBytes,
        'document_expires_at': documentExpiresAt?.millisecondsSinceEpoch,
        'local_file_path': localFilePath,
        'requested_printer_key': requestedPrinterKey,
        'resolved_printer_key': resolvedPrinterKey,
        'allow_fallback': allowFallback ? 1 : 0,
        'profile_json': jsonEncode(profile.toJson()),
        'copies': copies,
        'priority': priority,
        'status': status.name,
        'attempt_count': attemptCount,
        'max_attempts': maxAttempts,
        'next_attempt_at': nextAttemptAt?.millisecondsSinceEpoch,
        'lease_owner': leaseOwner,
        'lease_expires_at': leaseExpiresAt?.millisecondsSinceEpoch,
        'spooler_job_id': spoolerJobId,
        'error_code': errorCode,
        'error_message': errorMessage,
        'error_detail': errorDetail,
        'created_at': createdAt.millisecondsSinceEpoch,
        'claimed_at': claimedAt?.millisecondsSinceEpoch,
        'started_at': startedAt?.millisecondsSinceEpoch,
        'completed_at': completedAt?.millisecondsSinceEpoch,
        'reported_at': reportedAt?.millisecondsSinceEpoch,
        'metadata_json': jsonEncode(metadata),
      };

  static PrintJob fromDatabaseRow(Map<String, Object?> row) {
    PrintProfile profile = PrintProfile.defaultProfile();
    final profileRaw = row['profile_json'] as String?;
    if (profileRaw != null && profileRaw.isNotEmpty && profileRaw != '{}') {
      try {
        profile = PrintProfile.fromJson(
          (jsonDecode(profileRaw) as Map).cast<String, dynamic>(),
        );
      } catch (_) {
        // A profile that cannot be decoded must not strand the job.
        profile = PrintProfile.defaultProfile();
      }
    }

    Map<String, dynamic> metadata = <String, dynamic>{};
    final metaRaw = row['metadata_json'] as String?;
    if (metaRaw != null && metaRaw.isNotEmpty && metaRaw != '{}') {
      try {
        metadata = (jsonDecode(metaRaw) as Map).cast<String, dynamic>();
      } catch (_) {
        metadata = <String, dynamic>{};
      }
    }

    DateTime? at(String column) {
      final value = row[column] as int?;
      return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
    }

    return PrintJob(
      id: row['id']! as String,
      storeId: row['store_id']! as String,
      serverJobId: row['server_job_id']! as String,
      orderId: row['order_id'] as String?,
      orderReference: row['order_reference'] as String?,
      documentType: DocumentType.fromWire(row['document_type'] as String?),
      documentUrl: row['document_url'] as String?,
      documentFilename: row['document_filename'] as String?,
      documentSha256: row['document_sha256'] as String?,
      documentSizeBytes: row['document_size_bytes'] as int?,
      documentExpiresAt: at('document_expires_at'),
      localFilePath: row['local_file_path'] as String?,
      requestedPrinterKey: row['requested_printer_key'] as String?,
      resolvedPrinterKey: row['resolved_printer_key'] as String?,
      allowFallback: (row['allow_fallback'] as int? ?? 0) == 1,
      profile: profile,
      copies: row['copies'] as int? ?? 1,
      priority: row['priority'] as int? ?? 0,
      status: PrintJobStatus.fromWire(row['status'] as String?),
      attemptCount: row['attempt_count'] as int? ?? 0,
      maxAttempts: row['max_attempts'] as int? ?? 4,
      nextAttemptAt: at('next_attempt_at'),
      leaseOwner: row['lease_owner'] as String?,
      leaseExpiresAt: at('lease_expires_at'),
      spoolerJobId: row['spooler_job_id'] as int?,
      errorCode: row['error_code'] as String?,
      errorMessage: row['error_message'] as String?,
      errorDetail: row['error_detail'] as String?,
      createdAt: at('created_at') ?? DateTime.now(),
      claimedAt: at('claimed_at'),
      startedAt: at('started_at'),
      completedAt: at('completed_at'),
      reportedAt: at('reported_at'),
      metadata: metadata,
    );
  }
}

/// Aggregate counters shown on the dashboard and sent in heartbeats.
class QueueCounters {
  const QueueCounters({
    this.pending = 0,
    this.printing = 0,
    this.completed = 0,
    this.failed = 0,
    this.interrupted = 0,
  });

  final int pending;
  final int printing;
  final int completed;
  final int failed;
  final int interrupted;

  int get total => pending + printing + completed + failed + interrupted;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pending': pending,
        'printing': printing,
        'completed': completed,
        'failed': failed,
        if (interrupted > 0) 'interrupted': interrupted,
      };

  static const QueueCounters empty = QueueCounters();
}
