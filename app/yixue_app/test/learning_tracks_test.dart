import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/learning_tracks.dart';

void main() {
  const entries = [
    DictionaryEntry(
      word: 'hello',
      ipa: '/həˈləʊ/',
      partOfSpeech: 'int.',
      meanings: ['你好'],
      example: 'Hello, friend.',
      exampleTranslation: '你好，朋友。',
      coverageBands: ['foundation'],
      learningTags: ['小学'],
    ),
    DictionaryEntry(
      word: 'academic',
      ipa: '/ˌækəˈdemɪk/',
      partOfSpeech: 'adj.',
      meanings: ['学术的'],
      example: 'Academic writing needs clear evidence.',
      exampleTranslation: '学术写作需要清晰的证据。',
      coverageBands: ['cet6', 'graduate'],
      learningTags: ['考研', '学术'],
    ),
  ];

  test('catalog maps dictionary coverage to learner-friendly sets', () {
    final catalog = LearningSetCatalog.build(
      entries,
      favoriteWords: const ['hello'],
    );

    expect(catalog.first.id, learningDefaultSetId);
    expect(catalog.first.availableCount, 2);
    expect(catalog.byId('primary')!.availableCount, 1);
    expect(catalog.byId('cet6')!.availableCount, 1);
    expect(catalog.byId('graduate')!.availableCount, 1);
    expect(catalog.byId('favorites')!.availableCount, 1);
  });

  test('catalog returns normalized words for a selected set', () {
    final catalog = LearningSetCatalog.build(entries);

    expect(catalog.byId('primary')!.words, ['hello']);
    expect(catalog.byId('favorites')!.words, isEmpty);
  });

  test('sentence answers normalize harmless punctuation and whitespace', () {
    expect(normalizeSentenceAnswer('  Hello,   friend! '), 'hello friend');
    expect(sentenceTokens('Hello, friend!'), ['Hello', 'friend']);
  });
}
