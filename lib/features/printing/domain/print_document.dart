import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

/// Generic document types the print pipeline understands.
/// Nothing here is vendor- or carrier-specific.
enum DocumentType {
  @JsonValue('pdf')
  pdf,
  @JsonValue('png')
  png,
  @JsonValue('jpeg')
  jpeg,
  @JsonValue('html')
  html,
  @JsonValue('text')
  text,

  /// Pre-rendered printer language (ESC/POS, ZPL, PCL, PostScript…). Passed to
  /// the device untouched via the RAW spooler path.
  @JsonValue('raw')
  raw;

  String get label => switch (this) {
        DocumentType.pdf => 'PDF',
        DocumentType.png => 'PNG image',
        DocumentType.jpeg => 'JPEG image',
        DocumentType.html => 'HTML',
        DocumentType.text => 'Plain text',
        DocumentType.raw => 'Raw printer data',
      };

  bool get isImage => this == DocumentType.png || this == DocumentType.jpeg;

  /// Content types the server may legitimately return for this document type.
  List<String> get acceptedContentTypes => switch (this) {
        DocumentType.pdf => const <String>['application/pdf'],
        DocumentType.png => const <String>['image/png'],
        DocumentType.jpeg => const <String>['image/jpeg', 'image/jpg'],
        DocumentType.html => const <String>['text/html', 'application/xhtml+xml'],
        DocumentType.text => const <String>['text/plain'],
        DocumentType.raw => const <String>[
            'application/octet-stream',
            'application/vnd.escpos',
            'application/x-pcl',
            'application/postscript',
          ],
      };

  String get fileExtension => switch (this) {
        DocumentType.pdf => 'pdf',
        DocumentType.png => 'png',
        DocumentType.jpeg => 'jpg',
        DocumentType.html => 'html',
        DocumentType.text => 'txt',
        DocumentType.raw => 'bin',
      };

  static DocumentType fromWire(String? value) {
    switch (value?.toLowerCase().trim()) {
      case 'pdf':
      case 'application/pdf':
        return DocumentType.pdf;
      case 'png':
      case 'image/png':
        return DocumentType.png;
      case 'jpg':
      case 'jpeg':
      case 'image/jpeg':
        return DocumentType.jpeg;
      case 'html':
      case 'text/html':
        return DocumentType.html;
      case 'text':
      case 'txt':
      case 'text/plain':
        return DocumentType.text;
      case 'raw':
      case 'escpos':
      case 'zpl':
      case 'binary':
        return DocumentType.raw;
      default:
        return DocumentType.pdf;
    }
  }

  /// Best-effort detection from the first bytes of a payload. Used as a
  /// cross-check against the declared type — a mismatch fails the job rather
  /// than being silently corrected.
  static DocumentType? sniff(Uint8List bytes) {
    if (bytes.length < 4) return null;
    // %PDF
    if (bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      return DocumentType.pdf;
    }
    // \x89PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return DocumentType.png;
    }
    // JPEG SOI + APPn
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return DocumentType.jpeg;
    }
    return null;
  }
}

/// Where the bytes of a job's document come from and how to validate them.
class PrintDocument {
  const PrintDocument({
    required this.type,
    this.url,
    this.inlineData,
    this.filename,
    this.sha256,
    this.sizeBytes,
    this.expiresAt,
  });

  final DocumentType type;

  /// Absolute HTTPS URL on the paired store. Mutually exclusive with
  /// [inlineData] in practice; if both are present, inline wins (no network).
  final String? url;

  /// Base64-decoded payload delivered inline in the job listing.
  final Uint8List? inlineData;

  final String? filename;
  final String? sha256;
  final int? sizeBytes;
  final DateTime? expiresAt;

  bool get hasInlineData => inlineData != null && inlineData!.isNotEmpty;
  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  String get safeFilename {
    final raw = filename;
    if (raw == null || raw.isEmpty) return 'document.${type.fileExtension}';
    // Strip any path component; a server-supplied name must never escape the
    // documents directory.
    final base = raw.split(RegExp(r'[\\/]')).last;
    final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'document.${type.fileExtension}' : cleaned;
  }

  static PrintDocument fromJson(Map<String, dynamic> json) {
    Uint8List? inline;
    final raw = json['inline'];
    if (raw is String && raw.isNotEmpty) {
      try {
        inline = base64Decode(raw);
      } catch (_) {
        inline = null;
      }
    }
    return PrintDocument(
      type: DocumentType.fromWire(json['type'] as String?),
      url: json['url'] as String?,
      inlineData: inline,
      filename: json['filename'] as String?,
      sha256: json['sha256'] as String?,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.tryParse(json['expires_at'] as String)?.toLocal(),
    );
  }
}
