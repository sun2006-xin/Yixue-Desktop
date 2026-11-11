import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_service.dart';

void main() {
  const dictionary = LocalDictionaryService();

  test('looks up local word entries case-insensitively', () {
    expect(dictionary.lookup(' Apple ')?.meanings, contains('苹果'));
    expect(dictionary.lookup('HELLO')?.ipa, '/həˈləʊ/');
  });

  test('looks up indexed English forms by their canonical headword', () {
    expect(dictionary.lookup('abandoned')?.word, 'abandon');
    expect(dictionary.lookup('resolving')?.word, 'resolve');
    expect(dictionary.lookup('reading')?.word, 'reading');
  });

  test('prefers an exact headword when it is another entry’s variant', () {
    expect(dictionary.lookup('rise')?.variants, contains('rose'));
    expect(dictionary.lookup('rose')?.word, 'rose');
  });

  test('trims and normalizes case when looking up indexed variants', () {
    expect(dictionary.lookup(' ABANDONED ')?.word, 'abandon');
  });

  test('returns null for an unknown word', () {
    expect(dictionary.lookup('not-in-seed'), isNull);
  });

  test('only published examples enter the default sentence practice bank', () {
    const authored = DictionaryEntry(
      word: 'practice',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['练习'],
      example: 'Practice makes progress.',
      exampleTranslation: '练习带来进步。',
    );
    const openCandidate = DictionaryEntry(
      word: 'candidate',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['候选'],
      example: 'This is an unreviewed example.',
      exampleTranslation: '这是未经审校的例句。',
      source: 'open-ecdict',
      qualityStatus: 'candidate',
    );
    const publishedOpenExample = DictionaryEntry(
      word: 'reviewed',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['已发布'],
      example: 'The approved main example remains usable.',
      exampleTranslation: '已批准的主例句仍可用于练习。',
      source: 'open-ecdict',
      qualityStatus: 'published_with_candidate_enrichment',
      candidateSourceIds: ['tatoeba-cc-by-2.0-fr'],
    );
    const assistantVerified = DictionaryEntry(
      word: 'assistant-verified',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['机器审校候选'],
      example: 'An assistant-verified candidate.',
      exampleTranslation: '一条机器审校的候选例句。',
      source: 'open-ecdict',
      qualityStatus: 'assistant_verified',
    );
    const draft = DictionaryEntry(
      word: 'draft',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['草稿'],
      example: 'A draft example.',
      exampleTranslation: '一条例句草稿。',
      qualityStatus: 'draft',
    );
    const withdrawn = DictionaryEntry(
      word: 'withdrawn',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['撤回'],
      example: 'A withdrawn example.',
      exampleTranslation: '一条已撤回的例句。',
      qualityStatus: 'withdrawn',
    );
    const empty = DictionaryEntry(
      word: 'empty',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['空'],
      example: '',
      exampleTranslation: '',
    );

    expect(authored.isApprovedSentencePracticeEntry, isTrue);
    expect(openCandidate.isApprovedSentencePracticeEntry, isFalse);
    expect(publishedOpenExample.isApprovedSentencePracticeEntry, isTrue);
    expect(assistantVerified.isApprovedSentencePracticeEntry, isFalse);
    expect(draft.isApprovedSentencePracticeEntry, isFalse);
    expect(withdrawn.isApprovedSentencePracticeEntry, isFalse);
    expect(empty.isApprovedSentencePracticeEntry, isFalse);
  });

  test('finds Chinese meaning terms beyond the curated direct lookup map', () {
    expect(dictionary.lookupChinese('教师')?.word, 'teacher');
    expect(dictionary.lookupChinese(' 教师 ')?.word, 'teacher');
    expect(dictionary.lookupChinese('苹果公司')?.word, 'apple');
  });

  test('prefers an exact headword before fuzzy dictionary results', () {
    const prefix = DictionaryEntry(
      word: 'arun',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['测试前缀词'],
      example: '',
      exampleTranslation: '',
    );
    const exact = DictionaryEntry(
      word: 'run',
      ipa: '',
      partOfSpeech: 'v.',
      meanings: ['跑；运行'],
      example: '',
      exampleTranslation: '',
    );

    expect(bestDictionaryEntryForTerm('run', [prefix, exact])?.word, 'run');
  });

  test('prefers an exact Chinese meaning match before fuzzy results', () {
    const fuzzy = DictionaryEntry(
      word: 'teacher-assistant',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['助理教师'],
      example: '',
      exampleTranslation: '',
    );
    final exact = dictionary.lookup('teacher')!;

    expect(bestDictionaryEntryForTerm('教师', [fuzzy, exact])?.word, 'teacher');
  });

  test(
    'does not mistake a fuzzy substring result for an exact dictionary hit',
    () {
      const unrelated = DictionaryEntry(
        word: 'teacher-assistant',
        ipa: '',
        partOfSpeech: 'n.',
        meanings: ['助理教师'],
        example: '',
        exampleTranslation: '',
      );

      expect(bestDictionaryEntryForTerm('教师', [unrelated]), isNull);
    },
  );

  test('ships a useful self-authored learning seed beyond demo words', () {
    expect(dictionary.entries.length, greaterThanOrEqualTo(240));
    expect(dictionary.lookup('understand')?.meanings, isNotEmpty);
    expect(dictionary.lookup('practice')?.exampleTranslation, isNotEmpty);
    expect(dictionary.lookupChinese('学习')?.word, 'learn');
    expect(dictionary.lookup('ability')?.meanings, containsAll(['能力', '本领']));
    expect(dictionary.lookup('evidence')?.exampleTranslation, '这个结论有证据支持。');
    expect(dictionary.lookup('resource')?.meanings, contains('资源；资料'));
    expect(dictionary.lookupChinese('资源')?.word, 'resource');
    expect(dictionary.lookup('assess')?.meanings, contains('评估；评价'));
    expect(dictionary.lookupChinese('评估')?.word, 'assess');
    expect(dictionary.lookup('academic')?.coverageBands, contains('cet4'));
    expect(
      dictionary.lookup('hypothesis')?.coverageBands,
      contains('graduate'),
    );
    expect(dictionary.lookup('sustainable')?.coverageBands, contains('cet6'));
    expect(dictionary.lookupChinese('学术')?.word, 'academic');
  });

  test('extracts one English word around a caret or selection', () {
    expect(englishWordAtSelection('Hello, teacher!', 1, 1), 'Hello');
    expect(englishWordAtSelection('Hello, teacher!', 14, 14), 'teacher');
    expect(englishWordAtSelection('Hello, teacher!', 7, 14), 'teacher');
    expect(englishWordAtSelection('Don’t panic', 0, 5), "Don't");
  });

  test('extracts one English word or selected Chinese dictionary term', () {
    expect(
      dictionaryTermAtSelection('The learner is studying.', 4, 11),
      'learner',
    );
    expect(dictionaryTermAtSelection('我正在学习语言', 3, 5), '学习');
    expect(dictionaryTermAtSelection('学习', 1, 1), '学习');
    expect(dictionaryTermAtSelection('这是一整句中文内容', 0, 9), isNull);
    expect(dictionaryTermAtSelection('hello world', 0, 11), isNull);
    expect(dictionaryTermAtSelection('学习。', 0, 3), isNull);
    expect(dictionaryTermAtSelection('学习', -1, 1), isNull);
  });

  test('validates screenshot dictionary terms against recognized source', () {
    expect(dictionaryTermAppearsInText('学习', '我正在学习语言'), isTrue);
    expect(dictionaryTermAppearsInText('hello', 'hello world'), isTrue);
    expect(dictionaryTermAppearsInText('hell', 'hello world'), isFalse);
    expect(dictionaryTermAppearsInText('整句', '我正在学习语言'), isFalse);
  });

  test('quick dictionary terms accept one English or Chinese headword', () {
    expect(dictionaryTermAtInput('  Apple  '), 'Apple');
    expect(dictionaryTermAtInput('a'), 'a');
    expect(dictionaryTermAtInput('I'), 'I');
    expect(dictionaryTermAtInput('苹果'), '苹果');
    expect(dictionaryTermAtInput('资源'), '资源');
    expect(dictionaryTermAtInput('hello world'), isNull);
    expect(dictionaryTermAtInput('苹果 apple'), isNull);
    expect(dictionaryTermAtInput(''), isNull);
    expect(dictionary.lookupChinese(dictionaryTermAtInput('苹果')!), isNotNull);
  });

  test(
    'does not extract a phrase or invalid selection as a dictionary word',
    () {
      expect(englishWordAtSelection('hello world', 0, 11), isNull);
      expect(englishWordAtSelection('你好 world', 0, 2), isNull);
      expect(englishWordAtSelection('hello', -1, 2), isNull);
      expect(englishWordAtSelection('hello', 2, 99), isNull);
    },
  );
}
