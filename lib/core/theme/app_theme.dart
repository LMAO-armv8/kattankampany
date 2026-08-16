import 'package:flutter/material.dart';

/// Design tokens.
///
/// One accent, a neutral surface ramp and four semantic status colours. The
/// palette is deliberately restrained: this is an operations tool that sits
/// open on a warehouse PC all day, and the only things that should draw the eye
/// are status changes.
abstract final class AppColors {
  static const Color brand = Color(0xFF5B4BE0);
  static const Color brandDark = Color(0xFF8B7CF6);

  static const Color success = Color(0xFF15803D);
  static const Color successDark = Color(0xFF4ADE80);
  static const Color warning = Color(0xFFB45309);
  static const Color warningDark = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFB91C1C);
  static const Color dangerDark = Color(0xFFF87171);
  static const Color info = Color(0xFF0E7490);
  static const Color infoDark = Color(0xFF22D3EE);
  static const Color neutral = Color(0xFF64748B);

  static const Color lightSurface = Color(0xFFF7F8FB);
  static const Color lightCard = Colors.white;
  static const Color lightBorder = Color(0xFFE2E6EF);

  static const Color darkSurface = Color(0xFF12141A);
  static const Color darkCard = Color(0xFF1A1D26);
  static const Color darkBorder = Color(0xFF2A2E3B);
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  static const double radius = 10;
  static const double cardRadius = 14;
  static const double sidebarWidth = 232;
}

/// Colours attached to the theme so widgets do not branch on brightness.
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.neutral,
    required this.border,
    required this.cardBackground,
    required this.subtleBackground,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color neutral;
  final Color border;
  final Color cardBackground;
  final Color subtleBackground;

  @override
  StatusColors copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? neutral,
    Color? border,
    Color? cardBackground,
    Color? subtleBackground,
  }) =>
      StatusColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        info: info ?? this.info,
        neutral: neutral ?? this.neutral,
        border: border ?? this.border,
        cardBackground: cardBackground ?? this.cardBackground,
        subtleBackground: subtleBackground ?? this.subtleBackground,
      );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      border: Color.lerp(border, other.border, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      subtleBackground: Color.lerp(subtleBackground, other.subtleBackground, t)!,
    );
  }

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ?? _fallback;

  static const StatusColors _fallback = StatusColors(
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    info: AppColors.info,
    neutral: AppColors.neutral,
    border: AppColors.lightBorder,
    cardBackground: AppColors.lightCard,
    subtleBackground: AppColors.lightSurface,
  );
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
    );

    final surface = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final card = isDark ? AppColors.darkCard : AppColors.lightCard;
    final border = isDark ? AppColors.darkBorder : AppColors.lightBorder;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme.copyWith(surface: surface),
      scaffoldBackgroundColor: surface,
      visualDensity: VisualDensity.compact,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[
        StatusColors(
          success: isDark ? AppColors.successDark : AppColors.success,
          warning: isDark ? AppColors.warningDark : AppColors.warning,
          danger: isDark ? AppColors.dangerDark : AppColors.danger,
          info: isDark ? AppColors.infoDark : AppColors.info,
          neutral: AppColors.neutral,
          border: border,
          cardBackground: card,
          subtleBackground: isDark
              ? const Color(0xFF161923)
              : const Color(0xFFF1F3F8),
        ),
      ],
      cardTheme: CardThemeData(
        elevation: 0,
        color: card,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: border,
        space: 1,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radius),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          letterSpacing: 0.4,
          color: scheme.onSurfaceVariant,
        ),
        dataTextStyle: const TextStyle(fontSize: 13),
        dividerThickness: 1,
      ),
    );
  }
}
