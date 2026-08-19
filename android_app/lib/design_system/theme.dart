import 'package:flutter/material.dart';

/// Design-token entry point, a 1:1 port of
/// `ios/BatteryHolder/DesignSystem/Theme.swift`.
/// See docs/DESIGN_TOKENS.md for the reference table.
///
/// Colors are *adaptive*: every token carries a light and a dark value and
/// resolves against the ambient [Brightness], the same way the iOS dynamic
/// `UIColor` does. Views read them through `Theme.colorOf(context)`.
class AppTheme {
  static const spacing = Spacing();
  static const radius = Radius();
  static const font = Typography();
  static const elevation = Elevation();

  /// Resolve the color set for the current brightness.
  static AppColor colorOf(BuildContext context) =>
      AppColor(Theme.of(context).brightness == Brightness.dark);

  static const AppColor light = AppColor(false);
  static const AppColor dark = AppColor(true);
}

Color _hex(int hex, [double opacity = 1]) => Color(hex | 0xFF000000)
    .withValues(alpha: opacity);

// MARK: - Color tokens

class AppColor {
  /// True when resolving against a dark trait environment.
  final bool isDark;

  const AppColor(this.isDark);

  Color _adaptive(int light, int dark) => _hex(isDark ? dark : light);

  // Brand & accent
  Color get brand => _adaptive(0x0A84FF, 0x0A84FF);
  Color get brandPressed => _adaptive(0x0060DF, 0x409CFF);
  Color get accent => _adaptive(0x30D158, 0x30D158);

  // Battery status scale
  Color get batteryGood => _adaptive(0x30D158, 0x32D74B);
  Color get batteryMedium => _adaptive(0xFF9F0A, 0xFFB340);
  Color get batteryLow => _adaptive(0xFF9500, 0xFF9F0A);
  Color get batteryCritical => _adaptive(0xFF453B, 0xFF6961);

  // Feedback
  Color get success => _adaptive(0x248A3D, 0x30D158);
  Color get warning => _adaptive(0xB25000, 0xFF9F0A);
  Color get danger => _adaptive(0xD70015, 0xFF453B);

  // Surfaces & text
  Color get background => _adaptive(0xF2F2F7, 0x000000);
  Color get surface => _adaptive(0xFFFFFF, 0x1C1C1E);
  Color get surfaceElevated => _adaptive(0xFFFFFF, 0x2C2C2E);
  Color get border => _adaptive(0xE5E5EA, 0x38383A);
  Color get textPrimary => _adaptive(0x1C1C1E, 0xFFFFFF);
  Color get textSecondary => _adaptive(0x6C6C70, 0x98989F);
  Color get textOnBrand => _adaptive(0xFFFFFF, 0xFFFFFF);

  /// Maps a battery percentage (0...1) to its status color.
  Color battery(double pct) {
    if (pct < 0.10) return batteryCritical;
    if (pct < 0.25) return batteryLow;
    if (pct < 0.60) return batteryMedium;
    return batteryGood;
  }
}

// MARK: - Spacing (4pt grid)

class Spacing {
  const Spacing();
  final double xxs = 2;
  final double xs = 4;
  final double sm = 8;
  final double md = 12;
  final double lg = 16;
  final double xl = 24;
  final double xxl = 32;
  final double xxxl = 48;
}

// MARK: - Radius

class Radius {
  const Radius();
  final double sm = 8;
  final double md = 12;
  final double lg = 16;
  final double xl = 24;
  final double pill = 999;
}

// MARK: - Typography
//
// iOS uses SF Pro; Android's platform face is Roboto. Sizes and weights match
// the Swift tokens exactly so the vertical rhythm is identical.

class Typography {
  const Typography();

  TextStyle get largeTitle =>
      const TextStyle(fontSize: 34, fontWeight: FontWeight.w700);
  TextStyle get title =>
      const TextStyle(fontSize: 22, fontWeight: FontWeight.w600);
  TextStyle get headline =>
      const TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
  TextStyle get body =>
      const TextStyle(fontSize: 17, fontWeight: FontWeight.w400);
  TextStyle get callout =>
      const TextStyle(fontSize: 16, fontWeight: FontWeight.w400);
  TextStyle get subheadline =>
      const TextStyle(fontSize: 15, fontWeight: FontWeight.w400);
  TextStyle get footnote =>
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w400);
  TextStyle get caption =>
      const TextStyle(fontSize: 12, fontWeight: FontWeight.w400);

  /// `RobotoMono` ships with Flutter's Material assets and is the closest
  /// match to SF Mono for the ADC / voltage readouts.
  TextStyle get mono => const TextStyle(
      fontSize: 17, fontWeight: FontWeight.w400, fontFamily: 'monospace');
  TextStyle get monoLarge => const TextStyle(
      fontSize: 40, fontWeight: FontWeight.w600, fontFamily: 'monospace');
}

// MARK: - Elevation

class Elevation {
  const Elevation();

  List<BoxShadow> get card => const [
        BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2)),
      ];
  List<BoxShadow> get raised => const [
        BoxShadow(
            color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 6)),
      ];
  List<BoxShadow> get overlay => const [
        BoxShadow(
            color: Color(0x2E000000), blurRadius: 32, offset: Offset(0, 12)),
      ];
}

// MARK: - Motion

class Motion {
  static const quick = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 350);
  static const emphasis = Duration(milliseconds: 500);
}

// MARK: - MaterialTheme wiring

/// Builds the [ThemeData] the app runs on, seeded from the tokens above so
/// stock Material widgets (dialogs, pickers, the tab bar) inherit the same
/// palette as the hand-built components.
ThemeData buildAppTheme(Brightness brightness) {
  final c = AppColor(brightness == Brightness.dark);
  final base = brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light();

  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    dividerColor: c.border,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.brand,
      brightness: brightness,
    ).copyWith(
      primary: c.brand,
      onPrimary: c.textOnBrand,
      surface: c.surface,
      onSurface: c.textPrimary,
      error: c.danger,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        // Matches SwiftUI's inline `.navigationTitle` weight/size.
        fontSize: 34,
        fontWeight: FontWeight.w700,
        color: c.textPrimary,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 0.5, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.brand,
      linearTrackColor: c.border,
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.brand),
  );
}
