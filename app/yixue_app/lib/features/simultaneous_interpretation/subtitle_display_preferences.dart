import 'dart:convert';
import 'dart:io';

enum SubtitleDisplayMode { bilingual, sourceOnly, translatedOnly }

enum SubtitleFontScale { compact, standard, large }

enum SubtitleColorPreset { ice, amber, mint, rose }

extension SubtitleDisplayModeLabel on SubtitleDisplayMode {
  String get label => switch (this) {
    SubtitleDisplayMode.bilingual => '原文 + 译文',
    SubtitleDisplayMode.sourceOnly => '仅原文',
    SubtitleDisplayMode.translatedOnly => '仅译文',
  };
}

extension SubtitleFontScalePresentation on SubtitleFontScale {
  String get label => switch (this) {
    SubtitleFontScale.compact => '小 · 18 px',
    SubtitleFontScale.standard => '标准 · 21 px',
    SubtitleFontScale.large => '大 · 25 px',
  };

  double get fontSize => switch (this) {
    SubtitleFontScale.compact => 18,
    SubtitleFontScale.standard => 21,
    SubtitleFontScale.large => 25,
  };
}

extension SubtitleColorPresetPresentation on SubtitleColorPreset {
  String get label => switch (this) {
    SubtitleColorPreset.ice => '冰蓝',
    SubtitleColorPreset.amber => '琥珀',
    SubtitleColorPreset.mint => '薄荷',
    SubtitleColorPreset.rose => '玫瑰',
  };

  int get darkAccentArgb => switch (this) {
    SubtitleColorPreset.ice => 0xFF64D7FF,
    SubtitleColorPreset.amber => 0xFFFFD166,
    SubtitleColorPreset.mint => 0xFF61E6B2,
    SubtitleColorPreset.rose => 0xFFFF8CA8,
  };

  int get lightAccentArgb => switch (this) {
    SubtitleColorPreset.ice => 0xFF005C86,
    SubtitleColorPreset.amber => 0xFF805000,
    SubtitleColorPreset.mint => 0xFF006B4F,
    SubtitleColorPreset.rose => 0xFF9B2944,
  };
}

final class SubtitleDisplayPreferences {
  const SubtitleDisplayPreferences({
    this.mode = SubtitleDisplayMode.bilingual,
    this.fontScale = SubtitleFontScale.standard,
    this.colorPreset = SubtitleColorPreset.ice,
    this.highContrast = true,
    this.windowOpacity = 0.82,
  });

  static const defaults = SubtitleDisplayPreferences();

  final SubtitleDisplayMode mode;
  final SubtitleFontScale fontScale;
  final SubtitleColorPreset colorPreset;
  final bool highContrast;
  final double windowOpacity;

  SubtitleDisplayPreferences copyWith({
    SubtitleDisplayMode? mode,
    SubtitleFontScale? fontScale,
    SubtitleColorPreset? colorPreset,
    bool? highContrast,
    double? windowOpacity,
  }) => SubtitleDisplayPreferences(
    mode: mode ?? this.mode,
    fontScale: fontScale ?? this.fontScale,
    colorPreset: colorPreset ?? this.colorPreset,
    highContrast: highContrast ?? this.highContrast,
    windowOpacity: windowOpacity == null
        ? this.windowOpacity
        : windowOpacity.clamp(0.55, 1.0).toDouble(),
  );

  Map<String, Object> toJson() => {
    'schemaVersion': 2,
    'mode': mode.name,
    'fontScale': fontScale.name,
    'colorPreset': colorPreset.name,
    'highContrast': highContrast,
    'windowOpacity': windowOpacity,
  };

  factory SubtitleDisplayPreferences.fromJson(Map<String, dynamic> json) =>
      SubtitleDisplayPreferences(
        mode: _enumByName(
          SubtitleDisplayMode.values,
          json['mode'],
          SubtitleDisplayMode.bilingual,
        ),
        fontScale: _enumByName(
          SubtitleFontScale.values,
          json['fontScale'],
          SubtitleFontScale.standard,
        ),
        colorPreset: _enumByName(
          SubtitleColorPreset.values,
          json['colorPreset'],
          SubtitleColorPreset.ice,
        ),
        highContrast: json['highContrast'] is bool
            ? json['highContrast'] as bool
            : true,
        windowOpacity: json['windowOpacity'] is num
            ? (json['windowOpacity'] as num)
                  .toDouble()
                  .clamp(0.55, 1.0)
                  .toDouble()
            : 0.82,
      );

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? name,
    T fallback,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }
}

abstract interface class SubtitleDisplayPreferencesStore {
  Future<SubtitleDisplayPreferences> read();

  Future<void> write(SubtitleDisplayPreferences preferences);
}

final class FileSubtitleDisplayPreferencesStore
    implements SubtitleDisplayPreferencesStore {
  FileSubtitleDisplayPreferencesStore(this.file);

  final File file;
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<SubtitleDisplayPreferences> read() async {
    try {
      if (!await file.exists()) return SubtitleDisplayPreferences.defaults;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['schemaVersion'] is! int ||
          (value['schemaVersion'] as int) < 1 ||
          (value['schemaVersion'] as int) > 2) {
        return SubtitleDisplayPreferences.defaults;
      }
      return SubtitleDisplayPreferences.fromJson(value);
    } on FileSystemException {
      return SubtitleDisplayPreferences.defaults;
    } on FormatException {
      return SubtitleDisplayPreferences.defaults;
    }
  }

  @override
  Future<void> write(SubtitleDisplayPreferences preferences) {
    final operation = _writeTail.then((_) async {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }
}
