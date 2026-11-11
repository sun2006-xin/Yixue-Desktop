import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

enum YixueOfficialTheme { vitality, light, dark }

enum YixueVisualStyle { focus, vitality }

enum YixueMotionLevel { full, reduced, off }

enum YixueWorkspace {
  home,
  quickTranslation,
  screenshotTranslation,
  reader,
  learning,
  liveInterpretation,
  models,
  settings,
}

@immutable
class CustomThemeSpec {
  const CustomThemeSpec({
    required this.name,
    required this.background,
    required this.surface,
    required this.accent,
    required this.outline,
    required this.sidebarTop,
    required this.sidebarBottom,
    required this.sidebarForeground,
    required this.sidebarGlow,
    required this.selectedStart,
    required this.selectedEnd,
    required this.topStart,
    required this.topEnd,
    required this.topForeground,
    required this.topBorder,
    this.fontFamily = defaultFontFamily,
    this.backgroundImagePath,
    this.statusBarColor,
  });

  static const defaultFontFamily = 'Microsoft YaHei UI';

  final String name;
  final Color background;
  final Color surface;
  final Color accent;
  final Color outline;
  final Color sidebarTop;
  final Color sidebarBottom;
  final Color sidebarForeground;
  final Color sidebarGlow;
  final Color selectedStart;
  final Color selectedEnd;
  final Color topStart;
  final Color topEnd;
  final Color topForeground;
  final Color topBorder;
  final String fontFamily;
  final String? backgroundImagePath;
  final Color? statusBarColor;

  bool get isDark => background.computeLuminance() < 0.42;

  /// Returns a usable local background path; missing assets deliberately fall
  /// back to the solid theme background instead of breaking the workspace.
  String? get usableBackgroundImagePath {
    final path = backgroundImagePath?.trim();
    if (path == null || path.isEmpty || !File(path).existsSync()) return null;
    return path;
  }

  Map<String, Object?> toJson() {
    final colors = <String, String>{
      'background': _hex(background),
      'surface': _hex(surface),
      'accent': _hex(accent),
      'outline': _hex(outline),
      'sidebarTop': _hex(sidebarTop),
      'sidebarBottom': _hex(sidebarBottom),
      'sidebarForeground': _hex(sidebarForeground),
      'sidebarGlow': _hex(sidebarGlow),
      'selectedStart': _hex(selectedStart),
      'selectedEnd': _hex(selectedEnd),
      'topStart': _hex(topStart),
      'topEnd': _hex(topEnd),
      'topForeground': _hex(topForeground),
      'topBorder': _hex(topBorder),
    };
    colors['statusBarColor'] = _hex(statusBarColor ?? topStart);
    return <String, Object?>{
      'schemaVersion': 1,
      'name': name,
      'fontFamily': fontFamily,
      if (backgroundImagePath != null)
        'backgroundImagePath': backgroundImagePath,
      'colors': colors,
    };
  }

  factory CustomThemeSpec.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('主题包版本不受支持');
    }
    final name = json['name'];
    final colors = json['colors'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 64 ||
        colors is! Map) {
      throw const FormatException('主题包缺少合法名称或颜色令牌');
    }
    Color color(String key, [Color? fallback]) {
      final value = colors[key];
      if (value == null && fallback != null) return fallback;
      if (value is! String) throw FormatException('缺少颜色令牌：$key');
      final normalized = value.trim().replaceFirst('#', '');
      final hex = normalized.length == 6 ? 'FF$normalized' : normalized;
      if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(hex)) {
        throw FormatException('颜色令牌无效：$key');
      }
      return Color(int.parse(hex, radix: 16));
    }

    final rawFontFamily = json['fontFamily'];
    final fontFamily = rawFontFamily == null
        ? defaultFontFamily
        : _validateFontFamily(rawFontFamily);
    final rawBackgroundPath = json['backgroundImagePath'];
    final backgroundImagePath = rawBackgroundPath == null
        ? null
        : _validateBackgroundPath(rawBackgroundPath);

    return CustomThemeSpec(
      name: name.trim(),
      background: color('background'),
      surface: color('surface'),
      accent: color('accent'),
      outline: color('outline'),
      sidebarTop: color('sidebarTop'),
      sidebarBottom: color('sidebarBottom'),
      sidebarForeground: color('sidebarForeground'),
      sidebarGlow: color('sidebarGlow'),
      selectedStart: color('selectedStart'),
      selectedEnd: color('selectedEnd'),
      topStart: color('topStart'),
      topEnd: color('topEnd'),
      topForeground: color('topForeground'),
      topBorder: color('topBorder'),
      fontFamily: fontFamily,
      backgroundImagePath: backgroundImagePath,
      statusBarColor: color('statusBarColor', color('topStart')),
    );
  }

  static String _validateFontFamily(Object value) {
    if (value is! String) throw const FormatException('字体名称无效');
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 120 ||
        normalized.contains('\u0000') ||
        normalized.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('字体名称无效');
    }
    return normalized;
  }

  static String _validateBackgroundPath(Object value) {
    if (value is! String) throw const FormatException('背景图路径无效');
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 4096 ||
        normalized.contains('\u0000') ||
        normalized.contains(RegExp(r'[\r\n]')) ||
        normalized.contains('://') ||
        normalized.toLowerCase().startsWith('data:')) {
      throw const FormatException('背景图必须是本地文件路径');
    }
    return normalized;
  }

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

