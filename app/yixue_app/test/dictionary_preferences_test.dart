import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

DictionaryEntryData _entry(String id, String source, String meaning) =>
    DictionaryEntryData(
      id: id,
      word: 'hello',
      ipa: '/həˈləʊ/',
      partOfSpeech: 'int.',
      meanings: [meaning],
      example: 'Hello.',
      exampleTranslation: '你好。',
      source: source,
    );

void main() {
  test('orders enabled dictionary sources by user priority', () {
    const preferences = DictionaryPreferences(
      sources: [
        DictionarySourcePreference(
          id: 'licensed',
          displayName: '授权词典',
          license: 'CC BY-NC',
        ),
        DictionarySourcePreference(
          id: 'yixue-basic',
          displayName: '译学基础词典',
          license: '项目内置',
          enabled: false,
        ),
      ],
    );
    final result = preferences.sortEntries([
      _entry('seed', 'yixue-basic', '内置你好'),
      _entry('licensed', 'licensed · 授权词典 · CC BY-NC', '授权你好'),
      _entry('other', 'legacy-source · 旧词典 · 未知', '旧你好'),
    ]);

    expect(result.map((entry) => entry.meanings.single), ['授权你好', '旧你好']);
  });

  test('registers an imported source without losing its enabled state', () {
    const initial = DictionaryPreferences(
      sources: [
        DictionarySourcePreference(
          id: 'demo',
          displayName: '旧名称',
          license: 'MIT',
          enabled: false,
        ),
      ],
    );
    final updated = initial.registerSource(
      id: 'demo',
      displayName: '新名称',
      license: 'Apache-2.0',
    );

    expect(updated.sources.single.displayName, '新名称');
    expect(updated.sources.single.license, 'Apache-2.0');
    expect(updated.sources.single.enabled, isFalse);
  });

  test('round trips preferences and ignores malformed files', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-dict-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileDictionaryPreferencesStore(
      File('${directory.path}${Platform.pathSeparator}preferences.json'),
    );
    const preferences = DictionaryPreferences();

    await store.write(preferences);
    expect((await store.read())?.sources.single.id, 'yixue-basic');
    await store.file.writeAsString('{broken');
    expect(await store.read(), isNull);
  });
}
