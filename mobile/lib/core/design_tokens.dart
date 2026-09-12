import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// WAEC platform design tokens (plan §3.1).
///
/// Single source of truth for colors, typography and spacing.
/// Navy `#0A2540` + mint `#00D4B1` brand; light canvas `#F8FAFC`,
/// dark canvas `#051424`. Typography follows the WAEC Direct design
/// system: DM Sans (UI) + JetBrains Mono (index / reference numbers),
/// loaded at runtime via google_fonts (see docs/WAEC Result Verification
/// App/src/index.css).
abstract final class WaecColors {
  // Brand
  static const Color navy = Color(0xFF0A2540);
  static const Color mint = Color(0xFF00D4B1);

  // Light theme surfaces
  static const Color canvasLight = Color(0xFFF8FAFC);
  static const Color cardLight = Color(0xFFFFFFFF);

  // Dark theme surfaces
  static const Color canvasDark = Color(0xFF051424);
  static const Color cardDark = Color(0xFF0D1F35);

  // Semantic
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color danger = Color(0xFFDC2626);
  static const Color info = Color(0xFF2563EB);

  // Text
  static const Color textPrimaryLight = Color(0xFF0A2540);
  static const Color textSecondaryLight = Color(0xFF475569);
  static const Color textPrimaryDark = Color(0xFFF1F5F9);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
}

/// Spacing scale (4pt grid).
abstract final class WaecSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Corner radii.
abstract final class WaecRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 100;
}

/// Builds the light and dark [ThemeData] for the app.
abstract final class WaecTheme {
  /// UI font (DM Sans) and the monospace used for index / reference numbers
  /// (JetBrains Mono), matching the WAEC Direct design system.
  static const String fontFamily = 'DM Sans';
  static const String monoFamily = 'JetBrains Mono';

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: WaecColors.mint,
      brightness: brightness,
      primary: isLight ? WaecColors.navy : WaecColors.mint,
      secondary: WaecColors.mint,
      surface: isLight ? WaecColors.canvasLight : WaecColors.canvasDark,
    );

    // Apply DM Sans as the default text theme; JetBrains Mono is applied
    // selectively to index / reference-number text via [WaecTheme.mono].
    final baseTextTheme = GoogleFonts.dmSansTextTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      fontFamily: fontFamily,
      textTheme: baseTextTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor:
            isLight ? WaecColors.textPrimaryLight : WaecColors.textPrimaryDark,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: isLight ? WaecColors.cardLight : WaecColors.cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WaecRadii.lg),
          side: BorderSide(
            color: isLight
                ? const Color(0xFFE2E8F0)
                : const Color(0xFF1E3A5F),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: WaecColors.mint,
          foregroundColor: WaecColors.navy,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WaecRadii.md),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isLight ? WaecColors.cardLight : WaecColors.cardDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WaecRadii.md),
          borderSide: BorderSide(
            color: isLight
                ? const Color(0xFFE2E8F0)
                : const Color(0xFF1E3A5F),
          ),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Convenience: a [TextStyle] using JetBrains Mono for index numbers,
  /// reference codes and other monospaced identifiers (per the design system).
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
        color: WaecColors.textPrimaryLight,
      );

  /// Letter-spaced monospace style for reference numbers shown on cards.
  static TextStyle monoNum(double size, [Color color = WaecColors.textPrimaryLight]) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        letterSpacing: 0.08,
        fontWeight: FontWeight.w600,
        color: color,
      );
}
