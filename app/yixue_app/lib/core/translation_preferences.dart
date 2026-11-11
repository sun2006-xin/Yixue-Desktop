import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum PreferredDirection { auto, englishToChinese, chineseToEnglish }

enum TranslationTone { natural, formal, concise, learning }

class TranslationPreferences {
  const TranslationPreferences({
    this.direction = PreferredDirection.auto,
    this.tone = TranslationTone.natural,
    this.preserveLineBreaks = true,
  });

  final PreferredDirection direction;
  final TranslationTone tone;
  final bool preserveLineBreaks;

  TranslationPreferences copyWith({
    PreferredDirection? direction,
    TranslationTone? tone,
    bool? preserveLineBreaks,
  }) => TranslationPreferences(
    direction: direction ?? this.direction,
    tone: tone ?? this.tone,
    preserveLineBreaks: preserveLineBreaks ?? this.preserveLineBreaks,
  );

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'direction': direction.name,
    'tone': tone.name,
    'preserveLineBreaks': preserveLineBreaks,
  };

  factory TranslationPreferences.fromJson(Map<String, dynamic> json) {
    PreferredDirection parseDirection() => PreferredDirection.values.firstWhere(
      (value) => value.name == json['direction'],
      orElse: () => PreferredDirection.auto,
    );
    TranslationTone parseTone() => TranslationTone.values.firstWhere(
      (value) => value.name == json['tone'],
      orElse: () => TranslationTone.natural,
    );

    return TranslationPreferences(
      direction: parseDirection(),
      tone: parseTone(),
      preserveLineBreaks: json['preserveLineBreaks'] is bool
          ? json['preserveLineBreaks'] as bool
          : true,
    );
  }
}

abstract interface class TranslationPreferencesStore {
  Future<TranslationPreferences?> read();

  Future<void> write(TranslationPreferences preferences);
}

class FileTranslationPreferencesStore implements TranslationPreferencesStore {
  FileTranslationPreferencesStore(this.file);

  final File file;

  @override
  Future<TranslationPreferences?> read() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> || value['schemaVersion'] != 1) {
        return null;
      }
      return TranslationPreferences.fromJson(value);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(TranslationPreferences preferences) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
  }
}

class TranslationPreferencesController extends ChangeNotifier {
  TranslationPreferencesController({TranslationPreferences? initialValue})
    : _value = initialValue ?? const TranslationPreferences();

  TranslationPreferences _value;

  TranslationPreferences get value => _value;

  void update(TranslationPreferences value) {
    if (_value == value) return;
    _value = value;
    notifyListeners();
  }
}
