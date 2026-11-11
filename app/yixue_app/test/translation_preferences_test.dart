import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/translation_preferences.dart';

void main() {
  test('round trips translation preferences through a local file', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-prefs-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileTranslationPreferencesStore(
      File('${directory.path}\\translation-preferences.json'),
    );
    const expected = TranslationPreferences(
      direction: PreferredDirection.chineseToEnglish,
      tone: TranslationTone.formal,
      preserveLineBreaks: false,
    );

    await store.write(expected);

    expect((await store.read())?.toJson(), expected.toJson());
  });

  test('falls back safely when the preference file is malformed', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-prefs-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}\\translation-preferences.json');
    await file.writeAsString('{not-json');

    expect(await FileTranslationPreferencesStore(file).read(), isNull);
  });

  test('invalid enum values use safe defaults', () {
    final preferences = TranslationPreferences.fromJson({
      'schemaVersion': 1,
      'direction': 'unknown',
      'tone': 'unknown',
    });

    expect(preferences.direction, PreferredDirection.auto);
    expect(preferences.tone, TranslationTone.natural);
    expect(preferences.preserveLineBreaks, isTrue);
  });
}
