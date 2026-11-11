import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_cet_open_rich_examples_model.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_tracks.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/features/learning/open_example_attribution.dart';

class LearningVocabularyRangeView {
  const LearningVocabularyRangeView({
    required this.id,
    required this.group,
    required this.title,
    required this.detail,
    required this.count,
    required this.catalogId,
  });

  final String id;
  final String group;
  final String title;
  final String detail;
  final int count;
  final String? catalogId;
}

/// A range choice, followed by a separate dictionary detail or study page.
class LearningVocabularyWorkspace extends StatefulWidget {
  const LearningVocabularyWorkspace({
    required this.catalog,
    required this.selectedCatalogId,
    required this.ranges,
    required this.selectedRangeId,
    required this.onSelectRange,
    required this.selectedEntries,
    required this.selectedItems,
    required this.selectedMode,
    required this.onModeChanged,
    required this.dailyCount,
    required this.onDailyCountChanged,
    required this.onStart,
    required this.busy,
    required this.onSpeak,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.onOpenDictionary,
    super.key,
  });

  final LearningSetCatalog catalog;
  final String selectedCatalogId;
  final List<LearningVocabularyRangeView> ranges;
  final String selectedRangeId;
  final ValueChanged<LearningVocabularyRangeView> onSelectRange;
  final List<DictionaryEntry> selectedEntries;
  final List<LearningItemData> selectedItems;
  final LearningPromptMode selectedMode;
  final ValueChanged<LearningPromptMode> onModeChanged;
  final int dailyCount;
  final ValueChanged<int> onDailyCountChanged;
  final VoidCallback onStart;
  final bool busy;
  final Future<void> Function(String word)? onSpeak;
  final bool Function(String word) isFavorite;
  final Future<void> Function(String word) onToggleFavorite;
  final VoidCallback? onOpenDictionary;

  @override
  State<LearningVocabularyWorkspace> createState() =>
      _LearningVocabularyWorkspaceState();
}

