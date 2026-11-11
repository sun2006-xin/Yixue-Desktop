import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Versioned local contracts for the vocabulary learning vertical slice.
///
/// The dictionary answers "what does this word mean?". These records answer
/// "what has this user learned, and when should it return?". Keeping the two
/// layers separate lets the learning page evolve without coupling it to a
/// particular translation model or dictionary provider.
const learningWorkbenchSchemaVersion = 2;
const learningDefaultSetId = 'yixue-basic-all';
const learningScreenshotWordsSetId = 'screenshot-words';
const learningScreenshotWordsSetTitle = '截屏生词';

enum LearningReviewResult { again, fuzzy, mastered }

extension LearningReviewResultWire on LearningReviewResult {
  String get wireName => switch (this) {
    LearningReviewResult.again => 'again',
    LearningReviewResult.fuzzy => 'fuzzy',
    LearningReviewResult.mastered => 'mastered',
  };

  String get label => switch (this) {
    LearningReviewResult.again => '不会',
    LearningReviewResult.fuzzy => '模糊',
    LearningReviewResult.mastered => '掌握',
  };

  bool get correct => this != LearningReviewResult.again;
}

LearningReviewResult learningReviewResultFromWire(Object? raw) {
  return switch (raw) {
    'again' => LearningReviewResult.again,
    'fuzzy' => LearningReviewResult.fuzzy,
    'mastered' => LearningReviewResult.mastered,
    _ => throw const FormatException('复习结果无效'),
  };
}

enum LearningPromptMode {
  recognition,
  englishToChinese,
  chineseToEnglish,
  variants,
}

extension LearningPromptModeWire on LearningPromptMode {
  String get wireName => switch (this) {
    LearningPromptMode.recognition => 'recognition',
    LearningPromptMode.englishToChinese => 'english_to_chinese',
    LearningPromptMode.chineseToEnglish => 'chinese_to_english',
    LearningPromptMode.variants => 'variants',
  };

  String get label => switch (this) {
    LearningPromptMode.recognition => '看词认义',
    LearningPromptMode.englishToChinese => '英译中',
    LearningPromptMode.chineseToEnglish => '中译英',
    LearningPromptMode.variants => '词形辨认',
  };
}

LearningPromptMode learningPromptModeFromWire(Object? raw) {
  return switch (raw) {
    'recognition' => LearningPromptMode.recognition,
    'english_to_chinese' => LearningPromptMode.englishToChinese,
    'chinese_to_english' => LearningPromptMode.chineseToEnglish,
    'variants' => LearningPromptMode.variants,
    _ => throw const FormatException('学习模式无效'),
  };
}

String normalizeLearningWord(String word) => word.trim().toLowerCase();

String learningDateKey(DateTime date) {
  final local = date.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${twoDigits(local.month)}-${twoDigits(local.day)}';
}

DateTime _dateFromKey(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || learningDateKey(parsed) != value) {
    throw const FormatException('学习日期无效');
  }
  return parsed;
}

String _dateAfter(String date, int days) {
  final parsed = _dateFromKey(date);
  return learningDateKey(parsed.add(Duration(days: days)));
}

String _text(Object? value, String label, {int maxLength = 240}) {
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$label无效');
  }
  return value;
}

String _boundedText(Object? value, String label, {int maxLength = 240}) {
  if (value is! String || value.length > maxLength) {
    throw FormatException('$label无效');
  }
  return value;
}

String? _optionalBoundedText(
  Object? value,
  String label, {
  int maxLength = 240,
}) => value == null ? null : _boundedText(value, label, maxLength: maxLength);

String? _optionalMeaningSource(Object? value) {
  if (value == null) return null;
  if (value != 'dictionary' && value != 'user') {
    throw const FormatException('词义来源无效');
  }
  return value as String;
}

String _date(Object? value, String label) {
  if (value is! String) throw FormatException('$label无效');
  _dateFromKey(value);
  return value;
}

String _timestamp(Object? value, String label) {
  if (value is! String || DateTime.tryParse(value) == null) {
    throw FormatException('$label无效');
  }
  return value;
}

int _nonNegativeInt(Object? value, String label, {int max = 1000000000}) {
  if (value is! int || value < 0 || value > max) {
    throw FormatException('$label无效');
  }
  return value;
}

bool _bool(Object? value, String label) {
  if (value is! bool) throw FormatException('$label无效');
  return value;
}

void _requireSchema(Map<String, dynamic> json) {
  final version = json['schema_version'];
  if (version is! int ||
      (version != 1 && version != learningWorkbenchSchemaVersion)) {
    throw const FormatException('学习数据版本不受支持');
  }
}

List<Map<String, dynamic>> _mapList(Object? raw, String label) {
  if (raw is! List) throw FormatException('$label格式无效');
  return [
    for (final item in raw)
      if (item is Map<String, dynamic>)
        item
      else
        throw FormatException('$label条目无效'),
  ];
}

String _optionalText(
  Object? value,
  String label,
  String fallback, {
  int maxLength = 240,
}) {
  if (value == null) return fallback;
  return _text(value, label, maxLength: maxLength);
}

List<String> _optionalStringList(Object? value, String label) {
  if (value == null) return const [];
  if (value is! List ||
      value.any((item) => item is! String || item.trim().isEmpty)) {
    throw FormatException('$label无效');
  }
  final values = value.cast<String>();
  if (values.any((item) => item.length > 120)) {
    throw FormatException('$label过长');
  }
  return List.unmodifiable(values);
}

class LearningSetData {
  const LearningSetData({
    required this.id,
    required this.title,
    required this.description,
    required this.sourceId,
    required this.dailyNewLimit,
    required this.dailyReviewLimit,
    required this.createdAt,
    required this.updatedAt,
    this.level = 'all',
    this.language = 'en',
    this.unit = '',
    this.tags = const [],
    this.isSystem = true,
  });

  final String id;
  final String title;
  final String description;
  final String sourceId;
  final int dailyNewLimit;
  final int dailyReviewLimit;
  final String createdAt;
  final String updatedAt;
  final String level;
  final String language;
  final String unit;
  final List<String> tags;
  final bool isSystem;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'title': title,
    'description': description,
    'source_id': sourceId,
    'daily_new_limit': dailyNewLimit,
    'daily_review_limit': dailyReviewLimit,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'level': level,
    'language': language,
    'unit': unit,
    'tags': tags,
    'is_system': isSystem,
  };

  factory LearningSetData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final newLimit = _nonNegativeInt(
      json['daily_new_limit'],
      '每日新词上限',
      max: 500,
    );
    final reviewLimit = _nonNegativeInt(
      json['daily_review_limit'],
      '每日复习上限',
      max: 1000,
    );
    return LearningSetData(
      id: _text(json['id'], '学习集合 ID', maxLength: 160),
      title: _text(json['title'], '学习集合名称'),
      description: _text(json['description'], '学习集合说明', maxLength: 1000),
      sourceId: _text(json['source_id'], '学习集合来源', maxLength: 200),
      dailyNewLimit: newLimit,
      dailyReviewLimit: reviewLimit,
      createdAt: _timestamp(json['created_at'], '学习集合创建时间'),
      updatedAt: _timestamp(json['updated_at'], '学习集合更新时间'),
      level: _optionalText(json['level'], '学习集合学段', 'all', maxLength: 80),
      language: _optionalText(json['language'], '学习集合语言', 'en', maxLength: 32),
      unit:
          json['unit'] == null ||
              (json['unit'] is String &&
                  (json['unit'] as String).trim().isEmpty)
          ? ''
          : _text(json['unit'], '学习集合单元', maxLength: 160),
      tags: _optionalStringList(json['tags'], '学习集合标签'),
      isSystem: json['is_system'] is bool ? json['is_system'] as bool : true,
    );
  }

  LearningSetData copyWith({
    String? title,
    String? description,
    String? sourceId,
    int? dailyNewLimit,
    int? dailyReviewLimit,
    String? createdAt,
    String? updatedAt,
    String? level,
    String? language,
    String? unit,
    List<String>? tags,
    bool? isSystem,
  }) => LearningSetData(
    id: id,
    title: title ?? this.title,
    description: description ?? this.description,
    sourceId: sourceId ?? this.sourceId,
    dailyNewLimit: dailyNewLimit ?? this.dailyNewLimit,
    dailyReviewLimit: dailyReviewLimit ?? this.dailyReviewLimit,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    level: level ?? this.level,
    language: language ?? this.language,
    unit: unit ?? this.unit,
    tags: tags ?? this.tags,
    isSystem: isSystem ?? this.isSystem,
  );
}

