import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_articles.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/learning_speech_service.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/learning_tracks.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/pronunciation_scoring.dart';
import 'package:yixue_app/features/learning/learning_landing_workspace.dart';
import 'package:yixue_app/features/learning/learning_article_workbench.dart';
import 'package:yixue_app/features/learning/learning_article_learning_hub.dart';
import 'package:yixue_app/features/learning/learning_vocabulary_workspace.dart';
import 'package:yixue_app/features/learning/learning_textbook_workspace.dart';

typedef LearningEntriesLoader = Future<List<DictionaryEntry>> Function();
typedef LearningDictionaryLookup = Future<DictionaryEntry?> Function(
  String word,
);
typedef LearningFavoriteWordsLoader = Future<List<String>> Function();
typedef LearningFavoriteWordSetter = Future<void> Function(
  String word,
  bool favorite,
);
typedef LearningWordAnnotationLoader = Future<WordAnnotationData?> Function(
  String word,
);
typedef LearningWordAnnotationSaver = Future<void> Function(
  WordAnnotationData annotation,
);
typedef LearningActivityRecorder = Future<void> Function(
  ActivityEventData activity,
);
typedef LearningSummaryGenerator = Future<String> Function(String text);
typedef LearningTextbookPicker = Future<XFile?> Function();
typedef LearningTextbookTranslator = Future<String> Function(String text);

DictionaryEntry _preserveLearningEditorialMetadata(
  DictionaryEntry resolved,
  DictionaryEntry? existing,
) {
  if (existing == null ||
      normalizeLearningWord(existing.word) !=
          normalizeLearningWord(resolved.word) ||
      dictionarySourceId(existing.source) !=
          dictionarySourceId(resolved.source)) {
    return resolved;
  }
  return DictionaryEntry(
    word: resolved.word,
    ipa: resolved.ipa.isEmpty ? existing.ipa : resolved.ipa,
    partOfSpeech: resolved.partOfSpeech.isEmpty
        ? existing.partOfSpeech
        : resolved.partOfSpeech,
    meanings: resolved.meanings.isEmpty ? existing.meanings : resolved.meanings,
    example: resolved.example.isEmpty ? existing.example : resolved.example,
    exampleTranslation: resolved.exampleTranslation.isEmpty
        ? existing.exampleTranslation
        : resolved.exampleTranslation,
    coverageBands: existing.coverageBands,
    source: resolved.source,
    exampleCandidates: existing.exampleCandidates,
    senseCandidates: existing.senseCandidates,
    partOfSpeechCandidates: existing.partOfSpeechCandidates,
    pronunciationCandidates: existing.pronunciationCandidates,
    learningTags: existing.learningTags,
    frequency: existing.frequency,
    qualityStatus: existing.qualityStatus,
    reviewFields: existing.reviewFields,
    candidateSourceIds: existing.candidateSourceIds,
    variants: existing.variants,
    collocationCandidates: existing.collocationCandidates,
    relationCandidates: existing.relationCandidates,
  );
}

/// Local learning workspace for vocabulary, speaking, sentence and article
/// practice.
///
/// It intentionally depends on the dictionary only through a loader and on
/// the local learning repository through [LearningStore]. No model call is
/// made for dictionary facts, examples, favorites, notes or review scheduling.
/// AI sentence generation is an explicit learner action and goes only through
/// the configured understanding-model callback.
class LearningWorkspace extends StatefulWidget {
  const LearningWorkspace({
    required this.store,
    required this.loadEntries,
    this.lookupDictionary,
    this.dataRevision = 0,
    this.loadFavoriteWords,
    this.setFavoriteWord,
    this.loadWordAnnotation,
    this.saveWordAnnotation,
    this.recordActivity,
    this.onOpenFocus,
    this.onOpenTranslation,
    this.onOpenContentLibrary,
    this.onSummarize,
    this.onGenerateSentenceExercises,
    this.onOpenUnderstandingModelSettings,
    this.speechRecognizer,
    this.textbookStore,
    this.textbookPicker,
    this.onTranslateTextbook,
    this.onSpeak,
    this.clock = DateTime.now,
    super.key,
  });

  final LearningStore store;
  final LearningEntriesLoader loadEntries;
  final LearningDictionaryLookup? lookupDictionary;

  /// Signals a write from another workspace without replacing this page state.
  final int dataRevision;
  final LearningFavoriteWordsLoader? loadFavoriteWords;
  final LearningFavoriteWordSetter? setFavoriteWord;
  final LearningWordAnnotationLoader? loadWordAnnotation;
  final LearningWordAnnotationSaver? saveWordAnnotation;
  final LearningActivityRecorder? recordActivity;
  final VoidCallback? onOpenFocus;
  final VoidCallback? onOpenTranslation;
  final void Function(VoidCallback openTextbooks)? onOpenContentLibrary;
  final LearningSummaryGenerator? onSummarize;
  final LearningSentenceExerciseGenerator? onGenerateSentenceExercises;
  final VoidCallback? onOpenUnderstandingModelSettings;
  final LearningSpeechRecognizer? speechRecognizer;
  final LearningTextbookStore? textbookStore;
  final LearningTextbookPicker? textbookPicker;
  final LearningTextbookTranslator? onTranslateTextbook;
  final Future<void> Function(String value)? onSpeak;
  final DateTime Function() clock;

  @override
  State<LearningWorkspace> createState() => _LearningWorkspaceState();
}

class _LearningWorkspaceState extends State<LearningWorkspace> {
  late final LearningRepository _repository;
  late final LearningTextbookStore _textbookStore;
  final GlobalKey _articleWorkbenchStateKey = GlobalKey();
  final _noteController = TextEditingController();
  final _recallAnswerController = TextEditingController();
  final _screenshotMeaningController = TextEditingController();
  final _sentenceController = TextEditingController();
  final _customSentenceTitleController = TextEditingController();
  final _customSentenceChineseController = TextEditingController();
  final _customSentenceEnglishController = TextEditingController();
  final _pronunciationQueryController = TextEditingController();
  final _sentenceCellControllers = <TextEditingController>[];
  final _localNotes = <String, String>{};
  final _entriesByWord = <String, DictionaryEntry>{};
  final _favoriteWords = <String>{};
  var _catalog = LearningSetCatalog.build(const []);
  var _selectedCatalogId = learningDefaultSetId;
  var _selectedTrack = _LearningTrack.landing;
  var _selectedRangeId = 'all';
  var _pronunciationBand = _PronunciationBand.cet4;
  var _pronunciationAccent = _PronunciationAccent.american;
  var _pronunciationSource = _PronunciationSource.newWords;
  String? _pronunciationSelectedWord;
  var _pronunciationTargetCount = 10;
  var _sentenceMode = SentencePracticeMode.chineseToEnglish;
  var _sentenceDifficulty = 1;
  var _sentenceScenario = _SentenceScenario.greeting;
  var _sentenceLibrary = _SentenceLibrary.builtIn;
  var _sentenceRoundSize = 5;
  var _sentenceIndex = 0;
  var _sentenceRoundActive = false;
  var _sentenceRoundFinished = false;
  var _sentenceRoundFromCustom = false;
  var _sentenceRoundFromAi = false;
  var _sentenceRoundTarget = 0;
  var _sentenceShowHistory = false;
  var _sentenceHistoryVisibleCount = 5;
  DateTime? _sentenceQuestionStartedAt;
  List<DictionaryEntry> _sentenceRoundEntries = const [];
  String _sentenceCellSeed = '';
  String? _sentenceStatus;
  var _sentenceStatusIsError = false;
  var _sentenceModelSettingsRecommended = false;
  String? _sentencePendingAnswer;
  String? _sentencePendingExpected;
  LearningSentenceAttemptData? _lastSentenceAttempt;
  String? _selectedArticleId;
  var _articleImmersiveReader = false;
  var _articleHubEntered = false;
  var _articleHubView = _ArticleHubView.home;
  var _articleSource = _ArticleSource.builtIn;
  var _articleParagraphIndex = 0;
  var _articleTranslationVisible = false;
  String? _articleSummary;
  String? _articleSelectedWord;
  String _articleWordNote = '';
  var _articleWordSelectionVersion = 0;
  var _pronunciationRunning = false;
  var _pronunciationElapsed = Duration.zero;
  Timer? _pronunciationTimer;
  var _speechListening = false;
  var _speechFinalizing = false;
  String _speechRecognized = '';
  String? _speechStatus;
  PronunciationScoreResult? _speechScore;
  final _textbookPackages = <LearningTextbookPackageData>[];
  String? _selectedTextbookPackageId;
  String? _selectedTextbookLessonId;

