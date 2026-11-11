import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_cet_open_entries.dart';
import 'package:yixue_app/core/dictionary_cet_open_rich_examples_model.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_articles.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/learning_speech_service.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/settings/content_library_workspace.dart';
import 'package:yixue_app/features/learning/learning_workspace.dart';
import 'package:yixue_app/features/learning/learning_article_workbench.dart';
import 'package:yixue_app/features/learning/learning_textbook_workspace.dart';

class _FakeSpeechRecognizer implements LearningSpeechRecognizer {
  LearningSpeechResultCallback? _onResult;

  @override
  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String message) onError,
  }) async => true;

  @override
  Future<void> listen({
    required String localeId,
    required LearningSpeechResultCallback onResult,
  }) async {
    _onResult = onResult;
  }

  void emit(String text, {bool isFinal = true}) =>
      _onResult?.call(text, isFinal);

  @override
  bool get isListening => true;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _DeferredLearningStore implements LearningStore {
  final Completer<void> _readGate = Completer<void>();
  final MemoryLearningStore _delegate = MemoryLearningStore();

  void releaseReads() {
    if (!_readGate.isCompleted) _readGate.complete();
  }

  @override
  Future<LearningStateData?> read() async {
    await _readGate.future;
    return _delegate.read();
  }

  @override
  Future<void> write(LearningStateData state) => _delegate.write(state);

  @override
  Future<void> clear() => _delegate.clear();
}

class _ToggleFailLearningStore implements LearningStore {
  final MemoryLearningStore _delegate = MemoryLearningStore();
  bool failWrites = false;

  @override
  Future<LearningStateData?> read() => _delegate.read();

  @override
  Future<void> write(LearningStateData state) async {
    if (failWrites) throw StateError('simulated local storage failure');
    await _delegate.write(state);
  }

  @override
  Future<void> clear() => _delegate.clear();
}

