import 'dart:typed_data';

import '../../printers/domain/print_profile.dart';
import 'print_document.dart';

/// Everything a [PrintStrategy] needs to put one document on paper.
///
/// The bytes are already resolved and validated by the time a request is built —
/// strategies never download anything.
class PrintRequest {
  const PrintRequest({
    required this.jobId,
    required this.printerKey,
    required this.documentType,
    required this.data,
    required this.profile,
    required this.documentTitle,
    this.localFilePath,
    this.copies = 1,
  });

  final String jobId;
  final String printerKey;
  final DocumentType documentType;

  /// The document payload.
  final Uint8List data;

  /// Where [data] was written on disk. Strategies that shell out to an external
  /// renderer need a real file; strategies that spool bytes do not.
  final String? localFilePath;

  final PrintProfile profile;

  /// Shown in the Windows print queue, so an operator can tell jobs apart.
  final String documentTitle;

  final int copies;

  PrintRequest copyWith({
    String? printerKey,
    DocumentType? documentType,
    Uint8List? data,
    String? localFilePath,
    PrintProfile? profile,
    String? documentTitle,
    int? copies,
  }) =>
      PrintRequest(
        jobId: jobId,
        printerKey: printerKey ?? this.printerKey,
        documentType: documentType ?? this.documentType,
        data: data ?? this.data,
        localFilePath: localFilePath ?? this.localFilePath,
        profile: profile ?? this.profile,
        documentTitle: documentTitle ?? this.documentTitle,
        copies: copies ?? this.copies,
      );
}

/// The outcome of handing a document to the printing subsystem.
///
/// `success == true` means the Windows spooler accepted and closed the document.
/// See `docs/PRINT_PIPELINE.md` §6 for exactly what that does and does not
/// guarantee.
class PrintResult {
  const PrintResult({
    required this.success,
    this.spoolerJobId,
    this.strategyName,
    this.bytesSent,
    this.duration,
    this.errorCode,
    this.errorMessage,
    this.errorDetail,
  });

  const PrintResult.ok({
    int? spoolerJobId,
    String? strategyName,
    int? bytesSent,
    Duration? duration,
  }) : this(
          success: true,
          spoolerJobId: spoolerJobId,
          strategyName: strategyName,
          bytesSent: bytesSent,
          duration: duration,
        );

  const PrintResult.failed({
    required String errorCode,
    required String errorMessage,
    String? errorDetail,
    String? strategyName,
    Duration? duration,
  }) : this(
          success: false,
          errorCode: errorCode,
          errorMessage: errorMessage,
          errorDetail: errorDetail,
          strategyName: strategyName,
          duration: duration,
        );

  final bool success;

  /// The Windows spool job id, when the path used exposes one.
  final int? spoolerJobId;
  final String? strategyName;
  final int? bytesSent;
  final Duration? duration;
  final String? errorCode;
  final String? errorMessage;
  final String? errorDetail;
}