class _LearningVocabularyWorkspaceState
    extends State<LearningVocabularyWorkspace> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';
  bool _showList = false;
  bool _showSettings = false;

  static const _stageIds = [
    'primary-all',
    'middle-all',
    'high-all',
    'cet4',
    'graduate',
    'oxford',
    'all',
    'screenshot-words',
  ];

  List<LearningVocabularyRangeView> get _stages => [
    for (final id in _stageIds)
      for (final range in widget.ranges)
        if (range.id ==
            (id == 'cet4' && widget.selectedRangeId == 'cet6' ? 'cet6' : id))
          range,
  ];

  LearningVocabularyRangeView? get _activeRange {
    final stages = _stages;
    if (stages.isEmpty) return null;
    return stages
            .where((range) => range.id == widget.selectedRangeId)
            .firstOrNull ??
        stages.first;
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    final next = _searchController.text.trim();
    if (next == _query || !mounted) return;
    setState(() => _query = next);
  }

  List<DictionaryEntry> _filteredEntries() {
    final query = _query.toLowerCase();
    if (query.isEmpty) return widget.selectedEntries;
    return widget.selectedEntries
        .where((entry) {
          final searchable = <String>[
            entry.word,
            entry.ipa,
            entry.partOfSpeech,
            ...entry.meanings,
            ...entry.variants,
            entry.example,
          ].join(' ').toLowerCase();
          return searchable.contains(query);
        })
        .toList(growable: false);
  }

  List<LearningItemData> _filteredScreenshotItems() {
    final query = _query.toLowerCase();
    final items = widget.selectedItems;
    if (query.isEmpty) return items;
    return items
        .where((item) {
          final searchable = [
            item.word,
            item.sourceContext ?? '',
            item.sourceTranslation ?? '',
            item.meaning ?? '',
          ].join(' ').toLowerCase();
          return searchable.contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.catalog.byId(widget.selectedCatalogId);
    final activeRange = _activeRange;
    final rangeHasWords =
        activeRange?.catalogId != null &&
        activeRange?.catalogId == widget.selectedCatalogId;
    final isScreenshotWords =
        rangeHasWords && selected?.id == learningScreenshotWordsSetId;
    final entries = rangeHasWords && !isScreenshotWords
        ? _filteredEntries()
        : <DictionaryEntry>[];
    final screenshotItems = isScreenshotWords
        ? _filteredScreenshotItems()
        : <LearningItemData>[];
    final totalCount = rangeHasWords
        ? isScreenshotWords
              ? widget.selectedItems.length
              : widget.selectedEntries.length
        : 0;
    final colors = Theme.of(context).colorScheme;

    return Center(
      key: const ValueKey('learning-start-workspace'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _WorkspaceIntro(
                    icon: Icons.layers_rounded,
                    title: '词汇循环',
                    detail: '选择词库，开启专属的词汇循环。',
                  ),
                ),
                if (!_showList && !_showSettings) ...[
                  TextButton(
                    key: const ValueKey('learning-vocabulary-open-list'),
                    onPressed: activeRange?.catalogId != null && !rangeHasWords
                        ? null
                        : () => setState(() => _showList = true),
                    child: Text(
                      MediaQuery.sizeOf(context).width < 700
                          ? '词库详情 →'
                          : '查看词库详情 →',
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('learning-vocabulary-settings'),
                    tooltip: '学习设置',
                    onPressed: () => setState(() => _showSettings = true),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (_showList) ...[
              TextButton.icon(
                key: const ValueKey('learning-vocabulary-back-to-ranges'),
                onPressed: () => setState(() => _showList = false),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('返回词库选择'),
              ),
              const SizedBox(height: 12),
              _VocabularyListPanel(
                entries: entries,
                screenshotItems: screenshotItems,
                isScreenshotWords: isScreenshotWords,
                totalCount: totalCount,
                filteredCount: entries.length + screenshotItems.length,
                selectedTitle: rangeHasWords
                    ? selected?.title ?? '本地词典'
                    : activeRange?.title ?? '词库',
                searchController: _searchController,
                searchFocusNode: _searchFocusNode,
                onSpeak: widget.onSpeak,
                isFavorite: widget.isFavorite,
                onToggleFavorite: widget.onToggleFavorite,
              ),
            ] else if (_showSettings) ...[
              TextButton.icon(
                onPressed: () => setState(() => _showSettings = false),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('返回词库选择'),
              ),
              const SizedBox(height: 12),
              _LearningConfigStrip(
                selectedCatalogId: widget.selectedCatalogId,
                selected: rangeHasWords ? selected : null,
                selectedMode: widget.selectedMode,
                onCatalogChanged: (value) {
                  final range = widget.ranges
                      .where((item) => item.catalogId == value)
                      .firstOrNull;
                  if (range != null) widget.onSelectRange(range);
                },
                onModeChanged: widget.onModeChanged,
                dailyCount: widget.dailyCount,
                onDailyCountChanged: widget.onDailyCountChanged,
                busy: widget.busy,
                onOpenDictionary: widget.onOpenDictionary,
              ),
            ] else ...[
              _RangeDeck(
                ranges: _stages,
                selectedRangeId: activeRange?.id ?? '',
                onSelect: widget.onSelectRange,
              ),
              const SizedBox(height: 8),
              KeyedSubtree(
                key: const ValueKey('learning-vocabulary-preview'),
                child: _VocabularyPreview(
                  title: activeRange?.id == 'all'
                      ? '全部词汇'
                      : activeRange?.title ?? '词库',
                  entries: entries.take(3).toList(growable: false),
                  screenshotItems: isScreenshotWords
                      ? widget.selectedItems.take(3).toList(growable: false)
                      : const <LearningItemData>[],
                  totalCount: totalCount,
                  emptyMessage: isScreenshotWords
                      ? '从截屏翻译历史中选词后，可在这里开始复习'
                      : activeRange?.catalogId != null && !rangeHasWords
                      ? widget.busy
                            ? '正在切换词库…'
                            : '词库尚未就绪'
                      : '这个范围暂时没有可学习词条',
                  onSpeak: widget.onSpeak,
                  onOpenList: () => setState(() => _showList = true),
                ),
              ),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: const ValueKey('learning-vocabulary-start-cycle'),
                child: FilledButton.icon(
                  key: const ValueKey('learning-start'),
                  onPressed: widget.busy || totalCount == 0
                      ? null
                      : widget.onStart,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(widget.busy ? '准备中…' : '开始循环'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    backgroundColor: const Color(0xFF087C8B),
                    foregroundColor: colors.onPrimary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkspaceIntro extends StatelessWidget {
  const _WorkspaceIntro({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: colors.primary, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RangeDeck extends StatefulWidget {
  const _RangeDeck({
    required this.ranges,
    required this.selectedRangeId,
    required this.onSelect,
  });

  final List<LearningVocabularyRangeView> ranges;
  final String selectedRangeId;
  final ValueChanged<LearningVocabularyRangeView> onSelect;

  @override
  State<_RangeDeck> createState() => _RangeDeckState();
}

class _RangeDeckState extends State<_RangeDeck> {
  var _index = 0;

  @override
  void initState() {
    super.initState();
    _syncIndex();
  }

  @override
  void didUpdateWidget(covariant _RangeDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncIndex();
  }

  void _syncIndex() {
    if (widget.ranges.isEmpty) {
      _index = 0;
      return;
    }
    final selectedIndex = widget.ranges.indexWhere(
      (range) => range.id == widget.selectedRangeId,
    );
    if (selectedIndex >= 0) _index = selectedIndex;
    if (_index >= widget.ranges.length) _index = widget.ranges.length - 1;
  }

  LearningVocabularyRangeView get _current => widget.ranges[_index];

  int _distance(int index) {
    var distance = index - _index;
    final half = widget.ranges.length ~/ 2;
    if (distance > half) distance -= widget.ranges.length;
    if (distance < -half) distance += widget.ranges.length;
    return distance;
  }

  void _move(int amount) {
    if (widget.ranges.length < 2) return;
    setState(() {
      _index = (_index + amount) % widget.ranges.length;
      if (_index < 0) _index += widget.ranges.length;
    });
    widget.onSelect(_current);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (widget.ranges.isEmpty) {
      return _SurfacePanel(
        key: const ValueKey('learning-vocabulary-range-deck'),
        child: const Text('暂无可选择的学习范围。'),
      );
    }
    return Column(
      key: const ValueKey('learning-vocabulary-range-deck'),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final compact = width < 520;
            final cardWidth = compact ? 104.0 : 148.0;
            final step = compact ? (width - cardWidth) / 6 : 89.0;
            final ordered = List.generate(
              widget.ranges.length,
              (index) => index,
            )..sort((a, b) => _distance(b).abs().compareTo(_distance(a).abs()));
            return GestureDetector(
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity.abs() > 100) _move(velocity < 0 ? 1 : -1);
              },
              child: SizedBox(
                height: compact ? 174 : 190,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final index in ordered)
                      Positioned(
                        left: (width - cardWidth) / 2 + _distance(index) * step,
                        top: _distance(index).abs() * (compact ? 8 : 9),
                        width: cardWidth,
                        height:
                            (compact ? 158.0 : 180.0) -
                            _distance(index).abs() * (compact ? 7 : 8),
                        child: _DeckCard(
                          key: index == _index
                              ? const ValueKey(
                                  'learning-vocabulary-current-range',
                                )
                              : ValueKey(
                                  'learning-vocabulary-stage-${widget.ranges[index].id}',
                                ),
                          range: widget.ranges[index],
                          selected: index == _index,
                          onTap: () => widget.onSelect(widget.ranges[index]),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const ValueKey('learning-vocabulary-range-prev'),
              tooltip: '上一个词库',
              onPressed: () => _move(-1),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Text(
              '切换词库',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            IconButton(
              key: const ValueKey('learning-vocabulary-range-next'),
              tooltip: '下一个词库',
              onPressed: () => _move(1),
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({
    required this.range,
    required this.selected,
    this.onTap,
    super.key,
  });

  final LearningVocabularyRangeView range;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = switch (range.id) {
      'primary-all' => '小学',
      'middle-all' => '初中',
      'high-all' => '高中',
      'cet4' => '四六级',
      'cet6' => '四六级',
      'graduate' => '考研',
      'oxford' => '牛津',
      'all' => '全部',
      _ => range.title,
    };
    return Material(
      color: selected ? const Color(0xFFE4F4FF) : const Color(0xFFD9ECFB),
      elevation: selected ? 7 : 2,
      shadowColor: colors.primary.withValues(alpha: .18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colors.primary.withValues(alpha: selected ? .28 : .08),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style:
                    (selected
                            ? Theme.of(context).textTheme.titleLarge
                            : Theme.of(context).textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                range.count > 0 ? '${range.count} 词' : '待补充',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (selected) ...[
                const Spacer(),
                Icon(Icons.menu_book_rounded, color: colors.primary, size: 36),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VocabularyPreview extends StatelessWidget {
  const _VocabularyPreview({
    required this.title,
    required this.entries,
    required this.screenshotItems,
    required this.totalCount,
    required this.emptyMessage,
    required this.onSpeak,
    required this.onOpenList,
  });

  final String title;
  final List<DictionaryEntry> entries;
  final List<LearningItemData> screenshotItems;
  final int totalCount;
  final String emptyMessage;
  final Future<void> Function(String word)? onSpeak;
  final VoidCallback onOpenList;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _SurfacePanel(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '词库预览 · $title',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(onPressed: onOpenList, child: const Text('查看全部 →')),
            ],
          ),
          Text(
            totalCount > 0
                ? screenshotItems.isNotEmpty
                      ? '共 $totalCount 词 · 可结合截图原文与译文复习'
                      : '共 $totalCount 词 · 释义与发音'
                : emptyMessage,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '朗读 ${entry.word}',
                    onPressed: onSpeak == null
                        ? null
                        : () => onSpeak!(entry.word),
                    icon: Icon(
                      Icons.volume_up_rounded,
                      color: colors.primary,
                      size: 19,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 34,
                      height: 34,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Text(
                      entry.word,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      entry.ipa,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      entry.meanings.join('；'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          for (final item in screenshotItems)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Icon(
                    Icons.document_scanner_outlined,
                    color: colors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.word,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if ((item.sourceContext?.trim().isNotEmpty ?? false))
                          Text(
                            item.sourceContext!.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _VocabularyListPanel extends StatelessWidget {
  const _VocabularyListPanel({
    required this.entries,
    required this.screenshotItems,
    required this.isScreenshotWords,
    required this.totalCount,
    required this.filteredCount,
    required this.selectedTitle,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSpeak,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final List<DictionaryEntry> entries;
  final List<LearningItemData> screenshotItems;
  final bool isScreenshotWords;
  final int totalCount;
  final int filteredCount;
  final String selectedTitle;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final Future<void> Function(String word)? onSpeak;
  final bool Function(String word) isFavorite;
  final Future<void> Function(String word) onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _SurfacePanel(
      key: const ValueKey('learning-vocabulary-list-panel'),
      padding: const EdgeInsets.fromLTRB(20, 17, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '词库内容',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$selectedTitle · $totalCount 个词条',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.search_rounded, color: colors.primary),
            ],
          ),
          const SizedBox(height: 13),
          TextField(
            key: const ValueKey('learning-vocabulary-search'),
            controller: searchController,
            focusNode: searchFocusNode,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: isScreenshotWords
                  ? '搜索单词、截图原文、译文或已填释义'
                  : '搜索单词、中文释义、音标或例句',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: searchController.clear,
                      icon: const Icon(Icons.close_rounded),
                    ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                searchController.text.trim().isEmpty ? '完整列表' : '搜索结果',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '$filteredCount 个',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (totalCount == 0 && isScreenshotWords)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 45),
              child: Center(
                child: Text(
                  '还没有从截屏翻译中添加单词',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            )
          else if (totalCount == 0)
            _EmptyDictionaryState(colors: colors)
          else if (entries.isEmpty && screenshotItems.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 45),
              child: Center(
                child: Text(
                  '没有找到匹配词条',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            )
          else
            SizedBox(
              height: 520,
              child: ListView.separated(
                key: const ValueKey('learning-vocabulary-entry-list'),
                padding: EdgeInsets.zero,
                itemCount: entries.length + screenshotItems.length,
                separatorBuilder: (_, _) => const SizedBox(height: 7),
                itemBuilder: (context, index) {
                  if (index >= entries.length) {
                    final item = screenshotItems[index - entries.length];
                    return _ScreenshotVocabularyEntryTile(
                      item: item,
                      onSpeak: onSpeak,
                    );
                  }
                  final entry = entries[index];
                  return _VocabularyEntryTile(
                    entry: entry,
                    onSpeak: onSpeak,
                    favorite: isFavorite(entry.word),
                    onToggleFavorite: () => onToggleFavorite(entry.word),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyDictionaryState extends StatelessWidget {
  const _EmptyDictionaryState({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 35, 8, 35),
    child: Column(
      children: [
        Icon(
          Icons.menu_book_outlined,
          size: 35,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(height: 10),
        Text(
          '这个范围还没有可展示的合法词表',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Text(
          '可以到内容库导入你有权使用的词典包。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _ScreenshotVocabularyEntryTile extends StatelessWidget {
  const _ScreenshotVocabularyEntryTile({
    required this.item,
    required this.onSpeak,
  });

  final LearningItemData item;
  final Future<void> Function(String word)? onSpeak;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('learning-screenshot-word-${item.word}'),
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.document_scanner_outlined, color: colors.primary),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.word,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                if ((item.sourceContext?.trim().isNotEmpty ?? false))
                  Text(
                    item.sourceContext!.replaceAll('\n', ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '朗读 ${item.word}',
            onPressed: onSpeak == null ? null : () => onSpeak!(item.word),
            icon: const Icon(Icons.volume_up_rounded),
          ),
        ],
      ),
    );
  }
}

class _LearningConfigStrip extends StatelessWidget {
  const _LearningConfigStrip({
    required this.selectedCatalogId,
    required this.selected,
    required this.selectedMode,
    required this.onCatalogChanged,
    required this.onModeChanged,
    required this.dailyCount,
    required this.onDailyCountChanged,
    required this.busy,
    this.onOpenDictionary,
  });

  final String selectedCatalogId;
  final LearningSetCatalogItem? selected;
  final LearningPromptMode selectedMode;
  final ValueChanged<String?> onCatalogChanged;
  final ValueChanged<LearningPromptMode> onModeChanged;
  final int dailyCount;
  final ValueChanged<int> onDailyCountChanged;
  final bool busy;
  final VoidCallback? onOpenDictionary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _SurfacePanel(
      key: const ValueKey('learning-vocabulary-config'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, color: colors.primary, size: 21),
              const SizedBox(width: 8),
              Text(
                '学习配置',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (onOpenDictionary != null)
                TextButton.icon(
                  key: const ValueKey('learning-open-dictionary'),
                  onPressed: onOpenDictionary,
                  icon: const Icon(Icons.library_books_outlined, size: 18),
                  label: const Text('内容库'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final mode = Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final item in LearningPromptMode.values)
                    ChoiceChip(
                      key: ValueKey('learning-vocabulary-mode-${item.name}'),
                      label: Text(item.label),
                      selected: selectedMode == item,
                      onSelected: busy ? null : (_) => onModeChanged(item),
                    ),
                ],
              );
              final count = Wrap(
                spacing: 7,
                children: [
                  for (final value in [10, 20, 30, 50])
                    ChoiceChip(
                      label: Text('$value 个'),
                      selected: dailyCount == value,
                      onSelected: busy
                          ? null
                          : (_) => onDailyCountChanged(value),
                    ),
                ],
              );
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selectedCatalogId == 'cet4' ||
                      selectedCatalogId == 'cet6') ...[
                    const Text('四六级词库'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final level in const ['cet4', 'cet6'])
                          ChoiceChip(
                            label: Text(level == 'cet4' ? '英语四级' : '英语六级'),
                            selected: selectedCatalogId == level,
                            onSelected: busy
                                ? null
                                : (_) => onCatalogChanged(level),
                          ),
                      ],
                    ),
                  ],
                  if (selected != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      selected!.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '今日题型',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  mode,
                  const SizedBox(height: 11),
                  Row(
                    children: [
                      Text(
                        '今日新词',
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 10),
                      count,
                    ],
                  ),
                ],
              );
              return content;
            },
          ),
          const SizedBox(height: 12),
          Text(
            '设置完成后返回词库选择，再开始对应范围的学习。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({required this.child, this.padding, super.key});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .8)),
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

class _VocabularyQualityBadge extends StatelessWidget {
  const _VocabularyQualityBadge({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = entry.qualityStatus;
    final reviewed = status == 'published' ||
        status == 'published_with_assistant_enrichment' ||
        status == 'published_with_candidate_enrichment';
    final assistantChecked =
        status.startsWith('assistant_verified') ||
        status == 'published_with_assistant_enrichment';
    final label = switch (status) {
      'published' => '译学已审校',
      'assistant_verified' => 'AI 来源已核对',
      'assistant_verified_with_gaps' => 'AI 来源已核对 · 有字段待补',
      'published_with_assistant_enrichment' => '基础已审校 · AI 来源已核对',
      'published_with_candidate_enrichment' => '基础已审校 · 候选待核对',
      _ => '来源内容待核对',
    };
    final background = reviewed
        ? colors.primaryContainer
        : assistantChecked
        ? colors.tertiaryContainer
        : colors.surfaceContainerHighest;
    final foreground = reviewed
        ? colors.onPrimaryContainer
        : assistantChecked
        ? colors.onTertiaryContainer
        : colors.onSurfaceVariant;
    final icon = reviewed
        ? Icons.verified_outlined
        : assistantChecked
        ? Icons.fact_check_outlined
        : Icons.info_outline;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _VocabularyEntryTile extends StatelessWidget {
  const _VocabularyEntryTile({
    required this.entry,
    required this.onSpeak,
    required this.favorite,
    required this.onToggleFavorite,
  });

  final DictionaryEntry entry;
  final Future<void> Function(String word)? onSpeak;
  final bool favorite;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExpansionTile(
      key: ValueKey('learning-vocabulary-entry-${entry.word}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
      ),
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 5,
        children: [
          Text(
            entry.word,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          _VocabularyQualityBadge(entry: entry),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry.ipa.isNotEmpty)
            Text(
              entry.ipa,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          Text(
            '${entry.partOfSpeech} · ${entry.meanings.take(2).join('；')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: Wrap(
        spacing: 1,
        children: [
          IconButton(
            tooltip: '播放读音',
            onPressed: onSpeak == null ? null : () => onSpeak!(entry.word),
            icon: const Icon(Icons.volume_up_outlined),
          ),
          IconButton(
            tooltip: favorite ? '取消收藏' : '收藏单词',
            onPressed: onToggleFavorite,
            isSelected: favorite,
            icon: const Icon(Icons.bookmark_border),
            selectedIcon: const Icon(Icons.bookmark),
            color: favorite ? colors.primary : null,
          ),
        ],
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '释义',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 5),
        for (var index = 0; index < entry.meanings.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(right: 7, top: 1),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${index + 1}.',
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    entry.meanings[index],
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!entry.needsEditorialEnrichment && entry.variants.isNotEmpty) ...[
          const SizedBox(height: 9),
          _VocabularyMetadataLine(
            label: '词形变化',
            value: entry.variants.join(' · '),
          ),
        ],
        if (!entry.needsEditorialEnrichment &&
            entry.collocationCandidates.isNotEmpty) ...[
          const SizedBox(height: 9),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '常用搭配',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: entry.collocationCandidates
                  .take(6)
                  .map(
                    (collocation) => Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(collocation),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
        if (entry.hasExample && !entry.exampleIsOpenCandidate) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '例句',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  entry.example,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.exampleTranslation,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (entry.needsEditorialEnrichment ||
            entry.partOfSpeechCandidates.isNotEmpty ||
            entry.pronunciationCandidates.isNotEmpty ||
            entry.senseCandidates.isNotEmpty ||
            entry.exampleCandidates.isNotEmpty ||
            entry.reviewFields.isNotEmpty ||
            (entry.needsEditorialEnrichment &&
                (entry.variants.isNotEmpty ||
                    entry.collocationCandidates.isNotEmpty ||
                    entry.relationCandidates.isNotEmpty)))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ExpansionTile(
              key: ValueKey('learning-vocabulary-usage-${entry.word}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(
                entry.needsEditorialEnrichment
                    ? '用法与词形线索（待核对）'
                    : '更多用法与词形',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: entry.needsEditorialEnrichment
                  ? const Text('来源资料尚未完成译学人工审校')
                  : null,
              children: [
                if (entry.needsEditorialEnrichment && entry.variants.isNotEmpty)
                  _VocabularyMetadataLine(
                    label: entry.needsEditorialEnrichment
                        ? '词形候选'
                        : '词形变化',
                    value: entry.variants.join(' · '),
                  ),
                if (entry.partOfSpeechCandidates.isNotEmpty) ...[
                  _VocabularyCandidateSectionTitle(
                    title: '词性线索（待人工核对）',
                  ),
                  for (final candidate in entry.partOfSpeechCandidates
                      .take(6))
                    _VocabularyCandidateValue(
                      value: candidate.value,
                      source: candidate.sourceId,
                    ),
                ],
                if (entry.pronunciationCandidates.isNotEmpty) ...[
                  _VocabularyCandidateSectionTitle(
                    title: '来源读音线索（待人工核对）',
                  ),
                  for (final candidate in entry.pronunciationCandidates
                      .take(4))
                    _VocabularyCandidateValue(
                      value:
                          '${_pronunciationDialectLabel(candidate.dialect)} · '
                          '${_pronunciationNotationLabel(candidate.notation)} · '
                          '${candidate.value}',
                      source: [
                        candidate.partOfSpeech,
                        candidate.sourceId,
                      ].where((value) => value.trim().isNotEmpty).join(' · '),
                    ),
                ],
                if (entry.senseCandidates.isNotEmpty) ...[
                  _VocabularyCandidateSectionTitle(
                    title: '来源词义线索（待人工核对）',
                  ),
                  for (final candidate in entry.senseCandidates.take(6))
                    _VocabularySenseCandidateCard(candidate: candidate),
                ],
                if (entry.needsEditorialEnrichment &&
                    entry.collocationCandidates.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      entry.needsEditorialEnrichment ? '搭配线索' : '常用搭配',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: entry.collocationCandidates
                          .take(8)
                          .map(
                            (collocation) => Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(collocation),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                ],
                if (entry.needsEditorialEnrichment &&
                    entry.relationCandidates.isNotEmpty)
                  for (final relation in entry.relationCandidates.entries.take(6))
                    _VocabularyMetadataLine(
                      label: '${relation.key}线索',
                      value: relation.value.take(8).join(' · '),
                    ),
                if (entry.exampleCandidates.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '来源例句（待核对）',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final candidate in entry.exampleCandidates.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(candidate.englishText),
                          if (candidate.chineseText.isNotEmpty)
                            Text(
                              candidate.chineseText,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          OpenExampleAttribution(candidate: candidate),
                        ],
                      ),
                    ),
                ],
                if (entry.reviewFields.isNotEmpty)
                  _VocabularyMetadataLine(
                    label: '待补齐',
                    value: entry.reviewFields.take(6).join(' · '),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

final class _VocabularyMetadataLine extends StatelessWidget {
  const _VocabularyMetadataLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text('$label：$value'),
    ),
  );
}

final class _VocabularyCandidateSectionTitle extends StatelessWidget {
  const _VocabularyCandidateSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 5),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

final class _VocabularyCandidateValue extends StatelessWidget {
  const _VocabularyCandidateValue({required this.value, required this.source});

  final String value;
  final String source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value),
            if (source.trim().isNotEmpty)
              Text(
                '来源 · $source',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _VocabularySenseCandidateCard extends StatelessWidget {
  const _VocabularySenseCandidateCard({required this.candidate});

  final OpenCetRichSenseRow candidate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final qualifiers = <String>[
      if (candidate.partOfSpeech.trim().isNotEmpty)
        candidate.partOfSpeech.trim(),
      if (candidate.qualifier.trim().isNotEmpty) candidate.qualifier.trim(),
      ...candidate.usageTags
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .take(4),
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 5),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '来源 · ${candidate.sourceId} · ${candidate.reviewStatus}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (qualifiers.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(qualifiers.join(' · ')),
          ],
          for (final gloss in candidate.englishGlosses
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .take(3))
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(gloss, style: const TextStyle(height: 1.35)),
            ),
          for (final gloss in candidate.chineseGlosses
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .take(3))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                gloss,
                style: TextStyle(color: colors.onSurfaceVariant, height: 1.35),
              ),
            ),
          for (final example in candidate.sourceExamples
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .take(3))
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '例句线索 · $example',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _pronunciationDialectLabel(String dialect) => switch (
  dialect.trim().toLowerCase()
) {
  'uk' || 'british' || 'gb' => '英式',
  'us' || 'american' || 'us-us' => '美式',
  '' || 'base' || 'unknown' => '未标注口音',
  final value => value,
};

String _pronunciationNotationLabel(String notation) => switch (
  notation.trim().toLowerCase()
) {
  'ipa' => 'IPA',
  '' || 'unknown' => '未标注音标体系',
  final value => value,
};

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