void main() {
  test('built-in article questions point to valid choices and evidence', () {
    expect(builtInLearningArticles, hasLength(greaterThanOrEqualTo(8)));
    for (final article in builtInLearningArticles) {
      expect(
        article.paragraphs,
        hasLength(greaterThanOrEqualTo(5)),
        reason: article.id,
      );
      expect(
        article.questions,
        hasLength(greaterThanOrEqualTo(2)),
        reason: article.id,
      );
      final questionIds = article.questions.map((question) => question.id);
      expect(
        questionIds.toSet().length,
        questionIds.length,
        reason: article.id,
      );
      for (final question in article.questions) {
        expect(question.choices.length, greaterThanOrEqualTo(2));
        expect(
          question.correctChoiceIndex,
          inInclusiveRange(0, question.choices.length - 1),
        );
        expect(
          question.evidenceParagraphIndex,
          inInclusiveRange(0, article.paragraphCount - 1),
        );
      }
    }
  });

  test(
    'article text selection opens lookup only for one exact dictionary term',
    () {
      expect(
        learningArticleDictionaryTermFromSelection(
          'A habit can change how we learn.',
          const TextSelection(baseOffset: 2, extentOffset: 7),
        ),
        'habit',
      );
      expect(
        learningArticleDictionaryTermFromSelection(
          '一个好习惯会改变学习方式。',
          const TextSelection(baseOffset: 2, extentOffset: 5),
        ),
        '好习惯',
      );
      expect(
        learningArticleDictionaryTermFromSelection(
          'A habit can change how we learn.',
          const TextSelection(baseOffset: 2, extentOffset: 12),
        ),
        isNull,
      );
      expect(
        learningArticleDictionaryTermFromSelection(
          'A habit can change how we learn.',
          const TextSelection.collapsed(offset: 7),
        ),
        isNull,
      );
    },
  );

  const entry = DictionaryEntry(
    word: 'hello',
    ipa: '/həˈləʊ/',
    partOfSpeech: 'interj. 感叹词',
    meanings: ['你好', '喂'],
    example: 'Hello, it is good to meet you.',
    exampleTranslation: '你好，很高兴见到你。',
    variants: ['helloed'],
  );
  final now = DateTime(2026, 9, 16, 10, 30);

  Widget app(
    LearningStore store, {
    LearningSpeechRecognizer? speechRecognizer,
    LearningTextbookStore? textbookStore,
    List<DictionaryEntry>? dictionaryEntries,
    Future<DictionaryEntry?> Function(String word)? lookupDictionary,
    List<String> favoriteWords = const [],
    void Function(VoidCallback openTextbooks)? onOpenContentLibrary,
    VoidCallback? onOpenUnderstandingModelSettings,
    LearningSentenceExerciseGenerator? generateSentenceExercises,
    DateTime Function()? clock,
  }) => MaterialApp(
    home: LearningWorkspace(
      store: store,
      loadEntries: () async => dictionaryEntries ?? const [entry],
      lookupDictionary: lookupDictionary,
      loadFavoriteWords: () async => favoriteWords,
      speechRecognizer: speechRecognizer,
      textbookStore: textbookStore,
      onOpenContentLibrary: onOpenContentLibrary,
      onOpenUnderstandingModelSettings: onOpenUnderstandingModelSettings,
      onGenerateSentenceExercises: generateSentenceExercises,
      clock: clock ?? () => now,
    ),
  );

  Future<void> openArticleHub(WidgetTester tester) async {
    final articleCard = find.byKey(const ValueKey('learning-card-article'));
    await tester.ensureVisible(articleCard);
    await tester.tap(articleCard);
    await tester.pumpAndSettle();
  }

  Future<void> openArticleWorkbenchFromHub(WidgetTester tester) async {
    await openArticleHub(tester);
    final sourceSettings = find.byKey(
      const ValueKey('learning-article-source-settings'),
    );
    await tester.ensureVisible(sourceSettings);
    await tester.tap(sourceSettings);
    await tester.pumpAndSettle();
  }

  Future<void> openSentenceHub(WidgetTester tester) async {
    final track = find.byKey(const ValueKey('learning-track-sentence'));
    await tester.ensureVisible(track);
    await tester.tap(track);
    await tester.pumpAndSettle();
  }

  Future<void> expandSentenceSettings(WidgetTester tester) async {
    final settings = find.byKey(const ValueKey('learning-sentence-settings'));
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    await tester.pumpAndSettle();
  }

  Future<void> startSentenceRound(WidgetTester tester) async {
    final start = find.byKey(const ValueKey('learning-sentence-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'article text selection looks up a user dictionary entry missing from the seed list',
    (tester) async {
      final lookups = <String>[];
      await tester.pumpWidget(
        app(
          MemoryLearningStore(),
          dictionaryEntries: const [],
          lookupDictionary: (word) async {
            lookups.add(word);
            if (word != 'habit') return null;
            return const DictionaryEntry(
              word: 'habit',
              ipa: '/ˈhæbɪt/',
              partOfSpeech: 'n. 名词',
              meanings: ['来自已配置词典的释义'],
              example: 'A user dictionary example.',
              exampleTranslation: '用户词典例句。',
              source: 'user-imported',
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await openArticleWorkbenchFromHub(tester);

      final paragraphText = 'A small habit can change the way we learn.';
      final paragraphFinder = find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == paragraphText,
      );
      expect(paragraphFinder, findsOneWidget);
      final paragraph = tester.widget<SelectableText>(paragraphFinder);
      paragraph.onSelectionChanged!(
        const TextSelection(baseOffset: 8, extentOffset: 13),
        SelectionChangedCause.longPress,
      );
      await tester.pumpAndSettle();

      expect(lookups, ['habit']);
      expect(
        find.byKey(const ValueKey('learning-article-word-detail')),
        findsOneWidget,
      );
      expect(find.text('1. 来自已配置词典的释义'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable article sources are disabled and explain usable alternatives',
    (tester) async {
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();
      await openArticleWorkbenchFromHub(tester);

      const unavailableSources = <String>[
        'web',
        'localEnglish',
        'localChinese',
      ];
      for (final source in unavailableSources) {
        final card = find.byKey(ValueKey('learning-article-source-$source'));
        expect(card, findsOneWidget);
        expect(tester.widget<InkWell>(card).onTap, isNull);
        expect(
          find.byKey(ValueKey('learning-article-source-unavailable-$source')),
          findsOneWidget,
        );
        await tester.tap(card, warnIfMissed: false);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('learning-article-source-placeholder')),
          findsNothing,
        );
      }

      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('learning-article-source-builtIn')),
            )
            .onTap,
        isNotNull,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('learning-article-source-textbook')),
            )
            .onTap,
        isNotNull,
      );
      expect(
        find.text('A small habit can change the way we learn.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> openArticleHubShortcut(WidgetTester tester, String label) async {
    final shortcut = find.text(label);
    await tester.ensureVisible(shortcut);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'starts a card, reveals dictionary details, and records mastery',
    (tester) async {
      final store = MemoryLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-home-header')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('learning-start')), findsOneWidget);
      final start = find.byKey(const ValueKey('learning-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(find.byKey(const ValueKey('learning-reveal')), findsOneWidget);
      final reveal = find.byKey(const ValueKey('learning-reveal'));
      await tester.ensureVisible(reveal);
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(find.textContaining('你好'), findsWidgets);
      expect(find.text('你好，很高兴见到你。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-screenshot-meaning-field')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-screenshot-source-context')),
        findsNothing,
      );

      final mastered = find.byKey(const ValueKey('learning-result-mastered'));
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      final state = await store.read();
      expect(state!.reviews, hasLength(1));
      expect(state.reviews.single.result, LearningReviewResult.mastered);
      expect(state.session, isNull);
      expect(find.text('本轮学习完成'), findsOneWidget);
    },
  );

  testWidgets(
    'written recall stays for self-check and clears on the next word',
    (tester) async {
      const nextEntry = DictionaryEntry(
        word: 'world',
        ipa: '/wɜːld/',
        partOfSpeech: 'n.',
        meanings: ['世界'],
        example: 'The world is full of small wonders.',
        exampleTranslation: '世界充满了小小的奇迹。',
      );
      final store = MemoryLearningStore();
      await tester.pumpWidget(
        app(store, dictionaryEntries: const [entry, nextEntry]),
      );
      await tester.pumpAndSettle();

      final start = find.byKey(const ValueKey('learning-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();

      final recallField = find.byKey(const ValueKey('learning-recall-answer'));
      expect(recallField, findsOneWidget);
      expect(tester.widget<TextField>(recallField).readOnly, isFalse);
      await tester.enterText(recallField, '喂，打招呼');
      await tester.tap(find.byKey(const ValueKey('learning-reveal')));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(recallField).controller!.text, '喂，打招呼');
      expect(tester.widget<TextField>(recallField).readOnly, isTrue);
      expect(find.textContaining('你好'), findsWidgets);

      final mastered = find.byKey(const ValueKey('learning-result-mastered'));
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      expect(find.text('world'), findsOneWidget);
      expect(tester.widget<TextField>(recallField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(recallField).readOnly, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'screenshot word hides saved context until reveal, then saves a user-confirmed meaning',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.addScreenshotWord(
        word: 'quasar',
        sourceContext: 'A quasar shines across the distant galaxy.',
        sourceTranslation: '类星体的光芒穿过遥远的星系。',
        sourceHistoryId: 'history-learning-unknown',
      );
      await repository.startSession(
        setId: learningScreenshotWordsSetId,
        mode: LearningPromptMode.recognition,
        now: now,
      );
      await tester.pumpWidget(app(store, dictionaryEntries: const []));
      await tester.pumpAndSettle();
      final continueSession = find.byKey(const ValueKey('learning-start'));
      await tester.ensureVisible(continueSession);
      await tester.tap(continueSession);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-screenshot-source-context')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-screenshot-source-translation')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-screenshot-meaning-field')),
        findsNothing,
      );
      expect(
        find.text('A quasar shines across the distant galaxy.'),
        findsNothing,
      );
      expect(find.text('类星体的光芒穿过遥远的星系。'), findsNothing);
      expect(find.text('尚未填写释义'), findsNothing);
      expect(find.text('查看答案后显示截图原文、译文快照和词义。'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('learning-reveal')));
      await tester.pumpAndSettle();
      expect(find.text('查看答案后显示截图原文、译文快照和词义。'), findsNothing);
      expect(find.text('尚未填写释义'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-screenshot-source-context')),
        findsOneWidget,
      );
      expect(
        find.text('A quasar shines across the distant galaxy.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-screenshot-source-translation')),
        findsOneWidget,
      );
      expect(find.text('类星体的光芒穿过遥远的星系。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-screenshot-meaning-field')),
        findsOneWidget,
      );

      final meaningField = find.byKey(
        const ValueKey('learning-screenshot-meaning-field'),
      );
      await tester.ensureVisible(meaningField);
      await tester.enterText(meaningField, '类星体（用户确认）');
      final saveMeaning = find.byKey(
        const ValueKey('learning-screenshot-save-meaning'),
      );
      await tester.ensureVisible(saveMeaning);
      await tester.tap(saveMeaning);
      await tester.pumpAndSettle();

      final saved = (await store.read())!.items.single;
      expect(saved.meaning, '类星体（用户确认）');
      expect(saved.meaningSource, 'user');
      expect(find.text('类星体（用户确认）'), findsWidgets);
      expect(find.text('你填写的释义'), findsOneWidget);
    },
  );

  testWidgets(
    'screenshot card names dictionary source and keeps it read-only',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.addScreenshotWord(
        word: 'quasar',
        sourceContext: 'A quasar shines.',
        sourceTranslation: '类星体很亮。',
        sourceHistoryId: 'history-learning-dictionary',
        dictionaryMeaning: '类星体',
      );
      await repository.startSession(
        setId: learningScreenshotWordsSetId,
        mode: LearningPromptMode.recognition,
        now: now,
      );
      await tester.pumpWidget(
        app(
          store,
          dictionaryEntries: const [
            DictionaryEntry(
              word: 'quasar',
              ipa: '/ˈkweɪzɑːr/',
              partOfSpeech: 'n. 名词',
              meanings: ['类星体'],
              example: '',
              exampleTranslation: '',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final continueSession = find.byKey(const ValueKey('learning-start'));
      await tester.ensureVisible(continueSession);
      await tester.tap(continueSession);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('learning-reveal')));
      await tester.pumpAndSettle();
      expect(find.text('类星体'), findsWidgets);
      expect(find.text('本地词典释义'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('learning-screenshot-meaning-field')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'screenshot word variants stay hidden until the review answer is revealed',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.addScreenshotWord(
        word: 'hello',
        sourceContext: 'Hello again.',
        sourceTranslation: '再次你好。',
        sourceHistoryId: 'history-variants-review',
      );
      await repository.startSession(
        setId: learningScreenshotWordsSetId,
        mode: LearningPromptMode.variants,
        now: now,
      );
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      final continueSession = find.byKey(const ValueKey('learning-start'));
      await tester.ensureVisible(continueSession);
      await tester.tap(continueSession);
      await tester.pumpAndSettle();

      expect(find.text('helloed'), findsNothing);
      expect(find.text('查看答案后显示词形变化'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('learning-reveal')));
      await tester.pumpAndSettle();
      expect(find.text('helloed'), findsOneWidget);
      expect(find.text('查看答案后显示词形变化'), findsNothing);
    },
  );

  testWidgets(
    'screenshot words are discoverable in vocabulary and start a review session',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.addScreenshotWord(
        word: 'literature',
        sourceContext: 'The literature review summarizes recent findings.',
        sourceTranslation: '文献综述总结了近期研究成果。',
        sourceHistoryId: 'history-vocabulary-integration',
      );

      await tester.pumpWidget(
        app(
          store,
          dictionaryEntries: const [
            DictionaryEntry(
              word: 'literature',
              ipa: '/ˈlɪtərətʃə/',
              partOfSpeech: 'n. 名词',
              meanings: ['文学；文献'],
              example: '',
              exampleTranslation: '',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
      await tester.pumpAndSettle();

      final screenshotWords = find.byKey(
        const ValueKey('learning-vocabulary-stage-screenshot-words'),
      );
      expect(screenshotWords, findsOneWidget);
      await tester.tap(screenshotWords);
      await tester.pumpAndSettle();

      expect(find.text('词库预览 · 截屏生词'), findsOneWidget);
      expect(find.text('共 1 词 · 可结合截图原文与译文复习'), findsOneWidget);
      expect(find.text('literature'), findsOneWidget);
      final details = find.byKey(
        const ValueKey('learning-vocabulary-open-list'),
      );
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      final screenshotWordRow = find.byKey(
        const ValueKey('learning-screenshot-word-literature'),
      );
      expect(screenshotWordRow, findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('learning-vocabulary-search')),
        '文献综述',
      );
      await tester.pumpAndSettle();
      expect(screenshotWordRow, findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('learning-vocabulary-back-to-ranges')),
      );
      await tester.pumpAndSettle();

      final startCycle = find.byKey(
        const ValueKey('learning-vocabulary-start-cycle'),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('learning-start')))
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(startCycle);
      await tester.tap(startCycle);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
      expect(find.text('literature'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('learning-reveal')));
      await tester.pumpAndSettle();
      expect(
        find.text('The literature review summarizes recent findings.'),
        findsOneWidget,
      );
      expect(find.text('文献综述总结了近期研究成果。'), findsOneWidget);
    },
  );

  testWidgets('reloads with the same active queue and supports a note', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('learning-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();

    final firstState = await store.read();
    expect(firstState!.session, isNotNull);
    final currentWord = firstState.session!.currentItemId!;

    final note = find.byKey(const ValueKey('learning-note-field'));
    await tester.ensureVisible(note);
    await tester.enterText(note, '先记住问候语境');
    final saveNote = find.byKey(const ValueKey('learning-save-note'));
    await tester.ensureVisible(saveNote);
    await tester.tap(saveNote);
    await tester.pumpAndSettle();
    expect(find.text('笔记已保存'), findsOneWidget);

    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    final restored = await store.read();
    expect(restored!.session!.currentItemId, currentWord);
    expect(find.textContaining('正在学习'), findsOneWidget);
    expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
  });

  testWidgets('compact learning layout stays scrollable without exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(560, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(MemoryLearningStore()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('learning-start')), findsOneWidget);
  });

  testWidgets(
    'learning startup shows useful loading feedback while local data is pending',
    (tester) async {
      final store = _DeferredLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('learning-loading-skeleton')),
        findsOneWidget,
      );
      expect(find.text('正在准备你的学习空间'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      store.releaseReads();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('learning-start')), findsOneWidget);
    },
  );

  testWidgets('learning landing shows four independent study cards', (
    tester,
  ) async {
    await tester.pumpWidget(app(MemoryLearningStore()));
    await tester.pumpAndSettle();

    for (final id in ['vocabulary', 'pronunciation', 'sentence', 'article']) {
      expect(find.byKey(ValueKey('learning-card-$id')), findsOneWidget);
    }
    final vocabularyRect = tester.getRect(
      find.byKey(const ValueKey('learning-card-vocabulary')),
    );
    final pronunciationRect = tester.getRect(
      find.byKey(const ValueKey('learning-card-pronunciation')),
    );
    final sentenceRect = tester.getRect(
      find.byKey(const ValueKey('learning-card-sentence')),
    );
    final articleRect = tester.getRect(
      find.byKey(const ValueKey('learning-card-article')),
    );
    expect(pronunciationRect.top, closeTo(vocabularyRect.top, 0.1));
    expect(sentenceRect.top, greaterThan(vocabularyRect.bottom));
    expect(articleRect.top, closeTo(sentenceRect.top, 0.1));
    expect(find.byKey(const ValueKey('learning-card-textbook')), findsNothing);

    final vocabulary = find.byKey(const ValueKey('learning-card-vocabulary'));
    await tester.ensureVisible(vocabulary);
    await tester.tap(vocabulary);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-vocabulary-range-deck')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('learning-back')), findsOneWidget);

    final back = find.byKey(const ValueKey('learning-back'));
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('learning-plan-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('learning-header-quote')), findsNothing);
  });

  testWidgets(
    'learning landing opens the shared dictionary and content library',
    (tester) async {
      var opened = 0;
      VoidCallback? openTextbooks;
      await tester.pumpWidget(
        app(
          MemoryLearningStore(),
          onOpenContentLibrary: (callback) {
            opened++;
            openTextbooks = callback;
          },
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(
        const ValueKey('learning-open-content-library'),
      );
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(opened, 1);
      expect(openTextbooks, isNotNull);
      expect(
        find.byKey(const ValueKey('learning-card-vocabulary')),
        findsOneWidget,
      );
      openTextbooks!();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-textbook-workspace')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'learning landing presents the connected study path and plan strip',
    (tester) async {
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('learning-plan-strip')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-plan-due-count')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('learning-plan-today')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-plan-continue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-module-grid')),
        findsOneWidget,
      );
      expect(find.text('学习路径'), findsOneWidget);
      expect(find.text('从查词到真正会用'), findsOneWidget);
    },
  );

  testWidgets('learning landing connects lookup, review, and practice', (
    tester,
  ) async {
    await tester.pumpWidget(app(MemoryLearningStore()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('learning-home-header')), findsOneWidget);
    expect(find.text('学习路径'), findsOneWidget);
    expect(find.text('从查词到真正会用'), findsOneWidget);
    expect(find.textContaining('文章或截图中查词收藏'), findsOneWidget);
    expect(find.text('开始今日计划'), findsOneWidget);
    expect(find.text('间隔复习到期词，再补充新词'), findsOneWidget);
    expect(find.text('跟读词音，记录自我评估'), findsOneWidget);
    expect(find.text('在语境中回忆并运用表达'), findsOneWidget);
    expect(find.text('文章精读'), findsOneWidget);
    expect(find.text('按段精读，查词收藏并保存进度'), findsOneWidget);
    expect(find.text('把查到的词，练成会用的表达。'), findsOneWidget);

    expect(
      find.byKey(const ValueKey('learning-plan-progress')),
      findsOneWidget,
    );
    expect(find.text('词汇循环 · 今日目标 10 词'), findsOneWidget);
    expect(find.text('0 / 10 词已完成'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-track-status-article')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-track-progress-article')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('learning-plan-rest')), findsNothing);
    expect(find.text('四种方式，彼此独立'), findsNothing);
    expect(find.text('进入学习'), findsNothing);
    expect(find.text('教材课程属于文章内容来源 · 打开课程管理'), findsNothing);
  });

  testWidgets('today plan prioritizes due vocabulary over its daily rotation', (
    tester,
  ) async {
    final tomorrow = now.add(const Duration(days: 1));
    final store = MemoryLearningStore();
    final repository = LearningRepository(store, clock: () => tomorrow);
    await repository.ensureDefaultSet(const [], now: tomorrow);
    await repository.setWordEnabled('hello', enabled: true, now: tomorrow);

    await tester.pumpWidget(app(store, clock: () => tomorrow));
    await tester.pumpAndSettle();

    expect(find.text('词汇循环 · 今日目标 10 词'), findsOneWidget);
    expect(find.textContaining('当前待复习 1 词'), findsOneWidget);
  });

  testWidgets('learning home summarizes saved article reading progress', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    final repository = LearningRepository(store, clock: () => now);
    await repository.ensureDefaultSet(const [], now: now);
    await repository.saveArticleProgress(
      LearningArticleProgressData(
        articleId: 'evidence-and-clarity',
        title: 'Clear Ideas Need Evidence',
        currentParagraph: 3,
        completedParagraphs: const [0, 1, 2],
        favoriteParagraphs: const [],
        lookedUpWords: const [],
        lastReadAt: now.toIso8601String(),
      ),
    );

    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('learning-track-status-article')),
          )
          .data,
      '${builtInLearningArticles.length} 篇可读 · 已读 3 段',
    );
  });

  testWidgets(
    'vocabulary range selection matches preview and opens details separately',
    (tester) async {
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-vocabulary-range-deck')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-preview')),
        findsOneWidget,
      );
      expect(find.text('选择词库，开启专属的词汇循环。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-vocabulary-list-panel')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-search')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-config')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-stage-strip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-start-cycle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-shortcuts')),
        findsNothing,
      );
      final details = find.byKey(
        const ValueKey('learning-vocabulary-open-list'),
      );
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-vocabulary-list-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-range-deck')),
        findsNothing,
      );
      final search = find.byKey(const ValueKey('learning-vocabulary-search'));
      expect(search, findsOneWidget);
      await tester.enterText(search, 'hello');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-vocabulary-entry-hello')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('learning-vocabulary-back-to-ranges')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-vocabulary-range-deck')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-vocabulary-list-panel')),
        findsNothing,
      );
    },
  );

  testWidgets('vocabulary entry opens a structured learner dictionary card', (
    tester,
  ) async {
    const resolveEntry = DictionaryEntry(
      word: 'resolve',
      ipa: '/rɪˈzɒlv/',
      partOfSpeech: 'v. 动词',
      meanings: ['解决；处理', '下定决心'],
      example: 'We need to resolve this issue today.',
      exampleTranslation: '我们需要今天解决这个问题。',
      variants: ['resolves', 'resolved', 'resolving'],
      collocationCandidates: ['resolve an issue', 'resolve to do something'],
      source: 'open-ecdict',
      partOfSpeechCandidates: const [
        OpenCetRichPartOfSpeechRow(value: 'vt.', sourceId: 'open-ecdict'),
      ],
      pronunciationCandidates: const [
        OpenCetRichPronunciationRow(
          value: '/rɪˈzɒlv/',
          dialect: 'uk',
          notation: 'ipa',
          sourceId: 'open-ecdict',
          partOfSpeech: 'verb',
        ),
      ],
      senseCandidates: const [
        OpenCetRichSenseRow(
          sourceId: 'open-ecdict',
          senseId: 'resolve-verb-1',
          partOfSpeech: 'verb',
          englishGlosses: ['to find a solution to a problem'],
          chineseGlosses: ['解决问题；找到解决办法'],
          usageTags: ['transitive'],
          sourceExamples: ['They resolved the dispute.'],
          qualifier: 'general',
        ),
      ],
    );
    await tester.pumpWidget(
      app(MemoryLearningStore(), dictionaryEntries: const [resolveEntry]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
    await tester.pumpAndSettle();
    final details = find.byKey(const ValueKey('learning-vocabulary-open-list'));
    await tester.ensureVisible(details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('learning-vocabulary-search'));
    await tester.enterText(search, 'resolve');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('learning-vocabulary-entry-resolve')),
    );
    await tester.pumpAndSettle();

    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('解决；处理'), findsOneWidget);
    expect(find.text('下定决心'), findsOneWidget);
    expect(find.text('例句'), findsOneWidget);
    expect(find.text('We need to resolve this issue today.'), findsOneWidget);
    expect(find.text('我们需要今天解决这个问题。'), findsOneWidget);
    final usage = find.byKey(
      const ValueKey('learning-vocabulary-usage-resolve'),
    );
    await tester.ensureVisible(usage);
    final usageTitle = find.text('用法与词形线索（待核对）');
    await tester.ensureVisible(usageTitle);
    await tester.tap(usageTitle);
    await tester.pumpAndSettle();
    expect(find.text('用法与词形线索（待核对）'), findsOneWidget);
    expect(find.text('词形候选：resolves · resolved · resolving'), findsOneWidget);
    expect(find.text('搭配线索'), findsOneWidget);
    expect(find.text('resolve an issue'), findsOneWidget);
    expect(find.text('resolve to do something'), findsOneWidget);
    expect(find.text('词性线索（待人工核对）'), findsOneWidget);
    expect(find.text('vt.'), findsOneWidget);
    expect(find.text('来源读音线索（待人工核对）'), findsOneWidget);
    expect(find.text('英式 · IPA · /rɪˈzɒlv/'), findsOneWidget);
    expect(find.text('来源词义线索（待人工核对）'), findsOneWidget);
    expect(find.text('to find a solution to a problem'), findsOneWidget);
    expect(find.text('解决问题；找到解决办法'), findsOneWidget);
    expect(find.textContaining('They resolved the dispute.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'learner dictionary separates reviewed content from source candidates and reflects favorite state',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const reviewedEntry = DictionaryEntry(
        word: 'clarify',
        ipa: '/ˈklærɪfaɪ/',
        partOfSpeech: 'v. 动词',
        meanings: ['澄清；阐明'],
        example: 'Please clarify the main point.',
        exampleTranslation: '请阐明主要观点。',
        source: 'yixue-basic',
        qualityStatus: 'published',
      );
      const candidateEntry = DictionaryEntry(
        word: 'resolve',
        ipa: '/rɪˈzɒlv/',
        partOfSpeech: 'v. 动词',
        meanings: ['解决；处理'],
        example: 'They resolved the dispute.',
        exampleTranslation: '他们解决了争议。',
        source: 'open-ecdict',
        qualityStatus: 'assistant_verified_with_gaps',
        reviewFields: ['pronunciation'],
        exampleCandidates: [
          OpenCetRichExampleRow(
            exampleId: 'resolve-example-1',
            sourceId: 'tatoeba-cc-by-2.0-fr',
            englishText: 'They resolved the dispute.',
            chineseText: '他们解决了争议。',
            englishUsername: 'source-en',
            chineseUsername: 'source-zh',
          ),
        ],
      );

      await tester.pumpWidget(
        app(
          MemoryLearningStore(),
          dictionaryEntries: const [reviewedEntry, candidateEntry],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
      await tester.pumpAndSettle();
      final openList = find.byKey(
        const ValueKey('learning-vocabulary-open-list'),
      );
      await tester.ensureVisible(openList);
      await tester.tap(openList);
      await tester.pumpAndSettle();

      final search = find.byKey(const ValueKey('learning-vocabulary-search'));
      await tester.enterText(search, 'clarify');
      await tester.pumpAndSettle();
      final reviewedTile = find.byKey(
        const ValueKey('learning-vocabulary-entry-clarify'),
      );
      await tester.tap(reviewedTile);
      await tester.pumpAndSettle();

      expect(find.text('译学已审校'), findsOneWidget);
      expect(find.text('澄清；阐明'), findsOneWidget);
      expect(find.text('Please clarify the main point.'), findsOneWidget);
      final favoriteButton = find.descendant(
        of: reviewedTile,
        matching: find.byTooltip('收藏单词'),
      );
      expect(favoriteButton, findsOneWidget);
      final favoriteButtonControl = find.ancestor(
        of: favoriteButton,
        matching: find.byType(IconButton),
      );
      expect(
        tester.widget<IconButton>(favoriteButtonControl.first).isSelected,
        isFalse,
      );
      await tester.tap(favoriteButton);
      await tester.pumpAndSettle();
      final savedFavoriteButton = find.descendant(
        of: reviewedTile,
        matching: find.byTooltip('取消收藏'),
      );
      expect(savedFavoriteButton, findsOneWidget);
      final savedFavoriteButtonControl = find.ancestor(
        of: savedFavoriteButton,
        matching: find.byType(IconButton),
      );
      expect(
        tester.widget<IconButton>(savedFavoriteButtonControl.first).isSelected,
        isTrue,
      );

      await tester.enterText(search, 'resolve');
      await tester.pumpAndSettle();
      final candidateTile = find.byKey(
        const ValueKey('learning-vocabulary-entry-resolve'),
      );
      await tester.tap(candidateTile);
      await tester.pumpAndSettle();
      expect(find.text('AI 来源已核对 · 有字段待补'), findsOneWidget);
      expect(find.text('They resolved the dispute.'), findsNothing);

      final candidateDetails = find.byKey(
        const ValueKey('learning-vocabulary-usage-resolve'),
      );
      await tester.ensureVisible(candidateDetails);
      await tester.tap(find.text('用法与词形线索（待核对）'));
      await tester.pumpAndSettle();
      expect(find.text('来源例句（待核对）'), findsOneWidget);
      expect(find.text('They resolved the dispute.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('vocabulary range page starts its own real word session', (
    tester,
  ) async {
    await tester.pumpWidget(app(MemoryLearningStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
    await tester.pumpAndSettle();

    final startCycle = find.byKey(
      const ValueKey('learning-vocabulary-start-cycle'),
    );
    await tester.ensureVisible(startCycle);
    await tester.tap(startCycle);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('selecting a study stage changes the preview and study set', (
    tester,
  ) async {
    const cetWord = DictionaryEntry(
      word: 'study',
      ipa: '/ˈstʌdi/',
      partOfSpeech: 'v.',
      meanings: ['学习'],
      example: 'I study every day.',
      exampleTranslation: '我每天学习。',
      coverageBands: ['cet4'],
    );
    await tester.pumpWidget(
      app(MemoryLearningStore(), dictionaryEntries: const [entry, cetWord]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-vocabulary-range-deck')),
      findsOneWidget,
    );
    expect(find.text('词库预览 · 英语四级'), findsOneWidget);
    expect(find.text('study'), findsOneWidget);
    expect(find.text('hello'), findsNothing);

    final high = find.byKey(
      const ValueKey('learning-vocabulary-stage-high-all'),
    );
    final highRect = tester.getRect(high);
    await tester.tapAt(Offset(highRect.left + 12, highRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('词库预览 · 高中阶段'), findsOneWidget);
    expect(find.text('这个范围暂时没有可学习词条'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('learning-start')))
          .onPressed,
      isNull,
    );

    final four = find.byKey(const ValueKey('learning-vocabulary-stage-cet4'));
    final fourRect = tester.getRect(four);
    await tester.tapAt(Offset(fourRect.right - 12, fourRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('词库预览 · 英语四级'), findsOneWidget);
    expect(find.text('study'), findsOneWidget);

    final startCycle = find.byKey(
      const ValueKey('learning-vocabulary-start-cycle'),
    );
    await tester.ensureVisible(startCycle);
    await tester.tap(startCycle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('learning-word-card')), findsOneWidget);
    expect(find.text('study'), findsOneWidget);
  });

  testWidgets('the combined college stage can switch to six-level words', (
    tester,
  ) async {
    const four = DictionaryEntry(
      word: 'study',
      ipa: '/ˈstʌdi/',
      partOfSpeech: 'v.',
      meanings: ['学习'],
      example: 'I study.',
      exampleTranslation: '我学习。',
      coverageBands: ['cet4'],
    );
    const six = DictionaryEntry(
      word: 'research',
      ipa: '/rɪˈsɜːtʃ/',
      partOfSpeech: 'n.',
      meanings: ['研究'],
      example: 'I do research.',
      exampleTranslation: '我做研究。',
      coverageBands: ['cet6'],
    );
    await tester.pumpWidget(
      app(MemoryLearningStore(), dictionaryEntries: const [four, six]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('learning-card-vocabulary')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('learning-vocabulary-settings')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-vocabulary-start-cycle')),
      findsNothing,
    );
    await tester.tap(find.text('英语六级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回词库选择'));
    await tester.pumpAndSettle();
    expect(find.text('词库预览 · 英语六级'), findsOneWidget);
    expect(find.text('research'), findsOneWidget);
    expect(find.text('study'), findsNothing);
  });

  testWidgets('sentence practice is independent and hides answer word blocks', (
    tester,
  ) async {
    await tester.pumpWidget(app(MemoryLearningStore()));
    await tester.pumpAndSettle();

    await openSentenceHub(tester);
    await startSentenceRound(tester);

    expect(
      find.byKey(const ValueKey('learning-sentence-cell-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-sentence-token-Hello')),
      findsNothing,
    );
  });

  testWidgets(
    'article track opens its hub and source settings open the local workbench',
    (tester) async {
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();

      await openArticleHub(tester);
      expect(
        find.byKey(const ValueKey('learning-article-learning-hub')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-shortcuts')),
        findsOneWidget,
      );

      final sourceSettings = find.byKey(
        const ValueKey('learning-article-source-settings'),
      );
      await tester.ensureVisible(sourceSettings);
      await tester.tap(sourceSettings);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-article-workbench')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-original')),
        findsOneWidget,
      );
      expect(
        find.text('A small habit can change the way we learn.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-unavailable')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-article-reader')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('article comprehension answer is saved and restored', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await openArticleWorkbenchFromHub(tester);

    final quiz = find.byKey(const ValueKey('learning-article-comprehension'));
    await tester.ensureVisible(quiz);
    expect(quiz, findsOneWidget);

    final wrongAnswer = find.byKey(
      const ValueKey('learning-article-answer-main-idea-0'),
    );
    await tester.ensureVisible(wrongAnswer);
    await tester.tap(wrongAnswer);
    await tester.pumpAndSettle();
    expect(find.textContaining('回到第 3 段找线索'), findsOneWidget);
    final evidenceLink = find.byKey(
      const ValueKey('learning-article-answer-evidence-main-idea'),
    );
    expect(evidenceLink, findsOneWidget);
    final evidenceParagraph = find.byKey(
      const ValueKey('learning-article-paragraph-2'),
    );
    final evidenceMaterial = find
        .descendant(of: evidenceParagraph, matching: find.byType(Material))
        .first;
    final paragraphColorBefore = tester
        .widget<Material>(evidenceMaterial)
        .color;
    await tester.tap(evidenceLink);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Material>(evidenceMaterial).color,
      isNot(paragraphColorBefore),
    );

    final correctAnswer = find.byKey(
      const ValueKey('learning-article-answer-main-idea-2'),
    );
    await tester.ensureVisible(correctAnswer);
    await tester.tap(correctAnswer);
    await tester.pumpAndSettle();
    expect(find.textContaining('答对了'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-article-answer-feedback-main-idea')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await openArticleWorkbenchFromHub(tester);
    await tester.ensureVisible(quiz);

    expect(find.textContaining('答对了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('article learning plan resumes the saved article paragraph', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    final repository = LearningRepository(store, clock: () => now);
    await repository.ensureDefaultSet(const [], now: now);
    await repository.saveArticleProgress(
      LearningArticleProgressData(
        articleId: 'language-and-ideas',
        title: 'Language Opens a Door',
        currentParagraph: 2,
        completedParagraphs: const [0, 1],
        favoriteParagraphs: const [],
        lookedUpWords: const ['language'],
        lastReadAt: now.toIso8601String(),
      ),
    );

    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await openArticleHub(tester);
    await openArticleHubShortcut(tester, '学习计划');

    expect(
      find.byKey(const ValueKey('learning-article-hub-plan')),
      findsOneWidget,
    );
    expect(find.text('Language Opens a Door'), findsOneWidget);
    expect(find.textContaining('第 3 段'), findsOneWidget);

    final resume = find.byKey(const ValueKey('learning-article-plan-resume'));
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('learning-article-workbench')),
      findsOneWidget,
    );
    expect(find.text('段落 3'), findsOneWidget);
  });

  testWidgets(
    'article progress lists completion and resumes a selected article',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.ensureDefaultSet(const [], now: now);
      await repository.saveArticleProgress(
        LearningArticleProgressData(
          articleId: 'evidence-and-clarity',
          title: 'Clear Ideas Need Evidence',
          currentParagraph: 3,
          completedParagraphs: const [0, 1, 2],
          favoriteParagraphs: const [],
          lookedUpWords: const [],
          lastReadAt: now.toIso8601String(),
        ),
      );

      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await openArticleHub(tester);
      await openArticleHubShortcut(tester, '阅读进度');

      expect(
        find.byKey(const ValueKey('learning-article-hub-progress')),
        findsOneWidget,
      );
      expect(find.textContaining('已读 3 / 5 段'), findsOneWidget);
      expect(find.text('A Small Habit'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey(
                  'learning-article-progress-count-habit-and-progress',
                ),
              ),
            )
            .data,
        contains('已读 0 / 5 段'),
      );

      final resume = find.byKey(
        const ValueKey('learning-article-progress-resume-evidence-and-clarity'),
      );
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-article-workbench')),
        findsOneWidget,
      );
      expect(find.text('段落 4'), findsOneWidget);
    },
  );

  testWidgets(
    'article vocabulary exposes saved and favorited words for lookup',
    (tester) async {
      final store = MemoryLearningStore();
      final repository = LearningRepository(store, clock: () => now);
      await repository.ensureDefaultSet(const [], now: now);
      await repository.saveArticleProgress(
        LearningArticleProgressData(
          articleId: 'habit-and-progress',
          title: 'A Small Habit',
          currentParagraph: 0,
          completedParagraphs: const [],
          favoriteParagraphs: const [],
          lookedUpWords: const ['habit'],
          lastReadAt: now.toIso8601String(),
        ),
      );

      await tester.pumpWidget(
        app(
          store,
          favoriteWords: const ['small'],
          lookupDictionary: (word) async => word == 'small'
              ? const DictionaryEntry(
                  word: 'small',
                  ipa: '/smɔːl/',
                  partOfSpeech: 'adj. 形容词',
                  meanings: ['小的'],
                  example: 'Start with a small step.',
                  exampleTranslation: '从一小步开始。',
                  source: openCetDictionarySourceId,
                )
              : null,
          dictionaryEntries: const [
            DictionaryEntry(
              word: 'habit',
              ipa: '/ˈhæbɪt/',
              partOfSpeech: 'n. 名词',
              meanings: ['习惯'],
              example: 'A good habit helps us learn.',
              exampleTranslation: '好习惯有助于我们学习。',
            ),
            DictionaryEntry(
              word: 'small',
              ipa: '/smɔːl/',
              partOfSpeech: 'adj. 形容词',
              meanings: ['小的'],
              example: 'Start with a small step.',
              exampleTranslation: '从一小步开始。',
              source: openCetDictionarySourceId,
              qualityStatus: 'published_with_candidate_enrichment',
              exampleCandidates: [
                OpenCetRichExampleRow(
                  exampleId: 'tatoeba:606530:1351367',
                  sourceId: 'tatoeba-cc-by-2.0-fr',
                  englishText: 'Take a small step forward.',
                  chineseText: '向前迈出一小步。',
                  englishUsername: 'source-author',
                  chineseUsername: 'translator',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await openArticleHub(tester);
      await openArticleHubShortcut(tester, '收藏词汇');

      expect(
        find.byKey(const ValueKey('learning-article-hub-vocabulary')),
        findsOneWidget,
      );
      expect(find.text('habit'), findsOneWidget);
      expect(find.text('small'), findsOneWidget);

      final habit = find.byKey(
        const ValueKey(
          'learning-article-vocabulary-word-habit-and-progress-habit',
        ),
      );
      await tester.ensureVisible(habit);
      await tester.tap(habit);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-article-workbench')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-word-detail')),
        findsOneWidget,
      );
      expect(find.text('1. 习惯'), findsOneWidget);

      final small = find
          .byKey(const ValueKey('learning-article-word-small'))
          .first;
      await tester.ensureVisible(small);
      await tester.tap(small);
      await tester.pumpAndSettle();

      expect(find.text('基础已审校 · 候选待核对'), findsOneWidget);
      expect(find.text('开放来源例句候选 · 待核对'), findsOneWidget);
      expect(find.text('Start with a small step.'), findsNothing);
      final candidateExamples = find.byKey(
        const ValueKey('learning-article-candidate-examples'),
      );
      await tester.ensureVisible(candidateExamples);
      await tester.tap(candidateExamples);
      await tester.pumpAndSettle();
      expect(find.text('Take a small step forward.'), findsOneWidget);
      expect(find.text('向前迈出一小步。'), findsOneWidget);
      expect(
        find.text('Tatoeba · 文本默认 CC BY 2.0 FR（本条许可未核）· 待审校候选'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tatoeba-license-url')), findsOneWidget);
      expect(find.text('英文作者 source-author · 中文作者 translator'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tatoeba-source-606530')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tatoeba-source-1351367')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '例句'));
      await tester.pumpAndSettle();
      expect(find.text('开放来源例句候选 · 待核对'), findsOneWidget);
      expect(find.text('Start with a small step.'), findsNothing);
    },
  );

  testWidgets('immersive article reading stays in the built-in learning flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        dictionaryEntries: const [
          DictionaryEntry(
            word: 'habit',
            ipa: '/ˈhæbɪt/',
            partOfSpeech: 'n. 名词',
            meanings: ['习惯'],
            example: 'A good habit helps us learn.',
            exampleTranslation: '好习惯有助于我们学习。',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await openArticleWorkbenchFromHub(tester);

    final habit = find
        .byKey(const ValueKey('learning-article-word-habit'))
        .first;
    await tester.ensureVisible(habit);
    await tester.tap(habit);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-article-word-detail')),
      findsOneWidget,
    );

    final notesTab = find.widgetWithText(ChoiceChip, '批注');
    await tester.ensureVisible(notesTab);
    await tester.tap(notesTab);
    await tester.pumpAndSettle();
    final noteField = find.byKey(
      const ValueKey('learning-article-word-note-field'),
    );
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, '沉浸切换时保留未保存笔记');

    final openImmersive = find.byKey(
      const ValueKey('learning-article-open-immersive'),
    );
    await tester.ensureVisible(openImmersive);
    await tester.tap(openImmersive);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('learning-article-immersive')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-article-original')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-article-tool-panel')),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(noteField).controller!.text,
      '沉浸切换时保留未保存笔记',
    );
    expect(
      find.byKey(const ValueKey('learning-article-unavailable')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);
    expect(
      find.text('A small habit can change the way we learn.'),
      findsOneWidget,
    );

    final leaveImmersive = find.byKey(
      const ValueKey('learning-article-immersive-exit'),
    );
    await tester.ensureVisible(leaveImmersive);
    await tester.tap(leaveImmersive);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('learning-article-immersive')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('learning-article-workbench')),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(noteField).controller!.text,
      '沉浸切换时保留未保存笔记',
    );
    expect(
      find.byKey(const ValueKey('learning-article-notes-tool')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'article learning keeps the separate document reader unconnected',
    (tester) async {
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();

      await openArticleWorkbenchFromHub(tester);

      expect(
        find.byKey(const ValueKey('learning-article-workbench')),
        findsOneWidget,
      );
      expect(find.text('去阅读器导入文章'), findsNothing);
      expect(find.text('打开文章阅读器'), findsNothing);
      expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);
    },
  );

  testWidgets('content library exposes local dictionary and source inventory', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 900,
          height: 700,
          child: ContentLibraryWorkspace(
            loadDictionary: () async => const [entry],
            loadSources: () async => const [
              ContentSourceData(
                id: 'article-1',
                kind: 'article',
                title: '本地文章',
                localPath: 'D:/articles/demo.txt',
                contentText: 'Learning grows through practice.',
                readingPosition: 0,
                translatedParagraphsJson: '{}',
                createdAt: '2026-09-16T10:30:00+08:00',
              ),
            ],
            loadTextbooks: () async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('content-library-dictionary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('content-library-articles')),
      findsOneWidget,
    );
    expect(find.text('本地文章'), findsNWidgets(2));
    expect(find.text('当前共 1 条；词典和翻译模型是两套不同资料。'), findsOneWidget);
  });

  testWidgets(
    'content library labels imported dictionary rights as unverified',
    (tester) async {
      const imported = DictionaryEntry(
        word: 'abide',
        ipa: '',
        partOfSpeech: 'v.',
        meanings: ['遵守'],
        example: '',
        exampleTranslation: '',
        source: 'sample-pack · 自用词典 · CC BY-SA 4.0',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 900,
            height: 700,
            child: ContentLibraryWorkspace(
              loadDictionary: () async => const [imported],
              loadSources: () async => const [],
              loadTextbooks: () async => const [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('自用词典 · 1 条'), findsOneWidget);
      expect(find.textContaining('CC BY-SA 4.0'), findsOneWidget);
      expect(find.textContaining('应用未核验'), findsOneWidget);
      expect(find.textContaining('已授权'), findsNothing);
    },
  );

  testWidgets('pronunciation track records a local self-assessment', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    final track = find.byKey(const ValueKey('learning-track-pronunciation'));
    await tester.ensureVisible(track);
    await tester.tap(track);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-pronunciation-workspace')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-pronunciation-config')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-pronunciation-accent-grid')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-pronunciation-follow')),
      findsOneWidget,
    );

    final clear = find.byKey(const ValueKey('learning-pronunciation-clear'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();

    final state = await store.read();
    expect(
      state!.pronunciationPractices.single.result,
      LearningPronunciationResult.clear,
    );
  });

  testWidgets(
    'pronunciation dictionary search uses all local entries and exact Chinese meanings',
    (tester) async {
      const inCurrentBand = DictionaryEntry(
        word: 'teacher-training',
        ipa: '',
        partOfSpeech: 'n.',
        meanings: ['教师培训'],
        example: '',
        exampleTranslation: '',
        coverageBands: ['cet4'],
      );
      const outsideCurrentBand = DictionaryEntry(
        word: 'teacher',
        ipa: '/ˈtiːtʃə(r)/',
        partOfSpeech: 'n.',
        meanings: ['教师；老师'],
        example: '',
        exampleTranslation: '',
        coverageBands: ['graduate'],
      );
      const englishOutsideCurrentBand = DictionaryEntry(
        word: 'resilient',
        ipa: '',
        partOfSpeech: 'adj.',
        meanings: ['有韧性的'],
        example: '',
        exampleTranslation: '',
        coverageBands: ['graduate'],
      );
      final store = MemoryLearningStore();
      await tester.pumpWidget(
        app(
          store,
          dictionaryEntries: const [
            inCurrentBand,
            outsideCurrentBand,
            englishOutsideCurrentBand,
          ],
        ),
      );
      await tester.pumpAndSettle();
      final pronunciationTrack = find.byKey(
        const ValueKey('learning-track-pronunciation'),
      );
      await tester.ensureVisible(pronunciationTrack);
      await tester.tap(pronunciationTrack);
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('learning-pronunciation-query'));
      final lookup = find.byKey(
        const ValueKey('learning-pronunciation-lookup'),
      );
      await tester.enterText(query, 'resilient');
      await tester.tap(lookup);
      await tester.pumpAndSettle();
      expect(find.text('resilient').last, findsOneWidget);

      await tester.enterText(query, '教师');
      await tester.tap(lookup);
      await tester.pumpAndSettle();
      expect(find.text('teacher'), findsOneWidget);
      expect(find.text('teacher-training'), findsNothing);
    },
  );

  testWidgets('microphone recognition shows a local word score and saves it', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    final speech = _FakeSpeechRecognizer();
    await tester.pumpWidget(app(store, speechRecognizer: speech));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('learning-track-pronunciation')),
    );
    await tester.pumpAndSettle();
    final mic = find.byKey(const ValueKey('learning-pronunciation-mic'));
    expect(mic, findsOneWidget);
    await tester.ensureVisible(mic);
    await tester.tap(mic);
    await tester.pump();
    speech.emit('hello');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('learning-pronunciation-score')),
      findsOneWidget,
    );
    expect(find.text('100 分'), findsOneWidget);
    final state = await store.read();
    expect(
      state!.pronunciationPractices.single.result,
      LearningPronunciationResult.clear,
    );
  });

  testWidgets('default sentence bank excludes open dictionary candidates', (
    tester,
  ) async {
    const openCandidate = DictionaryEntry(
      word: 'greeting-candidate',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['问候候选'],
      example: 'Good morning, this example is not reviewed.',
      exampleTranslation: '早上好，这条例句还没有审校。',
      source: openCetDictionarySourceId,
      qualityStatus: 'candidate',
    );
    const publishedOpenExample = DictionaryEntry(
      word: 'reviewed-greeting',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['问候'],
      example: 'Good morning, welcome to the class.',
      exampleTranslation: '早上好，欢迎来到课堂。',
      source: openCetDictionarySourceId,
      qualityStatus: 'published_with_candidate_enrichment',
      candidateSourceIds: ['tatoeba-cc-by-2.0-fr'],
      exampleCandidates: [
        OpenCetRichExampleRow(
          exampleId: 'reviewed-greeting-candidate-1',
          sourceId: 'tatoeba-cc-by-2.0-fr',
          englishText: 'UNREVIEWED CANDIDATE: The train leaves at noon.',
          chineseText: '未审核候选：火车中午出发。',
          englishUsername: 'candidate-en',
          chineseUsername: 'candidate-zh',
          reviewStatus: 'candidate',
        ),
      ],
    );
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        dictionaryEntries: const [openCandidate, publishedOpenExample],
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    expect(find.textContaining('本地词典例句（可练 1）'), findsOneWidget);
    expect(find.textContaining('当前可用 1 句'), findsOneWidget);
    await startSentenceRound(tester);
    expect(find.text('早上好，欢迎来到课堂。'), findsOneWidget);
    expect(
      find.text('UNREVIEWED CANDIDATE: The train leaves at noon.'),
      findsNothing,
    );
    expect(find.text('未审核候选：火车中午出发。'), findsNothing);
    final optionalAnswer = find.text('需要时展开整句输入（可选）');
    await tester.ensureVisible(optionalAnswer);
    await tester.tap(optionalAnswer);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('learning-sentence-answer')),
      'A temporary learner answer.',
    );
    final revealAnswer = find.byKey(const ValueKey('learning-sentence-submit'));
    await tester.ensureVisible(revealAnswer);
    await tester.tap(revealAnswer);
    await tester.pumpAndSettle();
    expect(
      find.text('参考答案：Good morning, welcome to the class.'),
      findsOneWidget,
    );
    expect(
      find.text('UNREVIEWED CANDIDATE: The train leaves at noon.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sentence track checks and persists a sentence attempt', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    final track = find.byKey(const ValueKey('learning-track-sentence'));
    await tester.ensureVisible(track);
    await tester.tap(track);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-sentence-settings')),
      findsOneWidget,
    );
    await expandSentenceSettings(tester);
    expect(
      find.byKey(const ValueKey('learning-sentence-scenario-strip')),
      findsOneWidget,
    );
    await startSentenceRound(tester);
    expect(
      find.byKey(const ValueKey('learning-sentence-cell-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('learning-sentence-practice-card')),
      findsOneWidget,
    );
    final optionalAnswer = find.text('需要时展开整句输入（可选）');
    await tester.ensureVisible(optionalAnswer);
    await tester.tap(optionalAnswer);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('learning-sentence-answer')),
      'Hello, it is good to meet you.',
    );
    final submit = find.byKey(const ValueKey('learning-sentence-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect((await store.read())!.sentenceAttempts, isEmpty);
    final mastered = find.byKey(
      const ValueKey('learning-sentence-assessment-mastered'),
    );
    await tester.ensureVisible(mastered);
    await tester.tap(mastered);
    await tester.pumpAndSettle();

    final state = await store.read();
    expect(state!.sentenceAttempts.single.correct, isTrue);
    expect(find.text('已按你的自评记录为掌握。'), findsOneWidget);
  });

  testWidgets(
    'AI sentence generation is explicit and saves a usable AI prompt',
    (tester) async {
      final store = MemoryLearningStore();
      var generationCalls = 0;
      String? generatedScenario;
      var generatedDifficulty = 0;
      var generatedCount = 0;
      await tester.pumpWidget(
        app(
          store,
          generateSentenceExercises:
              ({
                required String scenario,
                required int difficulty,
                required int count,
              }) async {
                generationCalls++;
                generatedScenario = scenario;
                generatedDifficulty = difficulty;
                generatedCount = count;
                return const [
                  LearningSentenceExerciseData(
                    title: '课堂提问',
                    chineseText: '我可以再问一个问题吗？',
                    englishText: 'May I ask one more question?',
                  ),
                ];
              },
        ),
      );
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      final aiLibrary = find.byKey(
        const ValueKey('learning-sentence-source-ai'),
      );
      await tester.ensureVisible(aiLibrary);
      await tester.tap(aiLibrary);
      await tester.pumpAndSettle();
      expect(generationCalls, 0);
      expect(find.textContaining('仅在点击后'), findsOneWidget);
      await expandSentenceSettings(tester);

      final studyScenario = find.byKey(
        const ValueKey('learning-sentence-scenario-study'),
      );
      await tester.ensureVisible(studyScenario);
      await tester.tap(studyScenario);
      await tester.pumpAndSettle();
      final advanced = find.byKey(
        const ValueKey('learning-sentence-difficulty-2'),
      );
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final oneSentence = find.byKey(
        const ValueKey('learning-sentence-round-count-1'),
      );
      await tester.ensureVisible(oneSentence);
      await tester.tap(oneSentence);
      await tester.pumpAndSettle();

      final generate = find.byKey(
        const ValueKey('learning-sentence-generate-ai'),
      );
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      await tester.pumpAndSettle();

      expect(generationCalls, 1);
      expect(generatedScenario, '学习表达');
      expect(generatedDifficulty, 2);
      expect(generatedCount, 1);
      final state = await store.read();
      expect(
        state!.customSentencePrompts.single.origin,
        LearningSentencePromptOrigin.aiGenerated,
      );
      expect(state.customSentencePrompts.single.title, '课堂提问');
      expect(find.text('AI 生成 · 课堂提问'), findsOneWidget);

      final start = find.byKey(const ValueKey('learning-sentence-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-answer')),
        'May I ask one more question?',
      );
      final submit = find.byKey(const ValueKey('learning-sentence-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final mastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      final saved = (await store.read())!.sentenceAttempts.single;
      expect(saved.fromCustomPrompt, isTrue);
      expect(saved.fromAiPrompt, isTrue);
      expect(find.textContaining('AI 生成'), findsWidgets);
    },
  );

  testWidgets(
    'sentence filters stay locked during AI generation and the new batch is visible',
    (tester) async {
      final store = MemoryLearningStore();
      final generated = Completer<List<LearningSentenceExerciseData>>();
      await tester.pumpWidget(
        app(
          store,
          generateSentenceExercises: ({
            required String scenario,
            required int difficulty,
            required int count,
          }) => generated.future,
        ),
      );
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      final aiSource = find.byKey(
        const ValueKey('learning-sentence-source-ai'),
      );
      await tester.ensureVisible(aiSource);
      await tester.tap(aiSource);
      await tester.pumpAndSettle();
      await expandSentenceSettings(tester);
      final oneSentence = find.byKey(
        const ValueKey('learning-sentence-round-count-1'),
      );
      await tester.ensureVisible(oneSentence);
      await tester.tap(oneSentence);
      await tester.pumpAndSettle();

      final generate = find.byKey(
        const ValueKey('learning-sentence-generate-ai'),
      );
      await tester.ensureVisible(generate);
      await tester.tap(generate);
      await tester.pump();

      final studyScenario = tester.widget<InkWell>(
        find.byKey(const ValueKey('learning-sentence-scenario-study')),
      );
      expect(studyScenario.onTap, isNull);
      final customSource = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('learning-sentence-source-custom')),
      );
      expect(customSource.onSelected, isNull);

      generated.complete(const [
        LearningSentenceExerciseData(
          title: '问候练习',
          chineseText: '很高兴见到你。',
          englishText: 'It is nice to meet you.',
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('AI 生成 · 问候练习'), findsOneWidget);
      expect(find.textContaining('当前可用 1'), findsOneWidget);
    },
  );

  testWidgets('built-in sentence count reflects the active filters', (
    tester,
  ) async {
    const studyEntry = DictionaryEntry(
      word: 'class',
      ipa: '',
      partOfSpeech: 'n.',
      meanings: ['课程'],
      example: 'Class starts at nine.',
      exampleTranslation: '课程九点开始。',
      learningTags: ['study'],
    );
    await tester.pumpWidget(
      app(MemoryLearningStore(), dictionaryEntries: const [entry, studyEntry]),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    expect(find.text('本地词典例句（可练 1）'), findsOneWidget);
    expect(find.text('当前可用 1 句，本轮会固定为 1 句，不会循环重复。'), findsOneWidget);
  });

  testWidgets('AI sentence generation exposes failure and can be retried', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        generateSentenceExercises:
            ({
              required String scenario,
              required int difficulty,
              required int count,
            }) async {
              calls++;
              if (calls == 1) throw StateError('simulated provider failure');
              return const [
                LearningSentenceExerciseData(
                  title: '重试句子',
                  chineseText: '请再说一遍。',
                  englishText: 'Could you say that again?',
                ),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final aiSource = find.byKey(const ValueKey('learning-sentence-source-ai'));
    await tester.ensureVisible(aiSource);
    await tester.tap(aiSource);
    await tester.pumpAndSettle();
    await expandSentenceSettings(tester);
    final oneSentence = find.byKey(
      const ValueKey('learning-sentence-round-count-1'),
    );
    await tester.ensureVisible(oneSentence);
    await tester.tap(oneSentence);
    await tester.pumpAndSettle();
    final generate = find.byKey(
      const ValueKey('learning-sentence-generate-ai'),
    );
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    expect(find.text('AI 请求未完成，暂时没有生成题目。请检查模型连接后重试。'), findsOneWidget);
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);

    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('AI 生成 · 重试句子'), findsOneWidget);
    expect(find.textContaining('已生成并保存 1 句'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing AI sentence provider links to model settings', (
    tester,
  ) async {
    var settingsOpened = 0;
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        onOpenUnderstandingModelSettings: () => settingsOpened++,
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final aiSource = find.byKey(const ValueKey('learning-sentence-source-ai'));
    await tester.ensureVisible(aiSource);
    await tester.tap(aiSource);
    await tester.pumpAndSettle();

    final generate = find.byKey(
      const ValueKey('learning-sentence-generate-ai'),
    );
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    expect(find.text('尚未接入 AI 句子生成。请检查“理解与总结”模型配置后重试。'), findsOneWidget);
    final configure = find.byKey(
      const ValueKey('learning-sentence-open-model-settings'),
    );
    expect(configure, findsOneWidget);
    await tester.tap(configure);
    expect(settingsOpened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty AI sentence bank does not direct users to model settings',
    (tester) async {
      await tester.pumpWidget(
        app(MemoryLearningStore(), onOpenUnderstandingModelSettings: () {}),
      );
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      final aiSource = find.byKey(
        const ValueKey('learning-sentence-source-ai'),
      );
      await tester.ensureVisible(aiSource);
      await tester.tap(aiSource);
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有生成题目'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-sentence-open-model-settings')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AI response format failure does not suggest model settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        onOpenUnderstandingModelSettings: () {},
        generateSentenceExercises:
            ({
              required String scenario,
              required int difficulty,
              required int count,
            }) async => throw const LearningSummaryException(
              'invalid_sentence_response',
            ),
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final aiSource = find.byKey(const ValueKey('learning-sentence-source-ai'));
    await tester.ensureVisible(aiSource);
    await tester.tap(aiSource);
    await tester.pumpAndSettle();
    await expandSentenceSettings(tester);
    final oneSentence = find.byKey(
      const ValueKey('learning-sentence-round-count-1'),
    );
    await tester.ensureVisible(oneSentence);
    await tester.tap(oneSentence);
    await tester.pumpAndSettle();

    final generate = find.byKey(
      const ValueKey('learning-sentence-generate-ai'),
    );
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    expect(find.text('模型返回的句子格式或数量不正确，请减少题量或换用更稳定的模型后重试。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-sentence-open-model-settings')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI sentence save failure explains that generation succeeded', (
    tester,
  ) async {
    final store = _ToggleFailLearningStore();
    await tester.pumpWidget(
      app(
        store,
        onOpenUnderstandingModelSettings: () {},
        generateSentenceExercises:
            ({
              required String scenario,
              required int difficulty,
              required int count,
            }) async => const [
              LearningSentenceExerciseData(
                title: '保存失败句子',
                chineseText: '请再说一遍。',
                englishText: 'Could you say that again?',
              ),
            ],
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final aiSource = find.byKey(const ValueKey('learning-sentence-source-ai'));
    await tester.ensureVisible(aiSource);
    await tester.tap(aiSource);
    await tester.pumpAndSettle();
    await expandSentenceSettings(tester);
    final oneSentence = find.byKey(
      const ValueKey('learning-sentence-round-count-1'),
    );
    await tester.ensureVisible(oneSentence);
    await tester.tap(oneSentence);
    await tester.pumpAndSettle();

    store.failWrites = true;
    final generate = find.byKey(
      const ValueKey('learning-sentence-generate-ai'),
    );
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    expect(find.text('题目已生成，但保存到本地失败；请检查学习空间存储后重试。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-sentence-open-model-settings')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sentence history can expand beyond the five most recent items', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    final repository = LearningRepository(store, clock: () => now);
    await repository.ensureDefaultSet(['hello']);
    for (var index = 0; index < 6; index++) {
      await repository.recordSentenceAttempt(
        setId: learningDefaultSetId,
        word: '历史句 $index',
        mode: SentencePracticeMode.chineseToEnglish,
        sourceText: 'History sentence $index.',
        translation: '历史句子 $index。',
        answer: 'My answer $index.',
        expectedAnswer: 'History sentence $index.',
        correct: true,
        mistakes: const [],
        now: now.add(Duration(minutes: index)),
      );
    }
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final historyToggle = find.byKey(
      const ValueKey('learning-sentence-open-history'),
    );
    await tester.ensureVisible(historyToggle);
    await tester.tap(historyToggle);
    await tester.pumpAndSettle();
    expect(find.text('历史句 0'), findsNothing);
    expect(find.text('历史句 5'), findsOneWidget);

    final expandHistory = find.byKey(
      const ValueKey('learning-sentence-history-expand'),
    );
    await tester.ensureVisible(expandHistory);
    await tester.tap(expandHistory);
    await tester.pumpAndSettle();

    expect(find.text('历史句 0'), findsOneWidget);
    expect(find.text('历史句 5'), findsOneWidget);
    expect(expandHistory, findsNothing);
  });

  testWidgets(
    'sentence hub supports a saved custom prompt and round progress',
    (tester) async {
      final store = MemoryLearningStore();
      var clockTick = 0;
      await tester.pumpWidget(
        app(store, clock: () => now.add(Duration(seconds: clockTick++))),
      );
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      expect(
        find.byKey(const ValueKey('learning-sentence-hub')),
        findsOneWidget,
      );
      expect(find.text('今日练习'), findsOneWidget);
      expect(find.text('昨日练习'), findsOneWidget);
      await expandSentenceSettings(tester);

      final customSource = find.byKey(
        const ValueKey('learning-sentence-source-custom'),
      );
      await tester.ensureVisible(customSource);
      await tester.tap(customSource);
      await tester.pumpAndSettle();
      final customTitle = find.byKey(
        const ValueKey('learning-sentence-custom-title'),
      );
      await tester.ensureVisible(customTitle);
      await tester.enterText(customTitle, '我的问候');
      final customChinese = find.byKey(
        const ValueKey('learning-sentence-custom-chinese'),
      );
      await tester.ensureVisible(customChinese);
      await tester.enterText(customChinese, '很高兴认识你。');
      final customEnglish = find.byKey(
        const ValueKey('learning-sentence-custom-english'),
      );
      await tester.ensureVisible(customEnglish);
      await tester.enterText(customEnglish, 'It is a pleasure to meet you.');
      final saveCustom = find.byKey(
        const ValueKey('learning-sentence-save-custom'),
      );
      await tester.ensureVisible(saveCustom);
      await tester.pumpAndSettle();
      await tester.tap(saveCustom);
      await tester.pumpAndSettle();
      expect((await store.read())!.customSentencePrompts.single.title, '我的问候');

      await tester.ensureVisible(customTitle);
      await tester.enterText(customTitle, '第二个问候');
      await tester.ensureVisible(customChinese);
      await tester.enterText(customChinese, '下次见。');
      await tester.ensureVisible(customEnglish);
      await tester.enterText(customEnglish, 'See you next time.');
      await tester.ensureVisible(saveCustom);
      await tester.pumpAndSettle();
      await tester.tap(saveCustom);
      await tester.pumpAndSettle();
      expect((await store.read())!.customSentencePrompts, hasLength(2));

      final englishToChinese = find.byKey(
        const ValueKey('learning-sentence-mode-englishToChinese'),
      );
      await tester.ensureVisible(englishToChinese);
      await tester.tap(englishToChinese);
      await tester.pumpAndSettle();
      final start = find.byKey(const ValueKey('learning-sentence-start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();

      expect(find.text('第 1 / 2 句'), findsOneWidget);
      expect(find.text('It is a pleasure to meet you.'), findsOneWidget);
      final optionalAnswer = find.text('需要时展开整句输入（可选）');
      await tester.ensureVisible(optionalAnswer);
      await tester.tap(optionalAnswer);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-answer')),
        '很高兴认识你。',
      );
      final submit = find.byKey(const ValueKey('learning-sentence-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final mastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      final next = find.byKey(const ValueKey('learning-sentence-next'));
      await tester.ensureVisible(next);
      expect(find.text('下一句'), findsOneWidget);
      await tester.tap(next);
      await tester.pumpAndSettle();

      expect(find.text('第 2 / 2 句'), findsOneWidget);
      expect(find.text('See you next time.'), findsOneWidget);
      final secondOptionalAnswer = find.text('需要时展开整句输入（可选）');
      final answerField = find.byKey(
        const ValueKey('learning-sentence-answer'),
      );
      if (answerField.evaluate().isEmpty) {
        await tester.ensureVisible(secondOptionalAnswer);
        await tester.tap(secondOptionalAnswer);
        await tester.pumpAndSettle();
      }
      await tester.enterText(answerField, '下次见。');
      final secondSubmit = find.byKey(
        const ValueKey('learning-sentence-submit'),
      );
      await tester.ensureVisible(secondSubmit);
      await tester.tap(secondSubmit);
      await tester.pumpAndSettle();
      final secondMastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(secondMastered);
      await tester.tap(secondMastered);
      await tester.pumpAndSettle();
      await tester.ensureVisible(next);
      expect(find.text('完成本轮'), findsOneWidget);
      await tester.tap(next);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-sentence-hub')),
        findsOneWidget,
      );
      expect(find.text('本轮已完成 · 2 / 2 句'), findsOneWidget);
      expect(find.textContaining('很高兴认识你。'), findsWidgets);
      final builtInSource = find.byKey(
        const ValueKey('learning-sentence-source-builtIn'),
      );
      await tester.ensureVisible(builtInSource);
      await tester.tap(builtInSource);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-sentence-round-complete')),
        findsNothing,
      );
      final state = await store.read();
      expect(state!.sentenceAttempts, hasLength(2));
      expect(state.sentenceAttempts.first.word, '我的问候');
      expect(
        state.sentenceAttempts.first.mode,
        SentencePracticeMode.englishToChinese,
      );
    },
  );

  testWidgets('new AI sentence batches are selected before older batches', (
    tester,
  ) async {
    var generation = 0;
    var clockTick = 0;
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        clock: () => now.add(Duration(seconds: clockTick++)),
        generateSentenceExercises:
            ({
              required String scenario,
              required int difficulty,
              required int count,
            }) async {
              final prefix = generation++ == 0 ? '旧批次' : '新批次';
              return [
                for (var index = 1; index <= count; index++)
                  LearningSentenceExerciseData(
                    title: '$prefix 课堂句子 $index',
                    chineseText: '$prefix 中文句子 $index。',
                    englishText: '$prefix sentence $index.',
                  ),
              ];
            },
      ),
    );
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    final aiLibrary = find.byKey(const ValueKey('learning-sentence-source-ai'));
    await tester.ensureVisible(aiLibrary);
    await tester.tap(aiLibrary);
    await tester.pumpAndSettle();
    await expandSentenceSettings(tester);
    final tenSentences = find.byKey(
      const ValueKey('learning-sentence-round-count-10'),
    );
    await tester.ensureVisible(tenSentences);
    await tester.tap(tenSentences);
    await tester.pumpAndSettle();

    final generate = find.byKey(
      const ValueKey('learning-sentence-generate-ai'),
    );
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    await startSentenceRound(tester);
    final practiceCard = find.byKey(
      const ValueKey('learning-sentence-practice-card'),
    );
    expect(
      find.descendant(of: practiceCard, matching: find.text('新批次 中文句子 1。')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a saved custom sentence remains a success if a later read fails',
    (tester) async {
      final store = _FailReadOnceAfterWriteLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      final customSource = find.byKey(
        const ValueKey('learning-sentence-source-custom'),
      );
      await tester.ensureVisible(customSource);
      await tester.tap(customSource);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-custom-title')),
        '日常问候',
      );
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-custom-chinese')),
        '今天过得怎么样？',
      );
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-custom-english')),
        'How is your day going?',
      );
      store.failReadAfterNextWrite();
      final save = find.byKey(const ValueKey('learning-sentence-save-custom'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.text('已保存到我的句子库。'), findsOneWidget);
      expect(find.textContaining('自建句子保存失败'), findsNothing);
    },
  );

  testWidgets(
    'a saved sentence assessment is not reported as failed if reload fails',
    (tester) async {
      final store = _FailReadOnceAfterWriteLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await openSentenceHub(tester);
      await startSentenceRound(tester);

      final optionalAnswer = find.text('需要时展开整句输入（可选）');
      await tester.ensureVisible(optionalAnswer);
      await tester.tap(optionalAnswer);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-answer')),
        'Hello, it is good to meet you.',
      );
      final submit = find.byKey(const ValueKey('learning-sentence-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      store.failReadAfterNextWrite();

      final mastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      expect(find.text('已按你的自评记录为掌握。'), findsOneWidget);
      expect(find.textContaining('句子练习保存失败'), findsNothing);
    },
  );

  testWidgets('sentence hub shows practice completed today and yesterday', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    final repository = LearningRepository(store, clock: () => now);
    await repository.ensureDefaultSet(['hello']);
    for (final date in [DateTime(2026, 9, 15, 10), DateTime(2026, 9, 16, 10)]) {
      await repository.recordSentenceAttempt(
        setId: learningDefaultSetId,
        word: 'hello',
        mode: SentencePracticeMode.chineseToEnglish,
        sourceText: 'Hello, it is good to meet you.',
        translation: '你好，很高兴见到你。',
        answer: 'Hello, it is good to meet you.',
        expectedAnswer: 'Hello, it is good to meet you.',
        correct: true,
        mistakes: const [],
        now: date,
      );
    }
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await openSentenceHub(tester);

    expect(find.text('今日完成 1 句'), findsOneWidget);
    expect(find.text('昨日完成 1 句'), findsOneWidget);
  });

  testWidgets(
    'sentence hub keeps progress and start action visible before settings expand',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(MemoryLearningStore()));
      await tester.pumpAndSettle();
      await openSentenceHub(tester);

      expect(find.text('今日练习'), findsOneWidget);
      expect(find.text('昨日练习'), findsOneWidget);
      final start = find.byKey(const ValueKey('learning-sentence-start'));
      expect(start, findsOneWidget);
      expect(tester.getRect(start).bottom, lessThanOrEqualTo(760));
      expect(find.text('翻译方向'), findsNothing);
      expect(
        find.byKey(const ValueKey('learning-sentence-round-count-5')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-sentence-history')),
        findsNothing,
      );

      final historyToggle = find.byKey(
        const ValueKey('learning-sentence-open-history'),
      );
      await tester.tap(historyToggle);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('learning-sentence-history')),
        findsOneWidget,
      );
      await tester.tap(historyToggle);
      await tester.pumpAndSettle();

      await expandSentenceSettings(tester);
      expect(find.text('翻译方向'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-sentence-round-count-5')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sentence translation can be self-assessed after comparing the reference answer',
    (tester) async {
      final store = MemoryLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();

      final track = find.byKey(const ValueKey('learning-track-sentence'));
      await tester.ensureVisible(track);
      await tester.tap(track);
      await tester.pumpAndSettle();
      await startSentenceRound(tester);
      final optionalAnswer = find.text('需要时展开整句输入（可选）');
      await tester.ensureVisible(optionalAnswer);
      await tester.tap(optionalAnswer);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('learning-sentence-answer')),
        'It is nice to meet you.',
      );
      final submit = find.byKey(const ValueKey('learning-sentence-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect((await store.read())!.sentenceAttempts, isEmpty);
      expect(find.text('查看参考答案'), findsOneWidget);
      expect(find.text('检查答案'), findsNothing);
      expect(find.textContaining('参考答案：'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-sentence-assessment-mastered')),
        findsOneWidget,
      );

      final mastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      final state = await store.read();
      expect(state!.sentenceAttempts.single.answer, 'It is nice to meet you.');
      expect(state.sentenceAttempts.single.correct, isTrue);
      expect(find.text('已按你的自评记录为掌握。'), findsOneWidget);
    },
  );

  testWidgets(
    'changing the full sentence after assessment requires a new review',
    (tester) async {
      final store = MemoryLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();

      final track = find.byKey(const ValueKey('learning-track-sentence'));
      await tester.ensureVisible(track);
      await tester.tap(track);
      await tester.pumpAndSettle();
      await startSentenceRound(tester);
      final optionalAnswer = find.text('需要时展开整句输入（可选）');
      await tester.ensureVisible(optionalAnswer);
      await tester.tap(optionalAnswer);
      await tester.pumpAndSettle();

      final answer = find.byKey(const ValueKey('learning-sentence-answer'));
      await tester.enterText(answer, 'It is nice to meet you.');
      final submit = find.byKey(const ValueKey('learning-sentence-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final mastered = find.byKey(
        const ValueKey('learning-sentence-assessment-mastered'),
      );
      await tester.ensureVisible(mastered);
      await tester.tap(mastered);
      await tester.pumpAndSettle();

      final next = find.byKey(const ValueKey('learning-sentence-next'));
      expect(tester.widget<OutlinedButton>(next).onPressed, isNotNull);
      await tester.enterText(answer, 'I would like to meet you.');
      await tester.pumpAndSettle();

      expect(tester.widget<OutlinedButton>(next).onPressed, isNull);
      expect(find.text('已按你的自评记录为掌握。'), findsNothing);
      expect(
        (await store.read())!.sentenceAttempts.single.answer,
        'It is nice to meet you.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing a word cell after assessment requires a new review', (
    tester,
  ) async {
    final store = MemoryLearningStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    final track = find.byKey(const ValueKey('learning-track-sentence'));
    await tester.ensureVisible(track);
    await tester.tap(track);
    await tester.pumpAndSettle();
    await startSentenceRound(tester);

    final firstCell = find.byKey(const ValueKey('learning-sentence-cell-0'));
    await tester.enterText(firstCell, 'changed');
    final submit = find.byKey(const ValueKey('learning-sentence-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final mastered = find.byKey(
      const ValueKey('learning-sentence-assessment-mastered'),
    );
    await tester.ensureVisible(mastered);
    await tester.tap(mastered);
    await tester.pumpAndSettle();

    final next = find.byKey(const ValueKey('learning-sentence-next'));
    expect(tester.widget<OutlinedButton>(next).onPressed, isNotNull);
    await tester.enterText(firstCell, 'revised');
    await tester.pumpAndSettle();

    expect(tester.widget<OutlinedButton>(next).onPressed, isNull);
    expect(find.text('已按你的自评记录为掌握。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sentence difficulty switches to independent full-sentence input',
    (tester) async {
      final store = MemoryLearningStore();
      const longGreeting = DictionaryEntry(
        word: 'welcome',
        ipa: '',
        partOfSpeech: 'v.',
        meanings: ['欢迎'],
        example: 'I am always happy to welcome new friends into our classroom.',
        exampleTranslation: '我总是很高兴欢迎新朋友来到我们的教室。',
        learningTags: ['greeting'],
      );
      await tester.pumpWidget(
        app(store, dictionaryEntries: const [entry, longGreeting]),
      );
      await tester.pumpAndSettle();

      final track = find.byKey(const ValueKey('learning-track-sentence'));
      await tester.ensureVisible(track);
      await tester.tap(track);
      await tester.pumpAndSettle();
      await expandSentenceSettings(tester);
      final challenge = find.byKey(
        const ValueKey('learning-sentence-difficulty-2'),
      );
      await tester.ensureVisible(challenge);
      await tester.tap(challenge);
      await tester.pumpAndSettle();
      await startSentenceRound(tester);

      expect(
        find.byKey(const ValueKey('learning-sentence-cell-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('learning-sentence-answer')),
        findsOneWidget,
      );
      expect(find.text('你好，很高兴见到你。'), findsNothing);
      expect(find.text('我总是很高兴欢迎新朋友来到我们的教室。'), findsOneWidget);
      expect(find.text('独立挑战：不显示逐词方格，直接完成整句。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sentence scenario filters the available question set', (
    tester,
  ) async {
    const studyEntry = DictionaryEntry(
      word: 'study',
      ipa: '',
      partOfSpeech: 'v.',
      meanings: ['学习'],
      example: 'We study English together after class.',
      exampleTranslation: '我们下课后一起学习英语。',
      learningTags: ['study'],
    );
    await tester.pumpWidget(
      app(MemoryLearningStore(), dictionaryEntries: const [entry, studyEntry]),
    );
    await tester.pumpAndSettle();

    final track = find.byKey(const ValueKey('learning-track-sentence'));
    await tester.ensureVisible(track);
    await tester.tap(track);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('learning-sentence-hub')), findsOneWidget);
    await expandSentenceSettings(tester);

    final studyScenario = find.byKey(
      const ValueKey('learning-sentence-scenario-study'),
    );
    await tester.ensureVisible(studyScenario);
    await tester.tap(studyScenario);
    await tester.pumpAndSettle();
    await startSentenceRound(tester);

    expect(find.text('我们下课后一起学习英语。'), findsOneWidget);
    expect(find.text('你好，很高兴见到你。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'article track keeps local learning separate from reader import',
    (tester) async {
      final store = MemoryLearningStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();

      final track = find.byKey(const ValueKey('learning-track-article'));
      await tester.ensureVisible(track);
      await tester.tap(track);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-article-learning-hub')),
        findsOneWidget,
      );
      final sourceSettings = find.byKey(
        const ValueKey('learning-article-source-settings'),
      );
      await tester.ensureVisible(sourceSettings);
      await tester.tap(sourceSettings);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('learning-article-workbench')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('learning-article-unavailable')),
        findsNothing,
      );
      expect(find.text('去阅读器导入文章'), findsNothing);
      expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);
      expect((await store.read())?.articleProgress, isEmpty);
    },
  );

  testWidgets('daily plan opens its displayed pronunciation focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        MemoryLearningStore(),
        dictionaryEntries: const [],
        clock: () => DateTime(2026, 9, 17, 10, 30),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('发音跟读 · 今日目标'), findsOneWidget);
    final action = find.byKey(const ValueKey('learning-plan-continue'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('learning-pronunciation-workspace')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('learning-plan-title')), findsNothing);
  });

  testWidgets('textbook catalog stays reachable from the content library', (
    tester,
  ) async {
    final package = LearningTextbookPackageData(
      id: 'demo-textbook',
      title: '我的演示教材',
      ageBand: '初中',
      level: 'middle',
      version: '授权导入 1.0',
      language: 'en-zh',
      licenseName: '用户合法授权',
      licenseUrl: '',
      rightsHolder: '用户本人',
      sourceUrl: '',
      redistributionAllowed: false,
      origin: LearningTextbookOrigin.userImported,
      lessons: const [
        LearningTextbookLessonData(
          id: 'unit-1',
          title: '第一单元',
          sourceText: 'Learning grows through practice.',
          translation: '学习在练习中成长。',
          vocabulary: ['learning'],
        ),
      ],
      importedAt: '2026-09-16T10:30:00+08:00',
      importedFrom: 'demo.json',
    );
    final learningStore = MemoryLearningStore();
    final repository = LearningRepository(learningStore, clock: () => now);
    var openTextbooks = false;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            if (!openTextbooks) {
              return SizedBox(
                width: 900,
                height: 700,
                child: ContentLibraryWorkspace(
                  loadDictionary: () async => const [entry],
                  loadSources: () async => const [],
                  loadTextbooks: () async =>
                      const <LearningTextbookPackageData>[],
                  onOpenTextbooks: () => setState(() => openTextbooks = true),
                ),
              );
            }
            return Material(
              child: SingleChildScrollView(
                child: LearningTextbookWorkspace(
                  packages: [package],
                  references: learningTextbookReferences,
                  selectedPackageId: package.id,
                  selectedLessonId: package.lessons.first.id,
                  onImport: () {},
                  onShowFormat: () {},
                  onSelectLesson: (_, _) {},
                  onAddVocabulary: () {},
                  onMarkLesson: () async {
                    await repository.saveArticleProgress(
                      LearningArticleProgressData(
                        articleId: 'textbook:demo-textbook:unit-1',
                        title: '第一单元',
                        currentParagraph: 0,
                        completedParagraphs: const [0],
                        favoriteParagraphs: const [],
                        lookedUpWords: const [],
                        lastReadAt: now.toIso8601String(),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('内容库读取失败，请检查本地数据后重试。'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -520));
    await tester.pumpAndSettle();
    final open = find.text('打开课程管理');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-textbook-workspace')),
      findsOneWidget,
    );
    expect(find.text('我的演示教材'), findsNWidgets(2));
    expect(find.text('Learning grows through practice.'), findsOneWidget);

    final mark = find.byKey(const ValueKey('learning-textbook-mark-lesson'));
    await tester.ensureVisible(mark);
    await tester.tap(mark);
    await tester.pumpAndSettle();
    final state = await learningStore.read();
    expect(
      state!.articleProgress.any(
        (item) => item.articleId == 'textbook:demo-textbook:unit-1',
      ),
      isTrue,
    );
  });
}

class _FailReadOnceAfterWriteLearningStore extends MemoryLearningStore {
  var _armed = false;
  var _failNextRead = false;

  void failReadAfterNextWrite() => _armed = true;

  @override
  Future<LearningStateData?> read() async {
    if (_failNextRead) {
      _failNextRead = false;
      throw StateError('simulated read failure after successful write');
    }
    return super.read();
  }

  @override
  Future<void> write(LearningStateData state) async {
    await super.write(state);
    if (_armed) {
      _armed = false;
      _failNextRead = true;
    }
  }
}