@immutable
class AppearanceState {
  AppearanceState({
    this.officialTheme = YixueOfficialTheme.vitality,
    this.motionLevel = YixueMotionLevel.full,
    this.customTheme,
    Map<YixueWorkspace, YixueVisualStyle> workspaceStyles = const {},
  }) : workspaceStyles = UnmodifiableMapView(workspaceStyles);

  final YixueOfficialTheme officialTheme;
  final YixueMotionLevel motionLevel;
  final CustomThemeSpec? customTheme;
  final Map<YixueWorkspace, YixueVisualStyle> workspaceStyles;

  YixueVisualStyle styleFor(YixueWorkspace workspace) =>
      workspaceStyles[workspace] ??
      (officialTheme == YixueOfficialTheme.vitality
          ? YixueVisualStyle.vitality
          : YixueVisualStyle.focus);

  AppearanceState copyWith({
    YixueOfficialTheme? officialTheme,
    YixueMotionLevel? motionLevel,
    CustomThemeSpec? customTheme,
    bool clearCustomTheme = false,
    Map<YixueWorkspace, YixueVisualStyle>? workspaceStyles,
  }) {
    return AppearanceState(
      officialTheme: officialTheme ?? this.officialTheme,
      motionLevel: motionLevel ?? this.motionLevel,
      customTheme: clearCustomTheme ? null : customTheme ?? this.customTheme,
      workspaceStyles: workspaceStyles ?? this.workspaceStyles,
    );
  }
}

class AppearanceController extends ChangeNotifier {
  AppearanceController({AppearanceState? initialValue})
    : _value = initialValue ?? AppearanceState();

  AppearanceState _value;
  AppearanceState get value => _value;

  void restore(AppearanceState state) {
    _value = state;
    notifyListeners();
  }

  void setOfficialTheme(YixueOfficialTheme officialTheme) {
    if (_value.officialTheme == officialTheme) return;
    _replace(
      _value.copyWith(officialTheme: officialTheme, clearCustomTheme: true),
    );
  }

  void setCustomTheme(CustomThemeSpec theme) =>
      _replace(_value.copyWith(customTheme: theme));

  void clearCustomTheme() => _replace(_value.copyWith(clearCustomTheme: true));

  void setMotionLevel(YixueMotionLevel motionLevel) {
    if (_value.motionLevel == motionLevel) return;
    _replace(_value.copyWith(motionLevel: motionLevel));
  }

  void setWorkspaceStyle(
    YixueWorkspace workspace,
    YixueVisualStyle? visualStyle,
  ) {
    if (_value.workspaceStyles[workspace] == visualStyle ||
        (visualStyle == null &&
            !_value.workspaceStyles.containsKey(workspace))) {
      return;
    }

    final styles = Map<YixueWorkspace, YixueVisualStyle>.of(
      _value.workspaceStyles,
    );
    if (visualStyle == null) {
      styles.remove(workspace);
    } else {
      styles[workspace] = visualStyle;
    }
    _replace(_value.copyWith(workspaceStyles: styles));
  }

  void _replace(AppearanceState next) {
    _value = next;
    notifyListeners();
  }
}

abstract interface class AppearancePreferenceStore {
  Future<AppearanceState?> read();

  Future<void> write(AppearanceState value);
}

class FileAppearancePreferenceStore implements AppearancePreferenceStore {
  FileAppearancePreferenceStore(this.file);

  final File file;

  @override
  Future<AppearanceState?> read() async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
        return null;
      }
      final official = YixueOfficialTheme.values.firstWhere(
        (item) => item.name == decoded['officialTheme'],
        orElse: () => YixueOfficialTheme.vitality,
      );
      final motion = YixueMotionLevel.values.firstWhere(
        (item) => item.name == decoded['motionLevel'],
        orElse: () => YixueMotionLevel.full,
      );
      CustomThemeSpec? custom;
      final rawCustom = decoded['customTheme'];
      if (rawCustom is Map<String, dynamic>) {
        try {
          custom = CustomThemeSpec.fromJson(rawCustom);
        } on FormatException {
          custom = null;
        }
      }
      final styles = <YixueWorkspace, YixueVisualStyle>{};
      final rawStyles = decoded['workspaceStyles'];
      if (rawStyles is Map) {
        for (final entry in rawStyles.entries) {
          if (entry.key is! String || entry.value is! String) continue;
          final workspace = YixueWorkspace.values.where(
            (item) => item.name == entry.key,
          );
          final style = YixueVisualStyle.values.where(
            (item) => item.name == entry.value,
          );
          if (workspace.length == 1 && style.length == 1) {
            styles[workspace.first] = style.first;
          }
        }
      }
      return AppearanceState(
        officialTheme: official,
        motionLevel: motion,
        customTheme: custom,
        workspaceStyles: styles,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(AppearanceState value) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'officialTheme': value.officialTheme.name,
        'motionLevel': value.motionLevel.name,
        'customTheme': value.customTheme?.toJson(),
        'workspaceStyles': <String, String>{
          for (final entry in value.workspaceStyles.entries)
            entry.key.name: entry.value.name,
        },
      }),
      flush: true,
    );
  }
}