  LearningStateData? _state;
  var _loading = true;
  var _busy = false;
  var _textbookTranslationBusy = false;
  String? _textbookTranslationStatus;
  String? _textbookTranslationError;
  var _answerVisible = false;
  var _savingNote = false;
  var _savingScreenshotMeaning = false;
  var _dailyCount = 10;
  var _selectedMode = LearningPromptMode.recognition;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository = LearningRepository(widget.store, clock: widget.clock);
    _textbookStore = widget.textbookStore ?? MemoryLearningTextbookStore();
    unawaited(_restore());
  }

  @override
  void didUpdateWidget(covariant LearningWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataRevision != widget.dataRevision) {
      unawaited(_refreshExternalData());
    }
  }

  Future<void> _refreshExternalData() async {
    final revision = widget.dataRevision;
    try {
      final state = await _repository.load();
      if (!mounted || revision != widget.dataRevision) return;
      setState(() {
        _state = state;
        _catalog = LearningSetCatalog.build(
          _entriesByWord.values.toList(),
          favoriteWords: _favoriteWords,
          learningState: state,
        );
      });
      // Text controllers, current view and reveal state hold user drafts. An
      // external word addition must not reload notes or reset those controls.
    } catch (error) {
      if (mounted && revision == widget.dataRevision) {
        setState(() => _error = '学习资料刷新失败：$error');
      }
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    _recallAnswerController.dispose();
    _screenshotMeaningController.dispose();
    _sentenceController.dispose();
    _customSentenceTitleController.dispose();
    _customSentenceChineseController.dispose();
    _customSentenceEnglishController.dispose();
    _pronunciationQueryController.dispose();
    for (final controller in _sentenceCellControllers) {
      controller.dispose();
    }
    _pronunciationTimer?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final entries = await widget.loadEntries();
      _entriesByWord
        ..clear()
        ..addEntries(
          entries.map(
            (entry) => MapEntry(normalizeLearningWord(entry.word), entry),
          ),
        );
      var state = await _repository.ensureDefaultSet(
        _entriesByWord.keys,
        now: widget.clock(),
      );
      _textbookPackages
        ..clear()
        ..addAll(await _textbookStore.read());
      if (widget.loadFavoriteWords != null) {
        _favoriteWords
          ..clear()
          ..addAll(
            (await widget.loadFavoriteWords!()).map(normalizeLearningWord),
          );
      }
      // An external write may finish while the other initial loaders await.
      state = await _repository.load();
      _catalog = LearningSetCatalog.build(
        entries,
        favoriteWords: _favoriteWords,
        learningState: state,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
        _selectedCatalogId = state.session?.setId ?? learningDefaultSetId;
        _selectedMode = state.session?.mode ?? _selectedMode;
        _dailyCount =
            state.sets
                .where((set) => set.id == learningDefaultSetId)
                .firstOrNull
                ?.dailyNewLimit ??
            _dailyCount;
      });
      await _loadCurrentNote();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '学习资料读取失败：$error';
      });
    }
  }

  Future<void> _loadCurrentNote() async {
    final item = _currentItem;
    if (item == null) {
      _noteController.clear();
      _screenshotMeaningController.clear();
      return;
    }
    _screenshotMeaningController.text =
        item.setId == learningScreenshotWordsSetId ? item.meaning ?? '' : '';
    final localNote = _localNotes[item.word];
    if (localNote != null) {
      _noteController.text = localNote;
      return;
    }
    final loader = widget.loadWordAnnotation;
    if (loader == null) {
      _noteController.clear();
      return;
    }
    final annotation = await loader(item.word);
    if (!mounted || _currentItem?.id != item.id) return;
    _noteController.text = annotation?.note ?? '';
  }

  LearningItemData? get _currentItem {
    final state = _state;
    final session = state?.session;
    if (state == null || session == null || session.currentItemId == null) {
      return null;
    }
    for (final item in state.items) {
      if (item.id == session.currentItemId) return item;
    }
    return null;
  }

  DictionaryEntry? _entryFor(String word) =>
      _entriesByWord[normalizeLearningWord(word)];

  LearningSetCatalogItem? get _selectedCatalog =>
      _catalog.byId(_selectedCatalogId);

  List<DictionaryEntry> get _selectedEntries {
    final words =
        _selectedCatalog?.words.toSet() ?? _entriesByWord.keys.toSet();
    final entries = _entriesByWord.values
        .where((entry) => words.contains(normalizeLearningWord(entry.word)))
        .toList();
    entries.sort((left, right) => left.word.compareTo(right.word));
    return entries;
  }

  List<LearningItemData> get _selectedItems {
    final selectedId = _selectedCatalogId;
    final items =
        _state?.items.where((item) => item.setId == selectedId).toList() ??
        <LearningItemData>[];
    items.sort((left, right) {
      final due = left.dueDate.compareTo(right.dueDate);
      if (due != 0) return due;
      return left.word.compareTo(right.word);
    });
    return items;
  }

  LearningItemData? get _practiceItem =>
      _selectedItems.where((item) => !item.suspended).firstOrNull;

  /// Sentence practice is independent from vocabulary range selection.
  List<DictionaryEntry> get _sentenceEntries {
    if (_sentenceLibrary != _SentenceLibrary.builtIn) {
      final origin = _sentenceLibrary == _SentenceLibrary.ai
          ? LearningSentencePromptOrigin.aiGenerated
          : LearningSentencePromptOrigin.userCreated;
      final prompts = [
        for (final prompt
            in _state?.customSentencePrompts ??
                const <LearningSentencePromptData>[])
          if (prompt.origin == origin &&
              (_sentenceLibrary != _SentenceLibrary.ai ||
                  (prompt.scenario == _sentenceScenario.label &&
                      prompt.difficulty == _sentenceDifficulty)))
            prompt,
      ];
      final attemptsBySource = _sentenceAttemptsBySource;
      prompts.sort((left, right) {
        final leftAttempts =
            attemptsBySource[_sentencePromptPracticeKey(left)] ??
            const <LearningSentenceAttemptData>[];
        final rightAttempts =
            attemptsBySource[_sentencePromptPracticeKey(right)] ??
            const <LearningSentenceAttemptData>[];
        if (leftAttempts.length != rightAttempts.length) {
          return leftAttempts.length.compareTo(rightAttempts.length);
        }
        if (leftAttempts.isNotEmpty) {
          final leftLastAttempt = _latestSentenceAttempt(leftAttempts);
          final rightLastAttempt = _latestSentenceAttempt(rightAttempts);
          final recency = leftLastAttempt.compareTo(rightLastAttempt);
          if (recency != 0) return recency;
        }
        if (_sentenceLibrary == _SentenceLibrary.custom) {
          final created = left.createdAt.compareTo(right.createdAt);
          if (created != 0) return created;
          return left.id.compareTo(right.id);
        }
        final created = right.createdAt.compareTo(left.createdAt);
        if (created != 0) return created;
        final leftOrder = _aiSentencePromptOrder(left.id);
        final rightOrder = _aiSentencePromptOrder(right.id);
        if (leftOrder != null && rightOrder != null) {
          final batch = rightOrder.batch.compareTo(leftOrder.batch);
          if (batch != 0) return batch;
          final position = leftOrder.position.compareTo(rightOrder.position);
          if (position != 0) return position;
        }
        return left.id.compareTo(right.id);
      });
      return [
        for (final prompt in prompts)
          DictionaryEntry(
            word: prompt.title,
            ipa: '',
            partOfSpeech: prompt.origin.label,
            meanings: [prompt.chineseText],
            example: prompt.englishText,
            exampleTranslation: prompt.chineseText,
            learningTags: [
              prompt.origin == LearningSentencePromptOrigin.aiGenerated
                  ? 'ai-generated'
                  : 'user-created',
            ],
          ),
      ];
    }
    final entries = _entriesByWord.values
        .where(
          (entry) =>
              entry.isApprovedSentencePracticeEntry &&
              _sentenceScenario.matches(entry) &&
              _matchesSentenceDifficulty(entry, _sentenceDifficulty),
        )
        .toList();
    final attemptsBySource = _sentenceAttemptsBySource;
    entries.sort((left, right) {
      final leftAttempts =
          attemptsBySource[_sentenceEntryPracticeKey(left)] ??
          const <LearningSentenceAttemptData>[];
      final rightAttempts =
          attemptsBySource[_sentenceEntryPracticeKey(right)] ??
          const <LearningSentenceAttemptData>[];
      if (leftAttempts.length != rightAttempts.length) {
        return leftAttempts.length.compareTo(rightAttempts.length);
      }
      if (leftAttempts.isNotEmpty) {
        final leftLastAttempt = _latestSentenceAttempt(leftAttempts);
        final rightLastAttempt = _latestSentenceAttempt(rightAttempts);
        final recency = leftLastAttempt.compareTo(rightLastAttempt);
        if (recency != 0) return recency;
      }
      return left.word.compareTo(right.word);
    });
    return entries;
  }

  Map<String, List<LearningSentenceAttemptData>> get _sentenceAttemptsBySource {
    final result = <String, List<LearningSentenceAttemptData>>{};
    for (final attempt
        in _state?.sentenceAttempts ?? const <LearningSentenceAttemptData>[])
      result
          .putIfAbsent(_sentenceAttemptPracticeKey(attempt), () => [])
          .add(attempt);
    return result;
  }

  int _sentenceCountForLibrary(_SentenceLibrary library) {
    if (library == _SentenceLibrary.builtIn) {
      return _entriesByWord.values
          .where(
            (entry) =>
                entry.isApprovedSentencePracticeEntry &&
                _sentenceScenario.matches(entry) &&
                _matchesSentenceDifficulty(entry, _sentenceDifficulty),
          )
          .length;
    }
    final origin = library == _SentenceLibrary.ai
        ? LearningSentencePromptOrigin.aiGenerated
        : LearningSentencePromptOrigin.userCreated;
    return (_state?.customSentencePrompts ??
            const <LearningSentencePromptData>[])
        .where(
          (prompt) =>
              prompt.origin == origin &&
              (library != _SentenceLibrary.ai ||
                  (prompt.scenario == _sentenceScenario.label &&
                      prompt.difficulty == _sentenceDifficulty)),
        )
        .length;
  }

  String _sentenceAttemptPracticeKey(LearningSentenceAttemptData attempt) =>
      _sentencePracticeKey(
        fromCustomPrompt: attempt.fromCustomPrompt,
        fromAiPrompt: attempt.fromAiPrompt,
        title: attempt.word,
        englishText: attempt.sourceText,
        chineseText: attempt.translation,
      );

  String _sentencePromptPracticeKey(LearningSentencePromptData prompt) =>
      _sentencePracticeKey(
        fromCustomPrompt: true,
        fromAiPrompt: prompt.origin == LearningSentencePromptOrigin.aiGenerated,
        title: prompt.title,
        englishText: prompt.englishText,
        chineseText: prompt.chineseText,
      );

  String _sentenceEntryPracticeKey(DictionaryEntry entry) =>
      _sentencePracticeKey(
        fromCustomPrompt: false,
        fromAiPrompt: false,
        title: entry.word,
        englishText: entry.example,
        chineseText: entry.exampleTranslation,
      );

  String _sentencePracticeKey({
    required bool fromCustomPrompt,
    required bool fromAiPrompt,
    required String title,
    required String englishText,
    required String chineseText,
  }) =>
      '$fromCustomPrompt\u0000$fromAiPrompt\u0000$title\u0000$englishText\u0000$chineseText';

  ({int batch, int position})? _aiSentencePromptOrder(String id) {
    final match = RegExp(r'^ai-sentence-(\d+)-(\d+)(?:-\d+)?$').firstMatch(id);
    if (match == null) return null;
    final batch = int.tryParse(match.group(1)!);
    final position = int.tryParse(match.group(2)!);
    if (batch == null || position == null) return null;
    return (batch: batch, position: position);
  }

  String _latestSentenceAttempt(List<LearningSentenceAttemptData> attempts) =>
      attempts
          .map((attempt) => attempt.attemptedAt)
          .reduce((a, b) => a.compareTo(b) > 0 ? a : b);

  LearningArticle? get _selectedArticle => _selectedArticleId == null
      ? builtInLearningArticles.firstOrNull
      : builtInLearningArticles
            .where((article) => article.id == _selectedArticleId)
            .firstOrNull;

  List<LearningTextbookPackageData> get _availableTextbookPackages {
    final packages = <String, LearningTextbookPackageData>{
      for (final article in builtInLearningArticles)
        article.id: _packageFromArticle(article),
    };
    // An imported package with the same id is allowed to replace only its
    // visible catalog entry; the persisted package itself remains unchanged.
    for (final package in _textbookPackages) {
      packages[package.id] = package;
    }
    return packages.values.toList(growable: false);
  }

  LearningTextbookPackageData? get _selectedTextbookPackage {
    final packages = _availableTextbookPackages;
    for (final package in packages) {
      if (package.id == _selectedTextbookPackageId) return package;
    }
    return packages.firstOrNull;
  }

  LearningTextbookLessonData? get _selectedTextbookLesson {
    final package = _selectedTextbookPackage;
    if (package == null) return null;
    for (final lesson in package.lessons) {
      if (lesson.id == _selectedTextbookLessonId) return lesson;
    }
    return package.lessons.firstOrNull;
  }

  LearningTextbookPackageData _packageFromArticle(LearningArticle article) =>
      LearningTextbookPackageData(
        id: 'yixue-${article.id}',
        title: article.title,
        ageBand: '通用 / 自学',
        level: article.level,
        version: '译学自写 1.0',
        language: 'en-zh',
        licenseName: '译学自写内容许可（免费学习）',
        licenseUrl: '',
        rightsHolder: '花鱼鱼 / 译学',
        sourceUrl: '',
        redistributionAllowed: false,
        origin: LearningTextbookOrigin.selfAuthored,
        lessons: [
          LearningTextbookLessonData(
            id: 'lesson-1',
            title: '完整短课',
            sourceText: article.paragraphs
                .map((item) => item.text)
                .join('\n\n'),
            translation: article.paragraphs
                .map((item) => item.translation)
                .join('\n\n'),
            vocabulary: article.vocabulary,
          ),
        ],
        importedAt: '2026-09-16T00:00:00.000+08:00',
        importedFrom: '内置自写',
      );

  LearningArticleProgressData? _articleProgress(String articleId) => _state
      ?.articleProgress
      .where((progress) => progress.articleId == articleId)
      .firstOrNull;

  int get _todayCompleted {
    final today = learningDateKey(widget.clock());
    return _state?.reviews
            .where(
              (review) =>
                  review.setId == _selectedCatalogId &&
                  learningDateKey(DateTime.parse(review.reviewedAt)) == today,
            )
            .length ??
        0;
  }

  int get _dueCount {
    final today = learningDateKey(widget.clock());
    return _state?.items
            .where(
              (item) => !item.suspended && item.dueDate.compareTo(today) <= 0,
            )
            .where((item) => item.setId == _selectedCatalogId)
            .length ??
        0;
  }

  Future<void> _selectCatalog(String id) async {
    if (_busy || id == _selectedCatalogId) return;
    final catalogItem = _catalog.byId(id);
    if (catalogItem == null) return;
    final session = _state?.session;
    if (session != null && session.currentIndex < session.queueItemIds.length) {
      setState(() => _error = '当前有进行中的词汇学习，请先暂停或结束本轮后切换词书。');
      return;
    }
    setState(() => _busy = true);
    try {
      final moment = widget.clock();
      final next = await _repository.ensureSet(
        catalogItem.definition(moment),
        catalogItem.words,
        now: moment,
      );
      if (!mounted) return;
      setState(() {
        _state = next;
        _selectedCatalogId = id;
        _sentenceIndex = 0;
        _sentenceController.clear();
        _sentenceStatus = null;
        _lastSentenceAttempt = null;
        _answerVisible = false;
        _recallAnswerController.clear();
        _status = _selectedTrack == _LearningTrack.vocabulary
            ? null
            : '已切换到「${catalogItem.title}」';
        _error = null;
      });
      await _loadCurrentNote();
    } catch (error) {
      if (mounted) setState(() => _error = '切换学习集合失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startOrResume() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = _state?.session;
      final next = session == null
          ? await _repository.startSession(
              setId: _selectedCatalogId,
              mode: _selectedMode,
              newLimit: _dailyCount,
              reviewLimit: _dailyCount * 2,
              now: widget.clock(),
            )
          : await _repository.resumeSession();
      if (!mounted) return;
      setState(() {
        _state = next;
        _loading = false;
        _selectedTrack = _LearningTrack.vocabulary;
        _answerVisible = false;
        _recallAnswerController.clear();
        _status = next.session == null ? '今天没有到期的学习条目' : null;
      });
      await _loadCurrentNote();
    } catch (error) {
      if (mounted) setState(() => _error = '无法开始学习：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record(LearningReviewResult result) async {
    if (_busy || _currentItem == null) return;
    setState(() => _busy = true);
    try {
      final review = await _repository.recordReview(
        result: result,
        elapsedSeconds: 0,
        now: widget.clock(),
      );
      if (review == null) return;
      final next = await _repository.load();
      final recorder = widget.recordActivity;
      if (recorder != null) {
        try {
          await recorder(
            ActivityEventData(
              id: review.id,
              kind: ActivityKind.vocabulary,
              title: review.word,
              detail: '学习 · ${review.result.label}',
              durationSeconds: review.elapsedSeconds,
              itemCount: 1,
              occurredAt: review.reviewedAt,
              sourceId: 'learning',
            ),
          );
        } catch (_) {
          // A dashboard event must not undo a successfully saved review.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = next;
        _answerVisible = false;
        _recallAnswerController.clear();
        _status = next.session == null
            ? '本轮学习完成'
            : '已记录：${review.result.label} · 下一词已准备好';
      });
      await _loadCurrentNote();
    } catch (error) {
      if (mounted) setState(() => _error = '保存复习结果失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final item = _currentItem;
    if (item == null || _busy) return;
    final next = !_favoriteWords.contains(item.word);
    setState(() => _busy = true);
    try {
      if (widget.setFavoriteWord != null) {
        await widget.setFavoriteWord!(item.word, next);
      }
      if (!mounted) return;
      setState(() {
        if (next) {
          _favoriteWords.add(item.word);
        } else {
          _favoriteWords.remove(item.word);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '收藏状态保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveNote() async {
    final item = _currentItem;
    if (item == null || _savingNote) return;
    final note = _noteController.text.trim();
    setState(() => _savingNote = true);
    try {
      _localNotes[item.word] = note;
      final saver = widget.saveWordAnnotation;
      if (saver != null) {
        await saver(
          WordAnnotationData(
            word: item.word,
            note: note,
            addedToLearning: true,
            updatedAt: widget.clock().toIso8601String(),
          ),
        );
      }
      if (mounted) {
        setState(() => _status = '笔记已保存');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '笔记保存失败：$error');
    } finally {
      if (mounted) setState(() => _savingNote = false);
    }
  }

  Future<void> _saveScreenshotMeaning() async {
    final item = _currentItem;
    if (item == null ||
        item.setId != learningScreenshotWordsSetId ||
        _savingScreenshotMeaning) {
      return;
    }
    setState(() => _savingScreenshotMeaning = true);
    try {
      final next = await _repository.saveScreenshotWordMeaning(
        itemId: item.id,
        meaning: _screenshotMeaningController.text,
        now: widget.clock(),
      );
      if (!mounted) return;
      setState(() {
        _state = next;
        _screenshotMeaningController.text =
            next.items
                .where((candidate) => candidate.id == item.id)
                .firstOrNull
                ?.meaning ??
            '';
        _status = '截屏生词释义已保存';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '截屏生词释义保存失败：$error');
    } finally {
      if (mounted) setState(() => _savingScreenshotMeaning = false);
    }
  }

  Future<void> _pauseOrResume() async {
    if (_busy || _state?.session == null) return;
    setState(() => _busy = true);
    try {
      final paused = _state!.session!.paused;
      final next = paused
          ? await _repository.resumeSession()
          : await _repository.pauseSession();
      if (mounted) {
        setState(() {
          _state = next;
          _status = paused ? '继续当前学习' : '已暂停，进度已保存';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '学习状态保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _endSession() async {
    if (_busy || _state?.session == null) return;
    setState(() => _busy = true);
    try {
      final next = await _repository.endSession();
      if (mounted) {
        setState(() {
          _state = next;
          _answerVisible = false;
          _recallAnswerController.clear();
          _status = '本轮已结束，进度已保存';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '结束学习失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openTrack(String id) {
    final track = switch (id) {
      'vocabulary' => _LearningTrack.vocabulary,
      'pronunciation' => _LearningTrack.pronunciation,
      'sentence' => _LearningTrack.sentence,
      'article' => _LearningTrack.article,
      _ => _LearningTrack.landing,
    };
    if (track == _LearningTrack.landing) return;
    final useFourLevel =
        track == _LearningTrack.vocabulary &&
        _selectedRangeId == 'all' &&
        (_catalog.byId('cet4')?.availableCount ?? 0) > 0;
    setState(() {
      _selectedTrack = track;
      if (useFourLevel) _selectedRangeId = 'cet4';
      _sentenceStatus = null;
      _lastSentenceAttempt = null;
      if (track == _LearningTrack.article) {
        _articleImmersiveReader = false;
        _articleHubEntered = false;
        _articleHubView = _ArticleHubView.home;
        _articleSource = _ArticleSource.builtIn;
      }
    });
    if (useFourLevel) unawaited(_selectCatalog('cet4'));
  }

  void _continueLearningPlan() {
    final plan = _planView();
    if (plan.hasActiveSession || plan.focusTrackId == 'vocabulary') {
      unawaited(_startOrResume());
      return;
    }
    _openTrack(plan.focusTrackId);
  }

  void _openTextbooks() {
    setState(() {
      _selectedTrack = _LearningTrack.textbook;
      _status = null;
      _error = null;
    });
  }

  void _returnToLearningHome() {
    setState(() {
      _selectedTrack = _LearningTrack.landing;
      _articleImmersiveReader = false;
      _articleHubEntered = false;
      _articleHubView = _ArticleHubView.home;
      _status = null;
      _error = null;
    });
  }

  void _selectRange(LearningVocabularyRangeView range) {
    if (_busy) return;
    setState(() => _selectedRangeId = range.id);
    final catalogId = range.catalogId;
    if (catalogId != null) unawaited(_selectCatalog(catalogId));
  }

  Future<void> _toggleVocabularyFavorite(String word) async {
    if (_busy) return;
    final normalized = normalizeLearningWord(word);
    final nextFavorite = !_favoriteWords.contains(normalized);
    setState(() => _busy = true);
    try {
      if (widget.setFavoriteWord != null) {
        await widget.setFavoriteWord!(normalized, nextFavorite);
      }
      if (!mounted) return;
      setState(() {
        if (nextFavorite) {
          _favoriteWords.add(normalized);
        } else {
          _favoriteWords.remove(normalized);
        }
        _catalog = LearningSetCatalog.build(
          _entriesByWord.values,
          favoriteWords: _favoriteWords,
          learningState: _state,
        );
      });
    } catch (error) {
      if (mounted) setState(() => _error = '收藏状态保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _todayCount(Iterable<String> timestamps) {
    final today = learningDateKey(widget.clock());
    return timestamps.where((timestamp) {
      final parsed = DateTime.tryParse(timestamp);
      return parsed != null && learningDateKey(parsed) == today;
    }).length;
  }

  int _sentenceCountForDay(DateTime day) {
    final key = learningDateKey(day);
    return (_state?.sentenceAttempts ?? const <LearningSentenceAttemptData>[])
        .where((attempt) {
          final parsed = DateTime.tryParse(attempt.attemptedAt);
          return parsed != null && learningDateKey(parsed) == key;
        })
        .length;
  }

  void _startSentenceRound() {
    if (_busy) return;
    final available = _sentenceEntries;
    if (available.isEmpty) {
      setState(() {
        _sentenceStatus = '当前句子库没有可练习的句子。';
        _sentenceStatusIsError = true;
      });
      return;
    }
    final queue = available.take(_sentenceRoundSize).toList(growable: false);
    setState(() {
      _sentenceRoundEntries = queue;
      _sentenceRoundTarget = queue.length;
      _sentenceRoundFromCustom = _sentenceLibrary != _SentenceLibrary.builtIn;
      _sentenceRoundFromAi = _sentenceLibrary == _SentenceLibrary.ai;
      _sentenceRoundActive = true;
      _sentenceRoundFinished = false;
      _sentenceIndex = 0;
      _sentenceQuestionStartedAt = widget.clock();
      _resetSentenceAttempt();
      _error = null;
    });
  }

  void _returnToSentenceHub() {
    setState(() {
      _sentenceRoundActive = false;
      _resetSentenceAttempt();
    });
  }

  Future<void> _saveCustomSentencePrompt() async {
    if (_busy) return;
    final title = _customSentenceTitleController.text.trim();
    final chineseText = _customSentenceChineseController.text.trim();
    final englishText = _customSentenceEnglishController.text.trim();
    if (title.isEmpty || chineseText.isEmpty || englishText.isEmpty) {
      setState(() {
        _sentenceStatus = '请填写标题、中文句子和英文句子。';
        _sentenceStatusIsError = true;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final prompt = await _repository.saveCustomSentencePrompt(
        title: title,
        chineseText: chineseText,
        englishText: englishText,
        now: widget.clock(),
      );
      final current = _state;
      if (current == null) throw StateError('学习资料尚未完成加载');
      final next = current.withSentencePromptSaved(prompt);
      if (!mounted) return;
      setState(() {
        _state = next;
        _sentenceLibrary = _SentenceLibrary.custom;
        _customSentenceTitleController.clear();
        _customSentenceChineseController.clear();
        _customSentenceEnglishController.clear();
        _sentenceStatus = '已保存到我的句子库。';
        _sentenceStatusIsError = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '保存自建句子失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateAiSentencePrompts() async {
    if (_busy) return;
    final generator = widget.onGenerateSentenceExercises;
    if (generator == null) {
      setState(() {
        _sentenceStatus = '尚未接入 AI 句子生成。请检查“理解与总结”模型配置后重试。';
        _sentenceStatusIsError = true;
        _sentenceModelSettingsRecommended = true;
      });
      return;
    }
    final scenario = _sentenceScenario.label;
    final difficulty = _sentenceDifficulty;
    final count = _sentenceRoundSize;
    setState(() {
      _busy = true;
      _sentenceStatus = '正在向“理解与总结”模型请求双语句子…';
      _sentenceStatusIsError = false;
      _sentenceModelSettingsRecommended = false;
      _sentenceRoundFinished = false;
      _error = null;
    });
    try {
      final existingCount = _state?.customSentencePrompts.length ?? 0;
      final List<LearningSentenceExerciseData> exercises;
      try {
        exercises = await generator(
          scenario: scenario,
          difficulty: difficulty,
          count: count,
        );
      } on LearningSummaryException catch (error) {
        if (!mounted) return;
        setState(() {
          _sentenceStatus = error.message;
          _sentenceStatusIsError = true;
          _sentenceModelSettingsRecommended = const {
            'no_summary_model',
            'provider_unavailable',
            'provider_invalid',
            'missing_credential',
          }.contains(error.code);
        });
        return;
      } on Object {
        if (!mounted) return;
        setState(() {
          _sentenceStatus = 'AI 请求未完成，暂时没有生成题目。请检查模型连接后重试。';
          _sentenceStatusIsError = true;
          _sentenceModelSettingsRecommended = false;
        });
        return;
      }
      if (exercises.length != count) {
        if (!mounted) return;
        setState(() {
          _sentenceStatus = const LearningSummaryException(
            'invalid_sentence_response',
          ).message;
          _sentenceStatusIsError = true;
          _sentenceModelSettingsRecommended = false;
        });
        return;
      }
      final LearningStateData next;
      try {
        next = await _repository.saveGeneratedSentencePrompts(
          exercises: exercises,
          scenario: scenario,
          difficulty: difficulty,
          now: widget.clock(),
        );
      } on Object {
        if (!mounted) return;
        setState(() {
          _sentenceStatus = '题目已生成，但保存到本地失败；请检查学习空间存储后重试。';
          _sentenceStatusIsError = true;
          _sentenceModelSettingsRecommended = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _state = next;
        _sentenceLibrary = _SentenceLibrary.ai;
        _sentenceRoundFinished = false;
        final addedCount = next.customSentencePrompts.length - existingCount;
        _sentenceStatus = addedCount == 0
            ? '生成完成，但这些句子与本地题库重复；没有重复添加。'
            : addedCount < count
            ? '新增 $addedCount 句到本地 AI 句子库，重复题已跳过。'
            : '已生成并保存 $addedCount 句到 AI 句子库，可开始练习。';
        _sentenceStatusIsError = false;
        _sentenceModelSettingsRecommended = false;
        _error = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteCustomSentencePrompt(String id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = await _repository.deleteCustomSentencePrompt(id);
      if (mounted) {
        setState(() {
          _state = next;
          _sentenceRoundFinished = false;
          _sentenceStatus = '已从句子库移除；练习记录仍会保留。';
          _sentenceStatusIsError = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '删除自建句子失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LearningPlanViewData _planView() {
    final session = _state?.session;
    final due = _dueCount;
    final daySeed = widget.clock().difference(DateTime(2026, 1, 1)).inDays;
    final hasActiveSession =
        session != null && session.currentIndex < session.queueItemIds.length;
    // The article-reading integration remains intentionally unavailable. The
    // plan rotates only through active tracks so its primary action always
    // reaches a usable exercise. A saved vocabulary session always resumes.
    final focusTrack = hasActiveSession || due > 0
        ? _LearningTrack.vocabulary
        : [
            _LearningTrack.vocabulary,
            _LearningTrack.pronunciation,
            _LearningTrack.sentence,
          ][daySeed.remainder(3)];
    final target = switch (focusTrack) {
      _LearningTrack.vocabulary => _dailyCount,
      _LearningTrack.pronunciation => _pronunciationTargetCount,
      _LearningTrack.sentence => 5,
      _LearningTrack.article => 3,
      _ => _dailyCount,
    };
    final targetUnit = switch (focusTrack) {
      _LearningTrack.vocabulary || _LearningTrack.pronunciation => '词',
      _LearningTrack.sentence => '句',
      _LearningTrack.article => '段',
      _ => '项',
    };
    final completed =
        session?.completedCount ??
        switch (focusTrack) {
          _LearningTrack.vocabulary => _todayCompleted,
          _LearningTrack.pronunciation => _todayCount(
            _state?.pronunciationPractices.map((item) => item.practicedAt) ??
                const <String>[],
          ),
          _LearningTrack.sentence => _todayCount(
            _state?.sentenceAttempts.map((item) => item.attemptedAt) ??
                const <String>[],
          ),
          _LearningTrack.article =>
            _state?.articleProgress
                    .where(
                      (item) =>
                          learningDateKey(DateTime.parse(item.lastReadAt)) ==
                          learningDateKey(widget.clock()),
                    )
                    .fold<int>(
                      0,
                      (total, item) => total + item.completedParagraphs.length,
                    ) ??
                0,
          _ => 0,
        };
    final sessionProgress = session == null || session.queueItemIds.isEmpty
        ? 0.0
        : (session.completedCount / session.queueItemIds.length).clamp(
            0.0,
            1.0,
          );
    return LearningPlanViewData(
      focusTrackId: switch (focusTrack) {
        _LearningTrack.vocabulary => 'vocabulary',
        _LearningTrack.pronunciation => 'pronunciation',
        _LearningTrack.sentence => 'sentence',
        _ => 'vocabulary',
      },
      title: '${focusTrack.label} · 今日目标 $target $targetUnit',
      focus: switch (focusTrack) {
        _LearningTrack.vocabulary =>
          '先复习到期词汇，再学习新词。预计 ${target <= 5 ? 15 : 25} 分钟；当前待复习 $due 词。',
        _LearningTrack.pronunciation =>
          '跟读 $target 个词并记录自我评估，预计 ${target <= 5 ? 15 : 25} 分钟。',
        _LearningTrack.sentence =>
          '完成 $target 个句子练习，在语境中巩固表达，预计 ${target <= 5 ? 15 : 25} 分钟。',
        _ => '完成今日的学习目标。',
      },
      dueCount: due,
      completedCount: completed.clamp(0, target),
      targetCount: target,
      targetMinutes: target <= 5 ? 15 : 25,
      hasActiveSession: hasActiveSession,
      paused: session?.paused ?? false,
      sessionProgress: sessionProgress,
      targetUnit: targetUnit,
    );
  }

  List<LearningTrackViewData> _trackViews() {
    final pronunciationToday = _todayCount(
      _state?.pronunciationPractices.map((item) => item.practicedAt) ??
          const <String>[],
    );
    final sentenceToday = _todayCount(
      _state?.sentenceAttempts.map((item) => item.attemptedAt) ??
          const <String>[],
    );
    final articleReadParagraphs =
        _state?.articleProgress.fold<int>(
          0,
          (total, article) => total + article.completedParagraphs.length,
        ) ??
        0;
    return [
      LearningTrackViewData(
        id: 'vocabulary',
        title: '词汇循环',
        description: '间隔复习到期词，再补充新词',
        icon: Icons.menu_book_rounded,
        target: '优先复习到期词 · 本轮进度已保存',
        progress: (_todayCompleted / _dailyCount).clamp(0.0, 1.0),
        status: '今日 $_todayCompleted / $_dailyCount 词',
      ),
      LearningTrackViewData(
        id: 'pronunciation',
        title: '发音跟读',
        description: '跟读词音，记录自我评估',
        icon: Icons.mic_none_rounded,
        target: '每日目标 $_pronunciationTargetCount 词',
        progress: (pronunciationToday / _pronunciationTargetCount).clamp(
          0.0,
          1.0,
        ),
        status: '今日跟读 $pronunciationToday / $_pronunciationTargetCount 词',
      ),
      LearningTrackViewData(
        id: 'sentence',
        title: '句子练习',
        description: '在语境中回忆并运用表达',
        icon: Icons.chat_bubble_outline_rounded,
        target: '每日目标 5 句 · 理解并组织完整表达',
        progress: (sentenceToday / 5).clamp(0.0, 1.0),
        status: '今日完成 $sentenceToday / 5 句',
      ),
      LearningTrackViewData(
        id: 'article',
        title: '文章精读',
        description: '按段精读，查词收藏并保存进度',
        icon: Icons.menu_book_rounded,
        target: '中英对照 · 查词收藏 · 段落进度',
        progress: 0,
        status:
            '${builtInLearningArticles.length} 篇可读 · 已读 $articleReadParagraphs 段',
        showProgress: false,
      ),
    ];
  }

  List<LearningVocabularyRangeView> _vocabularyRanges() {
    int count(String? catalogId) =>
        catalogId == null ? 0 : _catalog.byId(catalogId)?.availableCount ?? 0;
    LearningVocabularyRangeView range(
      String id,
      String group,
      String title,
      String detail, {
      String? catalogId,
    }) => LearningVocabularyRangeView(
      id: id,
      group: group,
      title: title,
      detail: detail,
      count: count(catalogId),
      catalogId: catalogId,
    );
    return [
      range(
        'all',
        '本地词库与考试目标',
        '全部本地词典',
        '当前已打包/导入的全部词条',
        catalogId: learningDefaultSetId,
      ),
      range(
        'screenshot-words',
        '截屏翻译',
        '截屏生词',
        '从截屏翻译中收集，带着截图原文和译文语境复习',
        catalogId: learningScreenshotWordsSetId,
      ),
      range(
        'favorites',
        '本地词库与考试目标',
        '我的收藏',
        '从快速翻译和学习页收藏',
        catalogId: 'favorites',
      ),
      range('cet4', '本地词库与考试目标', '英语四级', '合法四级覆盖词表', catalogId: 'cet4'),
      range('cet6', '本地词库与考试目标', '英语六级', '合法六级覆盖词表', catalogId: 'cet6'),
      range(
        'graduate',
        '本地词库与考试目标',
        '考研词汇',
        '学术与研究生阅读目标',
        catalogId: 'graduate',
      ),
      range(
        'doctoral',
        '本地词库与考试目标',
        '考博与学术',
        '更高阶学术阅读目标',
        catalogId: 'doctoral',
      ),
      range('oxford', '本地词库与考试目标', '高阶目标（规划）', '当前没有独立授权词表或已审校高阶词条'),
      range(
        'primary-all',
        '小学教材词表',
        '小学阶段',
        '各版本单词表 · 先选年级/上下册',
        catalogId: 'primary',
      ),
      range('primary-1-up', '小学教材词表', '一年级上册', '人教/苏教等版本词表待选'),
      range('primary-1-down', '小学教材词表', '一年级下册', '人教/苏教等版本词表待选'),
      range('primary-2-up', '小学教材词表', '二年级上册', '版本和授权词表待选'),
      range('primary-2-down', '小学教材词表', '二年级下册', '版本和授权词表待选'),
      range('primary-3-up', '小学教材词表', '三年级上册', '版本和授权词表待选'),
      range('primary-3-down', '小学教材词表', '三年级下册', '版本和授权词表待选'),
      range('primary-4-up', '小学教材词表', '四年级上册', '版本和授权词表待选'),
      range('primary-4-down', '小学教材词表', '四年级下册', '版本和授权词表待选'),
      range('primary-5-up', '小学教材词表', '五年级上册', '版本和授权词表待选'),
      range('primary-5-down', '小学教材词表', '五年级下册', '版本和授权词表待选'),
      range('primary-6-up', '小学教材词表', '六年级上册', '版本和授权词表待选'),
      range('primary-6-down', '小学教材词表', '六年级下册', '版本和授权词表待选'),
      range(
        'middle-all',
        '初中教材词表',
        '初中阶段',
        '各版本单词表 · 先选年级/上下册',
        catalogId: 'middle',
      ),
      range('middle-7-up', '初中教材词表', '七年级上册', '版本和授权词表待选'),
      range('middle-7-down', '初中教材词表', '七年级下册', '版本和授权词表待选'),
      range('middle-8-up', '初中教材词表', '八年级上册', '版本和授权词表待选'),
      range('middle-8-down', '初中教材词表', '八年级下册', '版本和授权词表待选'),
      range('middle-9-up', '初中教材词表', '九年级上册', '版本和授权词表待选'),
      range('middle-9-down', '初中教材词表', '九年级下册', '版本和授权词表待选'),
      range(
        'high-all',
        '高中教材词表',
        '高中阶段',
        '必修/选择性必修词表 · 版本待选',
        catalogId: 'high',
      ),
      range('high-required', '高中教材词表', '必修词表', '版本和授权词表待选'),
      range('high-selective', '高中教材词表', '选择性必修', '版本和授权词表待选'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            key: const ValueKey('learning-scroll'),
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_articleImmersiveReader) _buildHeader(colors),
                  if (_status != null) ...[
                    const SizedBox(height: 14),
                    _NoticeBar(text: _status!, positive: true),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    _NoticeBar(text: _error!, positive: false),
                  ],
                  if (_loading)
                    _LearningWorkspaceLoadingSkeleton(
                      key: const ValueKey('learning-loading-skeleton'),
                    )
                  else if (_selectedTrack == _LearningTrack.landing)
                    LearningLandingWorkspace(
                      plan: _planView(),
                      tracks: _trackViews(),
                      onOpenTrack: _openTrack,
                      onStartPlan: _continueLearningPlan,
                      onRest: _pauseOrResume,
                      onExit: _endSession,
                      onOpenContentLibrary: widget.onOpenContentLibrary == null
                          ? null
                          : () => widget.onOpenContentLibrary!(_openTextbooks),
                      onOpenTextbooks: _openTextbooks,
                    )
                  else if (_selectedTrack == _LearningTrack.vocabulary)
                    if (_state?.session != null)
                      _buildActiveWorkspace(colors, constraints.maxWidth)
                    else
                      LearningVocabularyWorkspace(
                        catalog: _catalog,
                        selectedCatalogId: _selectedCatalogId,
                        ranges: _vocabularyRanges(),
                        selectedRangeId: _selectedRangeId,
                        onSelectRange: _selectRange,
                        selectedEntries: _selectedEntries,
                        selectedItems: _selectedItems,
                        selectedMode: _selectedMode,
                        onModeChanged: (mode) =>
                            setState(() => _selectedMode = mode),
                        dailyCount: _dailyCount,
                        onDailyCountChanged: (count) =>
                            setState(() => _dailyCount = count),
                        onStart: _startOrResume,
                        busy: _busy,
                        onSpeak: widget.onSpeak,
                        isFavorite: (word) => _favoriteWords.contains(
                          normalizeLearningWord(word),
                        ),
                        onToggleFavorite: _toggleVocabularyFavorite,
                      )
                  else if (_selectedTrack == _LearningTrack.pronunciation)
                    _buildPronunciationWorkspace(colors)
                  else if (_selectedTrack == _LearningTrack.sentence)
                    _buildSentenceWorkspace(colors)
                  else if (_selectedTrack == _LearningTrack.textbook)
                    _buildTextbookWorkspace(colors)
                  else if (_selectedTrack == _LearningTrack.article)
                    _buildArticleWorkspace(colors)
                  else
                    _buildArticleWorkspace(colors),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLanding = _selectedTrack == _LearningTrack.landing;
        if (isLanding) {
          return Align(
            key: const ValueKey('learning-home-header'),
            alignment: Alignment.centerLeft,
            child: Text(
              '学习',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: colors.onSurface,
              ),
            ),
          );
        }
        if (_selectedTrack == _LearningTrack.vocabulary &&
            _state?.session == null) {
          return Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const ValueKey('learning-back'),
              tooltip: '返回学习首页',
              onPressed: _returnToLearningHome,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          );
        }
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!isLanding) ...[
                  IconButton(
                    key: const ValueKey('learning-back'),
                    tooltip: '返回学习首页',
                    onPressed: _returnToLearningHome,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 2),
                ],
                Text(
                  isLanding ? '学习' : _selectedTrack.label,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '返回不会中断计划；只有“退出本轮”才会结束当前学习会话。',
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        );
        // The learning page deliberately keeps its header quiet like the
        // reference screen. Translation and focus remain available from the
        // home dashboard, while this surface is reserved for four learning
        // directions and their independent plans.
        const actions = SizedBox(width: 1);
        if (constraints.maxWidth < 700) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 10), actions],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: title),
            actions,
          ],
        );
      },
    );
  }

  DictionaryEntry? get _pronunciationEntry {
    final selectedWord = _pronunciationSelectedWord;
    if (selectedWord != null) {
      final selected = _entryFor(selectedWord);
      if (selected != null) return selected;
    }
    final item = _practiceItem;
    if (item != null) return _entryFor(item.word);
    return _pronunciationEntries.firstOrNull;
  }

  List<DictionaryEntry> get _pronunciationEntries {
    final entries = _selectedEntries;
    if (_pronunciationSource == _PronunciationSource.review) {
      final practiced =
          _state?.pronunciationPractices
              .where((item) => item.setId == _selectedCatalogId)
              .map((item) => normalizeLearningWord(item.word))
              .toSet() ??
          <String>{};
      final reviewed = entries
          .where(
            (entry) => practiced.contains(normalizeLearningWord(entry.word)),
          )
          .toList(growable: false);
      if (reviewed.isNotEmpty) return reviewed;
    }
    final aliases = _pronunciationBand.aliases;
    if (aliases.isEmpty) return entries;
    final filtered = entries
        .where((entry) {
          final tags = <String>[
            ...entry.coverageBands,
            ...entry.learningTags,
            entry.source,
          ].map(_normalizeLearningTag).toSet();
          return aliases.any(tags.contains);
        })
        .toList(growable: false);
    return filtered.isEmpty ? entries : filtered;
  }

  void _lookupPronunciationWord() {
    final query = _pronunciationQueryController.text.trim();
    if (query.isEmpty) {
      setState(() => _speechStatus = '输入英文或中文释义后再查询。');
      return;
    }
    final entry = bestDictionaryEntryForTerm(query, _entriesByWord.values);
    if (entry == null) {
      setState(() => _speechStatus = '本地词典暂时没有「$query」，可先在内容库导入合法词典条目。');
      return;
    }
    setState(() {
      _pronunciationSelectedWord = entry.word;
      _speechStatus = '已找到「${entry.word}」，可以播放、跟读或录音评分。';
      _speechScore = null;
      _speechRecognized = '';
    });
  }

  void _togglePronunciationTimer() {
    if (_pronunciationRunning) {
      _pronunciationTimer?.cancel();
      setState(() => _pronunciationRunning = false);
      return;
    }
    setState(() => _pronunciationRunning = true);
    _pronunciationTimer?.cancel();
    _pronunciationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _pronunciationElapsed += const Duration(seconds: 1);
      });
    });
  }

  Future<void> _toggleSpeechRecognition() async {
    final recognizer = widget.speechRecognizer;
    final entry = _pronunciationEntry;
    if (recognizer == null || entry == null) {
      setState(() => _speechStatus = '当前环境没有可用的麦克风跟读接口，可继续使用下面的手动自评。');
      return;
    }
    if (_speechListening) {
      await _stopSpeechRecognition(recognizer);
      return;
    }
    if (_busy) return;
    setState(() {
      _speechRecognized = '';
      _speechScore = null;
      _speechStatus = '正在准备麦克风…';
      _speechFinalizing = false;
    });
    try {
      final available = await recognizer.initialize(
        onStatus: (status) {
          if (!mounted) return;
          setState(() => _speechStatus = _speechStatusLabel(status));
        },
        onError: (message) {
          if (!mounted) return;
          setState(() => _speechStatus = _speechErrorLabel(message));
        },
      );
      if (!available) {
        if (mounted) {
          setState(
            () => _speechStatus = '系统语音识别不可用，请检查 Windows 麦克风和语音权限；也可以使用手动自评。',
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _speechListening = true;
        _speechStatus = '请朗读目标词，完成后点击停止。';
      });
      await recognizer.listen(localeId: 'en-US', onResult: _onSpeechResult);
    } catch (error) {
      if (mounted) {
        setState(() {
          _speechListening = false;
          _speechStatus = _speechErrorLabel('$error');
        });
      }
    }
  }

  Future<void> _stopSpeechRecognition(
    LearningSpeechRecognizer recognizer,
  ) async {
    try {
      await recognizer.stop();
    } catch (error) {
      if (mounted) setState(() => _speechStatus = _speechErrorLabel('$error'));
    }
    if (!mounted) return;
    setState(() => _speechListening = false);
    if (_speechFinalizing) return;
    final entry = _pronunciationEntry;
    final recognized = _speechRecognized.trim();
    if (entry == null || recognized.isEmpty) {
      setState(() => _speechStatus = '没有识别到清晰的词语，请再试一次或使用手动自评。');
      return;
    }
    _speechFinalizing = true;
    unawaited(_finishSpeechResult(entry, recognized));
  }

  void _onSpeechResult(String recognizedText, bool isFinal) {
    if (!mounted) return;
    final text = recognizedText.trim();
    setState(() {
      _speechRecognized = text;
      _speechStatus = isFinal ? '识别完成，正在计算词级评分…' : '正在识别…';
      if (isFinal) _speechListening = false;
    });
    if (!isFinal || _speechFinalizing) return;
    final entry = _pronunciationEntry;
    if (entry == null) return;
    _speechFinalizing = true;
    unawaited(_finishSpeechResult(entry, text));
  }

  Future<void> _finishSpeechResult(
    DictionaryEntry entry,
    String recognizedText,
  ) async {
    final score = scorePronunciation(
      targetText: entry.word,
      recognizedText: recognizedText,
    );
    if (mounted) {
      setState(() {
        _speechScore = score;
        _speechRecognized = recognizedText;
      });
    }
    await _recordPronunciation(
      _pronunciationResultForScore(score.score),
      score: score,
    );
  }

  LearningPronunciationResult _pronunciationResultForScore(int score) {
    if (score >= 90) return LearningPronunciationResult.clear;
    if (score >= 75) return LearningPronunciationResult.uncertain;
    return LearningPronunciationResult.needsPractice;
  }

  String _speechStatusLabel(String status) => switch (status) {
    'listening' => '正在听，请朗读目标词…',
    'notListening' || 'done' => '识别结束，正在整理结果…',
    _ => '正在准备语音识别…',
  };

  String _speechErrorLabel(String error) {
    final normalized = error.toLowerCase();
    if (normalized.contains('permission')) {
      return '麦克风权限未开启，请在 Windows 设置中允许译学使用麦克风。';
    }
    if (normalized.contains('network')) return '系统语音识别服务不可用，请检查网络或改用手动自评。';
    return '语音识别暂时不可用，请检查麦克风后重试；也可以使用手动自评。';
  }

  Future<void> _recordPronunciation(
    LearningPronunciationResult result, {
    PronunciationScoreResult? score,
  }) async {
    final entry = _pronunciationEntry;
    if (entry == null || _busy) return;
    _pronunciationTimer?.cancel();
    setState(() {
      _pronunciationRunning = false;
      _busy = true;
    });
    try {
      final item = _practiceItem;
      final practice = await _repository.recordPronunciationPractice(
        setId: _selectedCatalogId,
        itemId: item?.id ?? '$_selectedCatalogId::${entry.word}',
        word: entry.word,
        result: result,
        elapsedSeconds: _pronunciationElapsed.inSeconds,
        now: widget.clock(),
      );
      final next = await _repository.load();
      final recorder = widget.recordActivity;
      if (recorder != null) {
        try {
          await recorder(
            ActivityEventData(
              id: practice.id,
              kind: ActivityKind.speaking,
              title: entry.word,
              detail: '发音跟读 · ${result.label}',
              durationSeconds: practice.elapsedSeconds,
              itemCount: 1,
              occurredAt: practice.practicedAt,
              sourceId: 'learning-pronunciation',
            ),
          );
        } catch (_) {
          // Saving the local practice is the primary operation.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = next;
        _pronunciationElapsed = Duration.zero;
        _speechScore = score;
        _status = score == null
            ? '已记录「${entry.word}」：${result.label}'
            : '「${entry.word}」跟读 ${score.score} 分 · ${score.grade}，已记录：${result.label}';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '发音练习保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildPronunciationWorkspace(ColorScheme colors) {
    final entry = _pronunciationEntry;
    final practiceCount = entry == null
        ? 0
        : _state?.pronunciationPractices
                  .where(
                    (practice) =>
                        practice.setId == _selectedCatalogId &&
                        normalizeLearningWord(practice.word) ==
                            normalizeLearningWord(entry.word),
                  )
                  .length ??
              0;
    if (entry == null) {
      return _SectionCard(
        key: const ValueKey('learning-pronunciation-workspace'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPronunciationConfigReference(colors),
            const SizedBox(height: 15),
            const Text('当前范围还没有可练习的本地词条。请先在内容库添加合法词典条目。'),
          ],
        ),
      );
    }
    final elapsed = _pronunciationElapsed.inSeconds;
    final minutes = (elapsed ~/ 60).toString().padLeft(2, '0');
    final seconds = (elapsed % 60).toString().padLeft(2, '0');
    return _SectionCard(
      key: const ValueKey('learning-pronunciation-workspace'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '发音跟读',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '听标准读音 → 跟读 → 自评，练习记录保存在本地。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Text('$practiceCount 次', style: TextStyle(color: colors.primary)),
            ],
          ),
          const SizedBox(height: 22),
          _buildPronunciationConfigReference(colors),
          const SizedBox(height: 19),
          Container(
            key: const ValueKey('learning-pronunciation-word-stage'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 17),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: _buildPronunciationPracticeCard(entry, colors),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('learning-pronunciation-word'),
                onPressed: widget.onSpeak == null
                    ? null
                    : () => widget.onSpeak!(entry.word),
                icon: const Icon(Icons.volume_up_outlined),
                label: const Text('播放单词'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-pronunciation-example'),
                onPressed: widget.onSpeak == null || !entry.hasExample
                    ? null
                    : () => widget.onSpeak!(entry.example),
                icon: const Icon(Icons.record_voice_over_outlined),
                label: const Text('播放例句'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-pronunciation-timer'),
                onPressed: _busy ? null : _togglePronunciationTimer,
                icon: Icon(
                  _pronunciationRunning
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                ),
                label: Text(_pronunciationRunning ? '暂停跟读' : '开始跟读'),
              ),
              Text(
                '$minutes:$seconds',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (_speechStatus != null || _speechRecognized.isNotEmpty) ...[
            const SizedBox(height: 11),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .34),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Wrap(
                spacing: 11,
                runSpacing: 5,
                children: [
                  if (_speechStatus != null)
                    Text(
                      _speechStatus!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  if (_speechRecognized.isNotEmpty)
                    Text(
                      '本次识别：$_speechRecognized',
                      key: const ValueKey('learning-pronunciation-recognized'),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            '跟读后选择本次状态',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                key: const ValueKey('learning-pronunciation-retry'),
                onPressed: _busy
                    ? null
                    : () => _recordPronunciation(
                        LearningPronunciationResult.needsPractice,
                      ),
                child: const Text('需要再练'),
              ),
              OutlinedButton(
                key: const ValueKey('learning-pronunciation-uncertain'),
                onPressed: _busy
                    ? null
                    : () => _recordPronunciation(
                        LearningPronunciationResult.uncertain,
                      ),
                child: const Text('还不确定'),
              ),
              FilledButton(
                key: const ValueKey('learning-pronunciation-clear'),
                onPressed: _busy
                    ? null
                    : () => _recordPronunciation(
                        LearningPronunciationResult.clear,
                      ),
                child: const Text('读得清楚'),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Text(
            widget.speechRecognizer == null
                ? '预览版使用系统标准读音与本地自评。麦克风跟读将在系统语音识别可用时启用。'
                : '麦克风功能只保存本次评分结果；当前是词级文字匹配，不是音素、口音或语调评测。系统语音能力受 Windows 麦克风与隐私设置影响。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _buildPronunciationPracticeCard(
    DictionaryEntry entry,
    ColorScheme colors,
  ) {
    final score = _speechScore;
    final followButton = KeyedSubtree(
      key: const ValueKey('learning-pronunciation-follow'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primaryContainer,
              border: Border.all(
                color: colors.primary.withValues(alpha: .32),
                width: 7,
              ),
            ),
            child: IconButton(
              key: widget.speechRecognizer == null
                  ? null
                  : const ValueKey('learning-pronunciation-mic'),
              tooltip: '跟读并评分',
              onPressed: _busy ? null : _toggleSpeechRecognition,
              icon: Icon(
                _speechListening
                    ? Icons.stop_circle_outlined
                    : Icons.mic_none_rounded,
                size: 38,
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _speechListening ? '停止并评分' : '跟读',
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
    final scoreView = KeyedSubtree(
      key: score == null
          ? const ValueKey('learning-pronunciation-score-placeholder')
          : const ValueKey('learning-pronunciation-score'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '发音评分',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            score == null ? '— —' : '${score.score} 分',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            score?.grade ?? '评分引擎接口待接入',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
    final wordView = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '单词发音',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          entry.word,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.displaySmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          entry.ipa,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: colors.primary, fontFamily: 'serif'),
        ),
        const SizedBox(height: 7),
        Text('${entry.partOfSpeech} · ${entry.meanings.join('；')}'),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              wordView,
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [followButton, scoreView],
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(flex: 5, child: wordView),
            const SizedBox(width: 18),
            SizedBox(width: 112, child: followButton),
            const SizedBox(width: 18),
            Expanded(flex: 3, child: scoreView),
          ],
        );
      },
    );
  }

  Widget _buildPronunciationConfigReference(ColorScheme colors) {
    return Container(
      key: const ValueKey('learning-pronunciation-config'),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .28),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择发音类型',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 9),
          KeyedSubtree(
            key: const ValueKey('learning-pronunciation-accent-grid'),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 480;
                final width = compact
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 9) / 2;
                return Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    for (final accent in _PronunciationAccent.values)
                      SizedBox(
                        width: width,
                        child: _PronunciationAccentCard(
                          accent: accent,
                          selected: _pronunciationAccent == accent,
                          colors: colors,
                          onTap: () =>
                              setState(() => _pronunciationAccent = accent),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 13),
          Text(
            '搜索单词 / 输入内容',
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('learning-pronunciation-query'),
                  controller: _pronunciationQueryController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _lookupPronunciationWord(),
                  decoration: const InputDecoration(
                    hintText: '输入中文或英文',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              FilledButton.tonalIcon(
                key: const ValueKey('learning-pronunciation-lookup'),
                onPressed: _busy ? null : _lookupPronunciationWord,
                icon: const Icon(Icons.manage_search_outlined),
                label: const Text('搜索'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              maintainState: true,
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 5),
              title: const Text('学习范围与今日计划'),
              subtitle: Text(
                '${_pronunciationBand.label} · ${_pronunciationSource.label} · 每日 $_pronunciationTargetCount 个',
              ),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final band in _PronunciationBand.values)
                      ChoiceChip(
                        key: ValueKey(
                          'learning-pronunciation-band-${band.name}',
                        ),
                        label: Text(band.label),
                        selected: _pronunciationBand == band,
                        onSelected: (_) => setState(() {
                          _pronunciationBand = band;
                          _pronunciationSelectedWord = null;
                        }),
                      ),
                    for (final source in _PronunciationSource.values)
                      ChoiceChip(
                        key: ValueKey(
                          'learning-pronunciation-source-${source.name}',
                        ),
                        label: Text(source.label),
                        selected: _pronunciationSource == source,
                        onSelected: (_) =>
                            setState(() => _pronunciationSource = source),
                      ),
                    for (final count in [5, 10, 20])
                      ChoiceChip(
                        key: ValueKey('learning-pronunciation-count-$count'),
                        label: Text('$count 个'),
                        selected: _pronunciationTargetCount == count,
                        onSelected: (_) =>
                            setState(() => _pronunciationTargetCount = count),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Kept as a compatibility seam for any downstream feature branch that
  // still calls the earlier configuration surface.
  // ignore: unused_element
  Widget _buildPronunciationConfig(ColorScheme colors) {
    return Container(
      key: const ValueKey('learning-pronunciation-config'),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '练习配置',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final band in _PronunciationBand.values)
                ChoiceChip(
                  key: ValueKey('learning-pronunciation-band-${band.name}'),
                  label: Text(band.label),
                  selected: _pronunciationBand == band,
                  onSelected: (_) => setState(() {
                    _pronunciationBand = band;
                    _pronunciationSelectedWord = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final accent in _PronunciationAccent.values)
                ChoiceChip(
                  key: ValueKey('learning-pronunciation-accent-${accent.name}'),
                  label: Text(accent.label),
                  selected: _pronunciationAccent == accent,
                  onSelected: (_) =>
                      setState(() => _pronunciationAccent = accent),
                ),
              for (final source in _PronunciationSource.values)
                ChoiceChip(
                  key: ValueKey('learning-pronunciation-source-${source.name}'),
                  label: Text(source.label),
                  selected: _pronunciationSource == source,
                  onSelected: (_) =>
                      setState(() => _pronunciationSource = source),
                ),
              for (final count in [5, 10, 20])
                ChoiceChip(
                  key: ValueKey('learning-pronunciation-count-$count'),
                  label: Text('$count 个'),
                  selected: _pronunciationTargetCount == count,
                  onSelected: (_) =>
                      setState(() => _pronunciationTargetCount = count),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('learning-pronunciation-query'),
                  controller: _pronunciationQueryController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _lookupPronunciationWord(),
                  decoration: const InputDecoration(
                    labelText: '输入中文或英文查词',
                    hintText: '例如：consistency 或 一致性',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              FilledButton.tonalIcon(
                key: const ValueKey('learning-pronunciation-lookup'),
                onPressed: _busy ? null : _lookupPronunciationWord,
                icon: const Icon(Icons.manage_search_outlined),
                label: const Text('查找'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前偏好：${_pronunciationAccent.label} · ${_pronunciationSource.label} · 每日 $_pronunciationTargetCount 个。实际音频由系统/词典读音接口提供。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  DictionaryEntry? get _sentenceEntry {
    if (_sentenceRoundActive) {
      if (_sentenceIndex < 0 ||
          _sentenceIndex >= _sentenceRoundEntries.length) {
        return null;
      }
      return _sentenceRoundEntries[_sentenceIndex];
    }
    final entries = _sentenceEntries;
    if (entries.isEmpty) return null;
    if (_sentenceIndex < 0 || _sentenceIndex >= entries.length) return null;
    return entries[_sentenceIndex];
  }

  List<String> _sentenceAnswerTokens(DictionaryEntry entry) {
    final expected = _sentenceMode == SentencePracticeMode.chineseToEnglish
        ? entry.example
        : entry.exampleTranslation;
    if (_sentenceMode == SentencePracticeMode.chineseToEnglish) {
      return sentenceTokens(expected);
    }
    final tokens = RegExp(r'[\u4e00-\u9fff]|[A-Za-z0-9]+')
        .allMatches(expected)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    return tokens.isEmpty ? [expected] : tokens;
  }

  void _ensureSentenceCells(DictionaryEntry entry) {
    final seed = '${entry.word}|${_sentenceMode.name}|$_sentenceDifficulty';
    if (_sentenceCellSeed == seed && _sentenceCellControllers.isNotEmpty) {
      return;
    }
    for (final controller in _sentenceCellControllers) {
      controller.dispose();
    }
    _sentenceCellControllers
      ..clear()
      ..addAll([
        for (final _ in _sentenceAnswerTokens(entry)) TextEditingController(),
      ]);
    _sentenceCellSeed = seed;
  }

  String _sentenceCellAnswer() {
    final tokens = _sentenceCellControllers
        .map((controller) => controller.text.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    return tokens.join(
      _sentenceMode == SentencePracticeMode.chineseToEnglish ? ' ' : '',
    );
  }

  void _syncSentenceCellsToAnswer() {
    final value = _sentenceCellAnswer();
    _sentenceController
      ..text = value
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: value.length),
      );
    _invalidateSentenceReview();
  }

  void _invalidateSentenceReview() {
    if (_sentenceStatus == null &&
        !_sentenceStatusIsError &&
        _sentencePendingAnswer == null &&
        _sentencePendingExpected == null &&
        _lastSentenceAttempt == null) {
      return;
    }
    setState(() {
      _sentenceStatus = null;
      _sentenceStatusIsError = false;
      _sentencePendingAnswer = null;
      _sentencePendingExpected = null;
      _lastSentenceAttempt = null;
    });
  }

  Widget _buildSentenceAnswerField(String hint, {required String label}) =>
      TextField(
        key: const ValueKey('learning-sentence-answer'),
        controller: _sentenceController,
        minLines: 2,
        maxLines: 5,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: (_) => _invalidateSentenceReview(),
      );

  List<String> _sentenceMistakes(String answer, String expected) {
    final answerTokens = sentenceTokens(answer);
    final expectedTokens = sentenceTokens(expected);
    if (answerTokens.length != expectedTokens.length) {
      return ['句子长度或语序需要检查'];
    }
    final mistakes = <String>[];
    for (var index = 0; index < expectedTokens.length; index++) {
      if (normalizeSentenceAnswer(answerTokens[index]) !=
          normalizeSentenceAnswer(expectedTokens[index])) {
        mistakes.add('第 ${index + 1} 处：${expectedTokens[index]}');
      }
    }
    return mistakes;
  }

  void _submitSentence() {
    final entry = _sentenceEntry;
    if (entry == null || _busy) return;
    final answer = _sentenceController.text.trim().isNotEmpty
        ? _sentenceController.text.trim()
        : _sentenceCellAnswer().trim();
    if (answer.isEmpty) {
      setState(() => _sentenceStatus = '先写下你的译文，再查看参考答案。');
      return;
    }
    final expected = _sentenceMode == SentencePracticeMode.chineseToEnglish
        ? entry.example
        : entry.exampleTranslation;
    setState(() {
      _sentencePendingAnswer = answer;
      _sentencePendingExpected = expected;
      _sentenceStatus = '请对照参考答案，再按自己的理解记录掌握情况。';
      _lastSentenceAttempt = null;
    });
  }

  Future<void> _assessSentence({required bool mastered}) async {
    final entry = _sentenceEntry;
    final answer = _sentencePendingAnswer;
    final expected = _sentencePendingExpected;
    if (entry == null || answer == null || expected == null || _busy) return;
    final mistakes = mastered
        ? const <String>[]
        : _sentenceMistakes(answer, expected);
    setState(() => _busy = true);
    try {
      final attempt = await _repository.recordSentenceAttempt(
        // Sentence practice is independent from the selected vocabulary range.
        setId: learningDefaultSetId,
        word: entry.word,
        mode: _sentenceMode,
        sourceText: entry.example,
        translation: entry.exampleTranslation,
        answer: answer,
        expectedAnswer: expected,
        correct: mastered,
        mistakes: mistakes,
        elapsedSeconds: widget
            .clock()
            .difference(_sentenceQuestionStartedAt ?? widget.clock())
            .inSeconds
            .clamp(0, 86400)
            .toInt(),
        fromCustomPrompt: _sentenceRoundFromCustom,
        fromAiPrompt: _sentenceRoundFromAi,
        now: widget.clock(),
      );
      final current = _state;
      if (current == null) throw StateError('学习资料尚未完成加载');
      final next = current.withSentenceAttemptSaved(attempt);
      final recorder = widget.recordActivity;
      if (recorder != null) {
        try {
          await recorder(
            ActivityEventData(
              id: attempt.id,
              kind: ActivityKind.exercise,
              title: entry.word,
              detail: '句子练习 · ${mastered ? '掌握' : '需要复习'}',
              durationSeconds: attempt.elapsedSeconds,
              itemCount: 1,
              occurredAt: attempt.attemptedAt,
              sourceId: 'learning-sentence',
            ),
          );
        } catch (_) {
          // The learning record has already been saved locally.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = next;
        _lastSentenceAttempt = attempt;
        _sentencePendingAnswer = null;
        _sentencePendingExpected = null;
        _sentenceStatus = mastered ? '已按你的自评记录为掌握。' : '已按你的自评记录为需要复习。';
        _sentenceStatusIsError = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '句子练习保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _nextSentence() {
    if (!_sentenceRoundActive || _lastSentenceAttempt == null) return;
    if (_sentenceIndex + 1 >= _sentenceRoundEntries.length) {
      setState(() {
        _sentenceRoundActive = false;
        _sentenceRoundFinished = true;
        _sentenceStatus = null;
        _sentenceController.clear();
        for (final controller in _sentenceCellControllers) {
          controller.clear();
        }
        _sentenceCellSeed = '';
      });
      return;
    }
    setState(() {
      _sentenceIndex++;
      _sentenceQuestionStartedAt = widget.clock();
      _sentenceController.clear();
      for (final controller in _sentenceCellControllers) {
        controller.clear();
      }
      _sentenceCellSeed = '';
      _sentenceStatus = null;
      _sentenceStatusIsError = false;
      _sentencePendingAnswer = null;
      _sentencePendingExpected = null;
      _lastSentenceAttempt = null;
    });
  }

  void _resetSentenceAttempt() {
    _sentenceRoundFinished = false;
    _sentenceIndex = 0;
    _sentenceController.clear();
    for (final controller in _sentenceCellControllers) {
      controller.clear();
    }
    _sentenceCellSeed = '';
    _sentenceStatus = null;
    _sentenceStatusIsError = false;
    _sentencePendingAnswer = null;
    _sentencePendingExpected = null;
    _lastSentenceAttempt = null;
  }

  void _selectSentenceScenario(_SentenceScenario scenario) {
    if (_busy || _sentenceScenario == scenario) return;
    setState(() {
      _sentenceScenario = scenario;
      _resetSentenceAttempt();
    });
  }

  void _selectSentenceDifficulty(int difficulty) {
    if (_busy || _sentenceDifficulty == difficulty) return;
    setState(() {
      _sentenceDifficulty = difficulty;
      _resetSentenceAttempt();
    });
  }

  Widget _buildSentenceScenarioStrip(ColorScheme colors) {
    return KeyedSubtree(
      key: const ValueKey('learning-sentence-scenario-strip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择练习场景',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 82,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _SentenceScenario.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final scenario = _SentenceScenario.values[index];
                final selected = scenario == _sentenceScenario;
                return SizedBox(
                  width: 112,
                  child: Material(
                    color: selected
                        ? colors.primaryContainer.withValues(alpha: .68)
                        : colors.surfaceContainerHighest.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(13),
                    child: InkWell(
                      key: ValueKey(
                        'learning-sentence-scenario-${scenario.name}',
                      ),
                      onTap: _busy
                          ? null
                          : () => _selectSentenceScenario(scenario),
                      borderRadius: BorderRadius.circular(13),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: selected
                                ? colors.primary
                                : colors.outlineVariant,
                            width: selected ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              scenario.icon,
                              color: selected
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                              size: 22,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              scenario.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: selected
                                        ? colors.primary
                                        : colors.onSurface,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _sentenceScenario.hint,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSentenceDifficultyPicker(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '练习难度',
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 9,
          runSpacing: 8,
          children: [
            for (final difficulty in [1, 2])
              ChoiceChip(
                key: ValueKey('learning-sentence-difficulty-$difficulty'),
                label: Text(difficulty == 1 ? '基础 · 逐格练习' : '进阶 · 独立整句'),
                selected: _sentenceDifficulty == difficulty,
                onSelected: _busy
                    ? null
                    : (_) => _selectSentenceDifficulty(difficulty),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSentenceWorkspace(ColorScheme colors) => _sentenceRoundActive
      ? _buildSentenceRound(colors)
      : _buildSentenceHub(colors);

  String get _sentenceSettingsSummary {
    final settings = <String>[_sentenceMode.label];
    if (_sentenceLibrary != _SentenceLibrary.custom) {
      settings
        ..add(_sentenceScenario.label)
        ..add(_sentenceDifficulty == 1 ? '基础' : '进阶');
    }
    settings.add('$_sentenceRoundSize 句');
    return settings.join(' · ');
  }

  Widget _buildSentenceSettings(ColorScheme colors) {
    Widget settingGroup(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          child,
        ],
      ),
    );

    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('learning-sentence-settings'),
        initiallyExpanded: false,
        leading: Icon(Icons.tune_rounded, color: colors.primary),
        title: const Text('本轮设置'),
        subtitle: Text(
          _sentenceSettingsSummary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        children: [
          settingGroup(
            '翻译方向',
            Wrap(
              spacing: 9,
              runSpacing: 8,
              children: [
                for (final mode in SentencePracticeMode.values)
                  ChoiceChip(
                    key: ValueKey('learning-sentence-mode-${mode.name}'),
                    label: Text(mode.label),
                    selected: _sentenceMode == mode,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _sentenceMode = mode;
                            _sentenceStatus = null;
                            _sentenceStatusIsError = false;
                            _resetSentenceAttempt();
                          }),
                  ),
              ],
            ),
          ),
          if (_sentenceLibrary != _SentenceLibrary.custom) ...[
            settingGroup('练习场景', _buildSentenceScenarioStrip(colors)),
            settingGroup('难度', _buildSentenceDifficultyPicker(colors)),
          ],
          settingGroup(
            '本轮题量',
            Wrap(
              spacing: 9,
              runSpacing: 8,
              children: [
                for (final count in [1, 3, 5, 10])
                  ChoiceChip(
                    key: ValueKey('learning-sentence-round-count-$count'),
                    label: Text('$count 句'),
                    selected: _sentenceRoundSize == count,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _sentenceRoundSize = count;
                            _sentenceStatus = null;
                            _sentenceStatusIsError = false;
                            _sentenceRoundFinished = false;
                          }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSentenceHub(ColorScheme colors) {
    final available = _sentenceEntries;
    final sourceCounts = {
      for (final library in _SentenceLibrary.values)
        library: _sentenceCountForLibrary(library),
    };
    final attempts = (_state?.sentenceAttempts ?? const []).toList(
      growable: false,
    )..sort((left, right) => right.attemptedAt.compareTo(left.attemptedAt));
    final todayDate = widget.clock();
    final today = _sentenceCountForDay(todayDate);
    final yesterday = _sentenceCountForDay(
      DateTime(
        todayDate.year,
        todayDate.month,
        todayDate.day,
      ).subtract(const Duration(days: 1)),
    );
    final actualRoundSize = available.length < _sentenceRoundSize
        ? available.length
        : _sentenceRoundSize;
    return _SectionCard(
      key: const ValueKey('learning-sentence-hub'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note_rounded, color: colors.primary, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '句子练习',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '选句子、定方向和题量；每轮结束后保存作答与反馈。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                key: const ValueKey('learning-sentence-open-history'),
                onPressed: () => setState(() {
                  _sentenceShowHistory = !_sentenceShowHistory;
                  if (!_sentenceShowHistory) _sentenceHistoryVisibleCount = 5;
                }),
                icon: const Icon(Icons.history_rounded),
                label: Text(_sentenceShowHistory ? '收起记录' : '练习记录'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _SentenceProgressCard(
                key: const ValueKey('learning-sentence-today-progress'),
                label: '今日练习',
                detail: '今日完成 $today 句',
                icon: Icons.today_rounded,
                color: colors.primary,
              ),
              _SentenceProgressCard(
                key: const ValueKey('learning-sentence-yesterday-progress'),
                label: '昨日练习',
                detail: '昨日完成 $yesterday 句',
                icon: Icons.history_toggle_off_rounded,
                color: colors.secondary,
              ),
            ],
          ),
          const SizedBox(height: 19),
          Text(
            '练习题库',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 9,
            runSpacing: 8,
            children: [
              for (final library in _SentenceLibrary.values)
                ChoiceChip(
                  key: ValueKey('learning-sentence-source-${library.name}'),
                  label: Text(switch (library) {
                    _SentenceLibrary.builtIn =>
                      '本地词典例句（可练 ${sourceCounts[library]}）',
                    _SentenceLibrary.custom => '我的句子（${sourceCounts[library]}）',
                    _SentenceLibrary.ai => 'AI 句子（可练 ${sourceCounts[library]}）',
                  }),
                  selected: _sentenceLibrary == library,
                  onSelected: _busy
                      ? null
                      : (_) {
                          setState(() {
                            _sentenceLibrary = library;
                            _sentenceStatus = null;
                            _sentenceStatusIsError = false;
                            _sentenceRoundFinished = false;
                            _resetSentenceAttempt();
                          });
                        },
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildSentenceSettings(colors),
          const SizedBox(height: 5),
          if (_sentenceLibrary == _SentenceLibrary.custom) ...[
            const SizedBox(height: 12),
            _buildCustomSentenceLibrary(colors),
          ],
          if (_sentenceLibrary == _SentenceLibrary.ai) ...[
            const SizedBox(height: 12),
            _buildAiSentenceLibrary(colors),
          ],
          Text(
            available.isEmpty
                ? '当前题库没有可练习的句子。'
                : available.length < _sentenceRoundSize
                ? '当前可用 ${available.length} 句，本轮会固定为 $actualRoundSize 句，不会循环重复。'
                : '当前可用 ${available.length} 句，本轮将固定练习 $actualRoundSize 句。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 13),
          if (_sentenceRoundFinished)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _NoticeBar(
                key: const ValueKey('learning-sentence-round-complete'),
                text: '本轮已完成 · $_sentenceRoundTarget / $_sentenceRoundTarget 句',
                positive: true,
              ),
            ),
          if (_sentenceStatus != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _NoticeBar(
                text: _sentenceStatus!,
                positive: !_sentenceStatusIsError,
              ),
            ),
          if (_sentenceLibrary == _SentenceLibrary.ai &&
              _sentenceStatusIsError &&
              _sentenceModelSettingsRecommended &&
              widget.onOpenUnderstandingModelSettings != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('learning-sentence-open-model-settings'),
                onPressed: _busy
                    ? null
                    : widget.onOpenUnderstandingModelSettings,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('打开模型设置'),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_sentenceLibrary == _SentenceLibrary.ai) ...[
            FilledButton.tonalIcon(
              key: const ValueKey('learning-sentence-generate-ai'),
              onPressed: _busy ? null : _generateAiSentencePrompts,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(
                _busy ? '正在生成…' : '生成 AI 情景句子 · $_sentenceRoundSize 句',
              ),
            ),
            const SizedBox(height: 9),
          ],
          FilledButton.icon(
            key: const ValueKey('learning-sentence-start'),
            onPressed: _busy || available.isEmpty ? null : _startSentenceRound,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              available.isEmpty ? '暂无可练习句子' : '开始本轮 · $actualRoundSize 句',
            ),
          ),
          if (_sentenceShowHistory) ...[
            const SizedBox(height: 22),
            _buildSentenceAttemptHistory(colors, attempts),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomSentenceLibrary(ColorScheme colors) {
    final prompts =
        (_state?.customSentencePrompts ?? const <LearningSentencePromptData>[])
            .where(
              (prompt) =>
                  prompt.origin == LearningSentencePromptOrigin.userCreated,
            )
            .toList(growable: false);
    return Container(
      key: const ValueKey('learning-sentence-custom-library'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '添加我的句子',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            '填入一组中英文句子后即可加入练习；内容只保存在本机。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('learning-sentence-custom-title'),
            controller: _customSentenceTitleController,
            decoration: const InputDecoration(
              labelText: '标题或场景',
              hintText: '例如：会议开场',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('learning-sentence-custom-chinese'),
            controller: _customSentenceChineseController,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '中文句子', isDense: true),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('learning-sentence-custom-english'),
            controller: _customSentenceEnglishController,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '英文句子', isDense: true),
          ),
          const SizedBox(height: 9),
          FilledButton.tonalIcon(
            key: const ValueKey('learning-sentence-save-custom'),
            onPressed: _busy ? null : _saveCustomSentencePrompt,
            icon: const Icon(Icons.add_rounded),
            label: const Text('保存到我的句子'),
          ),
          if (prompts.isNotEmpty) ...[
            const Divider(height: 23),
            Text(
              '我的句子 · ${prompts.length}',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 5),
            for (final prompt in prompts)
              ListTile(
                key: ValueKey('learning-sentence-custom-${prompt.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(prompt.title),
                subtitle: Text('${prompt.chineseText}\n${prompt.englishText}'),
                isThreeLine: true,
                trailing: IconButton(
                  key: ValueKey('learning-sentence-delete-${prompt.id}'),
                  tooltip: '删除句子',
                  onPressed: _busy
                      ? null
                      : () => _deleteCustomSentencePrompt(prompt.id),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildAiSentenceLibrary(ColorScheme colors) {
    final prompts =
        (_state?.customSentencePrompts ?? const <LearningSentencePromptData>[])
            .where(
              (prompt) =>
                  prompt.origin == LearningSentencePromptOrigin.aiGenerated &&
                  prompt.scenario == _sentenceScenario.label &&
                  prompt.difficulty == _sentenceDifficulty,
            )
            .toList(growable: false);
    return Container(
      key: const ValueKey('learning-sentence-ai-library'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: colors.primary, size: 20),
              const SizedBox(width: 7),
              Text(
                'AI 情景句子',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                '理解与总结',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: colors.primary),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '仅在点击后发送场景、难度和题量给已分配的“理解与总结”模型。若使用远程模型，这些信息会发送给相应服务方；本地模型请求只发往本机。生成题会收进本地 AI 句子本并可直接练习，练习记录也保存在本机。',
            key: const ValueKey('learning-sentence-ai-privacy-notice'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.35),
          ),
          if (prompts.isNotEmpty) ...[
            const Divider(height: 22),
            Text(
              '当前场景与难度 · ${prompts.length} 句',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            for (final prompt in prompts)
              ListTile(
                key: ValueKey('learning-sentence-ai-${prompt.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.auto_awesome_rounded,
                  color: colors.primary,
                ),
                title: Text('AI 生成 · ${prompt.title}'),
                subtitle: Text('${prompt.chineseText}\n${prompt.englishText}'),
                isThreeLine: true,
                trailing: IconButton(
                  key: ValueKey('learning-sentence-delete-${prompt.id}'),
                  tooltip: '删除句子',
                  onPressed: _busy
                      ? null
                      : () => _deleteCustomSentencePrompt(prompt.id),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              '这个场景和难度还没有生成题目。选择场景、难度和题量后，点击下方按钮开始。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSentenceAttemptHistory(
    ColorScheme colors,
    List<LearningSentenceAttemptData> attempts,
  ) {
    final recent = attempts
        .take(_sentenceHistoryVisibleCount)
        .toList(growable: false);
    final remaining = attempts.length - recent.length;
    return Column(
      key: const ValueKey('learning-sentence-history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history_rounded, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              '练习记录',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            Text('${attempts.length} 条'),
          ],
        ),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Text(
            '还没有练习记录。完成一题并提交反馈后，会显示在这里。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          )
        else ...[
          for (final attempt in recent)
            Card(
              key: ValueKey('learning-sentence-attempt-${attempt.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      children: [
                        Text(
                          attempt.word,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(attempt.mode.label),
                        Text(
                          attempt.fromAiPrompt
                              ? 'AI 生成'
                              : attempt.fromCustomPrompt
                              ? '我的句子'
                              : '本地词典例句',
                        ),
                        Text(attempt.correct ? '掌握' : '待复习'),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text('原句：${attempt.sourceText}'),
                    Text('译文：${attempt.translation}'),
                    Text('你的答案：${attempt.answer}'),
                    Text(
                      '记录时间：${_formatLearningTimestamp(attempt.attemptedAt)}',
                    ),
                  ],
                ),
              ),
            ),
          if (remaining > 0)
            Align(
              alignment: Alignment.center,
              child: TextButton.icon(
                key: const ValueKey('learning-sentence-history-expand'),
                onPressed: () => setState(() {
                  _sentenceHistoryVisibleCount += 20;
                }),
                icon: const Icon(Icons.expand_more_rounded),
                label: Text('显示更多 · 剩余 $remaining 条'),
              ),
            ),
        ],
      ],
    );
  }

  String _formatLearningTimestamp(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    String two(int item) => item.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  Widget _buildSentenceRound(ColorScheme colors) {
    final entry = _sentenceEntry;
    if (entry == null) {
      return _buildSentenceHub(colors);
    }
    _ensureSentenceCells(entry);
    final prompt = _sentenceMode == SentencePracticeMode.chineseToEnglish
        ? entry.exampleTranslation
        : entry.example;
    final answerHint = _sentenceDifficulty == 2
        ? (_sentenceMode == SentencePracticeMode.chineseToEnglish
              ? '不看逐词提示，独立写出完整英文句子。'
              : '不看逐词提示，独立写出完整中文译文。')
        : _sentenceMode == SentencePracticeMode.chineseToEnglish
        ? '输入英文句子；不提供词块提示，完成后再对照标准答案。'
        : '输入中文译文，先保证意思完整，再调整表达。';
    return _SectionCard(
      key: const ValueKey('learning-sentence-workspace'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_note_rounded, color: colors.primary, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '句子练习',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '把词语放回语境，练习真正写出一句话。',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Text('第 ${_sentenceIndex + 1} / $_sentenceRoundTarget 句'),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: const Icon(Icons.library_books_outlined, size: 17),
                label: Text(
                  _sentenceRoundFromAi
                      ? 'AI 生成'
                      : _sentenceRoundFromCustom
                      ? '我的句子'
                      : '本地词典例句',
                ),
              ),
              Chip(label: Text(_sentenceMode.label)),
              OutlinedButton.icon(
                key: const ValueKey('learning-sentence-return-hub'),
                onPressed: _busy ? null : _returnToSentenceHub,
                icon: const Icon(Icons.list_alt_rounded),
                label: const Text('回到练习设置'),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            _sentenceMode == SentencePracticeMode.chineseToEnglish
                ? '中文提示 · 请独立写出英文句子'
                : '英文原句 · 请独立写出中文意思',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          KeyedSubtree(
            key: const ValueKey('learning-sentence-practice-card'),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Text(
                prompt,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(height: 1.45, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 15),
          if (_sentenceDifficulty == 1) ...[
            Text(
              '逐格输入句子',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _sentenceMode == SentencePracticeMode.chineseToEnglish
                  ? '每个方格填一个英文单词；不显示词块提示，完成后再对照标准答案。'
                  : '每个方格填一个中文词语或短语；先表达完整意思，再检查答案。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (
                  var index = 0;
                  index < _sentenceCellControllers.length;
                  index++
                )
                  SizedBox(
                    width:
                        _sentenceMode == SentencePracticeMode.chineseToEnglish
                        ? 86
                        : 62,
                    child: TextField(
                      key: ValueKey('learning-sentence-cell-$index'),
                      controller: _sentenceCellControllers[index],
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      onChanged: (_) => _syncSentenceCellsToAnswer(),
                      decoration: InputDecoration(
                        hintText: '',
                        isDense: true,
                        filled: true,
                        fillColor: colors.surface,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 13,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 1.6,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 13),
            Material(
              color: Colors.transparent,
              child: ExpansionTile(
                maintainState: true,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 5),
                title: const Text('需要时展开整句输入（可选）'),
                subtitle: const Text('默认使用上方方框逐词输入，不提供单词提示'),
                children: [
                  _buildSentenceAnswerField(answerHint, label: '整句输入（可选）'),
                ],
              ),
            ),
          ] else ...[
            Text(
              '独立挑战：不显示逐词方格，直接完成整句。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 9),
            _buildSentenceAnswerField(answerHint, label: '完整句子'),
          ],
          const SizedBox(height: 13),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                key: const ValueKey('learning-sentence-submit'),
                onPressed: _busy ? null : _submitSentence,
                icon: const Icon(Icons.check_rounded),
                label: const Text('查看参考答案'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-sentence-next'),
                onPressed: _busy || _lastSentenceAttempt == null
                    ? null
                    : _nextSentence,
                icon: const Icon(Icons.skip_next_rounded),
                label: Text(
                  _sentenceIndex + 1 >= _sentenceRoundEntries.length
                      ? '完成本轮'
                      : '下一句',
                ),
              ),
              if (widget.onSpeak != null)
                IconButton(
                  key: const ValueKey('learning-sentence-speak'),
                  tooltip: '播放标准读音',
                  onPressed: () => widget.onSpeak!(entry.example),
                  icon: const Icon(Icons.volume_up_outlined),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '参考答案用于对照；掌握情况由你自评记录。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (_sentenceStatus != null) ...[
            const SizedBox(height: 14),
            _NoticeBar(
              text: _sentenceStatus!,
              positive:
                  _sentencePendingAnswer != null ||
                  (_lastSentenceAttempt?.correct ?? false),
            ),
          ],
          if (_sentencePendingAnswer != null &&
              _sentencePendingExpected != null) ...[
            const SizedBox(height: 13),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: .28),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '参考答案：$_sentencePendingExpected',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey(
                          'learning-sentence-assessment-mastered',
                        ),
                        onPressed: _busy
                            ? null
                            : () => _assessSentence(mastered: true),
                        icon: const Icon(Icons.check_circle_outline_rounded),
                        label: const Text('我已掌握'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey(
                          'learning-sentence-assessment-review',
                        ),
                        onPressed: _busy
                            ? null
                            : () => _assessSentence(mastered: false),
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('需要复习'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (_lastSentenceAttempt != null) ...[
            const SizedBox(height: 13),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: .28),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '参考答案：${_lastSentenceAttempt!.expectedAnswer}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (_lastSentenceAttempt!.mistakes.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '可对照的词语差异：${_lastSentenceAttempt!.mistakes.join('；')}',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _selectArticle(LearningArticle article) {
    final progress = _articleProgress(article.id);
    setState(() {
      _selectedArticleId = article.id;
      _articleImmersiveReader = false;
      _articleParagraphIndex = (progress?.currentParagraph ?? 0).clamp(
        0,
        article.paragraphCount - 1,
      );
      _articleTranslationVisible = false;
      _articleSummary = null;
      _articleSelectedWord = null;
      _articleWordNote = '';
    });
  }

  void _openImmersiveArticleReader() {
    setState(() {
      _articleImmersiveReader = true;
      _status = null;
      _error = null;
    });
  }

  void _closeImmersiveArticleReader() {
    setState(() => _articleImmersiveReader = false);
  }

  void _openArticleWorkbench() {
    final article =
        _mostRecentlyReadArticle ??
        _selectedArticle ??
        builtInLearningArticles.first;
    _resumeArticle(article);
  }

  void _resumeArticle(LearningArticle article, {String? word}) {
    final progress = _articleProgress(article.id);
    setState(() {
      _articleHubEntered = true;
      _articleHubView = _ArticleHubView.home;
      _articleImmersiveReader = false;
      _articleSource = _ArticleSource.builtIn;
      _selectedArticleId = article.id;
      _articleParagraphIndex = (progress?.currentParagraph ?? 0).clamp(
        0,
        article.paragraphCount - 1,
      );
      _articleTranslationVisible = false;
      _articleSelectedWord = null;
      _articleWordNote = '';
      _articleSummary = null;
      _status = null;
      _error = null;
    });
    if (word != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_selectArticleWord(word));
      });
    }
  }

  LearningArticle? get _mostRecentlyReadArticle {
    final progress = _state?.articleProgress ?? const [];
    final candidates = <({LearningArticle article, String lastReadAt})>[];
    for (final article in builtInLearningArticles) {
      final saved = progress
          .where((item) => item.articleId == article.id)
          .firstOrNull;
      if (saved != null) {
        candidates.add((article: article, lastReadAt: saved.lastReadAt));
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final leftDate = DateTime.tryParse(left.lastReadAt);
      final rightDate = DateTime.tryParse(right.lastReadAt);
      if (leftDate == null) return rightDate == null ? 0 : 1;
      if (rightDate == null) return -1;
      return rightDate.compareTo(leftDate);
    });
    return candidates.first.article;
  }

  int _articleCompletedCount(
    LearningArticle article,
    LearningArticleProgressData? progress,
  ) =>
      progress?.completedParagraphs
          .where((index) => index >= 0 && index < article.paragraphCount)
          .toSet()
          .length ??
      0;

  List<_ArticleHubVocabularyItem> _articleHubVocabulary() {
    final items = <String, _ArticleHubVocabularyItem>{};
    for (final article in builtInLearningArticles) {
      final progress = _articleProgress(article.id);
      final savedWords = (progress?.lookedUpWords ?? const <String>[])
          .map(normalizeLearningWord)
          .where((word) => word.isNotEmpty)
          .toSet();
      final articleFavorites = article.vocabulary
          .map(normalizeLearningWord)
          .where((word) => _favoriteWords.contains(word))
          .toSet();
      for (final word in {...savedWords, ...articleFavorites}) {
        final key = '${article.id}:$word';
        items[key] = _ArticleHubVocabularyItem(
          article: article,
          word: word,
          savedToVocabulary: savedWords.contains(word),
          favorite: articleFavorites.contains(word),
        );
      }
    }
    return items.values.toList()..sort((left, right) {
      final byTitle = left.article.title.compareTo(right.article.title);
      return byTitle == 0 ? left.word.compareTo(right.word) : byTitle;
    });
  }

  void _showArticleHubView(_ArticleHubView view) {
    setState(() {
      _articleHubView = view;
      _status = null;
      _error = null;
    });
  }

  void _returnToArticleHub() {
    setState(() {
      _articleHubView = _ArticleHubView.home;
      _status = null;
      _error = null;
    });
  }

  void _showArticleHubStatus(String message) {
    setState(() {
      _status = message;
      _error = null;
    });
  }

  void _openArticleHubSummary() {
    final article = _selectedArticle;
    if (article == null || widget.onSummarize == null) {
      _showArticleHubStatus('文章总结目前暂未开放；阅读器完成验收后再评估接入。');
      return;
    }
    unawaited(_summarizeSelectedArticle());
  }

  void _selectArticleParagraph(int index) {
    final article = _selectedArticle;
    if (article == null || article.paragraphCount == 0) return;
    setState(() {
      _articleParagraphIndex = index.clamp(0, article.paragraphCount - 1);
      _articleTranslationVisible = false;
    });
  }

  Future<void> _selectArticleWord(String word) async {
    final normalized = normalizeLearningWord(word);
    final version = ++_articleWordSelectionVersion;
    setState(() {
      _articleSelectedWord = normalized;
      _articleWordNote = _localNotes[normalized] ?? '';
    });
    final dictionaryLookup = widget.lookupDictionary;
    if (dictionaryLookup != null) {
      try {
        final entry = await dictionaryLookup(normalized);
        if (!mounted || version != _articleWordSelectionVersion) return;
        if (entry != null) {
          setState(() {
            final canonicalWord = normalizeLearningWord(entry.word);
            final resolved = _preserveLearningEditorialMetadata(
              entry,
              _entriesByWord[normalized] ?? _entriesByWord[canonicalWord],
            );
            _entriesByWord[canonicalWord] = resolved;
            _entriesByWord[normalized] = resolved;
          });
        }
      } catch (_) {
        // Keep the article readable when a configured dictionary is offline.
      }
    }
    final loader = widget.loadWordAnnotation;
    if (loader == null) return;
    try {
      final annotation = await loader(normalized);
      if (!mounted || version != _articleWordSelectionVersion) return;
      setState(() {
        _articleWordNote = annotation?.note ?? _articleWordNote;
      });
    } catch (_) {
      // A missing annotation must not block article lookup or reading.
    }
  }

  Future<void> _saveArticleWordNote(String word, String note) async {
    final normalized = normalizeLearningWord(word);
    final value = note.trim();
    _localNotes[normalized] = value;
    final saver = widget.saveWordAnnotation;
    if (saver != null) {
      await saver(
        WordAnnotationData(
          word: normalized,
          note: value,
          addedToLearning: true,
          updatedAt: widget.clock().toIso8601String(),
        ),
      );
    }
    if (mounted) setState(() => _status = '「$normalized」的文章学习笔记已保存');
  }

  LearningArticleProgressData _defaultArticleProgress(
    LearningArticle article,
  ) => LearningArticleProgressData(
    articleId: article.id,
    title: article.title,
    currentParagraph: 0,
    completedParagraphs: const [],
    favoriteParagraphs: const [],
    lookedUpWords: const [],
    lastReadAt: widget.clock().toIso8601String(),
  );

  Future<void> _saveArticleComprehensionAnswer(
    String questionId,
    int answerIndex,
  ) async {
    final article = _selectedArticle;
    if (article == null || _busy) return;
    final question = article.questions
        .where((item) => item.id == questionId)
        .firstOrNull;
    if (question == null ||
        answerIndex < 0 ||
        answerIndex >= question.choices.length) {
      return;
    }
    final existing =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final answers = <String, int>{
      ...existing.questionAnswers,
      questionId: answerIndex,
    };
    final progress = existing.copyWith(
      questionAnswers: answers,
      lastReadAt: widget.clock().toIso8601String(),
    );
    setState(() => _busy = true);
    try {
      await _repository.saveArticleProgress(progress);
      final next = await _repository.load();
      if (!mounted) return;
      setState(() {
        _state = next;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '理解练习进度保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveArticleParagraph() async {
    final article = _selectedArticle;
    if (article == null || _busy) return;
    final index = _articleParagraphIndex.clamp(0, article.paragraphCount - 1);
    final existing =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final completed = {...existing.completedParagraphs, index}.toList()..sort();
    final nextIndex = index + 1 >= article.paragraphCount ? index : index + 1;
    final progress = existing.copyWith(
      currentParagraph: nextIndex,
      completedParagraphs: completed,
      lastReadAt: widget.clock().toIso8601String(),
    );
    setState(() => _busy = true);
    try {
      await _repository.saveArticleProgress(progress);
      final next = await _repository.load();
      final isNew = !existing.completedParagraphs.contains(index);
      if (isNew && widget.recordActivity != null) {
        try {
          await widget.recordActivity!(
            ActivityEventData(
              id: 'article-progress-${article.id}-$index-${widget.clock().microsecondsSinceEpoch}',
              kind: ActivityKind.reading,
              title: article.title,
              detail: '文章学习 · 第 ${index + 1} 段',
              durationSeconds: 0,
              itemCount: 1,
              occurredAt: progress.lastReadAt,
              sourceId: 'learning-article',
            ),
          );
        } catch (_) {
          // Progress is already durable in the learning store.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = next;
        _articleParagraphIndex = nextIndex;
        _status = '已保存「${article.title}」第 ${index + 1} 段进度';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '文章进度保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleArticleFavorite() async {
    final article = _selectedArticle;
    if (article == null || _busy) return;
    final index = _articleParagraphIndex.clamp(0, article.paragraphCount - 1);
    final existing =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final favorites = {...existing.favoriteParagraphs};
    final wasFavorite = favorites.remove(index);
    if (!wasFavorite) favorites.add(index);
    final progress = existing.copyWith(
      favoriteParagraphs: favorites.toList()..sort(),
      lastReadAt: widget.clock().toIso8601String(),
    );
    setState(() => _busy = true);
    try {
      await _repository.saveArticleProgress(progress);
      final next = await _repository.load();
      if (!mounted) return;
      setState(() {
        _state = next;
        _status = wasFavorite ? '已取消收藏这一段' : '已收藏这一段，后续可在学习记录中复习';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '文章收藏保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addArticleVocabulary() async {
    final article = _selectedArticle;
    final target = _selectedCatalogId == 'favorites'
        ? _catalog.byId(learningDefaultSetId)
        : _selectedCatalog;
    if (article == null || target == null || _busy) return;
    final words = article.vocabulary
        .map(normalizeLearningWord)
        .where(_entriesByWord.containsKey)
        .toSet()
        .toList();
    if (words.isEmpty) {
      setState(() => _status = '这篇文章暂时没有匹配到本地词典词条');
      return;
    }
    final existing =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final lookedUp = {...existing.lookedUpWords, ...words}.toList()..sort();
    setState(() => _busy = true);
    try {
      final moment = widget.clock();
      await _repository.ensureSet(
        target.definition(moment),
        words,
        now: moment,
      );
      await _repository.saveArticleProgress(
        existing.copyWith(
          lookedUpWords: lookedUp,
          lastReadAt: moment.toIso8601String(),
        ),
      );
      final persisted = await _repository.load();
      if (!mounted) return;
      setState(() {
        _state = persisted;
        _status = '已将 ${words.length} 个文章词条加入「${target.title}」';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '文章词条保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _summarizeSelectedArticle() async {
    final article = _selectedArticle;
    if (article == null || _busy) return;
    final generator = widget.onSummarize;
    if (generator == null) {
      setState(() => _status = 'AI 总结接口已预留，请先在模型与服务中选择总结模型。文章学习不受影响。');
      return;
    }
    setState(() => _busy = true);
    try {
      final summary = await generator(
        article.paragraphs.map((paragraph) => paragraph.text).join('\n'),
      );
      if (!mounted) return;
      setState(() {
        _articleSummary = summary.trim().isEmpty
            ? '模型没有返回总结内容。'
            : summary.trim();
        _status = '文章总结已生成';
      });
    } catch (error) {
      if (mounted) {
        final detail = error is LearningSummaryException
            ? error.message
            : '$error';
        setState(() => _error = '文章总结失败：$detail');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showTextbookFormat() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('教材导入说明'),
        content: const SingleChildScrollView(
          child: SelectableText(LearningTextbookPackageService.importGuidance),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _importTextbook() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '请选择教材文件…';
      _error = null;
    });
    try {
      final picker = widget.textbookPicker ?? _pickTextbookFile;
      final file = await picker();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final fileName = file.name.trim().isEmpty
          ? 'imported-textbook'
          : file.name;
      final extension = fileName.contains('.')
          ? fileName.substring(fileName.lastIndexOf('.') + 1).toLowerCase()
          : '';
      final service = const LearningTextbookPackageService();
      final package = switch (extension) {
        'json' ||
        'zip' ||
        'yxtbook' => service.parse(bytes, fileName: fileName),
        _ => await _parseDocumentTextbook(service, bytes, fileName),
      };
      final next = [..._textbookPackages];
      final existingIndex = next.indexWhere((item) => item.id == package.id);
      if (existingIndex < 0) {
        next.add(package);
      } else {
        next[existingIndex] = package;
      }
      await _textbookStore.write(next);
      if (!mounted) return;
      setState(() {
        _textbookPackages
          ..clear()
          ..addAll(next);
        _selectedTextbookPackageId = package.id;
        _selectedTextbookLessonId = package.lessons.first.id;
        _status =
            '已导入「${package.title}」· ${package.lessons.length} 个课次，资料保存在本地';
        _error = null;
      });
    } on LearningTextbookPackageException catch (error) {
      if (mounted) setState(() => _error = '教材导入失败：${error.message}');
    } catch (error) {
      if (mounted) setState(() => _error = '教材导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<XFile?> _pickTextbookFile() => openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: '教材与课程资料',
        extensions: const ['json', 'yxtbook', 'zip', 'txt', 'md', 'markdown'],
      ),
    ],
  );

  Future<LearningTextbookPackageData> _parseDocumentTextbook(
    LearningTextbookPackageService service,
    Uint8List bytes,
    String fileName,
  ) async {
    final details = await _showTextbookImportDetails(fileName);
    if (details == null) {
      throw const LearningTextbookPackageException('已取消教材导入');
    }
    return service.parseDocument(
      bytes: bytes,
      fileName: fileName,
      title: details.title,
      ageBand: details.ageBand,
      level: details.level,
      version: details.version,
      licenseName: details.licenseName,
      rightsHolder: details.rightsHolder,
      licenseUrl: details.licenseUrl,
      sourceUrl: details.sourceUrl,
    );
  }

  Future<_TextbookImportDetails?> _showTextbookImportDetails(
    String fileName,
  ) async {
    final titleController = TextEditingController(
      text: fileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
    );
    final ageBandController = TextEditingController(text: '通用 / 自学');
    final levelController = TextEditingController(text: 'custom');
    final versionController = TextEditingController(text: '用户导入版本');
    final licenseController = TextEditingController();
    final rightsHolderController = TextEditingController();
    final licenseUrlController = TextEditingController();
    final sourceUrlController = TextEditingController();
    try {
      return await showDialog<_TextbookImportDetails>(
        context: context,
        builder: (dialogContext) {
          final formKey = GlobalKey<FormState>();
          String? requiredValue(String? value) =>
              value == null || value.trim().isEmpty ? '请填写此项' : null;
          return AlertDialog(
            title: const Text('补充教材资料'),
            content: SizedBox(
              width: 560,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('网上能看到不等于可以复制。请只导入你自写、开放许可或已取得合法使用权的资料。'),
                      ),
                      const SizedBox(height: 14),
                      _dialogTextField(
                        controller: titleController,
                        label: '教材名称',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: ageBandController,
                        label: '年龄段 / 学段',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: levelController,
                        label: '学习目标标识（如 primary、cet6、考研）',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: versionController,
                        label: '教材版本 / 册次',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: licenseController,
                        label: '许可证或授权说明（必填）',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: rightsHolderController,
                        label: '权利人或来源（必填）',
                        validator: requiredValue,
                      ),
                      _dialogTextField(
                        controller: licenseUrlController,
                        label: '许可证链接（可选，HTTP/HTTPS）',
                      ),
                      _dialogTextField(
                        controller: sourceUrlController,
                        label: '来源链接（可选，HTTP/HTTPS）',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;
                  Navigator.of(dialogContext).pop(
                    _TextbookImportDetails(
                      title: titleController.text,
                      ageBand: ageBandController.text,
                      level: levelController.text,
                      version: versionController.text,
                      licenseName: licenseController.text,
                      rightsHolder: rightsHolderController.text,
                      licenseUrl: licenseUrlController.text,
                      sourceUrl: sourceUrlController.text,
                    ),
                  );
                },
                child: const Text('确认导入'),
              ),
            ],
          );
        },
      );
    } finally {
      titleController.dispose();
      ageBandController.dispose();
      levelController.dispose();
      versionController.dispose();
      licenseController.dispose();
      rightsHolderController.dispose();
      licenseUrlController.dispose();
      sourceUrlController.dispose();
    }
  }

  void _selectTextbookLesson(
    LearningTextbookPackageData package,
    LearningTextbookLessonData lesson,
  ) {
    setState(() {
      _selectedTextbookPackageId = package.id;
      _selectedTextbookLessonId = lesson.id;
      _textbookTranslationStatus = null;
      _textbookTranslationError = null;
      _status = null;
      _error = null;
    });
  }

  String _textbookSetId(LearningTextbookPackageData package) {
    final id = package.id.length > 150
        ? package.id.substring(0, 150)
        : package.id;
    return 'textbook-$id';
  }

  Future<void> _addTextbookVocabulary() async {
    final package = _selectedTextbookPackage;
    final lesson = _selectedTextbookLesson;
    if (package == null || lesson == null || _busy) return;
    final words =
        lesson.vocabulary
            .map(normalizeLearningWord)
            .where(_entriesByWord.containsKey)
            .toSet()
            .toList()
          ..sort();
    if (words.isEmpty) {
      setState(() => _status = '本课词汇暂时没有匹配到本地词典，词典扩建后即可加入学习。');
      return;
    }
    setState(() => _busy = true);
    try {
      final now = widget.clock();
      final setId = _textbookSetId(package);
      final definition = LearningSetData(
        id: setId,
        title: '${package.title} · 词汇',
        description: '来自「${package.title}」的本地教材词汇。',
        sourceId: 'textbook:${package.id}',
        dailyNewLimit: 10,
        dailyReviewLimit: 30,
        createdAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
        level: package.level,
        language: package.language.split('-').first,
        unit: lesson.title,
        tags: [package.level, package.ageBand],
        isSystem: false,
      );
      final next = await _repository.ensureSet(definition, words, now: now);
      if (!mounted) return;
      setState(() {
        _state = next;
        _status = '已将 ${words.length} 个词条加入「${package.title} · 词汇」';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '教材词汇保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addTextbookDictionaryWord(DictionaryEntry entry) async {
    final package = _selectedTextbookPackage;
    if (package == null) throw StateError('请先选择一门教材。');
    if (_busy) throw StateError('当前有操作正在进行，请稍后再试。');
    final normalized = normalizeLearningWord(entry.word);
    if (normalized.isEmpty) throw StateError('词条内容无效。');

    setState(() => _busy = true);
    try {
      _entriesByWord[normalized] = entry;
      final now = widget.clock();
      final definition = LearningSetData(
        id: _textbookSetId(package),
        title: '${package.title} · 词汇',
        description: '从“${package.title}”阅读过程中查词保存的本地词汇。',
        sourceId: 'textbook:${package.id}',
        dailyNewLimit: 10,
        dailyReviewLimit: 30,
        createdAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
        level: package.level,
        language: package.language.split('-').first,
        unit: _selectedTextbookLesson?.title ?? '阅读查词',
        tags: [package.level, package.ageBand],
        isSystem: false,
      );
      final next = await _repository.ensureSet(definition, [
        entry.word,
      ], now: now);
      if (!mounted) return;
      setState(() {
        _state = next;
        _status = '已将“${entry.word}”加入${package.title}词汇';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '加入学习词书失败：$error');
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _translateTextbookLesson(
    LearningTextbookPackageData package,
    LearningTextbookLessonData lesson,
  ) async {
    final translate = widget.onTranslateTextbook;
    if (translate == null || _busy) return;
    final source = lesson.sourceText.trim();
    if (source.isEmpty) {
      setState(() => _textbookTranslationError = '本课没有可翻译的原文。');
      return;
    }

    final segments =
        LearningTextbookPackageService.splitTextPreservingBoundaries(
          source,
          maxCharacters:
              LearningTextbookPackageService.maxDocumentLessonCharacters,
        );
    setState(() {
      _busy = true;
      _textbookTranslationBusy = true;
      _textbookTranslationStatus = '准备翻译 ${segments.length} 段';
      _textbookTranslationError = null;
    });
    try {
      final translatedSegments = <String>[];
      for (var index = 0; index < segments.length; index++) {
        if (mounted) {
          setState(
            () => _textbookTranslationStatus =
                '正在翻译第 ${index + 1}/${segments.length} 段',
          );
        }
        final translated = (await translate(segments[index])).trim();
        if (translated.isEmpty) {
          throw StateError('第 ${index + 1} 段没有收到译文');
        }
        translatedSegments.add(translated);
      }
      final translation = translatedSegments.join('\n\n');
      if (translation.length > 100000) {
        throw StateError('译文超过本地教材的保存上限，请把课次再拆短一些。');
      }

      final updatedLessons = [
        for (final item in package.lessons)
          if (item.id == lesson.id)
            item.copyWith(translation: translation)
          else
            item,
      ];
      final updatedPackage = package.copyWith(lessons: updatedLessons);
      final nextPackages = [..._textbookPackages];
      final packageIndex = nextPackages.indexWhere(
        (item) => item.id == package.id,
      );
      if (packageIndex < 0) {
        throw StateError('教材已从本地目录移除，请重新选择后再翻译。');
      }
      nextPackages[packageIndex] = updatedPackage;
      await _textbookStore.write(nextPackages);
      if (!mounted) return;
      setState(() {
        _textbookPackages
          ..clear()
          ..addAll(nextPackages);
        _textbookTranslationStatus = '译文已保存在本地教材中';
        _textbookTranslationError = null;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _textbookTranslationStatus = null;
          _textbookTranslationError = '本课翻译失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _textbookTranslationBusy = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _saveTextbookLesson() async {
    final package = _selectedTextbookPackage;
    final lesson = _selectedTextbookLesson;
    if (package == null || lesson == null || _busy) return;
    final progressId = 'textbook:${package.id}:${lesson.id}';
    final existing = _state?.articleProgress
        .where((item) => item.articleId == progressId)
        .firstOrNull;
    final now = widget.clock();
    final progress =
        (existing ??
                LearningArticleProgressData(
                  articleId: progressId,
                  title: '${package.title} · ${lesson.title}',
                  currentParagraph: 0,
                  completedParagraphs: const [],
                  favoriteParagraphs: const [],
                  lookedUpWords: const [],
                  lastReadAt: now.toIso8601String(),
                ))
            .copyWith(
              currentParagraph: 0,
              completedParagraphs: {
                ...?existing?.completedParagraphs,
                0,
              }.toList(),
              lastReadAt: now.toIso8601String(),
            );
    setState(() => _busy = true);
    try {
      await _repository.saveArticleProgress(progress);
      final next = await _repository.load();
      if (!mounted) return;
      setState(() {
        _state = next;
        _status = '已记录「${package.title} · ${lesson.title}」学习进度';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '教材进度保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildTextbookWorkspace(ColorScheme colors) =>
      LearningTextbookWorkspace(
        packages: _availableTextbookPackages,
        references: learningTextbookReferences,
        selectedPackageId: _selectedTextbookPackageId,
        selectedLessonId: _selectedTextbookLessonId,
        onImport: _importTextbook,
        onShowFormat: _showTextbookFormat,
        onSelectLesson: _selectTextbookLesson,
        onAddVocabulary: _addTextbookVocabulary,
        onMarkLesson: _saveTextbookLesson,
        onTranslateLesson: _translateTextbookLesson,
        translationBusy: _textbookTranslationBusy || _busy,
        translationStatus: _textbookTranslationStatus,
        translationError: _textbookTranslationError,
        lookupDictionary: widget.lookupDictionary,
        onSaveVocabularyWord: _addTextbookDictionaryWord,
        onSpeak: widget.onSpeak,
      );

  Widget _buildArticleSourceChooser(ColorScheme colors) {
    return Card(
      key: const ValueKey('learning-article-source-selector'),
      elevation: 0,
      color: colors.surface.withValues(alpha: .9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(17),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.source_outlined, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '选择文章来源',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '先选来源，再进入原文、译文、查词和批注工作台。联网内容需要你主动确认来源和使用权。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900
                    ? 5
                    : constraints.maxWidth >= 600
                    ? 3
                    : 1;
                final gap = 8.0;
                final width = columns == 1
                    ? constraints.maxWidth
                    : (constraints.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final source in _ArticleSource.values)
                      SizedBox(
                        width: width,
                        child: _ArticleSourceCard(
                          source: source,
                          selected: source == _articleSource,
                          onTap: source.isAvailable
                              ? () => setState(() {
                                  _articleSource = source;
                                  _status = source == _ArticleSource.builtIn
                                      ? '已切换到内置自写文章'
                                      : null;
                                })
                              : null,
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArticleSourcePlaceholder(ColorScheme colors) {
    final source = _articleSource;
    return _SectionCard(
      key: const ValueKey('learning-article-source-placeholder'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(source.icon, color: colors.primary, size: 30),
          const SizedBox(height: 12),
          Text(
            source.title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Text(source.description),
          const SizedBox(height: 13),
          _NoticeBar(text: source.notice, positive: true),
        ],
      ),
    );
  }

  Widget _buildArticleHubPanel({
    required Key key,
    required String title,
    required String description,
    required IconData icon,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('learning-article-hub-back'),
            onPressed: _returnToArticleHub,
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('返回文章学习'),
          ),
        ),
        const SizedBox(height: 8),
        _SectionCard(
          key: key,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, color: colors.primary, size: 23),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildArticleHubPlan() {
    final article = _mostRecentlyReadArticle ?? builtInLearningArticles.first;
    final progress = _articleProgress(article.id);
    final paragraph = (progress?.currentParagraph ?? 0).clamp(
      0,
      article.paragraphCount - 1,
    );
    final completed = _articleCompletedCount(article, progress);
    final hasSavedProgress = progress != null;
    return _buildArticleHubPanel(
      key: const ValueKey('learning-article-hub-plan'),
      title: hasSavedProgress ? '继续上次阅读' : '开始文章学习',
      description: hasSavedProgress
          ? '继续本机保存的文章与段落断点。阅读内容保存在本地。'
          : '还没有文章阅读记录。可以从第一篇本地文章开始，断点会保存在本机。',
      icon: Icons.event_available_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            article.title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            '${article.level} · 已读 $completed / ${article.paragraphCount} 段',
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: article.paragraphCount == 0
                ? 0
                : completed / article.paragraphCount,
          ),
          const SizedBox(height: 12),
          Text(
            '从第 ${paragraph + 1} 段继续',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('learning-article-plan-resume'),
              onPressed: () => _resumeArticle(article),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(hasSavedProgress ? '继续阅读' : '开始阅读'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArticleHubProgress() {
    return _buildArticleHubPanel(
      key: const ValueKey('learning-article-hub-progress'),
      title: '本机文章进度',
      description: '每篇文章单独记录已读段落和继续位置。选择一篇即可从保存的断点继续。',
      icon: Icons.query_stats_rounded,
      child: Column(
        children: [
          for (var index = 0; index < builtInLearningArticles.length; index++)
            Builder(
              builder: (context) {
                final article = builtInLearningArticles[index];
                final progress = _articleProgress(article.id);
                final completed = _articleCompletedCount(article, progress);
                final currentParagraph = (progress?.currentParagraph ?? 0)
                    .clamp(0, article.paragraphCount - 1);
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index == builtInLearningArticles.length - 1
                        ? 0
                        : 12,
                  ),
                  child: Container(
                    key: ValueKey(
                      'learning-article-progress-item-${article.id}',
                    ),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: .34),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant
                            .withValues(alpha: .66),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          article.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${article.level} · 已读 $completed / ${article.paragraphCount} 段 · 当前第 ${currentParagraph + 1} 段',
                          key: ValueKey(
                            'learning-article-progress-count-${article.id}',
                          ),
                        ),
                        const SizedBox(height: 9),
                        LinearProgressIndicator(
                          value: article.paragraphCount == 0
                              ? 0
                              : completed / article.paragraphCount,
                        ),
                        const SizedBox(height: 9),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            key: ValueKey(
                              'learning-article-progress-resume-${article.id}',
                            ),
                            onPressed: () => _resumeArticle(article),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(progress == null ? '开始阅读' : '继续阅读'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildArticleHubVocabulary() {
    final items = _articleHubVocabulary();
    return _buildArticleHubPanel(
      key: const ValueKey('learning-article-hub-vocabulary'),
      title: '文章词汇',
      description: '显示已加入本地词库的文章词条，以及本地词典中已收藏且出现在文章里的词。点击词条可查释义并返回对应文章。',
      icon: Icons.bookmarks_outlined,
      child: items.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _NoticeBar(
                  text: '还没有文章词汇记录。进入一篇文章后，可把匹配到的词条加入本地词库。',
                  positive: true,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('learning-article-vocabulary-start'),
                  onPressed: _openArticleWorkbench,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('打开本地文章'),
                ),
              ],
            )
          : Column(
              children: [
                for (var index = 0; index < items.length; index++)
                  Builder(
                    builder: (context) {
                      final item = items[index];
                      final dictionaryEntry =
                          _entriesByWord[normalizeLearningWord(item.word)];
                      final badges = <String>[
                        if (item.savedToVocabulary) '已加入词库',
                        if (item.favorite) '已收藏',
                      ];
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == items.length - 1 ? 0 : 7,
                        ),
                        child: Material(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: .28),
                          borderRadius: BorderRadius.circular(13),
                          child: ListTile(
                            key: ValueKey(
                              'learning-article-vocabulary-word-'
                              '${item.article.id}-${item.word}',
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                              side: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: .66),
                              ),
                            ),
                            leading: Icon(
                              Icons.translate_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(
                              item.word,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${item.article.title} · ${badges.join(' · ')}'
                              '${dictionaryEntry == null ? ' · 本地词典暂无释义' : ' · ${dictionaryEntry.meanings.firstOrNull ?? dictionaryEntry.partOfSpeech}'}',
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () =>
                                _resumeArticle(item.article, word: item.word),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }

  Widget _buildArticleWorkspace(ColorScheme colors) {
    if (_articleImmersiveReader) {
      return _buildImmersiveArticleWorkspace(colors);
    }
    if (!_articleHubEntered) {
      return switch (_articleHubView) {
        _ArticleHubView.home => LearningArticleLearningHub(
          onOpenPlan: () => _showArticleHubView(_ArticleHubView.plan),
          onOpenProgress: () => _showArticleHubView(_ArticleHubView.progress),
          onOpenVocabulary: () =>
              _showArticleHubView(_ArticleHubView.vocabulary),
          onOpenSummary: _openArticleHubSummary,
          onOpenSourceSettings: _openArticleWorkbench,
        ),
        _ArticleHubView.plan => _buildArticleHubPlan(),
        _ArticleHubView.progress => _buildArticleHubProgress(),
        _ArticleHubView.vocabulary => _buildArticleHubVocabulary(),
      };
    }
    if (_articleSource != _ArticleSource.builtIn) {
      return _buildArticleWorkspaceLegacy(colors);
    }
    final sourceChooser = _buildArticleSourceChooser(colors);
    final article = _selectedArticle ?? builtInLearningArticles.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sourceChooser,
        const SizedBox(height: 15),
        _buildArticleWorkbenchCard(article),
      ],
    );
  }

  Widget _buildArticleWorkbenchCard(
    LearningArticle article, {
    bool immersiveMode = false,
  }) {
    final progress =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final matchedVocabulary =
        article.vocabulary
            .map(normalizeLearningWord)
            .where(_entriesByWord.containsKey)
            .toSet()
            .toList()
          ..sort();
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: constraints.maxWidth.clamp(0.0, 1180.0).toDouble(),
          child: LearningArticleWorkbench(
            key: _articleWorkbenchStateKey,
            article: article,
            articles: immersiveMode ? const [] : builtInLearningArticles,
            selectedArticleId: article.id,
            progress: progress,
            paragraphIndex: _articleParagraphIndex,
            translationVisible: _articleTranslationVisible,
            matchedVocabulary: matchedVocabulary,
            entriesByWord: _entriesByWord,
            selectedWord: _articleSelectedWord,
            isFavorite: (word) =>
                _favoriteWords.contains(normalizeLearningWord(word)),
            wordNote: _articleWordNote,
            summary: _articleSummary,
            busy: _busy,
            onSelectParagraph: _selectArticleParagraph,
            onSelectArticle: _selectArticle,
            onSelectWord: _selectArticleWord,
            onToggleWordFavorite: _toggleVocabularyFavorite,
            onToggleTranslation: () => setState(
              () => _articleTranslationVisible = !_articleTranslationVisible,
            ),
            onCompleteParagraph: _saveArticleParagraph,
            onToggleFavorite: _toggleArticleFavorite,
            onAddVocabulary: _addArticleVocabulary,
            onSummarize: _summarizeSelectedArticle,
            onSaveWordNote: _saveArticleWordNote,
            onAnswerQuestion: _saveArticleComprehensionAnswer,
            onOpenImmersiveReader: immersiveMode
                ? null
                : _openImmersiveArticleReader,
            onSpeak: widget.onSpeak,
            immersiveMode: immersiveMode,
          ),
        ),
      ),
    );
  }

  Widget _buildImmersiveArticleWorkspace(ColorScheme colors) {
    final article = _selectedArticle ?? builtInLearningArticles.first;
    final progress =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final paragraphIndex = _articleParagraphIndex.clamp(
      0,
      article.paragraphCount - 1,
    );
    final completed = progress.completedParagraphs.length;
    final progressValue = article.paragraphCount == 0
        ? 0.0
        : completed / article.paragraphCount;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      key: const ValueKey('learning-article-immersive'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          key: const ValueKey('learning-article-immersive-header'),
          margin: EdgeInsets.zero,
          elevation: 0,
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .8),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('learning-article-immersive-exit'),
                      tooltip: '退出沉浸式阅读',
                      onPressed: _closeImmersiveArticleReader,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '沉浸式阅读 · ${article.level}',
                            style: textTheme.labelMedium?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            article.title,
                            key: const ValueKey(
                              'learning-article-immersive-title',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onSpeak != null)
                      IconButton(
                        tooltip: '朗读全文',
                        onPressed: () => widget.onSpeak!(
                          article.paragraphs
                              .map((paragraph) => paragraph.text)
                              .join('\n'),
                        ),
                        icon: const Icon(Icons.volume_up_outlined),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: progressValue,
                    minHeight: 6,
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '已读 $completed/${article.paragraphCount} 段 · 当前第 ${paragraphIndex + 1} 段',
                  key: const ValueKey('learning-article-immersive-progress'),
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildArticleWorkbenchCard(article, immersiveMode: true),
      ],
    );
  }

  Widget _buildArticleWorkspaceLegacy(ColorScheme colors) {
    final sourceChooser = _buildArticleSourceChooser(colors);
    if (_articleSource == _ArticleSource.textbook) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sourceChooser,
          const SizedBox(height: 15),
          _buildTextbookWorkspace(colors),
        ],
      );
    }
    if (_articleSource != _ArticleSource.builtIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sourceChooser,
          const SizedBox(height: 15),
          _buildArticleSourcePlaceholder(colors),
        ],
      );
    }
    final article = _selectedArticle ?? builtInLearningArticles.first;
    final progress =
        _articleProgress(article.id) ?? _defaultArticleProgress(article);
    final index = _articleParagraphIndex.clamp(0, article.paragraphCount - 1);
    final paragraph = article.paragraphs[index];
    final isFavorite = progress.favoriteParagraphs.contains(index);
    final completed = progress.completedParagraphs.length;
    final matchedVocabulary =
        article.vocabulary
            .map(normalizeLearningWord)
            .where(_entriesByWord.containsKey)
            .toSet()
            .toList()
          ..sort();
    final articleList = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '内置学习文章',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        for (final item in builtInLearningArticles) ...[
          _ArticleListTile(
            article: item,
            selected: item.id == article.id,
            completed:
                _articleProgress(item.id)?.completedParagraphs.length ?? 0,
            onTap: () => _selectArticle(item),
          ),
          const SizedBox(height: 9),
        ],
      ],
    );
    final articleBody = _SectionCard(
      key: const ValueKey('learning-article-workspace'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${article.level} · 已读 $completed/${article.paragraphCount} 段',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('learning-article-speak'),
                tooltip: '播放本段',
                onPressed: widget.onSpeak == null
                    ? null
                    : () => widget.onSpeak!(paragraph.text),
                icon: const Icon(Icons.volume_up_outlined),
              ),
            ],
          ),
          const SizedBox(height: 17),
          LinearProgressIndicator(value: completed / article.paragraphCount),
          const SizedBox(height: 20),
          Text(
            '第 ${index + 1} 段',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 9),
          Text(
            paragraph.text,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(height: 1.55, fontWeight: FontWeight.w700),
          ),
          if (_articleTranslationVisible) ...[
            const SizedBox(height: 13),
            Text(
              paragraph.translation,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(height: 1.55, color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 17),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('learning-article-translation'),
                onPressed: () => setState(
                  () =>
                      _articleTranslationVisible = !_articleTranslationVisible,
                ),
                icon: const Icon(Icons.translate_outlined),
                label: Text(_articleTranslationVisible ? '隐藏译文' : '显示译文'),
              ),
              FilledButton.icon(
                key: const ValueKey('learning-article-complete'),
                onPressed: _busy ? null : _saveArticleParagraph,
                icon: const Icon(Icons.done_rounded),
                label: const Text('标记本段已读'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-article-favorite'),
                onPressed: _busy ? null : _toggleArticleFavorite,
                icon: Icon(isFavorite ? Icons.bookmark : Icons.bookmark_border),
                label: Text(isFavorite ? '取消收藏' : '收藏本段'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-article-vocabulary'),
                onPressed: _busy ? null : _addArticleVocabulary,
                icon: const Icon(Icons.playlist_add_outlined),
                label: Text('加入词书（${matchedVocabulary.length}）'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-article-summary'),
                onPressed: _busy ? null : _summarizeSelectedArticle,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('AI 总结'),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Text(
            article.description,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
          ),
          if (matchedVocabulary.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '本地词典词条',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final word in matchedVocabulary)
                  InputChip(
                    label: Text(word),
                    onPressed: () => widget.onSpeak?.call(word),
                  ),
              ],
            ),
          ],
          if (_articleSummary != null) ...[
            const SizedBox(height: 16),
            _NoticeBar(text: 'AI 总结：$_articleSummary', positive: true),
          ],
          const SizedBox(height: 17),
          Row(
            children: [
              IconButton(
                key: const ValueKey('learning-article-previous'),
                onPressed: index == 0
                    ? null
                    : () => setState(() {
                        _articleParagraphIndex--;
                        _articleTranslationVisible = false;
                      }),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '点击“标记本段已读”会保存断点，关闭软件后可继续。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              IconButton(
                key: const ValueKey('learning-article-next'),
                onPressed: index + 1 >= article.paragraphCount
                    ? null
                    : () => setState(() {
                        _articleParagraphIndex++;
                        _articleTranslationVisible = false;
                      }),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sourceChooser,
        const SizedBox(height: 15),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 980) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 245, child: _SectionCard(child: articleList)),
                  const SizedBox(width: 16),
                  Expanded(child: articleBody),
                ],
              );
            }
            return Column(
              children: [
                _SectionCard(child: articleList),
                const SizedBox(height: 16),
                articleBody,
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildActiveWorkspace(ColorScheme colors, double width) {
    final session = _state!.session!;
    final item = _currentItem;
    final entry = item == null ? null : _entryFor(item.word);
    if (item == null) {
      return _SectionCard(child: const Text('当前学习条目暂时不可用，请结束本轮后重新开始。'));
    }
    final card = _buildCard(colors, session, item, entry);
    final details = _buildDetails(colors, item, entry);
    final body = width >= 1080
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: card),
              const SizedBox(width: 18),
              SizedBox(width: 350, child: details),
            ],
          )
        : Column(children: [card, const SizedBox(height: 18), details]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionCard(
          child: Row(
            children: [
              Icon(Icons.route_outlined, color: colors.primary),
              const SizedBox(width: 9),
              Text(
                session.paused
                    ? '已暂停 · 继续当前学习'
                    : '正在学习 · ${session.mode.label}',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                '${session.completedCount} / ${session.queueItemIds.length}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        body,
        const SizedBox(height: 18),
        _SectionCard(
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('learning-pause'),
                onPressed: _busy ? null : _pauseOrResume,
                icon: Icon(
                  session.paused ? Icons.play_arrow_rounded : Icons.pause,
                ),
                label: Text(session.paused ? '继续本轮' : '暂停学习'),
              ),
              TextButton.icon(
                key: const ValueKey('learning-end'),
                onPressed: _busy ? null : _endSession,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('结束并保存'),
              ),
              Text(
                '关闭窗口也不会丢失当前队列。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCard(
    ColorScheme colors,
    LearningSessionData session,
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    final prompt = _promptText(session.mode, item, entry);
    final answer = _answerText(session.mode, item, entry);
    return _SectionCard(
      key: const ValueKey('learning-word-card'),
      background: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  session.mode.label,
                  style: TextStyle(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('learning-speak'),
                tooltip: '播放读音',
                onPressed: widget.onSpeak == null
                    ? null
                    : () => widget.onSpeak!(item.word),
                icon: const Icon(Icons.volume_up_outlined),
              ),
              IconButton(
                key: const ValueKey('learning-favorite'),
                tooltip: '收藏单词',
                onPressed: _busy ? null : _toggleFavorite,
                icon: Icon(
                  _favoriteWords.contains(item.word)
                      ? Icons.bookmark
                      : Icons.bookmark_border,
                ),
                color: _favoriteWords.contains(item.word)
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 15),
          Text(
            prompt,
            style: Theme.of(context).textTheme.displaySmall
                ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: .2),
          ),
          if (entry != null && entry.ipa.trim().isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              entry.ipa,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(color: colors.primary, fontFamily: 'serif'),
            ),
          ],
          const SizedBox(height: 18),
          TextField(
            key: const ValueKey('learning-recall-answer'),
            controller: _recallAnswerController,
            readOnly: _answerVisible,
            minLines: 1,
            maxLines: 2,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: _answerVisible ? '我的回忆' : '主动回忆 · 可跳过',
              hintText: _answerVisible ? '未填写回忆答案' : '先写下你记得的答案，再打开释义对照',
              border: const OutlineInputBorder(),
              suffixIcon: _answerVisible
                  ? const Icon(Icons.lock_outline, size: 18)
                  : const Icon(Icons.edit_outlined, size: 18),
            ),
          ),
          const SizedBox(height: 22),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _answerVisible
                ? Container(
                    key: const ValueKey('learning-answer-visible'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: .38),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: colors.primary.withValues(alpha: .22),
                      ),
                    ),
                    child: _buildAnswerContent(colors, item, entry, answer),
                  )
                : OutlinedButton.icon(
                    key: const ValueKey('learning-reveal'),
                    onPressed: () => setState(() => _answerVisible = true),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('对照答案'),
                  ),
          ),
          const SizedBox(height: 24),
          Text(
            '你记得这个词吗？',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                key: const ValueKey('learning-result-again'),
                onPressed: _busy
                    ? null
                    : () => _record(LearningReviewResult.again),
                child: const Text('不会 · 再来'),
              ),
              OutlinedButton(
                key: const ValueKey('learning-result-fuzzy'),
                onPressed: _busy
                    ? null
                    : () => _record(LearningReviewResult.fuzzy),
                child: const Text('模糊 · 明天'),
              ),
              FilledButton(
                key: const ValueKey('learning-result-mastered'),
                onPressed: _busy
                    ? null
                    : () => _record(LearningReviewResult.mastered),
                child: const Text('掌握 · 下次更久'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetails(
    ColorScheme colors,
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PanelTitle(
                icon: Icons.menu_book_outlined,
                title: '词语解释',
                color: colors.primary,
              ),
              const SizedBox(height: 13),
              if (entry == null)
                Text(
                  '当前词典没有这条释义。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else ...[
                Text(
                  entry.partOfSpeech,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_answerVisible) ...[
                  const SizedBox(height: 7),
                  for (final meaning in entry.meanings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $meaning'),
                    ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      '查看词卡答案后显示分层释义。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                if (entry.variants.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    _answerVisible
                        ? '词形变化：${entry.variants.join(' · ')}'
                        : '查看答案后显示词形变化',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ],
            ],
          ),
        ),
        if (item.setId == learningScreenshotWordsSetId) ...[
          const SizedBox(height: 14),
          if (!_answerVisible)
            const _SectionCard(
              key: ValueKey('learning-screenshot-hidden-context'),
              child: Text('查看答案后显示截图原文、译文快照和词义。'),
            )
          else ...[
            if (item.sourceContext?.trim().isNotEmpty ?? false) ...[
              _screenshotSnapshotCard(
                colors,
                title: '截图原文语境',
                text: item.sourceContext!,
                icon: Icons.document_scanner_outlined,
                key: const ValueKey('learning-screenshot-source-context'),
              ),
              const SizedBox(height: 14),
            ],
            if (item.sourceTranslation?.trim().isNotEmpty ?? false) ...[
              _screenshotSnapshotCard(
                colors,
                title: '文章译文快照',
                text: item.sourceTranslation!,
                icon: Icons.translate_outlined,
                key: const ValueKey('learning-screenshot-source-translation'),
              ),
              const SizedBox(height: 14),
            ],
            _buildScreenshotMeaningEditor(colors, item),
          ],
        ],
        const SizedBox(height: 14),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PanelTitle(
                icon: Icons.chat_bubble_outline,
                title: '例句',
                color: colors.primary,
              ),
              const SizedBox(height: 13),
              if (!_answerVisible)
                Text(
                  '查看答案后显示双语例句。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else if (entry == null || !entry.hasExample)
                Text(
                  '这条词典记录暂时没有完整例句。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else ...[
                Text(
                  entry.example,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 7),
                Text(entry.exampleTranslation),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PanelTitle(
                icon: Icons.edit_note_outlined,
                title: '学习笔记',
                color: colors.primary,
              ),
              const SizedBox(height: 11),
              TextField(
                key: const ValueKey('learning-note-field'),
                controller: _noteController,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(hintText: '记下语境、易错点或自己的例句…'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  key: const ValueKey('learning-save-note'),
                  onPressed: _savingNote ? null : _saveNote,
                  child: Text(_savingNote ? '保存中…' : '保存笔记'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '单词、笔记和复习记录都保存在你的本地资料库。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _SectionCard(
          child: Row(
            children: [
              Icon(Icons.history, color: colors.primary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  '该词已复习 ${item.reviewCount} 次 · 下次：${item.dueDate}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _screenshotSnapshotCard(
    ColorScheme colors, {
    required String title,
    required String text,
    required IconData icon,
    required Key key,
  }) => _SectionCard(
    key: key,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PanelTitle(icon: icon, title: title, color: colors.primary),
        const SizedBox(height: 11),
        SelectableText(
          text,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
        ),
      ],
    ),
  );

  Widget _buildScreenshotMeaningEditor(
    ColorScheme colors,
    LearningItemData item,
  ) {
    final dictionaryMeaningIsProtected = item.meaningSource == 'dictionary';
    return _SectionCard(
      key: const ValueKey('learning-screenshot-meaning-editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelTitle(
            icon: Icons.edit_note_outlined,
            title: '我的确认释义',
            color: colors.primary,
          ),
          const SizedBox(height: 6),
          Text(
            dictionaryMeaningIsProtected
                ? '这条释义来自词典，词卡优先显示词典内容；此处不会覆盖。'
                : '单独保存你确认的词义；文章译文快照不会自动成为词义。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 11),
          TextField(
            key: const ValueKey('learning-screenshot-meaning-field'),
            controller: _screenshotMeaningController,
            enabled: !dictionaryMeaningIsProtected,
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '中文释义',
              hintText: '例如：类星体（天文学名词）',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              key: const ValueKey('learning-screenshot-save-meaning'),
              onPressed:
                  dictionaryMeaningIsProtected || _savingScreenshotMeaning
                  ? null
                  : _saveScreenshotMeaning,
              icon: const Icon(Icons.save_outlined),
              label: Text(_savingScreenshotMeaning ? '保存中…' : '保存释义'),
            ),
          ),
        ],
      ),
    );
  }

  String? _preferredScreenshotMeaning(
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    final dictionaryMeanings = entry?.meanings
        .map((meaning) => meaning.trim())
        .where((meaning) => meaning.isNotEmpty)
        .toList();
    if (dictionaryMeanings?.isNotEmpty ?? false) {
      return dictionaryMeanings!.join('；');
    }
    final savedMeaning = item.meaning?.trim();
    return savedMeaning == null || savedMeaning.isEmpty ? null : savedMeaning;
  }

  String? _screenshotMeaningSource(
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    final hasDictionaryMeaning =
        entry?.meanings.any((meaning) => meaning.trim().isNotEmpty) ?? false;
    if (hasDictionaryMeaning) return '本地词典释义';
    return switch (item.meaningSource) {
      'dictionary' => '已保存的词典释义',
      'user' => '你填写的释义',
      _ => null,
    };
  }

  Widget _buildAnswerContent(
    ColorScheme colors,
    LearningItemData item,
    DictionaryEntry? entry,
    String answer,
  ) {
    final answerStyle = Theme.of(context).textTheme.titleLarge
        ?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w700);
    if (item.setId != learningScreenshotWordsSetId) {
      return Text(answer, style: answerStyle);
    }
    final meaning = _preferredScreenshotMeaning(item, entry);
    final meaningSource = _screenshotMeaningSource(item, entry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(answer, style: answerStyle),
        if (meaning != null && answer != meaning) ...[
          const SizedBox(height: 10),
          Text('确认释义：$meaning'),
        ],
        if (meaningSource != null) ...[
          const SizedBox(height: 9),
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.verified_outlined, size: 16),
            label: Text(meaningSource),
          ),
        ] else if (meaning == null && answer != '尚未填写释义') ...[
          const SizedBox(height: 9),
          const Text('释义：尚未填写释义'),
        ],
      ],
    );
  }

  String _promptText(
    LearningPromptMode mode,
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    if (mode == LearningPromptMode.chineseToEnglish) {
      if (item.setId == learningScreenshotWordsSetId) {
        return _preferredScreenshotMeaning(item, entry) ?? '尚未填写释义';
      }
      return entry?.meanings.firstOrNull ?? '中文释义';
    }
    return item.word;
  }

  String _answerText(
    LearningPromptMode mode,
    LearningItemData item,
    DictionaryEntry? entry,
  ) {
    if (item.setId == learningScreenshotWordsSetId) {
      return switch (mode) {
        LearningPromptMode.chineseToEnglish => item.word,
        LearningPromptMode.variants =>
          entry == null || entry.variants.isEmpty
              ? '暂无词形变化'
              : entry.variants.join(' · '),
        _ => _preferredScreenshotMeaning(item, entry) ?? '尚未填写释义',
      };
    }
    if (entry == null) return '词典中暂无完整内容，请先补充合法词典条目。';
    return switch (mode) {
      LearningPromptMode.chineseToEnglish => item.word,
      LearningPromptMode.variants =>
        entry.variants.isEmpty ? '暂无词形变化' : entry.variants.join(' · '),
      _ => entry.meanings.join('；'),
    };
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({this.child, this.background, super.key});

  final Widget? child;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: background ?? colors.surface.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .75)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .035),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SentenceProgressCard extends StatelessWidget {
  const _SentenceProgressCard({
    required this.label,
    required this.detail,
    required this.icon,
    required this.color,
    super.key,
  });

  final String label;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 170),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .07),
      border: Border.all(color: color.withValues(alpha: .2)),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 9),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    ),
  );
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 21),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text, required this.positive, super.key});

  final String text;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = positive ? const Color(0xFF0A8F78) : colors.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: .23)),
      ),
      child: Row(
        children: [
          Icon(
            positive ? Icons.check_circle_outline : Icons.error_outline,
            color: color,
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _PronunciationAccentCard extends StatelessWidget {
  const _PronunciationAccentCard({
    required this.accent,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final _PronunciationAccent accent;
  final bool selected;
  final ColorScheme colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = selected ? colors.primary : colors.onSurface;
    final flag = accent == _PronunciationAccent.british ? '英' : '美';
    final detail = accent == _PronunciationAccent.british
        ? 'British English'
        : 'American English';
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: .62)
          : colors.surface.withValues(alpha: .88),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? colors.primary
                  : colors.outlineVariant.withValues(alpha: .8),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? colors.primary.withValues(alpha: .12)
                      : colors.surfaceContainerHighest,
                ),
                child: Text(
                  flag,
                  style: TextStyle(color: primary, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      accent.label,
                      style: TextStyle(
                        color: primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: colors.primary, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LearningTrack {
  landing,
  vocabulary,
  pronunciation,
  sentence,
  textbook,
  article;

  String get label => switch (this) {
    _LearningTrack.landing => '学习',
    _LearningTrack.vocabulary => '词汇循环',
    _LearningTrack.pronunciation => '发音跟读',
    _LearningTrack.sentence => '句子练习',
    _LearningTrack.textbook => '教材课程',
    _LearningTrack.article => '文章学习',
  };

  IconData get icon => switch (this) {
    _LearningTrack.landing => Icons.school_outlined,
    _LearningTrack.vocabulary => Icons.menu_book_outlined,
    _LearningTrack.pronunciation => Icons.graphic_eq_outlined,
    _LearningTrack.sentence => Icons.edit_note_outlined,
    _LearningTrack.textbook => Icons.school_outlined,
    _LearningTrack.article => Icons.article_outlined,
  };
}

enum _ArticleHubView { home, plan, progress, vocabulary }

enum _SentenceLibrary { builtIn, custom, ai }

class _ArticleHubVocabularyItem {
  const _ArticleHubVocabularyItem({
    required this.article,
    required this.word,
    required this.savedToVocabulary,
    required this.favorite,
  });

  final LearningArticle article;
  final String word;
  final bool savedToVocabulary;
  final bool favorite;
}

enum _PronunciationBand {
  all,
  cet4,
  cet6,
  oxford;

  String get label => switch (this) {
    _PronunciationBand.all => '全部词条',
    _PronunciationBand.cet4 => '英语四级',
    _PronunciationBand.cet6 => '英语六级',
    _PronunciationBand.oxford => '高阶词汇目标',
  };

  List<String> get aliases => switch (this) {
    _PronunciationBand.all => const [],
    _PronunciationBand.cet4 => const ['cet4', 'cet-4', 'college4', '四级'],
    _PronunciationBand.cet6 => const ['cet6', 'cet-6', 'college6', '六级'],
    _PronunciationBand.oxford => const ['advanced', '进阶', '高阶'],
  };
}

enum _PronunciationAccent {
  american,
  british;

  String get label => switch (this) {
    _PronunciationAccent.american => '美式发音',
    _PronunciationAccent.british => '英式发音',
  };
}

enum _PronunciationSource {
  newWords,
  review;

  String get label => switch (this) {
    _PronunciationSource.newWords => '新词/顺序',
    _PronunciationSource.review => '复习已学',
  };
}

enum _SentenceScenario {
  greeting,
  introduction,
  daily,
  study,
  formal;

  bool matches(DictionaryEntry entry) {
    final tags = entry.learningTags.map(_normalizeLearningTag).toSet();
    final taggedScenarios = _SentenceScenario.values
        .where(
          (scenario) =>
              scenario.tagAliases.map(_normalizeLearningTag).any(tags.contains),
        )
        .toSet();
    if (taggedScenarios.isNotEmpty) return taggedScenarios.contains(this);

    final text = [
      entry.word,
      ...entry.meanings,
      entry.example,
      entry.exampleTranslation,
    ].join(' ').toLowerCase();
    return keywords.any((keyword) {
      final normalized = keyword.toLowerCase();
      if (RegExp(r'[\u4e00-\u9fff]').hasMatch(normalized) ||
          normalized.contains(' ')) {
        return text.contains(normalized);
      }
      return RegExp(
        '\\b${RegExp.escape(normalized)}\\b',
        caseSensitive: false,
      ).hasMatch(text);
    });
  }

  List<String> get tagAliases => switch (this) {
    _SentenceScenario.greeting => [
      'greeting',
      'greetings',
      'hello',
      '问候',
      '打招呼',
      '寒暄',
    ],
    _SentenceScenario.introduction => [
      'introduction',
      'introduce',
      'self introduction',
      '自我介绍',
    ],
    _SentenceScenario.daily => ['daily', 'everyday', '日常', '生活'],
    _SentenceScenario.study => ['study', 'studying', 'school', '课堂', '课程'],
    _SentenceScenario.formal => ['formal', 'polite', 'business', '正式', '礼貌'],
  };

  List<String> get keywords => switch (this) {
    _SentenceScenario.greeting => [
      'hello',
      'hi',
      'welcome',
      'meet',
      'good morning',
      'goodbye',
      '你好',
      '喂',
      '问候',
      '见面',
      '早上好',
      '再见',
    ],
    _SentenceScenario.introduction => [
      'introduce',
      'introduction',
      'my name',
      'i am',
      'i come from',
      '自我介绍',
      '我叫',
      '姓名',
      '来自',
    ],
    _SentenceScenario.daily => [
      'daily',
      'everyday',
      'home',
      'food',
      'shopping',
      'today',
      'work',
      '日常',
      '生活',
      '吃饭',
      '购物',
      '工作',
    ],
    _SentenceScenario.study => [
      'study',
      'learn',
      'school',
      'class',
      'lesson',
      'reading',
      'read',
      'homework',
      'course',
      '学习',
      '课堂',
      '课程',
      '阅读',
      '作业',
    ],
    _SentenceScenario.formal => [
      'formal',
      'polite',
      'please',
      'thank you',
      'could you',
      'would you',
      'sincerely',
      '您好',
      '请',
      '谢谢',
      '正式',
      '麻烦',
    ],
  };

  String get label => switch (this) {
    _SentenceScenario.greeting => '打招呼',
    _SentenceScenario.introduction => '自我介绍',
    _SentenceScenario.daily => '日常交流',
    _SentenceScenario.study => '学习表达',
    _SentenceScenario.formal => '正式沟通',
  };

  String get hint => switch (this) {
    _SentenceScenario.greeting => '从问候、回应和初次见面开始练习。',
    _SentenceScenario.introduction => '练习介绍自己、兴趣和基本信息。',
    _SentenceScenario.daily => '把常见生活表达写成完整句子。',
    _SentenceScenario.study => '围绕课堂、阅读与学习计划组织表达。',
    _SentenceScenario.formal => '练习更正式、清晰和有礼貌的沟通。',
  };

  IconData get icon => switch (this) {
    _SentenceScenario.greeting => Icons.chat_bubble_outline_rounded,
    _SentenceScenario.introduction => Icons.person_outline_rounded,
    _SentenceScenario.daily => Icons.coffee_outlined,
    _SentenceScenario.study => Icons.school_outlined,
    _SentenceScenario.formal => Icons.business_center_outlined,
  };
}

String _normalizeLearningTag(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');

bool _matchesSentenceDifficulty(DictionaryEntry entry, int difficulty) {
  final wordCount = RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?")
      .allMatches(entry.example)
      .length;
  return difficulty <= 1 ? wordCount <= 8 : wordCount >= 9;
}

enum _ArticleSource {
  builtIn,
  web,
  localEnglish,
  localChinese,
  textbook;

  String get title => switch (this) {
    _ArticleSource.builtIn => '内置文章',
    _ArticleSource.web => '网上参考',
    _ArticleSource.localEnglish => '本地英文',
    _ArticleSource.localChinese => '本地中文',
    _ArticleSource.textbook => '教材课程',
  };

  bool get isAvailable =>
      this == _ArticleSource.builtIn || this == _ArticleSource.textbook;

  String get unavailableExplanation => switch (this) {
    _ArticleSource.web => '网页抓取尚未开放；先学习内置文章，授权课程可从教材课程导入。',
    _ArticleSource.localEnglish ||
    _ArticleSource.localChinese => '本地文章导入尚未开放；先学习内置文章，授权课程可从教材课程导入。',
    _ => '',
  };

  String get description => switch (this) {
    _ArticleSource.builtIn => '译学自写、可随软件发布的学习材料。',
    _ArticleSource.web => '未来可从公开网页选取学习材料；使用前需确认来源与权利。',
    _ArticleSource.localEnglish => '未来可从本地资料库打开你有权使用的英文文章。',
    _ArticleSource.localChinese => '未来可从本地资料库打开中文材料，作为翻译练习原文。',
    _ArticleSource.textbook => '选择已授权/合法导入的教材词表和课程元数据。',
  };

  String get notice => switch (this) {
    _ArticleSource.builtIn => '当前可直接学习，文章进度、收藏段落和总结请求会保存在本地。',
    _ArticleSource.web ||
    _ArticleSource.localEnglish ||
    _ArticleSource.localChinese => unavailableExplanation,
    _ArticleSource.textbook => '教材属于内容来源，不是第五种学习方式；导入前请确认版本和授权。',
  };

  IconData get icon => switch (this) {
    _ArticleSource.builtIn => Icons.auto_stories_outlined,
    _ArticleSource.web => Icons.language_outlined,
    _ArticleSource.localEnglish => Icons.description_outlined,
    _ArticleSource.localChinese => Icons.translate_outlined,
    _ArticleSource.textbook => Icons.school_outlined,
  };
}

class _ArticleSourceCard extends StatelessWidget {
  const _ArticleSourceCard({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final _ArticleSource source;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final available = source.isAvailable;
    return Material(
      color: !available
          ? colors.surfaceContainerLow
          : selected
          ? colors.primaryContainer.withValues(alpha: .65)
          : colors.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(12),
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: available
            ? source.title
            : '${source.title}，暂不可用。${source.unavailableExplanation}',
        child: InkWell(
          key: ValueKey('learning-article-source-${source.name}'),
          onTap: onTap,
          mouseCursor: onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
            child: Row(
              children: [
                Icon(
                  source.icon,
                  color: available && selected
                      ? colors.primary
                      : colors.onSurfaceVariant,
                  size: 21,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        source.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: available
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      if (!available) ...[
                        const SizedBox(height: 3),
                        Text(
                          '暂不可用 · ${source.unavailableExplanation}',
                          key: ValueKey(
                            'learning-article-source-unavailable-${source.name}',
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected && available)
                  Icon(Icons.check_circle, color: colors.primary, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArticleListTile extends StatelessWidget {
  const _ArticleListTile({
    required this.article,
    required this.selected,
    required this.completed,
    required this.onTap,
  });

  final LearningArticle article;
  final bool selected;
  final int completed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: .55)
          : colors.surfaceContainerHighest.withValues(alpha: .4),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                article.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${article.level} · $completed/${article.paragraphCount} 段',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextbookImportDetails {
  const _TextbookImportDetails({
    required this.title,
    required this.ageBand,
    required this.level,
    required this.version,
    required this.licenseName,
    required this.rightsHolder,
    required this.licenseUrl,
    required this.sourceUrl,
  });

  final String title;
  final String ageBand;
  final String level;
  final String version;
  final String licenseName;
  final String rightsHolder;
  final String licenseUrl;
  final String sourceUrl;
}

Widget _dialogTextField({
  required TextEditingController controller,
  required String label,
  FormFieldValidator<String>? validator,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 11),
  child: TextFormField(
    controller: controller,
    validator: validator,
    decoration: InputDecoration(labelText: label),
  ),
);

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _LearningWorkspaceLoadingSkeleton extends StatelessWidget {
  const _LearningWorkspaceLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '正在加载学习内容',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = constraints.maxWidth < 760
              ? constraints.maxWidth
              : (constraints.maxWidth - 16) / 2;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在准备你的学习空间',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  '正在读取本地词库、学习进度和练习内容',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: const LinearProgressIndicator(minHeight: 3),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final title in const [
                      '今日学习计划',
                      '词汇与复习',
                      '句子练习',
                      '文章精读',
                    ])
                      _LearningLoadingCard(
                        width: cardWidth,
                        title: title,
                        colors: colors,
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LearningLoadingCard extends StatelessWidget {
  const _LearningLoadingCard({
    required this.width,
    required this.title,
    required this.colors,
  });

  final double width;
  final String title;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final fill = colors.surfaceContainerHighest.withValues(alpha: .52);
    return Container(
      width: width,
      height: 118,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          Container(
            width: width * .56,
            height: 10,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 9),
          Container(
            width: width * .78,
            height: 10,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      ),
    );
  }
}
