import 'dictionary_service.dart';
import 'learning_workbench.dart';

/// A user-facing view over dictionary metadata.
///
/// A catalog item is intentionally derived from local dictionary fields. It
/// is not an assertion that the bundled data is an official textbook or exam
/// list. Empty sets remain visible so a later legal dictionary package can be
/// added without changing the learning page contract.
class LearningSetCatalogItem {
  const LearningSetCatalogItem({
    required this.id,
    required this.title,
    required this.description,
    required this.level,
    required this.words,
    required this.isSystem,
  });

  final String id;
  final String title;
  final String description;
  final String level;
  final List<String> words;
  final bool isSystem;

  int get availableCount => words.length;

  String get availabilityLabel =>
      availableCount == 0 ? '待补充合法词典数据' : '$availableCount 个本地词条可学习';

  LearningSetData definition(DateTime now) => LearningSetData(
    id: id,
    title: title,
    description: description,
    sourceId: switch (id) {
      learningDefaultSetId => 'yixue-basic',
      learningScreenshotWordsSetId => 'screenshot-translation',
      _ => 'dictionary-catalog',
    },
    dailyNewLimit: 10,
    dailyReviewLimit: 30,
    createdAt: now.toIso8601String(),
    updatedAt: now.toIso8601String(),
    level: level,
    language: 'en',
    unit: '',
    tags: [level],
    isSystem: isSystem,
  );
}

class LearningSetCatalog {
  const LearningSetCatalog._(this.items);

  final List<LearningSetCatalogItem> items;

  LearningSetCatalogItem? byId(String id) =>
      items.where((item) => item.id == id).firstOrNull;

  LearningSetCatalogItem get first => items.first;

  static LearningSetCatalog build(
    Iterable<DictionaryEntry> entries, {
    Iterable<String> favoriteWords = const [],
    LearningStateData? learningState,
  }) {
    final normalizedFavorites = favoriteWords
        .map(normalizeLearningWord)
        .where((word) => word.isNotEmpty)
        .toSet();
    final uniqueEntries = <String, DictionaryEntry>{};
    for (final entry in entries) {
      final word = normalizeLearningWord(entry.word);
      if (word.isNotEmpty) uniqueEntries[word] = entry;
    }

    final definitions = <_CatalogDefinition>[
      const _CatalogDefinition(
        id: learningDefaultSetId,
        title: '全部词汇',
        description: '当前本地词典中可用于学习的全部词条。',
        level: 'all',
        aliases: [],
      ),
      const _CatalogDefinition(
        id: 'foundation',
        title: '基础词汇',
        description: '适合入门、日常交流和建立基本词感。',
        level: 'foundation',
        aliases: ['foundation', 'basic', '基础', '入门'],
      ),
      const _CatalogDefinition(
        id: 'primary',
        title: '小学阶段',
        description: '按小学学习标签筛选；未提供教材授权时仅显示本地匹配词条。',
        level: 'primary',
        aliases: ['primary', 'elementary', '小学', '小学阶段'],
      ),
      const _CatalogDefinition(
        id: 'middle',
        title: '初中阶段',
        description: '按初中学习标签筛选，后续可接入合法教材单元。',
        level: 'middle',
        aliases: ['middle', 'junior', '初中', '初中阶段'],
      ),
      const _CatalogDefinition(
        id: 'high',
        title: '高中阶段',
        description: '按高中学习标签筛选，后续可接入合法教材单元。',
        level: 'high',
        aliases: ['high', 'senior', '高中', '高中阶段'],
      ),
      const _CatalogDefinition(
        id: 'cet4',
        title: '四级词汇',
        description: '按四级覆盖标记筛选，不等同于官方完整考试词表。',
        level: 'cet4',
        aliases: ['cet4', 'cet-4', 'college4', '四级', '英语四级'],
      ),
      const _CatalogDefinition(
        id: 'cet6',
        title: '六级词汇',
        description: '按六级覆盖标记筛选，不等同于官方完整考试词表。',
        level: 'cet6',
        aliases: ['cet6', 'cet-6', 'college6', '六级', '英语六级'],
      ),
      const _CatalogDefinition(
        id: 'graduate',
        title: '考研词汇',
        description: '按考研/学术覆盖标记筛选，来源状态会在词典中保留。',
        level: 'graduate',
        aliases: ['graduate', 'postgraduate', '考研', '研究生', '学术'],
      ),
      const _CatalogDefinition(
        id: 'doctoral',
        title: '考博与学术',
        description: '用于学术阅读和更高阶词汇扩展的本地筛选集合。',
        level: 'doctoral',
        aliases: ['doctoral', 'phd', '考博', '博士', '学术研究'],
      ),
      const _CatalogDefinition(
        id: 'social',
        title: '社会与工作',
        description: '面向日常沟通、职场表达和自定义工作词汇。',
        level: 'social',
        aliases: ['social', 'daily', 'work', '职场', '日常', '工作'],
      ),
      const _CatalogDefinition(
        id: 'favorites',
        title: '我的收藏',
        description: '从快速翻译和词典中收藏的词条，可直接进入复习。',
        level: 'favorites',
        aliases: [],
      ),
      const _CatalogDefinition(
        id: learningScreenshotWordsSetId,
        title: learningScreenshotWordsSetTitle,
        description: '从截屏翻译中收集的单词，可带着原文和译文上下文复习。',
        level: 'screenshot',
        aliases: [],
      ),
    ];

    final catalog = <LearningSetCatalogItem>[];
    for (final definition in definitions) {
      final List<String> words;
      if (definition.id == learningScreenshotWordsSetId) {
        words =
            (learningState?.items ?? const <LearningItemData>[])
                .where((item) => item.setId == learningScreenshotWordsSetId)
                .map((item) => normalizeLearningWord(item.word))
                .where((word) => word.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
      } else {
        words =
            uniqueEntries.values
                .where(
                  (entry) => definition.id == learningDefaultSetId
                      ? true
                      : definition.id == 'favorites'
                      ? normalizedFavorites.contains(
                          normalizeLearningWord(entry.word),
                        )
                      : _matches(entry, definition.aliases),
                )
                .map((entry) => normalizeLearningWord(entry.word))
                .toSet()
                .toList()
              ..sort();
      }
      catalog.add(
        LearningSetCatalogItem(
          id: definition.id,
          title: definition.title,
          description: definition.description,
          level: definition.level,
          words: List.unmodifiable(words),
          isSystem: true,
        ),
      );
    }
    return LearningSetCatalog._(List.unmodifiable(catalog));
  }

  static bool _matches(DictionaryEntry entry, List<String> aliases) {
    final searchable = <String>[
      ...entry.coverageBands,
      ...entry.learningTags,
      entry.source,
    ].map(_normalizeTag).where((value) => value.isNotEmpty).toSet();
    return aliases.map(_normalizeTag).any(searchable.contains);
  }
}

class _CatalogDefinition {
  const _CatalogDefinition({
    required this.id,
    required this.title,
    required this.description,
    required this.level,
    required this.aliases,
  });

  final String id;
  final String title;
  final String description;
  final String level;
  final List<String> aliases;
}

String _normalizeTag(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');

String normalizeSentenceAnswer(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'''[,.!?;:'"，。！？；：、“”‘’（）()\[\]{}…]'''), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

List<String> sentenceTokens(String value) => value
    .replaceAll(RegExp(r'''[,.!?;:'"，。！？；：、“”‘’（）()\[\]{}…]'''), ' ')
    .split(RegExp(r'\s+'))
    .where((token) => token.trim().isNotEmpty)
    .toList(growable: false);

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