class LearningItemData {
  const LearningItemData({
    required this.id,
    required this.setId,
    required this.word,
    required this.dueDate,
    required this.stage,
    required this.reviewCount,
    required this.correctCount,
    required this.againCount,
    required this.lastReviewedAt,
    required this.addedAt,
    required this.suspended,
    this.meaning,
    this.meaningSource,
    this.sourceContext,
    this.sourceTranslation,
    this.sourceHistoryId,
  });

  final String id;
  final String setId;
  final String word;
  final String dueDate;
  final int stage;
  final int reviewCount;
  final int correctCount;
  final int againCount;
  final String? lastReviewedAt;
  final String addedAt;
  final bool suspended;
  final String? meaning;
  final String? meaningSource;
  final String? sourceContext;
  final String? sourceTranslation;
  final String? sourceHistoryId;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'set_id': setId,
    'word': word,
    'due_date': dueDate,
    'stage': stage,
    'review_count': reviewCount,
    'correct_count': correctCount,
    'again_count': againCount,
    'last_reviewed_at': lastReviewedAt,
    'added_at': addedAt,
    'suspended': suspended,
    'meaning': meaning,
    'meaning_source': meaningSource,
    'source_context': sourceContext,
    'source_translation': sourceTranslation,
    'source_history_id': sourceHistoryId,
  };

  factory LearningItemData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final stage = _nonNegativeInt(json['stage'], '学习阶段', max: 8);
    final reviews = _nonNegativeInt(json['review_count'], '复习次数');
    final correct = _nonNegativeInt(json['correct_count'], '掌握次数');
    final again = _nonNegativeInt(json['again_count'], '不会次数');
    final lastReviewedAt = json['last_reviewed_at'];
    if (correct > reviews ||
        again > reviews ||
        (lastReviewedAt != null &&
            (lastReviewedAt is! String ||
                DateTime.tryParse(lastReviewedAt) == null))) {
      throw const FormatException('学习进度统计无效');
    }
    final meaning = _optionalBoundedText(
      json['meaning'],
      '学习词义',
      maxLength: 2000,
    );
    final meaningSource = _optionalMeaningSource(json['meaning_source']);
    if ((meaning?.trim().isNotEmpty ?? false) != (meaningSource != null)) {
      throw const FormatException('词义与词义来源不匹配');
    }
    return LearningItemData(
      id: _text(json['id'], '学习条目 ID', maxLength: 240),
      setId: _text(json['set_id'], '学习集合 ID', maxLength: 160),
      word: _text(json['word'], '学习单词', maxLength: 300),
      dueDate: _date(json['due_date'], '下次复习日期'),
      stage: stage,
      reviewCount: reviews,
      correctCount: correct,
      againCount: again,
      lastReviewedAt: lastReviewedAt as String?,
      addedAt: _timestamp(json['added_at'], '学习条目加入时间'),
      suspended: _bool(json['suspended'], '学习条目状态'),
      meaning: meaning,
      meaningSource: meaningSource,
      sourceContext: _optionalBoundedText(
        json['source_context'],
        '来源原文上下文',
        maxLength: 100000,
      ),
      sourceTranslation: _optionalBoundedText(
        json['source_translation'],
        '来源文章译文',
        maxLength: 100000,
      ),
      sourceHistoryId: _optionalBoundedText(
        json['source_history_id'],
        '来源历史 ID',
        maxLength: 240,
      ),
    );
  }

  LearningItemData copyWith({
    String? dueDate,
    int? stage,
    int? reviewCount,
    int? correctCount,
    int? againCount,
    String? lastReviewedAt,
    bool? suspended,
    String? meaning,
    String? meaningSource,
    String? sourceContext,
    String? sourceTranslation,
    String? sourceHistoryId,
  }) => LearningItemData(
    id: id,
    setId: setId,
    word: word,
    dueDate: dueDate ?? this.dueDate,
    stage: stage ?? this.stage,
    reviewCount: reviewCount ?? this.reviewCount,
    correctCount: correctCount ?? this.correctCount,
    againCount: againCount ?? this.againCount,
    lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
    addedAt: addedAt,
    suspended: suspended ?? this.suspended,
    meaning: meaning ?? this.meaning,
    meaningSource: meaningSource ?? this.meaningSource,
    sourceContext: sourceContext ?? this.sourceContext,
    sourceTranslation: sourceTranslation ?? this.sourceTranslation,
    sourceHistoryId: sourceHistoryId ?? this.sourceHistoryId,
  );
}

class LearningReviewData {
  const LearningReviewData({
    required this.id,
    required this.itemId,
    required this.setId,
    required this.word,
    required this.mode,
    required this.result,
    required this.correct,
    required this.elapsedSeconds,
    required this.reviewedAt,
    required this.nextDueDate,
  });

  final String id;
  final String itemId;
  final String setId;
  final String word;
  final LearningPromptMode mode;
  final LearningReviewResult result;
  final bool correct;
  final int elapsedSeconds;
  final String reviewedAt;
  final String nextDueDate;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'item_id': itemId,
    'set_id': setId,
    'word': word,
    'mode': mode.wireName,
    'result': result.wireName,
    'correct': correct,
    'elapsed_seconds': elapsedSeconds,
    'reviewed_at': reviewedAt,
    'next_due_date': nextDueDate,
  };

  factory LearningReviewData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    return LearningReviewData(
      id: _text(json['id'], '复习记录 ID', maxLength: 300),
      itemId: _text(json['item_id'], '复习条目 ID', maxLength: 240),
      setId: _text(json['set_id'], '复习集合 ID', maxLength: 160),
      word: _text(json['word'], '复习单词', maxLength: 300),
      mode: learningPromptModeFromWire(json['mode']),
      result: learningReviewResultFromWire(json['result']),
      correct: _bool(json['correct'], '复习结果正确性'),
      elapsedSeconds: _nonNegativeInt(
        json['elapsed_seconds'],
        '答题耗时',
        max: 86400,
      ),
      reviewedAt: _timestamp(json['reviewed_at'], '复习时间'),
      nextDueDate: _date(json['next_due_date'], '下次复习日期'),
    );
  }
}

enum LearningPronunciationResult { needsPractice, uncertain, clear }

extension LearningPronunciationResultWire on LearningPronunciationResult {
  String get wireName => switch (this) {
    LearningPronunciationResult.needsPractice => 'needs_practice',
    LearningPronunciationResult.uncertain => 'uncertain',
    LearningPronunciationResult.clear => 'clear',
  };

  String get label => switch (this) {
    LearningPronunciationResult.needsPractice => '需要再练',
    LearningPronunciationResult.uncertain => '还不确定',
    LearningPronunciationResult.clear => '读得清楚',
  };
}

LearningPronunciationResult learningPronunciationResultFromWire(Object? raw) {
  return switch (raw) {
    'needs_practice' => LearningPronunciationResult.needsPractice,
    'uncertain' => LearningPronunciationResult.uncertain,
    'clear' => LearningPronunciationResult.clear,
    _ => throw const FormatException('发音练习结果无效'),
  };
}

class LearningPronunciationPracticeData {
  const LearningPronunciationPracticeData({
    required this.id,
    required this.itemId,
    required this.setId,
    required this.word,
    required this.result,
    required this.elapsedSeconds,
    required this.practicedAt,
  });

  final String id;
  final String itemId;
  final String setId;
  final String word;
  final LearningPronunciationResult result;
  final int elapsedSeconds;
  final String practicedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'item_id': itemId,
    'set_id': setId,
    'word': word,
    'result': result.wireName,
    'elapsed_seconds': elapsedSeconds,
    'practiced_at': practicedAt,
  };

  factory LearningPronunciationPracticeData.fromJson(
    Map<String, dynamic> json,
  ) {
    _requireSchema(json);
    return LearningPronunciationPracticeData(
      id: _text(json['id'], '发音练习 ID', maxLength: 300),
      itemId: _text(json['item_id'], '发音练习条目 ID', maxLength: 300),
      setId: _text(json['set_id'], '发音练习集合 ID', maxLength: 160),
      word: _text(json['word'], '发音练习单词', maxLength: 300),
      result: learningPronunciationResultFromWire(json['result']),
      elapsedSeconds: _nonNegativeInt(
        json['elapsed_seconds'],
        '发音练习时长',
        max: 86400,
      ),
      practicedAt: _timestamp(json['practiced_at'], '发音练习时间'),
    );
  }
}

