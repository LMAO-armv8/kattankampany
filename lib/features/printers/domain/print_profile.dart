import 'package:freezed_annotation/freezed_annotation.dart';

part 'print_profile.freezed.dart';
part 'print_profile.g.dart';

/// Named page sizes the agent understands. `custom` uses [PrintProfile.widthMm]
/// and [PrintProfile.heightMm]. Deliberately generic — no vendor media names.
enum PaperSize {
  @JsonValue('a4')
  a4(210, 297),
  @JsonValue('a5')
  a5(148, 210),
  @JsonValue('a6')
  a6(105, 148),
  @JsonValue('letter')
  letter(215.9, 279.4),
  @JsonValue('legal')
  legal(215.9, 355.6),
  @JsonValue('4x6')
  label4x6(101.6, 152.4),
  @JsonValue('80mm')
  roll80mm(80, 297),
  @JsonValue('58mm')
  roll58mm(58, 297),
  @JsonValue('custom')
  custom(null, null);

  const PaperSize(this.defaultWidthMm, this.defaultHeightMm);

  final double? defaultWidthMm;
  final double? defaultHeightMm;

  String get label => switch (this) {
        PaperSize.a4 => 'A4',
        PaperSize.a5 => 'A5',
        PaperSize.a6 => 'A6',
        PaperSize.letter => 'Letter',
        PaperSize.legal => 'Legal',
        PaperSize.label4x6 => '4 × 6 in',
        PaperSize.roll80mm => '80 mm roll',
        PaperSize.roll58mm => '58 mm roll',
        PaperSize.custom => 'Custom',
      };

  static PaperSize fromWire(String? value) {
    if (value == null) return PaperSize.a4;
    final normalised = value.toLowerCase().trim();
    for (final size in PaperSize.values) {
      if (size.name.toLowerCase() == normalised) return size;
    }
    return switch (normalised) {
      'a4' => PaperSize.a4,
      'a5' => PaperSize.a5,
      'a6' => PaperSize.a6,
      'letter' => PaperSize.letter,
      'legal' => PaperSize.legal,
      '4x6' || '4X6' || 'label4x6' => PaperSize.label4x6,
      '80mm' || 'roll80mm' => PaperSize.roll80mm,
      '58mm' || 'roll58mm' => PaperSize.roll58mm,
      _ => PaperSize.custom,
    };
  }

  String get wireValue => switch (this) {
        PaperSize.label4x6 => '4x6',
        PaperSize.roll80mm => '80mm',
        PaperSize.roll58mm => '58mm',
        _ => name,
      };
}

enum PageOrientation {
  @JsonValue('portrait')
  portrait,
  @JsonValue('landscape')
  landscape;

  static PageOrientation fromWire(String? value) =>
      value?.toLowerCase() == 'landscape'
          ? PageOrientation.landscape
          : PageOrientation.portrait;
}

/// How the document content is mapped onto the page.
enum PrintScaling {
  /// Print at the document's own size, clipping if it overflows.
  @JsonValue('none')
  none,

  /// Scale down (never up) to fit inside the printable area, preserving aspect.
  @JsonValue('fit')
  fit,

  /// Scale to cover the printable area, preserving aspect, cropping overflow.
  @JsonValue('fill')
  fill,

  /// 100% — identical to [none] but explicit about intent.
  @JsonValue('actual')
  actual;

  static PrintScaling fromWire(String? value) {
    switch (value?.toLowerCase()) {
      case 'none':
        return PrintScaling.none;
      case 'fill':
        return PrintScaling.fill;
      case 'actual':
        return PrintScaling.actual;
      default:
        return PrintScaling.fit;
    }
  }
}

enum PrintQuality {
  @JsonValue('draft')
  draft,
  @JsonValue('normal')
  normal,
  @JsonValue('high')
  high;

  static PrintQuality fromWire(String? value) => switch (value?.toLowerCase()) {
        'draft' => PrintQuality.draft,
        'high' => PrintQuality.high,
        _ => PrintQuality.normal,
      };
}

enum DuplexMode {
  @JsonValue('simplex')
  simplex,
  @JsonValue('long_edge')
  longEdge,
  @JsonValue('short_edge')
  shortEdge;

  static DuplexMode fromWire(String? value) => switch (value?.toLowerCase()) {
        'long_edge' || 'longedge' => DuplexMode.longEdge,
        'short_edge' || 'shortedge' => DuplexMode.shortEdge,
        _ => DuplexMode.simplex,
      };

  String get wireValue => switch (this) {
        DuplexMode.simplex => 'simplex',
        DuplexMode.longEdge => 'long_edge',
        DuplexMode.shortEdge => 'short_edge',
      };
}

