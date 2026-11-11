import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_cet_open_rich_examples_model.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/vocabulary/favorite_words_workspace.dart';

FavoriteWordPageData _page({bool hasMore = false}) => FavoriteWordPageData(
  hasMore: hasMore,
  records: const [
    FavoriteWordRecordData(
      word: 'consistency',
      favoritedAt: '2026-09-14 12:00:00',
      languagePair: 'en-zh',
      dictionaryEntries: [
        DictionaryEntryData(
          id: 'seed.consistency',
          word: 'consistency',
          ipa: '/kənˈsɪstənsi/',
          partOfSpeech: 'n.',
          meanings: ['一致性；连贯性'],
          example: 'Consistency is the key to success.',
          exampleTranslation: '一致性是成功的关键。',
          source: 'yixue-basic',
        ),
      ],
      annotation: WordAnnotationData(
        word: 'consistency',
        note: '写作常用',
        addedToLearning: true,
        updatedAt: '2026-09-14T12:00:00+08:00',
      ),
    ),
  ],
);

void main() {
  testWidgets('favorite workspace shows a labeled skeleton while loading', (
    tester,
  ) async {
    final pendingPage = Completer<FavoriteWordPageData>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteWordsWorkspace(
            loadPage: ({query = '', limit = 40, offset = 0}) =>
                pendingPage.future,
            setFavoriteWord: (_, _) async {},
            saveWordAnnotation: (_) async {},
            onSpeak: (_) async {},
            onContinueTranslation: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('favorite-words-loading')),
      findsOneWidget,
    );
    expect(find.text('正在读取收藏词条'), findsOneWidget);
    expect(find.text('正在准备词条详情'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    pendingPage.complete(_page());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-words-list')), findsOneWidget);
    expect(find.text('consistency'), findsWidgets);
  });

  testWidgets('favorite refresh keeps the loaded list visible', (tester) async {
    final refreshPage = Completer<FavoriteWordPageData>();
    var loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteWordsWorkspace(
            loadPage: ({query = '', limit = 40, offset = 0}) {
              loadCount++;
              return loadCount == 1
                  ? Future.value(_page())
                  : refreshPage.future;
            },
            setFavoriteWord: (_, _) async {},
            saveWordAnnotation: (_) async {},
            onSpeak: (_) async {},
            onContinueTranslation: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('favorite-words-refresh')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('favorite-word-consistency')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('favorite-words-refresh-progress')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('favorite-words-loading')), findsNothing);

    refreshPage.complete(_page());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('favorite-words-refresh-progress')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('favorite-word-consistency')),
      findsOneWidget,
    );
  });

  testWidgets('favorite detail presents rich learner dictionary context', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const richEntry = DictionaryEntry(
      word: 'consistency',
      ipa: '/kənˈsɪstənsi/',
      partOfSpeech: 'n.',
      meanings: ['一致；连贯'],
      example: 'Consistency matters.',
      exampleTranslation: '一致性很重要。',
      source: 'open-ecdict',
      qualityStatus: 'candidate',
      reviewFields: ['senses', 'examples', 'collocations'],
      variants: ['consistent'],
      collocationCandidates: ['maintain consistency'],
      relationCandidates: {
        'related': ['consistent'],
      },
      pronunciationCandidates: [
        OpenCetRichPronunciationRow(
          value: '/kənˈsɪstənsi/',
          dialect: 'US',
          notation: 'IPA',
          sourceId: 'source-pronunciation',
          partOfSpeech: 'noun',
        ),
      ],
      senseCandidates: [
        OpenCetRichSenseRow(
          sourceId: 'source-sense',
          senseId: 'consistency.n.1',
          partOfSpeech: 'noun',
          englishGlosses: ['the quality of always behaving in the same way'],
          chineseGlosses: ['一致性；始终如一'],
          usageTags: ['formal'],
          sourceExamples: ['The team needs greater consistency.'],
          qualifier: 'formal',
        ),
      ],
      exampleCandidates: [
        OpenCetRichExampleRow(
          exampleId: 'example-1',
          sourceId: 'source-example',
          englishText: 'The team needs greater consistency.',
          chineseText: '团队需要更强的一致性。',
          englishUsername: 'source-a',
          chineseUsername: 'source-b',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteWordsWorkspace(
            loadPage: ({query = '', limit = 40, offset = 0}) async => _page(),
            lookupRichEntry: (_) async => richEntry,
            setFavoriteWord: (_, _) async {},
            saveWordAnnotation: (_) async {},
            onSpeak: (_) async {},
            onContinueTranslation: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final text in [
      '以下补充内容来自候选词典数据，尚待编辑核验；请结合上下文判断。',
      '词形',
      'consistent',
      '搭配候选',
      'maintain consistency',
      '例句候选',
      '团队需要更强的一致性。',
    ]) {
      await tester.scrollUntilVisible(
        find.text(text),
        220,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(text), findsOneWidget, reason: 'missing $text');
    }
  });

  testWidgets('favorite workspace exposes details and learning actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    WordAnnotationData? saved;
    String? continued;
    String? changedWord;
    var changedFavorite = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteWordsWorkspace(
            loadPage: ({query = '', limit = 40, offset = 0}) async => _page(),
            setFavoriteWord: (word, favorite) async {
              changedWord = word;
              changedFavorite = favorite;
            },
            saveWordAnnotation: (annotation) async => saved = annotation,
            onSpeak: (_) async {},
            onContinueTranslation: (word) => continued = word,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('favorite-words-workspace')),
      findsOneWidget,
    );
    expect(find.text('consistency'), findsWidgets);
    final continueButton = find.byKey(
      const ValueKey('favorite-words-open-translation'),
    );
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    expect(continued, 'consistency');

    await tester.scrollUntilVisible(
      find.text('Consistency is the key to success.'),
      220,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Consistency is the key to success.'), findsOneWidget);
    expect(find.text('一致性是成功的关键。'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('favorite-word-note')),
      220,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const ValueKey('favorite-word-note')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorite-word-save-note')));
    expect(saved, isNotNull);

    final unfavoriteButton = find.byKey(
      const ValueKey('favorite-word-unfavorite'),
    );
    await tester.ensureVisible(unfavoriteButton);
    await tester.tap(unfavoriteButton);
    await tester.pumpAndSettle();
    expect(changedWord, 'consistency');
    expect(changedFavorite, isFalse);
  });

  testWidgets('joining learning updates the actual review queue callback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    WordAnnotationData? saved;
    final learningChanges = <(String, bool)>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteWordsWorkspace(
            loadPage: ({query = '', limit = 40, offset = 0}) async => _page(),
            setFavoriteWord: (_, _) async {},
            saveWordAnnotation: (annotation) async => saved = annotation,
            setWordLearning: (word, enabled) async {
              learningChanges.add((word, enabled));
            },
            onSpeak: (_) async {},
            onContinueTranslation: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final learningToggle = find.byKey(
      const ValueKey('favorite-word-learning-toggle'),
    );
    await tester.scrollUntilVisible(
      learningToggle,
      220,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(learningToggle);
    await tester.pumpAndSettle();

    expect(learningChanges, [('consistency', false)]);
    expect(saved?.word, 'consistency');
    expect(saved?.addedToLearning, isFalse);
  });

  testWidgets(
    'favorite workspace requests the next page without a storage cap',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FavoriteWordsWorkspace(
              loadPage: ({query = '', limit = 40, offset = 0}) async {
                offsets.add(offset);
                return _page(hasMore: offset == 0);
              },
              setFavoriteWord: (_, _) async {},
              saveWordAnnotation: (_) async {},
              onSpeak: (_) async {},
              onContinueTranslation: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorite-words-load-more')));
      await tester.pumpAndSettle();

      expect(offsets, [0, 1]);
    },
  );
}