enum SentencePracticeMode { chineseToEnglish, englishToChinese }

extension SentencePracticeModeWire on SentencePracticeMode {
  String get wireName => switch (this) {
    SentencePracticeMode.chineseToEnglish => 'chinese_to_english',
    SentencePracticeMode.englishToChinese => 'english_to_chinese',
  };

  String get label => switch (this) {
    SentencePracticeMode.chineseToEnglish => '中译英',
    SentencePracticeMode.englishToChinese => '英译中',
  };
}

SentencePracticeMode sentencePracticeModeFromWire(Object? raw) {
  return switch (raw) {
    'chinese_to_english' => SentencePracticeMode.chineseToEnglish,
    'english_to_chinese' => SentencePracticeMode.englishToChinese,
    _ => throw const FormatException('句子练习模式无效'),
  };
}

enum LearningSentencePromptOrigin { userCreated, aiGenerated }

extension LearningSentencePromptOriginWire on LearningSentencePromptOrigin {
  String get wireName => switch (this) {
    LearningSentencePromptOrigin.userCreated => 'user_created',
    LearningSentencePromptOrigin.aiGenerated => 'ai_generated',
  };

  String get label => switch (this) {
    LearningSentencePromptOrigin.userCreated => '我的句子',
    LearningSentencePromptOrigin.aiGenerated => 'AI 生成',
  };
}

LearningSentencePromptOrigin learningSentencePromptOriginFromWire(Object? raw) {
  return switch (raw) {
    null || 'user_created' => LearningSentencePromptOrigin.userCreated,
    'ai_generated' => LearningSentencePromptOrigin.aiGenerated,
    _ => throw const FormatException('句子来源无效'),
  };
}

class LearningSentenceAttemptData {
  const LearningSentenceAttemptData({
    required this.id,
    required this.setId,
    required this.word,
    required this.mode,
    required this.sourceText,
    required this.translation,
    required this.answer,
    required this.expectedAnswer,
    required this.correct,
    required this.mistakes,
    required this.elapsedSeconds,
    required this.attemptedAt,
    this.fromCustomPrompt = false,
    this.fromAiPrompt = false,
  });

  final String id;
  final String setId;
  final String word;
  final SentencePracticeMode mode;
  final String sourceText;
  final String translation;
  final String answer;
  final String expectedAnswer;
  final bool correct;
  final List<String> mistakes;
  final int elapsedSeconds;
  final String attemptedAt;
  final bool fromCustomPrompt;
  final bool fromAiPrompt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'set_id': setId,
    'word': word,
    'mode': mode.wireName,
    'source_text': sourceText,
    'translation': translation,
    'answer': answer,
    'expected_answer': expectedAnswer,
    'correct': correct,
    'mistakes': mistakes,
    'elapsed_seconds': elapsedSeconds,
    'attempted_at': attemptedAt,
    'from_custom_prompt': fromCustomPrompt,
    'from_ai_prompt': fromAiPrompt,
  };

  factory LearningSentenceAttemptData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final fromCustomPrompt = json['from_custom_prompt'] == null
        ? false
        : _bool(json['from_custom_prompt'], '自建句子来源');
    final fromAiPrompt = json['from_ai_prompt'] == null
        ? false
        : _bool(json['from_ai_prompt'], 'AI 句子来源');
    if (fromAiPrompt && !fromCustomPrompt) {
      throw const FormatException('AI 句子练习来源无效');
    }
    return LearningSentenceAttemptData(
      id: _text(json['id'], '句子练习 ID', maxLength: 300),
      setId: _text(json['set_id'], '句子练习集合 ID', maxLength: 160),
      word: _text(json['word'], '句子练习单词', maxLength: 300),
      mode: sentencePracticeModeFromWire(json['mode']),
      sourceText: _text(json['source_text'], '句子原文', maxLength: 2000),
      translation: _text(json['translation'], '句子译文', maxLength: 2000),
      answer: _boundedText(json['answer'], '句子作答', maxLength: 2000),
      expectedAnswer: _text(json['expected_answer'], '句子标准答案', maxLength: 2000),
      correct: _bool(json['correct'], '句子练习正确性'),
      mistakes: _optionalStringList(json['mistakes'], '句子错误位置'),
      elapsedSeconds: _nonNegativeInt(
        json['elapsed_seconds'],
        '句子练习时长',
        max: 86400,
      ),
      attemptedAt: _timestamp(json['attempted_at'], '句子练习时间'),
      fromCustomPrompt: fromCustomPrompt,
      fromAiPrompt: fromAiPrompt,
    );
  }
}

class LearningSentencePromptData {
  const LearningSentencePromptData({
    required this.id,
    required this.title,
    required this.chineseText,
    required this.englishText,
    required this.createdAt,
    this.origin = LearningSentencePromptOrigin.userCreated,
    this.scenario,
    this.difficulty,
  });

  final String id;
  final String title;
  final String chineseText;
  final String englishText;
  final String createdAt;
  final LearningSentencePromptOrigin origin;
  final String? scenario;
  final int? difficulty;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'title': title,
    'chinese_text': chineseText,
    'english_text': englishText,
    'created_at': createdAt,
    'origin': origin.wireName,
    'scenario': scenario,
    'difficulty': difficulty,
  };

  factory LearningSentencePromptData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final origin = learningSentencePromptOriginFromWire(json['origin']);
    final scenario = _optionalBoundedText(
      json['scenario'],
      '句子练习场景',
      maxLength: 80,
    );
    if (scenario != null && scenario.trim().isEmpty) {
      throw const FormatException('句子练习场景无效');
    }
    final rawDifficulty = json['difficulty'];
    final difficulty = rawDifficulty == null
        ? null
        : _nonNegativeInt(rawDifficulty, '句子练习难度', max: 3);
    if (difficulty == 0 ||
        (origin == LearningSentencePromptOrigin.aiGenerated &&
            (scenario == null || difficulty == null))) {
      throw const FormatException('AI 句子练习元数据无效');
    }
    return LearningSentencePromptData(
      id: _text(json['id'], '自建句子 ID', maxLength: 300),
      title: _text(json['title'], '自建句子标题', maxLength: 300),
      chineseText: _text(json['chinese_text'], '自建句子中文', maxLength: 2000),
      englishText: _text(json['english_text'], '自建句子英文', maxLength: 2000),
      createdAt: _timestamp(json['created_at'], '自建句子创建时间'),
      origin: origin,
      scenario: scenario,
      difficulty: difficulty,
    );
  }
}

/// A bilingual sentence generated for a learning exercise. It is not
/// persisted until the learner explicitly saves it to the local sentence
/// library.
class LearningSentenceExerciseData {
  const LearningSentenceExerciseData({
    required this.title,
    required this.chineseText,
    required this.englishText,
  });

  final String title;
  final String chineseText;
  final String englishText;
}

class LearningArticleProgressData {
  const LearningArticleProgressData({
    required this.articleId,
    required this.title,
    required this.currentParagraph,
    required this.completedParagraphs,
    required this.favoriteParagraphs,
    required this.lookedUpWords,
    required this.lastReadAt,
    this.questionAnswers = const {},
  });

  final String articleId;
  final String title;
  final int currentParagraph;
  final List<int> completedParagraphs;
  final List<int> favoriteParagraphs;
  final List<String> lookedUpWords;
  final String lastReadAt;
  final Map<String, int> questionAnswers;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'article_id': articleId,
    'title': title,
    'current_paragraph': currentParagraph,
    'completed_paragraphs': completedParagraphs,
    'favorite_paragraphs': favoriteParagraphs,
    'looked_up_words': lookedUpWords,
    'question_answers': questionAnswers,
    'last_read_at': lastReadAt,
  };

  factory LearningArticleProgressData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final completed = _nonNegativeIntList(
      json['completed_paragraphs'],
      '文章已读段落',
    );
    final favorites = _nonNegativeIntList(
      json['favorite_paragraphs'],
      '文章收藏段落',
    );
    return LearningArticleProgressData(
      articleId: _text(json['article_id'], '文章 ID', maxLength: 200),
      title: _text(json['title'], '文章标题', maxLength: 300),
      currentParagraph: _nonNegativeInt(json['current_paragraph'], '文章当前位置'),
      completedParagraphs: completed,
      favoriteParagraphs: favorites,
      lookedUpWords: _optionalStringList(json['looked_up_words'], '文章查词记录'),
      questionAnswers: _nonNegativeIntMap(json['question_answers'], '文章理解练习答案'),
      lastReadAt: _timestamp(json['last_read_at'], '文章阅读时间'),
    );
  }

  LearningArticleProgressData copyWith({
    String? title,
    int? currentParagraph,
    List<int>? completedParagraphs,
    List<int>? favoriteParagraphs,
    List<String>? lookedUpWords,
    Map<String, int>? questionAnswers,
    String? lastReadAt,
  }) => LearningArticleProgressData(
    articleId: articleId,
    title: title ?? this.title,
    currentParagraph: currentParagraph ?? this.currentParagraph,
    completedParagraphs: completedParagraphs ?? this.completedParagraphs,
    favoriteParagraphs: favoriteParagraphs ?? this.favoriteParagraphs,
    lookedUpWords: lookedUpWords ?? this.lookedUpWords,
    questionAnswers: questionAnswers ?? this.questionAnswers,
    lastReadAt: lastReadAt ?? this.lastReadAt,
  );
}