/// Which [PrintStrategy] implementation should handle the job.
/// `auto` lets the registry decide from the document type.
enum PrintStrategyType {
  @JsonValue('auto')
  auto,
  @JsonValue('spooler')
  spooler,
  @JsonValue('raw')
  raw,
  @JsonValue('pdf')
  pdf,
  @JsonValue('image')
  image,
  @JsonValue('text')
  text,
  @JsonValue('html')
  html,
  @JsonValue('escpos')
  escpos;

  static PrintStrategyType fromWire(String? value) =>
      switch (value?.toLowerCase()) {
        'spooler' => PrintStrategyType.spooler,
        'raw' => PrintStrategyType.raw,
        'pdf' => PrintStrategyType.pdf,
        'image' => PrintStrategyType.image,
        'text' => PrintStrategyType.text,
        'html' => PrintStrategyType.html,
        'escpos' || 'esc_pos' || 'esc/pos' => PrintStrategyType.escpos,
        _ => PrintStrategyType.auto,
      };
}

@freezed
class PageMargins with _$PageMargins {
  const factory PageMargins({
    @Default(0) double topMm,
    @Default(0) double rightMm,
    @Default(0) double bottomMm,
    @Default(0) double leftMm,
  }) = _PageMargins;

  const PageMargins._();

  factory PageMargins.fromJson(Map<String, dynamic> json) =>
      _$PageMarginsFromJson(json);

  factory PageMargins.all(double mm) => PageMargins(
        topMm: mm,
        rightMm: mm,
        bottomMm: mm,
        leftMm: mm,
      );

  bool get isZero =>
      topMm == 0 && rightMm == 0 && bottomMm == 0 && leftMm == 0;
}

/// A generic, printer-independent page setup.
///
/// Profiles never name a printer model. `4x6 Label` describes 101.6 × 152.4 mm
/// media, not a particular device.
@freezed
class PrintProfile with _$PrintProfile {
  const factory PrintProfile({
    required String id,
    required String name,
    @Default(PaperSize.a4) PaperSize paperSize,
    double? widthMm,
    double? heightMm,
    @Default(PageOrientation.portrait) PageOrientation orientation,
    @Default(PrintScaling.fit) PrintScaling scaling,
    @Default(PageMargins()) PageMargins margins,
    @Default(1) int copies,
    @Default(PrintQuality.normal) PrintQuality quality,
    @Default(true) bool color,
    @Default(DuplexMode.simplex) DuplexMode duplex,
    @Default(PrintStrategyType.auto) PrintStrategyType strategy,
    @Default(false) bool isBuiltin,
  }) = _PrintProfile;

  const PrintProfile._();

  factory PrintProfile.fromJson(Map<String, dynamic> json) =>
      _$PrintProfileFromJson(json);

  /// A neutral default used when neither the server nor local configuration
  /// supplies a profile. Exposed as a `const` so it can be used as a `@Default`
  /// on other models.
  static const PrintProfile a4Default = PrintProfile(
    id: 'profile_a4',
    name: 'A4 Document',
    margins: PageMargins(topMm: 10, rightMm: 10, bottomMm: 10, leftMm: 10),
    isBuiltin: true,
  );

  factory PrintProfile.defaultProfile() => a4Default;

  /// Effective page width in millimetres.
  double get effectiveWidthMm =>
      widthMm ?? paperSize.defaultWidthMm ?? PaperSize.a4.defaultWidthMm!;

  /// Effective page height in millimetres.
  double get effectiveHeightMm =>
      heightMm ?? paperSize.defaultHeightMm ?? PaperSize.a4.defaultHeightMm!;

  /// Page size after orientation is applied.
  ({double widthMm, double heightMm}) get orientedSizeMm =>
      orientation == PageOrientation.landscape
          ? (widthMm: effectiveHeightMm, heightMm: effectiveWidthMm)
          : (widthMm: effectiveWidthMm, heightMm: effectiveHeightMm);

  String get summary {
    final size = paperSize == PaperSize.custom
        ? '${effectiveWidthMm.toStringAsFixed(0)} × '
            '${effectiveHeightMm.toStringAsFixed(0)} mm'
        : paperSize.label;
    return '$size · ${orientation.name} · ${scaling.name}'
        '${copies > 1 ? ' · ×$copies' : ''}';
  }

