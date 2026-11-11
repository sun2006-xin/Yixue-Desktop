import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_appearance.dart';

@immutable
class YixueShellTheme extends ThemeExtension<YixueShellTheme> {
  const YixueShellTheme(this.preset, {this.custom});

  final YixueOfficialTheme preset;
  final CustomThemeSpec? custom;

  @override
  YixueShellTheme copyWith({
    YixueOfficialTheme? preset,
    CustomThemeSpec? custom,
  }) => YixueShellTheme(preset ?? this.preset, custom: custom ?? this.custom);

  @override
  YixueShellTheme lerp(covariant YixueShellTheme? other, double t) {
    if (other == null || t < 0.5) return this;
    return other;
  }
}

class YixueShellPalette {
  const YixueShellPalette({
    required this.preset,
    required this.sidebarTop,
    required this.sidebarBottom,
    required this.sidebarForeground,
    required this.sidebarMuted,
    required this.sidebarGlow,
    required this.selectedStart,
    required this.selectedEnd,
    required this.hoverStart,
    required this.hoverEnd,
    required this.topStart,
    required this.topEnd,
    required this.topForeground,
    required this.topBorder,
    required this.statusBarColor,
    this.isCustomTheme = false,
  });

  final YixueOfficialTheme preset;
  final Color sidebarTop;
  final Color sidebarBottom;
  final Color sidebarForeground;
  final Color sidebarMuted;
  final Color sidebarGlow;
  final Color selectedStart;
  final Color selectedEnd;
  final Color hoverStart;
  final Color hoverEnd;
  final Color topStart;
  final Color topEnd;
  final Color topForeground;
  final Color topBorder;
  final Color statusBarColor;
  final bool isCustomTheme;

  bool get isVitality => preset == YixueOfficialTheme.vitality;

  static YixueShellPalette of(BuildContext context) {
    final shell = Theme.of(context).extension<YixueShellTheme>();
    final preset = shell?.preset ?? YixueOfficialTheme.vitality;
    final custom = shell?.custom;
    if (custom != null) {
      return YixueShellPalette(
        preset: preset,
        sidebarTop: custom.sidebarTop,
        sidebarBottom: custom.sidebarBottom,
        sidebarForeground: custom.sidebarForeground,
        sidebarMuted: custom.sidebarForeground.withValues(alpha: 0.7),
        sidebarGlow: custom.sidebarGlow,
        selectedStart: custom.selectedStart,
        selectedEnd: custom.selectedEnd,
        hoverStart: custom.selectedStart.withValues(alpha: 0.72),
        hoverEnd: custom.selectedEnd.withValues(alpha: 0.72),
        topStart: custom.topStart,
        topEnd: custom.topEnd,
        topForeground: custom.topForeground,
        topBorder: custom.topBorder,
        statusBarColor: custom.statusBarColor ?? custom.topStart,
        isCustomTheme: true,
      );
    }
    return switch (preset) {
      YixueOfficialTheme.vitality => vitality,
      YixueOfficialTheme.light => light,
      YixueOfficialTheme.dark => dark,
    };
  }

  static const vitality = YixueShellPalette(
    preset: YixueOfficialTheme.vitality,
    sidebarTop: Color(0xFF032F4B),
    sidebarBottom: Color(0xFF006270),
    sidebarForeground: Color(0xFFF7FCFF),
    sidebarMuted: Color(0xFFB8D7E2),
    sidebarGlow: Color(0xFF35E99A),
    selectedStart: Color(0xFF1766E7),
    selectedEnd: Color(0xFF18C9A0),
    hoverStart: Color(0xFF0A4E70),
    hoverEnd: Color(0xFF08768A),
    topStart: Color(0xFF032F4B),
    topEnd: Color(0xFF00586A),
    topForeground: Color(0xFFF4FBFF),
    topBorder: Color(0xFF1A8292),
    statusBarColor: Color(0xFF032F4B),
  );

  static const light = YixueShellPalette(
    preset: YixueOfficialTheme.light,
    sidebarTop: Color(0xFFF1F4F6),
    sidebarBottom: Color(0xFFF1F4F6),
    sidebarForeground: Color(0xFF253541),
    sidebarMuted: Color(0xFF697985),
    sidebarGlow: Colors.transparent,
    selectedStart: Color(0xFFDDE8F2),
    selectedEnd: Color(0xFFDDE8F2),
    hoverStart: Color(0xFFE7EDF2),
    hoverEnd: Color(0xFFE7EDF2),
    topStart: Color(0xFFF7F9FA),
    topEnd: Color(0xFFF7F9FA),
    topForeground: Color(0xFF344550),
    topBorder: Color(0xFFDCE3E8),
    statusBarColor: Color(0xFFF7F9FA),
  );

  static const dark = YixueShellPalette(
    preset: YixueOfficialTheme.dark,
    sidebarTop: Color(0xFF1B2026),
    sidebarBottom: Color(0xFF1B2026),
    sidebarForeground: Color(0xFFE8EEF3),
    sidebarMuted: Color(0xFFA5B0BA),
    sidebarGlow: Colors.transparent,
    selectedStart: Color(0xFF2A3641),
    selectedEnd: Color(0xFF2A3641),
    hoverStart: Color(0xFF242C34),
    hoverEnd: Color(0xFF242C34),
    topStart: Color(0xFF171C21),
    topEnd: Color(0xFF171C21),
    topForeground: Color(0xFFE8EEF3),
    topBorder: Color(0xFF303840),
    statusBarColor: Color(0xFF171C21),
  );
}

abstract final class AppTheme {
  static const _accent = Color(0xFF1768D5);

  static ThemeData vitality() => _build(
    preset: YixueOfficialTheme.vitality,
    brightness: Brightness.light,
    background: const Color(0xFFF2F7FA),
    surface: const Color(0xFFF9FBFC),
    accent: const Color(0xFF1474DF),
    outline: const Color(0xFFD7E2E8),
  );

  static ThemeData light() => _build(
    preset: YixueOfficialTheme.light,
    brightness: Brightness.light,
    background: const Color(0xFFF5F7F8),
    surface: const Color(0xFFFBFCFD),
    accent: _accent,
    outline: const Color(0xFFDCE2E6),
  );

  static ThemeData dark() => _build(
    preset: YixueOfficialTheme.dark,
    brightness: Brightness.dark,
    background: const Color(0xFF111519),
    surface: const Color(0xFF181D22),
    accent: const Color(0xFF66A9EB),
    outline: const Color(0xFF3A444D),
  );

  static ThemeData custom(CustomThemeSpec spec) => _build(
    preset: YixueOfficialTheme.vitality,
    brightness: spec.isDark ? Brightness.dark : Brightness.light,
    background: spec.background,
    surface: spec.surface,
    accent: spec.accent,
    outline: spec.outline,
    fontFamily: spec.fontFamily,
    custom: spec,
  );

  static ThemeData _build({
    required YixueOfficialTheme preset,
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color accent,
    required Color outline,
    String fontFamily = CustomThemeSpec.defaultFontFamily,
    CustomThemeSpec? custom,
  }) {
    final colors =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          surface: surface,
          outline: outline,
          surfaceContainer: brightness == Brightness.dark
              ? const Color(0xFF20262C)
              : const Color(0xFFEEF2F4),
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: background,
      fontFamily: fontFamily,
      extensions: [YixueShellTheme(preset, custom: custom)],
      dividerColor: outline.withValues(alpha: 0.62),
      focusColor: accent.withValues(alpha: 0.14),
      splashFactory: InkRipple.splashFactory,
      inputDecorationTheme: InputDecorationTheme(
        border: const OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}