Map<String, int> _nonNegativeIntMap(Object? value, String label) {
  if (value == null) return const {};
  if (value is! Map || value.length > 10000) {
    throw FormatException('$label无效');
  }
  final result = <String, int>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! int || entry.value < 0) {
      throw FormatException('$label无效');
    }
    final key = (entry.key as String).trim();
    if (key.isEmpty || key.length > 200 || result.containsKey(key)) {
      throw FormatException('$label无效');
    }
    result[key] = entry.value as int;
  }
  return Map.unmodifiable(result);
}

List<int> _nonNegativeIntList(Object? value, String label) {
  if (value is! List || value.any((item) => item is! int || item < 0)) {
    throw FormatException('$label无效');
  }
  final values = value.cast<int>();
  if (values.toSet().length != values.length || values.length > 100000) {
    throw FormatException('$label无效');
  }
  return List.unmodifiable(values);
}

class LearningSessionData {
  const LearningSessionData({
    required this.id,
    required this.setId,
    required this.mode,
    required this.queueItemIds,
    required this.currentIndex,
    required this.completedCount,
    required this.currentItemId,
    required this.startedAt,
    required this.updatedAt,
    required this.paused,
  });

  final String id;
  final String setId;
  final LearningPromptMode mode;
  final List<String> queueItemIds;
  final int currentIndex;
  final int completedCount;
  final String? currentItemId;
  final String startedAt;
  final String updatedAt;
  final bool paused;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'id': id,
    'set_id': setId,
    'mode': mode.wireName,
    'queue_item_ids': queueItemIds,
    'current_index': currentIndex,
    'completed_count': completedCount,
    'current_item_id': currentItemId,
    'started_at': startedAt,
    'updated_at': updatedAt,
    'paused': paused,
  };

  factory LearningSessionData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final rawIds = json['queue_item_ids'];
    if (rawIds is! List ||
        rawIds.isEmpty ||
        rawIds.any((id) => id is! String || id.trim().isEmpty)) {
      throw const FormatException('学习队列无效');
    }
    final ids = rawIds.cast<String>();
    if (ids.toSet().length != ids.length) {
      throw const FormatException('学习队列包含重复条目');
    }
    final currentIndex = _nonNegativeInt(json['current_index'], '当前学习位置');
    final completed = _nonNegativeInt(json['completed_count'], '已完成数量');
    if (currentIndex > ids.length ||
        completed > ids.length ||
        currentIndex != completed) {
      throw const FormatException('学习队列进度无效');
    }
    final currentItemId = json['current_item_id'];
    if (currentItemId != null &&
        (currentItemId is! String || !ids.contains(currentItemId))) {
      throw const FormatException('当前学习条目无效');
    }
    return LearningSessionData(
      id: _text(json['id'], '学习会话 ID', maxLength: 300),
      setId: _text(json['set_id'], '学习集合 ID', maxLength: 160),
      mode: learningPromptModeFromWire(json['mode']),
      queueItemIds: List.unmodifiable(ids),
      currentIndex: currentIndex,
      completedCount: completed,
      currentItemId: currentItemId as String?,
      startedAt: _timestamp(json['started_at'], '学习会话开始时间'),
      updatedAt: _timestamp(json['updated_at'], '学习会话更新时间'),
      paused: _bool(json['paused'], '学习会话状态'),
    );
  }

  LearningSessionData copyWith({
    int? currentIndex,
    int? completedCount,
    String? currentItemId,
    String? updatedAt,
    bool? paused,
  }) => LearningSessionData(
    id: id,
    setId: setId,
    mode: mode,
    queueItemIds: queueItemIds,
    currentIndex: currentIndex ?? this.currentIndex,
    completedCount: completedCount ?? this.completedCount,
    currentItemId: currentItemId ?? this.currentItemId,
    startedAt: startedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    paused: paused ?? this.paused,
  );
}

class LearningStateData {
  const LearningStateData({
    required this.sets,
    required this.items,
    required this.reviews,
    required this.session,
    this.pronunciationPractices = const [],
    this.sentenceAttempts = const [],
    this.customSentencePrompts = const [],
    this.articleProgress = const [],
  });

  const LearningStateData.empty()
    : sets = const [],
      items = const [],
      reviews = const [],
      session = null,
      pronunciationPractices = const [],
      sentenceAttempts = const [],
      customSentencePrompts = const [],
      articleProgress = const [];

  final List<LearningSetData> sets;
  final List<LearningItemData> items;
  final List<LearningReviewData> reviews;
  final LearningSessionData? session;
  final List<LearningPronunciationPracticeData> pronunciationPractices;
  final List<LearningSentenceAttemptData> sentenceAttempts;
  final List<LearningSentencePromptData> customSentencePrompts;
  final List<LearningArticleProgressData> articleProgress;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': learningWorkbenchSchemaVersion,
    'sets': [for (final set in sets) set.toJson()],
    'items': [for (final item in items) item.toJson()],
    'reviews': [for (final review in reviews) review.toJson()],
    'session': session?.toJson(),
    'pronunciation_practices': [
      for (final practice in pronunciationPractices) practice.toJson(),
    ],
    'sentence_attempts': [
      for (final attempt in sentenceAttempts) attempt.toJson(),
    ],
    'custom_sentence_prompts': [
      for (final prompt in customSentencePrompts) prompt.toJson(),
    ],
    'article_progress': [
      for (final progress in articleProgress) progress.toJson(),
    ],
  };

  factory LearningStateData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final sets = [
      for (final raw in _mapList(json['sets'], '学习集合'))
        LearningSetData.fromJson(raw),
    ];
    final items = [
      for (final raw in _mapList(json['items'], '学习条目'))
        LearningItemData.fromJson(raw),
    ];
    final reviews = [
      for (final raw in _mapList(json['reviews'], '复习记录'))
        LearningReviewData.fromJson(raw),
    ];
    final sessionRaw = json['session'];
    final session = sessionRaw == null
        ? null
        : sessionRaw is Map<String, dynamic>
        ? LearningSessionData.fromJson(sessionRaw)
        : throw const FormatException('学习会话格式无效');
    final pronunciationPractices = [
      for (final raw in _optionalMapList(
        json['pronunciation_practices'],
        '发音练习记录',
      ))
        LearningPronunciationPracticeData.fromJson(raw),
    ];
    final sentenceAttempts = [
      for (final raw in _optionalMapList(json['sentence_attempts'], '句子练习记录'))
        LearningSentenceAttemptData.fromJson(raw),
    ];
    final customSentencePrompts = [
      for (final raw in _optionalMapList(
        json['custom_sentence_prompts'],
        '自建句子',
      ))
        LearningSentencePromptData.fromJson(raw),
    ];
    final articleProgress = [
      for (final raw in _optionalMapList(json['article_progress'], '文章进度'))
        LearningArticleProgressData.fromJson(raw),
    ];
    if (sets.map((set) => set.id).toSet().length != sets.length ||
        items.map((item) => item.id).toSet().length != items.length ||
        reviews.map((review) => review.id).toSet().length != reviews.length ||
        pronunciationPractices.map((practice) => practice.id).toSet().length !=
            pronunciationPractices.length ||
        sentenceAttempts.map((attempt) => attempt.id).toSet().length !=
            sentenceAttempts.length ||
        customSentencePrompts.map((prompt) => prompt.id).toSet().length !=
            customSentencePrompts.length ||
        articleProgress.map((progress) => progress.articleId).toSet().length !=
            articleProgress.length) {
      throw const FormatException('学习数据包含重复 ID');
    }
    final setIds = sets.map((set) => set.id).toSet();
    if (items.any((item) => !setIds.contains(item.setId)) ||
        reviews.any((review) => !setIds.contains(review.setId)) ||
        pronunciationPractices.any(
          (practice) => !setIds.contains(practice.setId),
        ) ||
        sentenceAttempts.any((attempt) => !setIds.contains(attempt.setId)) ||
        (session != null && !setIds.contains(session.setId))) {
      throw const FormatException('学习数据引用了不存在的集合');
    }
    return LearningStateData(
      sets: List.unmodifiable(sets),
      items: List.unmodifiable(items),
      reviews: List.unmodifiable(reviews),
      session: session,
      pronunciationPractices: List.unmodifiable(pronunciationPractices),
      sentenceAttempts: List.unmodifiable(sentenceAttempts),
      customSentencePrompts: List.unmodifiable(customSentencePrompts),
      articleProgress: List.unmodifiable(articleProgress),
    );
  }

  LearningStateData withSentencePromptSaved(LearningSentencePromptData prompt) {
    if (customSentencePrompts.any((item) => item.id == prompt.id)) return this;
    return LearningStateData(
      sets: sets,
      items: items,
      reviews: reviews,
      session: session,
      pronunciationPractices: pronunciationPractices,
      sentenceAttempts: sentenceAttempts,
      customSentencePrompts: List.unmodifiable([
        ...customSentencePrompts,
        prompt,
      ]),
      articleProgress: articleProgress,
    );
  }

  LearningStateData withSentenceAttemptSaved(
    LearningSentenceAttemptData attempt,
  ) {
    if (sentenceAttempts.any((item) => item.id == attempt.id)) return this;
    return LearningStateData(
      sets: sets,
      items: items,
      reviews: reviews,
      session: session,
      pronunciationPractices: pronunciationPractices,
      sentenceAttempts: List.unmodifiable([...sentenceAttempts, attempt]),
      customSentencePrompts: customSentencePrompts,
      articleProgress: articleProgress,
    );
  }
}