  /// Builds a profile from the loosely-typed `profile` object in the job payload.
  /// Every field is optional; anything missing falls back to [base].
  factory PrintProfile.fromServerPayload(
    Map<String, dynamic>? payload, {
    PrintProfile? base,
  }) {
    final fallback = base ?? PrintProfile.defaultProfile();
    if (payload == null || payload.isEmpty) return fallback;

    final marginsRaw = payload['margins_mm'];
    final margins = marginsRaw is Map
        ? PageMargins(
            topMm: _toDouble(marginsRaw['top']) ?? fallback.margins.topMm,
            rightMm: _toDouble(marginsRaw['right']) ?? fallback.margins.rightMm,
            bottomMm:
                _toDouble(marginsRaw['bottom']) ?? fallback.margins.bottomMm,
            leftMm: _toDouble(marginsRaw['left']) ?? fallback.margins.leftMm,
          )
        : fallback.margins;

    final paperSize = payload.containsKey('paper_size')
        ? PaperSize.fromWire(payload['paper_size'] as String?)
        : fallback.paperSize;

    return fallback.copyWith(
      name: (payload['name'] as String?)?.trim().isNotEmpty ?? false
          ? payload['name'] as String
          : fallback.name,
      paperSize: paperSize,
      widthMm: _toDouble(payload['width_mm']) ??
          (paperSize == fallback.paperSize ? fallback.widthMm : null),
      heightMm: _toDouble(payload['height_mm']) ??
          (paperSize == fallback.paperSize ? fallback.heightMm : null),
      orientation: payload.containsKey('orientation')
          ? PageOrientation.fromWire(payload['orientation'] as String?)
          : fallback.orientation,
      scaling: payload.containsKey('scaling')
          ? PrintScaling.fromWire(payload['scaling'] as String?)
          : fallback.scaling,
      margins: margins,
      copies: _toInt(payload['copies']) ?? fallback.copies,
      quality: payload.containsKey('quality')
          ? PrintQuality.fromWire(payload['quality'] as String?)
          : fallback.quality,
      color: payload['color'] is bool ? payload['color'] as bool : fallback.color,
      duplex: payload.containsKey('duplex')
          ? DuplexMode.fromWire(payload['duplex'] as String?)
          : fallback.duplex,
      strategy: payload.containsKey('strategy')
          ? PrintStrategyType.fromWire(payload['strategy'] as String?)
          : fallback.strategy,
    );
  }

  // ---------------------------------------------------------------------
  // Database mapping
  // ---------------------------------------------------------------------

  Map<String, Object?> toDatabaseRow() => <String, Object?>{
        'id': id,
        'name': name,
        'paper_size': paperSize.wireValue,
        'width_mm': widthMm,
        'height_mm': heightMm,
        'orientation': orientation.name,
        'scaling': scaling.name,
        'margin_top_mm': margins.topMm,
        'margin_right_mm': margins.rightMm,
        'margin_bottom_mm': margins.bottomMm,
        'margin_left_mm': margins.leftMm,
        'copies': copies,
        'quality': quality.name,
        'color': color ? 1 : 0,
        'duplex': duplex.wireValue,
        'strategy': strategy.name,
        'is_builtin': isBuiltin ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

  static PrintProfile fromDatabaseRow(Map<String, Object?> row) => PrintProfile(
        id: row['id']! as String,
        name: row['name']! as String,
        paperSize: PaperSize.fromWire(row['paper_size'] as String?),
        widthMm: (row['width_mm'] as num?)?.toDouble(),
        heightMm: (row['height_mm'] as num?)?.toDouble(),
        orientation: PageOrientation.fromWire(row['orientation'] as String?),
        scaling: PrintScaling.fromWire(row['scaling'] as String?),
        margins: PageMargins(
          topMm: (row['margin_top_mm'] as num?)?.toDouble() ?? 0,
          rightMm: (row['margin_right_mm'] as num?)?.toDouble() ?? 0,
          bottomMm: (row['margin_bottom_mm'] as num?)?.toDouble() ?? 0,
          leftMm: (row['margin_left_mm'] as num?)?.toDouble() ?? 0,
        ),
        copies: (row['copies'] as int?) ?? 1,
        quality: PrintQuality.fromWire(row['quality'] as String?),
        color: (row['color'] as int? ?? 1) == 1,
        duplex: DuplexMode.fromWire(row['duplex'] as String?),
        strategy: PrintStrategyType.fromWire(row['strategy'] as String?),
        isBuiltin: (row['is_builtin'] as int? ?? 0) == 1,
      );

  static double? _toDouble(Object? value) => switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static int? _toInt(Object? value) => switch (value) {
        final num n => n.toInt(),
        final String s => int.tryParse(s),
        _ => null,
      };
}