List<Map<String, dynamic>> _optionalMapList(Object? raw, String label) {
  if (raw == null) return const [];
  return _mapList(raw, label);
}

abstract interface class LearningStore {
  Future<LearningStateData?> read();

  Future<void> write(LearningStateData state);

  Future<void> clear();
}

class MemoryLearningStore implements LearningStore {
  LearningStateData? _state;

  @override
  Future<LearningStateData?> read() async {
    final state = _state;
    return state == null ? null : LearningStateData.fromJson(state.toJson());
  }

  @override
  Future<void> write(LearningStateData state) async {
    _state = LearningStateData.fromJson(state.toJson());
  }

  @override
  Future<void> clear() async {
    _state = null;
  }
}

typedef LearningFileCommit = Future<void> Function(
  File staged,
  File destination,
);

class FileLearningStore implements LearningStore {
  FileLearningStore(this.file, {LearningFileCommit? commit})
    : _commit = commit ?? _atomicReplace,
      _fileWrites = _fileQueues.putIfAbsent(
        _pathKey(file),
        _LearningStoreWriteQueue.new,
      ),
      _repositoryTransactions = _repositoryQueues.putIfAbsent(
        _pathKey(file),
        _LearningStoreWriteQueue.new,
      );

  // This is a corrupted-file/parser safety bound, not a learning-item quota.
  static const _maxFileBytes = 64 * 1024 * 1024;
  static final Map<String, _LearningStoreWriteQueue> _fileQueues = {};
  static final Map<String, _LearningStoreWriteQueue> _repositoryQueues = {};

  final File file;
  final LearningFileCommit _commit;
  final _LearningStoreWriteQueue _fileWrites;
  final _LearningStoreWriteQueue _repositoryTransactions;

  static String _pathKey(File file) {
    // File paths are case-insensitive on Windows. Stores with the same
    // normalized absolute path string therefore share one write queue.
    final path = file.absolute.path.replaceAll('\\', '/');
    final String prefix;
    final String remaining;
    if (path.startsWith('//')) {
      prefix = '//';
      remaining = path.substring(2);
    } else if (RegExp(r'^[A-Za-z]:/').hasMatch(path)) {
      prefix = path.substring(0, 3);
      remaining = path.substring(3);
    } else {
      prefix = path.startsWith('/') ? '/' : '';
      remaining = prefix.isEmpty ? path : path.substring(1);
    }

    final segments = <String>[];
    for (final segment in remaining.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty && segments.last != '..') {
          segments.removeLast();
        } else if (prefix.isEmpty) {
          segments.add(segment);
        }
        continue;
      }
      segments.add(segment);
    }
    final normalized = '$prefix${segments.join('/')}';
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  @override
  Future<LearningStateData?> read() async {
    if (!await file.exists()) return null;
    if (await file.length() > _maxFileBytes) {
      throw const FormatException('学习资料文件过大，原文件已保留。');
    }
    final dynamic raw;
    try {
      raw = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      throw FormatException('学习资料读取失败，原文件已保留。', error);
    }
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('学习资料格式无效，原文件已保留。');
    }
    try {
      return LearningStateData.fromJson(raw);
    } on FormatException catch (error) {
      throw FormatException('学习资料读取失败，原文件已保留。', error);
    }
  }

  @override
  Future<void> write(LearningStateData state) =>
      _fileWrites.run(() => _write(state));

  Future<void> _write(LearningStateData state) async {
    final validated = LearningStateData.fromJson(state.toJson());
    final contents = jsonEncode(validated.toJson());
    if (utf8.encode(contents).length > _maxFileBytes) {
      throw const FormatException('学习资料文件过大，未写入。');
    }
    await file.parent.create(recursive: true);
    final token =
        '$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${identityHashCode(this)}';
    final staged = File('${file.path}.$token.pending');
    final backupStage = File('${file.path}.$token.backup.pending');
    var stagedCreated = false;
    var backupStageCreated = false;
    Object? operationError;
    StackTrace? operationStack;
    Object? cleanupError;
    StackTrace? cleanupStack;
    try {
      await staged.create(exclusive: true);
      stagedCreated = true;
      await staged.writeAsString(contents, flush: true);
      if (await file.exists()) {
        // Refuse to replace a corrupt or unreadable profile. Preserve an exact
        // previous snapshot before committing the staged replacement.
        await read();
        await backupStage.create(exclusive: true);
        backupStageCreated = true;
        await backupStage.writeAsBytes(await file.readAsBytes(), flush: true);
        await _commit(backupStage, File('${file.path}.backup'));
      }
      await _commit(staged, file);
    } on Object catch (error, stackTrace) {
      operationError = error;
      operationStack = stackTrace;
    } finally {
      if (stagedCreated) {
        try {
          if (await staged.exists()) await staged.delete();
        } on Object catch (error, stackTrace) {
          cleanupError ??= error;
          cleanupStack ??= stackTrace;
        }
      }
      if (backupStageCreated) {
        try {
          if (await backupStage.exists()) await backupStage.delete();
        } on Object catch (error, stackTrace) {
          cleanupError ??= error;
          cleanupStack ??= stackTrace;
        }
      }
    }
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, operationStack!);
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStack!);
    }
  }

  @override
  Future<void> clear() =>
      _repositoryTransactions.run(() => _fileWrites.run(_clear));

  Future<void> _clear() async {
    for (final target in [file, File('${file.path}.backup')]) {
      if (await target.exists()) await target.delete();
    }
  }

  static Future<void> _atomicReplace(File staged, File destination) async {
    if (!Platform.isWindows) {
      await staged.rename(destination.path);
      return;
    }
    final move = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final from = staged.path.toNativeUtf16();
    final to = destination.path.toNativeUtf16();
    try {
      // REPLACE_EXISTING | WRITE_THROUGH. A failed move leaves the current
      // profile untouched and the staged file is cleaned up by write().
      if (move(from, to, 9) == 0) {
        throw FileSystemException(
          'Atomic learning profile replacement failed',
          destination.path,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }
}

class LearningScreenshotWordAddResult {
  const LearningScreenshotWordAddResult({
    required this.state,
    required this.added,
  });

  final LearningStateData state;
  final bool added;

  bool get alreadyExists => !added;
}

/// Every repository using the same store must serialize its whole read-modify-
/// write operation, including review and collection updates.
class _LearningStoreWriteQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}

class LearningRepository {
  LearningRepository(this.store, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final LearningStore store;
  final DateTime Function() clock;
  static final _storeQueues = Expando<_LearningStoreWriteQueue>();
  late final _LearningStoreWriteQueue _writes = store is FileLearningStore
      ? (store as FileLearningStore)._repositoryTransactions
      : _storeQueues[store] ??= _LearningStoreWriteQueue();

  Future<LearningStateData> load() => _writes.run(_loaded);

  // Read current persisted data inside the queue. Other repositories and store
  // resets must never be replaced by a previously cached page snapshot.
  Future<LearningStateData> _loaded() async =>
      await store.read() ?? const LearningStateData.empty();

  Future<LearningStateData> ensureSet(
    LearningSetData definition,
    Iterable<String> words, {
    DateTime? now,
  }) => _writes.run(() => _ensureSet(definition, words, now: now));

  Future<LearningStateData> _ensureSet(
    LearningSetData definition,
    Iterable<String> words, {
    DateTime? now,
  }) async {
    final current = await _loaded();
    final moment = now ?? clock();
    final timestamp = moment.toIso8601String();
    final existingSet = current.sets
        .where((set) => set.id == definition.id)
        .firstOrNull;
    final set = existingSet == null
        ? definition.copyWith(createdAt: timestamp, updatedAt: timestamp)
        : existingSet.copyWith(
            title: definition.title,
            description: definition.description,
            sourceId: definition.sourceId,
            level: definition.level,
            language: definition.language,
            unit: definition.unit,
            tags: definition.tags,
            isSystem: definition.isSystem,
            updatedAt: timestamp,
          );
    final knownIds = current.items.map((item) => item.id).toSet();
    final additions = <LearningItemData>[];
    final normalizedWords =
        words
            .map(normalizeLearningWord)
            .where((word) => word.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    for (final word in normalizedWords) {
      final id = _itemId(definition.id, word);
      if (knownIds.contains(id)) continue;
      additions.add(
        LearningItemData(
          id: id,
          setId: definition.id,
          word: word,
          dueDate: learningDateKey(moment),
          stage: 0,
          reviewCount: 0,
          correctCount: 0,
          againCount: 0,
          lastReviewedAt: null,
          addedAt: timestamp,
          suspended: false,
        ),
      );
    }
    final sets = [
      for (final item in current.sets) item.id == set.id ? set : item,
      if (existingSet == null) set,
    ];
    final next = LearningStateData(
      sets: sets,
      items: [...current.items, ...additions],
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  }

  Future<LearningStateData> ensureDefaultSet(
    Iterable<String> words, {
    String setId = learningDefaultSetId,
    DateTime? now,
  }) => _writes.run(() => _ensureDefaultSet(words, setId: setId, now: now));

  Future<LearningStateData> _ensureDefaultSet(
    Iterable<String> words, {
    String setId = learningDefaultSetId,
    DateTime? now,
  }) => _ensureSet(
    LearningSetData(
      id: setId,
      title: setId == learningDefaultSetId ? '译学基础词书' : setId,
      description: '由本地词典条目驱动的学习集合',
      sourceId: 'yixue-basic',
      dailyNewLimit: 10,
      dailyReviewLimit: 30,
      createdAt: (now ?? clock()).toIso8601String(),
      updatedAt: (now ?? clock()).toIso8601String(),
      level: setId == learningDefaultSetId ? 'all' : 'custom',
      language: 'en',
      tags: const [],
      isSystem: setId == learningDefaultSetId,
    ),
    words,
    now: now,
  );

  Future<LearningScreenshotWordAddResult> addScreenshotWord({
    required String word,
    required String sourceContext,
    required String sourceTranslation,
    required String sourceHistoryId,
    String? userMeaning,
    String? dictionaryMeaning,
    DateTime? now,
  }) => _writes.run(
    () => _addScreenshotWord(
      word: word,
      sourceContext: sourceContext,
      sourceTranslation: sourceTranslation,
      sourceHistoryId: sourceHistoryId,
      userMeaning: userMeaning,
      dictionaryMeaning: dictionaryMeaning,
      now: now,
    ),
  );

  Future<LearningScreenshotWordAddResult> _addScreenshotWord({
    required String word,
    required String sourceContext,
    required String sourceTranslation,
    required String sourceHistoryId,
    String? userMeaning,
    String? dictionaryMeaning,
    DateTime? now,
  }) async {
    final normalized = normalizeLearningWord(word);
    if (normalized.length > 100 ||
        !RegExp(r"^[a-z]+(?:['’\-][a-z]+)*$").hasMatch(normalized)) {
      throw ArgumentError.value(word, 'word', '必须是单个英文词');
    }
    final context = _boundedText(sourceContext, '来源原文上下文', maxLength: 100000);
    final translation = _boundedText(
      sourceTranslation,
      '来源文章译文',
      maxLength: 100000,
    );
    final historyId = _text(sourceHistoryId, '来源历史 ID', maxLength: 240);
    final current = await _loaded();
    final setId = learningScreenshotWordsSetId;
    final itemId = _itemId(setId, normalized);
    final existing = current.items
        .where(
          (item) =>
              item.setId == setId &&
              (item.id == itemId ||
                  normalizeLearningWord(item.word) == normalized),
        )
        .firstOrNull;
    if (existing != null) {
      return LearningScreenshotWordAddResult(state: current, added: false);
    }

    final moment = now ?? clock();
    final timestamp = moment.toIso8601String();
    final existingSet = current.sets
        .where((set) => set.id == setId)
        .firstOrNull;
    final setDefinition = LearningSetData(
      id: setId,
      title: learningScreenshotWordsSetTitle,
      description: '从截图翻译中收集并复习的单词。',
      sourceId: 'screenshot-translation',
      dailyNewLimit: 10,
      dailyReviewLimit: 30,
      createdAt: timestamp,
      updatedAt: timestamp,
      level: 'screenshot',
      language: 'en',
      unit: '',
      tags: const ['screenshot'],
      isSystem: true,
    );
    final set = existingSet == null
        ? setDefinition
        : existingSet.copyWith(
            title: setDefinition.title,
            description: setDefinition.description,
            sourceId: setDefinition.sourceId,
            dailyNewLimit: setDefinition.dailyNewLimit,
            dailyReviewLimit: setDefinition.dailyReviewLimit,
            updatedAt: timestamp,
            level: setDefinition.level,
            language: setDefinition.language,
            unit: setDefinition.unit,
            tags: setDefinition.tags,
            isSystem: setDefinition.isSystem,
          );
    final normalizedDictionaryMeaning = dictionaryMeaning?.trim();
    final normalizedUserMeaning = userMeaning?.trim();
    final meaning = normalizedDictionaryMeaning?.isNotEmpty == true
        ? normalizedDictionaryMeaning
        : normalizedUserMeaning?.isNotEmpty == true
        ? normalizedUserMeaning
        : null;
    final meaningSource = normalizedDictionaryMeaning?.isNotEmpty == true
        ? 'dictionary'
        : normalizedUserMeaning?.isNotEmpty == true
        ? 'user'
        : null;
    final item = LearningItemData(
      id: itemId,
      setId: setId,
      word: normalized,
      dueDate: learningDateKey(moment),
      stage: 0,
      reviewCount: 0,
      correctCount: 0,
      againCount: 0,
      lastReviewedAt: null,
      addedAt: timestamp,
      suspended: false,
      meaning: meaning,
      meaningSource: meaningSource,
      sourceContext: context,
      sourceTranslation: translation,
      sourceHistoryId: historyId,
    );
    final next = LearningStateData(
      sets: [
        for (final currentSet in current.sets)
          if (currentSet.id == setId) set else currentSet,
        if (existingSet == null) set,
      ],
      items: [...current.items, item],
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return LearningScreenshotWordAddResult(state: next, added: true);
  }

  /// Saves a learner-confirmed meaning for an item from the screenshot set.
  ///
  /// A dictionary-provided meaning remains authoritative and ordinary
  /// vocabulary items cannot be changed through this screenshot-only path.
  Future<LearningStateData> saveScreenshotWordMeaning({
    required String itemId,
    required String meaning,
    DateTime? now,
  }) => _writes.run(
    () =>
        _saveScreenshotWordMeaning(itemId: itemId, meaning: meaning, now: now),
  );

  Future<LearningStateData> _saveScreenshotWordMeaning({
    required String itemId,
    required String meaning,
    DateTime? now,
  }) async {
    final normalizedMeaning = _text(meaning, '学习词义', maxLength: 2000).trim();
    final current = await _loaded();
    final item = current.items
        .where((candidate) => candidate.id == itemId)
        .firstOrNull;
    if (item == null || item.setId != learningScreenshotWordsSetId) {
      throw StateError('只能编辑截屏生词的词义');
    }
    if (item.meaningSource == 'dictionary' &&
        (item.meaning?.trim().isNotEmpty ?? false)) {
      throw StateError('词典释义优先保留，未覆盖原释义');
    }
    if (item.meaning == normalizedMeaning && item.meaningSource == 'user') {
      return current;
    }
    final timestamp = (now ?? clock()).toIso8601String();
    final next = LearningStateData(
      sets: [
        for (final set in current.sets)
          set.id == item.setId ? set.copyWith(updatedAt: timestamp) : set,
      ],
      items: [
        for (final candidate in current.items)
          candidate.id == item.id
              ? candidate.copyWith(
                  meaning: normalizedMeaning,
                  meaningSource: 'user',
                )
              : candidate,
      ],
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  }

  /// Adds a word to, or suspends it from, a learning set.
  ///
  /// The dictionary and the learning list are intentionally separate data
  /// concerns. This method is the small bridge used by the quick-translation
  /// panel so an explicit user action can opt a word into the local queue
  /// without coupling that panel to the learning page UI.
  Future<LearningStateData> setWordEnabled(
    String word, {
    required bool enabled,
    String setId = learningDefaultSetId,
    DateTime? now,
  }) => _writes.run(() async {
    final normalized = normalizeLearningWord(word);
    if (normalized.isEmpty) return _loaded();
    final current = await _loaded();
    final itemId = _itemId(setId, normalized);
    final existing = current.items
        .where((item) => item.id == itemId)
        .firstOrNull;
    if (existing == null) {
      if (!enabled) return current;
      return _ensureDefaultSet([normalized], setId: setId, now: now);
    }
    final nextSuspended = !enabled;
    if (existing.suspended == nextSuspended) return current;
    final timestamp = (now ?? clock()).toIso8601String();
    final next = LearningStateData(
      sets: [
        for (final set in current.sets)
          set.id == setId ? set.copyWith(updatedAt: timestamp) : set,
      ],
      items: [
        for (final item in current.items)
          item.id == itemId ? item.copyWith(suspended: nextSuspended) : item,
      ],
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  });

  Future<LearningStateData> startSession({
    required String setId,
    required LearningPromptMode mode,
    int? newLimit,
    int? reviewLimit,
    DateTime? now,
  }) => _writes.run(() async {
    final current = await _loaded();
    final active = current.session;
    if (active != null && active.currentIndex < active.queueItemIds.length) {
      return current;
    }
    final set = current.sets.where((item) => item.id == setId).firstOrNull;
    if (set == null) throw StateError('学习集合不存在：$setId');
    final moment = now ?? clock();
    final today = learningDateKey(moment);
    final due =
        current.items
            .where(
              (item) =>
                  item.setId == setId &&
                  !item.suspended &&
                  item.dueDate.compareTo(today) <= 0,
            )
            .toList()
          ..sort(_compareItems);
    final reviewed = due
        .where((item) => item.reviewCount > 0)
        .take((reviewLimit ?? set.dailyReviewLimit).clamp(0, 1000));
    final fresh = due
        .where((item) => item.reviewCount == 0)
        .take((newLimit ?? set.dailyNewLimit).clamp(0, 500));
    final queue = [...reviewed, ...fresh].map((item) => item.id).toList();
    if (queue.isEmpty) {
      if (current.session != null) {
        final cleared = LearningStateData(
          sets: current.sets,
          items: current.items,
          reviews: current.reviews,
          session: null,
          pronunciationPractices: current.pronunciationPractices,
          sentenceAttempts: current.sentenceAttempts,
          customSentencePrompts: current.customSentencePrompts,
          articleProgress: current.articleProgress,
        );
        await _save(cleared);
        return cleared;
      }
      return current;
    }
    final timestamp = moment.toIso8601String();
    final session = LearningSessionData(
      id: 'learning-session-${moment.microsecondsSinceEpoch}',
      setId: setId,
      mode: mode,
      queueItemIds: List.unmodifiable(queue),
      currentIndex: 0,
      completedCount: 0,
      currentItemId: queue.first,
      startedAt: timestamp,
      updatedAt: timestamp,
      paused: false,
    );
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  });

  Future<LearningReviewData?> recordReview({
    required LearningReviewResult result,
    int elapsedSeconds = 0,
    DateTime? now,
  }) => _writes.run(() async {
    final current = await _loaded();
    final session = current.session;
    if (session == null ||
        session.currentIndex >= session.queueItemIds.length) {
      return null;
    }
    final itemId = session.queueItemIds[session.currentIndex];
    final item = current.items.where((value) => value.id == itemId).firstOrNull;
    if (item == null) return null;
    final moment = now ?? clock();
    final nextStage = switch (result) {
      LearningReviewResult.again => item.stage > 0 ? item.stage - 1 : 0,
      LearningReviewResult.fuzzy => item.stage,
      LearningReviewResult.mastered => (item.stage + 1).clamp(0, 8),
    };
    final intervalDays = switch (result) {
      LearningReviewResult.again => 0,
      LearningReviewResult.fuzzy => _intervalForStage(nextStage),
      LearningReviewResult.mastered => _intervalForStage(nextStage),
    };
    final reviewedAt = moment.toIso8601String();
    final nextDueDate = _dateAfter(learningDateKey(moment), intervalDays);
    final reviewCount = item.reviewCount + 1;
    final review = LearningReviewData(
      id: 'learning-review-${item.id}-$reviewCount-${moment.microsecondsSinceEpoch}',
      itemId: item.id,
      setId: item.setId,
      word: item.word,
      mode: session.mode,
      result: result,
      correct: result.correct,
      elapsedSeconds: elapsedSeconds.clamp(0, 86400),
      reviewedAt: reviewedAt,
      nextDueDate: nextDueDate,
    );
    final updatedItem = item.copyWith(
      dueDate: nextDueDate,
      stage: nextStage,
      reviewCount: reviewCount,
      correctCount:
          item.correctCount + (result == LearningReviewResult.mastered ? 1 : 0),
      againCount:
          item.againCount + (result == LearningReviewResult.again ? 1 : 0),
      lastReviewedAt: reviewedAt,
    );
    final nextIndex = session.currentIndex + 1;
    final nextSession = nextIndex >= session.queueItemIds.length
        ? null
        : session.copyWith(
            currentIndex: nextIndex,
            completedCount: session.completedCount + 1,
            currentItemId: session.queueItemIds[nextIndex],
            updatedAt: reviewedAt,
            paused: false,
          );
    final next = LearningStateData(
      sets: [
        for (final set in current.sets)
          set.id == item.setId ? set.copyWith(updatedAt: reviewedAt) : set,
      ],
      items: [
        for (final value in current.items)
          value.id == item.id ? updatedItem : value,
      ],
      reviews: [...current.reviews, review],
      session: nextSession,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return review;
  });

  Future<LearningStateData> pauseSession() => _setSessionPaused(true);

  Future<LearningStateData> resumeSession() => _setSessionPaused(false);

  Future<LearningStateData> _setSessionPaused(bool paused) =>
      _writes.run(() async {
        final current = await _loaded();
        final session = current.session;
        if (session == null) return current;
        final updated = session.copyWith(
          updatedAt: clock().toIso8601String(),
          paused: paused,
        );
        final next = LearningStateData(
          sets: current.sets,
          items: current.items,
          reviews: current.reviews,
          session: updated,
          pronunciationPractices: current.pronunciationPractices,
          sentenceAttempts: current.sentenceAttempts,
          customSentencePrompts: current.customSentencePrompts,
          articleProgress: current.articleProgress,
        );
        await _save(next);
        return next;
      });

  Future<LearningStateData> endSession() => _writes.run(() async {
    final current = await _loaded();
    if (current.session == null) return current;
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: null,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  });

  Future<LearningPronunciationPracticeData> recordPronunciationPractice({
    required String setId,
    required String itemId,
    required String word,
    required LearningPronunciationResult result,
    int elapsedSeconds = 0,
    DateTime? now,
  }) => _writes.run(() async {
    final current = await _loaded();
    if (!current.sets.any((set) => set.id == setId)) {
      throw StateError('学习集合不存在：$setId');
    }
    final moment = now ?? clock();
    final practice = LearningPronunciationPracticeData(
      id: 'pronunciation-${moment.microsecondsSinceEpoch}',
      itemId: _text(itemId, '发音练习条目 ID', maxLength: 300),
      setId: setId,
      word: _text(normalizeLearningWord(word), '发音练习单词', maxLength: 300),
      result: result,
      elapsedSeconds: elapsedSeconds.clamp(0, 86400),
      practicedAt: moment.toIso8601String(),
    );
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: [...current.pronunciationPractices, practice],
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return practice;
  });

  Future<LearningSentencePromptData> saveCustomSentencePrompt({
    required String title,
    required String chineseText,
    required String englishText,
    LearningSentencePromptOrigin origin =
        LearningSentencePromptOrigin.userCreated,
    String? scenario,
    int? difficulty,
    DateTime? now,
  }) => _writes.run(() async {
    final current = await _loaded();
    final moment = now ?? clock();
    final timestamp = moment.toIso8601String();
    final baseId = 'custom-sentence-${moment.microsecondsSinceEpoch}';
    var id = baseId;
    var suffix = 2;
    final ids = current.customSentencePrompts
        .map((prompt) => prompt.id)
        .toSet();
    while (ids.contains(id)) {
      id = '$baseId-$suffix';
      suffix++;
    }
    final normalizedScenario = scenario?.trim();
    if (normalizedScenario != null &&
        (normalizedScenario.isEmpty || normalizedScenario.length > 80)) {
      throw const FormatException('句子练习场景无效');
    }
    if (difficulty != null && (difficulty < 1 || difficulty > 3)) {
      throw const FormatException('句子练习难度无效');
    }
    if (origin == LearningSentencePromptOrigin.aiGenerated &&
        ((normalizedScenario?.isEmpty ?? true) || difficulty == null)) {
      throw const FormatException('AI 句子练习元数据无效');
    }
    final prompt = LearningSentencePromptData(
      id: id,
      title: _text(title.trim(), '自建句子标题', maxLength: 300),
      chineseText: _text(chineseText.trim(), '自建句子中文', maxLength: 2000),
      englishText: _text(englishText.trim(), '自建句子英文', maxLength: 2000),
      createdAt: timestamp,
      origin: origin,
      scenario: normalizedScenario,
      difficulty: difficulty,
    );
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: [...current.customSentencePrompts, prompt],
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return prompt;
  });

  Future<LearningStateData> saveGeneratedSentencePrompts({
    required List<LearningSentenceExerciseData> exercises,
    required String scenario,
    required int difficulty,
    DateTime? now,
  }) => _writes.run(() async {
    if (!const {1, 3, 5, 10}.contains(exercises.length) ||
        scenario.trim().isEmpty ||
        scenario.trim().length > 80 ||
        difficulty < 1 ||
        difficulty > 3) {
      throw const FormatException('AI 句子练习元数据无效');
    }
    final current = await _loaded();
    final moment = now ?? clock();
    final timestamp = moment.toIso8601String();
    final existingIds = current.customSentencePrompts
        .map((prompt) => prompt.id)
        .toSet();
    String normalizedSentence(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    String pairKey(String chinese, String english) =>
        '${normalizedSentence(chinese)}\u0000${normalizedSentence(english)}';
    final existingPairs = current.customSentencePrompts
        .where(
          (prompt) =>
              prompt.origin == LearningSentencePromptOrigin.aiGenerated &&
              prompt.scenario == scenario.trim() &&
              prompt.difficulty == difficulty,
        )
        .map((prompt) => pairKey(prompt.chineseText, prompt.englishText))
        .toSet();
    final prompts = <LearningSentencePromptData>[];
    for (var index = 0; index < exercises.length; index++) {
      final exercise = exercises[index];
      if (!existingPairs.add(
        pairKey(exercise.chineseText, exercise.englishText),
      )) {
        continue;
      }
      final baseId = 'ai-sentence-${moment.microsecondsSinceEpoch}-$index';
      var id = baseId;
      var suffix = 2;
      while (existingIds.contains(id)) {
        id = '$baseId-$suffix';
        suffix++;
      }
      existingIds.add(id);
      prompts.add(
        LearningSentencePromptData(
          id: id,
          title: _text(exercise.title.trim(), 'AI 句子标题', maxLength: 100),
          chineseText: _text(
            exercise.chineseText.trim(),
            'AI 句子中文',
            maxLength: 500,
          ),
          englishText: _text(
            exercise.englishText.trim(),
            'AI 句子英文',
            maxLength: 500,
          ),
          createdAt: timestamp,
          origin: LearningSentencePromptOrigin.aiGenerated,
          scenario: scenario.trim(),
          difficulty: difficulty,
        ),
      );
    }
    if (prompts.isEmpty) return current;
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: [...current.customSentencePrompts, ...prompts],
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return next;
  });

  Future<LearningStateData> deleteCustomSentencePrompt(String id) =>
      _writes.run(() async {
        final current = await _loaded();
        if (!current.customSentencePrompts.any((prompt) => prompt.id == id)) {
          return current;
        }
        final next = LearningStateData(
          sets: current.sets,
          items: current.items,
          reviews: current.reviews,
          session: current.session,
          pronunciationPractices: current.pronunciationPractices,
          sentenceAttempts: current.sentenceAttempts,
          customSentencePrompts: [
            for (final prompt in current.customSentencePrompts)
              if (prompt.id != id) prompt,
          ],
          articleProgress: current.articleProgress,
        );
        await _save(next);
        return next;
      });

  Future<LearningSentenceAttemptData> recordSentenceAttempt({
    required String setId,
    required String word,
    required SentencePracticeMode mode,
    required String sourceText,
    required String translation,
    required String answer,
    required String expectedAnswer,
    required bool correct,
    required List<String> mistakes,
    int elapsedSeconds = 0,
    bool fromCustomPrompt = false,
    bool fromAiPrompt = false,
    DateTime? now,
  }) => _writes.run(() async {
    if (fromAiPrompt && !fromCustomPrompt) {
      throw const FormatException('AI 句子练习必须来自本地句子库');
    }
    final current = await _loaded();
    if (!current.sets.any((set) => set.id == setId)) {
      throw StateError('学习集合不存在：$setId');
    }
    final moment = now ?? clock();
    final attempt = LearningSentenceAttemptData(
      id: 'sentence-${moment.microsecondsSinceEpoch}',
      setId: setId,
      word: _text(normalizeLearningWord(word), '句子练习单词', maxLength: 300),
      mode: mode,
      sourceText: _text(sourceText, '句子原文', maxLength: 2000),
      translation: _text(translation, '句子译文', maxLength: 2000),
      answer: _boundedText(answer, '句子作答', maxLength: 2000),
      expectedAnswer: _text(expectedAnswer, '句子标准答案', maxLength: 2000),
      correct: correct,
      mistakes: List.unmodifiable(mistakes),
      elapsedSeconds: elapsedSeconds.clamp(0, 86400),
      attemptedAt: moment.toIso8601String(),
      fromCustomPrompt: fromCustomPrompt,
      fromAiPrompt: fromAiPrompt,
    );
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: [...current.sentenceAttempts, attempt],
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: current.articleProgress,
    );
    await _save(next);
    return attempt;
  });

  Future<LearningArticleProgressData> saveArticleProgress(
    LearningArticleProgressData progress,
  ) => _writes.run(() async {
    final current = await _loaded();
    final next = LearningStateData(
      sets: current.sets,
      items: current.items,
      reviews: current.reviews,
      session: current.session,
      pronunciationPractices: current.pronunciationPractices,
      sentenceAttempts: current.sentenceAttempts,
      customSentencePrompts: current.customSentencePrompts,
      articleProgress: [
        for (final item in current.articleProgress)
          if (item.articleId != progress.articleId) item,
        progress,
      ],
    );
    await _save(next);
    return progress;
  });

  Future<void> _save(LearningStateData state) async {
    await store.write(state);
  }

  static String _itemId(String setId, String word) =>
      setId == learningDefaultSetId ? word : '$setId::$word';

  static int _compareItems(LearningItemData left, LearningItemData right) {
    final due = left.dueDate.compareTo(right.dueDate);
    if (due != 0) return due;
    final added = left.addedAt.compareTo(right.addedAt);
    if (added != 0) return added;
    return left.id.compareTo(right.id);
  }

  static int _intervalForStage(int stage) => switch (stage) {
    0 => 1,
    1 => 1,
    2 => 2,
    3 => 4,
    4 => 7,
    5 => 14,
    6 => 30,
    7 => 60,
    _ => 90,
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
