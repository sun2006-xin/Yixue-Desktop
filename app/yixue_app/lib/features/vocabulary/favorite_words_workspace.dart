import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

typedef FavoriteWordPageLoader = Future<FavoriteWordPageData> Function({
  String query,
  int limit,
  int offset,
});

typedef FavoriteWordRichDictionaryLookup = Future<DictionaryEntry?> Function(
  String word,
);

/// A standalone local vocabulary workspace.
///
/// The widget deliberately receives data callbacks instead of owning a
/// database connection. The quick-translation rail and the future learning
/// workspace can therefore reuse the same page contract.
class FavoriteWordsWorkspace extends StatefulWidget {
  const FavoriteWordsWorkspace({
    required this.loadPage,
    required this.setFavoriteWord,
    required this.saveWordAnnotation,
    this.setWordLearning,
    this.lookupRichEntry,
    required this.onSpeak,
    required this.onContinueTranslation,
    super.key,
  });

  final FavoriteWordPageLoader loadPage;
  final Future<void> Function(String word, bool favorite) setFavoriteWord;
  final Future<void> Function(WordAnnotationData annotation) saveWordAnnotation;
  final Future<void> Function(String word, bool enabled)? setWordLearning;
  final FavoriteWordRichDictionaryLookup? lookupRichEntry;
  final Future<void> Function(String value) onSpeak;
  final ValueChanged<String> onContinueTranslation;

  @override
  State<FavoriteWordsWorkspace> createState() => _FavoriteWordsWorkspaceState();
}

class _FavoriteWordsWorkspaceState extends State<FavoriteWordsWorkspace> {
  static const _pageSize = 40;

  final _searchController = TextEditingController();
  final _noteController = TextEditingController();
  final _listController = ScrollController();
  List<FavoriteWordRecordData> _records = const [];
  String? _selectedWord;
  String? _errorMessage;
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = false;
  var _savingNote = false;
  var _loadingRichEntry = false;
  var _richEntryRequest = 0;
  DictionaryEntry? _richEntry;

  FavoriteWordRecordData? get _selectedRecord {
    final word = _selectedWord;
    if (word == null) return null;
    for (final record in _records) {
      if (record.word == word) return record;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final page = await widget.loadPage(
        query: _searchController.text.trim(),
        limit: _pageSize,
        offset: 0,
      );
      if (!mounted) return;
      final previousWord = _selectedWord;
      final nextWord = page.records.any((record) => record.word == previousWord)
          ? previousWord
          : page.records.firstOrNull?.word;
      final nextRecord = page.records.firstWhereOrNull(
        (record) => record.word == nextWord,
      );
      setState(() {
        _records = List<FavoriteWordRecordData>.of(page.records);
        _hasMore = page.hasMore;
        _selectedWord = nextWord;
        _noteController.text = nextRecord?.annotation?.note ?? '';
        _loading = false;
      });
      unawaited(_loadRichEntry(nextWord));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '收藏词库读取失败：$error';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.loadPage(
        query: _searchController.text.trim(),
        limit: _pageSize,
        offset: _records.length,
      );
      if (!mounted) return;
      final existing = _records.map((record) => record.word).toSet();
      final appended = page.records
          .where((record) => existing.add(record.word))
          .toList(growable: false);
      setState(() {
        _records = [..._records, ...appended];
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _errorMessage = '更多收藏读取失败：$error';
      });
    }
  }

  void _select(FavoriteWordRecordData record) {
    setState(() {
      _selectedWord = record.word;
      _noteController.text = record.annotation?.note ?? '';
    });
    unawaited(_loadRichEntry(record.word));
  }

  Future<void> _loadRichEntry(String? word) async {
    final lookup = widget.lookupRichEntry;
    final request = ++_richEntryRequest;
    if (word == null || lookup == null) {
      if (mounted) {
        setState(() {
          _richEntry = null;
          _loadingRichEntry = false;
        });
      }
      return;
    }
    setState(() {
      _richEntry = null;
      _loadingRichEntry = true;
    });
    try {
      final entry = await lookup(word);
      if (!mounted || request != _richEntryRequest || _selectedWord != word) {
        return;
      }
      setState(() {
        _richEntry = entry;
        _loadingRichEntry = false;
      });
    } catch (_) {
      if (!mounted || request != _richEntryRequest || _selectedWord != word) {
        return;
      }
      setState(() {
        _richEntry = null;
        _loadingRichEntry = false;
      });
    }
  }

  Future<void> _unfavorite() async {
    final record = _selectedRecord;
    if (record == null) return;
    try {
      await widget.setFavoriteWord(record.word, false);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('取消收藏失败：$error')));
      }
      return;
    }
    if (!mounted) return;
    final remaining = _records
        .where((item) => item.word != record.word)
        .toList(growable: false);
    final next = remaining.firstOrNull;
    setState(() {
      _records = remaining;
      _selectedWord = next?.word;
      _noteController.text = next?.annotation?.note ?? '';
    });
    unawaited(_loadRichEntry(next?.word));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已取消收藏，其他本地学习记录不会被删除'),
        duration: Duration(milliseconds: 1000),
      ),
    );
  }

  Future<void> _saveNote({bool? addedToLearning}) async {
    final record = _selectedRecord;
    if (record == null || _savingNote) return;
    final annotation = WordAnnotationData(
      word: record.word,
      note: _noteController.text,
      addedToLearning:
          addedToLearning ?? record.annotation?.addedToLearning ?? false,
      updatedAt: DateTime.now().toIso8601String(),
    );
    final previousLearningState = record.annotation?.addedToLearning ?? false;
    final learningStateChanged =
        previousLearningState != annotation.addedToLearning;
    final setWordLearning = widget.setWordLearning;
    setState(() => _savingNote = true);
    var learningStateAttempted = false;
    try {
      if (learningStateChanged && setWordLearning != null) {
        learningStateAttempted = true;
        await setWordLearning(record.word, annotation.addedToLearning);
      }
      await widget.saveWordAnnotation(annotation);
      if (!mounted) return;
      final updated = FavoriteWordRecordData(
        word: record.word,
        favoritedAt: record.favoritedAt,
        languagePair: record.languagePair,
        dictionaryEntries: record.dictionaryEntries,
        annotation: annotation,
      );
      setState(() {
        _records = _records
            .map((item) => item.word == updated.word ? updated : item)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('笔记与学习状态已保存在本地'),
          duration: Duration(milliseconds: 900),
        ),
      );
    } catch (error) {
      Object? rollbackError;
      if (learningStateAttempted && setWordLearning != null) {
        try {
          await setWordLearning(record.word, previousLearningState);
        } catch (error) {
          rollbackError = error;
        }
      }
      if (mounted) {
        final message = rollbackError == null
            ? '笔记或学习状态保存失败：$error'
            : '保存失败：$error；恢复学习状态也失败：$rollbackError';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _savingNote = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _noteController.dispose();
    _listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('favorite-words-workspace'),
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bookmark_rounded, color: colors.primary, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '收藏词库',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '收藏、理解、记录，再把单词带进后续学习。数据只保存在本地。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('favorite-words-refresh'),
                  tooltip: '刷新收藏',
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('favorite-words-search'),
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _reload(),
                    decoration: InputDecoration(
                      labelText: '搜索收藏单词',
                      hintText: '按单词查找，例如 consistency',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        tooltip: '搜索',
                        onPressed: _reload,
                        icon: const Icon(Icons.arrow_forward_rounded),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  avatar: Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: colors.primary,
                  ),
                  label: const Text('本地数据库'),
                ),
              ],
            ),
            if (_loading && _records.isNotEmpty) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(
                key: ValueKey('favorite-words-refresh-progress'),
                minHeight: 2,
              ),
            ],
            const SizedBox(height: 16),
            if (_errorMessage != null)
              _ErrorBanner(message: _errorMessage!, onRetry: _reload),
            if (_errorMessage != null) const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 760;
                  if (narrow) {
                    return Column(
                      children: [
                        SizedBox(height: 250, child: _buildList(context)),
                        const SizedBox(height: 14),
                        Expanded(child: _buildDetail(context)),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 310, child: _buildList(context)),
                      const SizedBox(width: 18),
                      Expanded(child: _buildDetail(context)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_loading && _records.isEmpty) {
      return const _FavoriteWordsLoadingSkeleton();
    }
    if (_records.isEmpty) {
      return _EmptyState(
        icon: Icons.bookmark_border_rounded,
        title: '还没有收藏单词',
        detail: '在快速翻译右侧词语解释中点击书签，单词就会出现在这里。',
      );
    }
    return DecoratedBox(
      key: const ValueKey('favorite-words-list'),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListView.separated(
        controller: _listController,
        padding: const EdgeInsets.all(8),
        itemCount: _records.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          if (index == _records.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: OutlinedButton.icon(
                key: const ValueKey('favorite-words-load-more'),
                onPressed: _loadingMore ? null : _loadMore,
                icon: _loadingMore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more_rounded),
                label: Text(_loadingMore ? '正在读取…' : '加载更多收藏'),
              ),
            );
          }
          final record = _records[index];
          final selected = record.word == _selectedWord;
          final firstMeaning = record.dictionaryEntries.isEmpty
              ? '暂无词典释义'
              : record.dictionaryEntries.first.meanings.firstOrNull ?? '暂无词典释义';
          return Material(
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: ValueKey('favorite-word-${record.word}'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => _select(record),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            record.word,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            firstMeaning,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (record.annotation?.addedToLearning == true)
                      const Icon(Icons.school_rounded, size: 17),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final record = _selectedRecord;
    if (record == null) {
      if (_loading) return const _FavoriteWordsLoadingSkeleton(detail: true);
      return _EmptyState(
        icon: Icons.touch_app_outlined,
        title: '选择一个收藏单词',
        detail: '这里会显示释义、例句、读音、笔记和学习状态。',
      );
    }
    final annotation = record.annotation;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.word,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text('${record.languagePair}  ·  ${record.favoritedAt}'),
                  ],
                ),
              ),
              IconButton(
                tooltip: '朗读单词',
                onPressed: () => widget.onSpeak(record.word),
                icon: const Icon(Icons.volume_up_outlined),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (record.dictionaryEntries.isNotEmpty)
                Chip(
                  avatar: const Icon(Icons.menu_book_outlined, size: 17),
                  label: Text('${record.dictionaryEntries.length} 条词典释义'),
                ),
              if (annotation?.addedToLearning == true)
                const Chip(
                  avatar: Icon(Icons.school_rounded, size: 17),
                  label: Text('已加入学习'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('favorite-words-open-translation'),
                onPressed: () => widget.onContinueTranslation(record.word),
                icon: const Icon(Icons.translate_rounded),
                label: const Text('继续翻译'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('favorite-word-unfavorite'),
                onPressed: _unfavorite,
                icon: const Icon(Icons.bookmark_remove_outlined),
                label: const Text('取消收藏'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_loadingRichEntry)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else if (_richEntry != null)
            _RichDictionaryEntryDetail(
              entry: _richEntry!,
              onSpeak: widget.onSpeak,
            )
          else if (record.dictionaryEntries.isEmpty)
            const _DetailNotice(
              icon: Icons.info_outline_rounded,
              text: '暂无本地词典详情，可直接继续翻译；导入合法词典包后这里会显示释义和例句。',
            )
          else
            for (final entry in record.dictionaryEntries) ...[
              _DictionaryEntryDetail(entry: entry, onSpeak: widget.onSpeak),
              const SizedBox(height: 12),
            ],
          const Divider(height: 26),
          TextField(
            key: const ValueKey('favorite-word-note'),
            controller: _noteController,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: '我的笔记',
              hintText: '写下自己的例句、工作含义或易错点…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('favorite-word-save-note'),
                  onPressed: _savingNote ? null : _saveNote,
                  icon: _savingNote
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存笔记'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('favorite-word-learning-toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('加入学习'),
                    value: annotation?.addedToLearning ?? false,
                    onChanged: _savingNote || widget.setWordLearning == null
                        ? null
                        : (value) => _saveNote(addedToLearning: value),
                  ),
                ),
              ),
            ],
          ),
          if (annotation != null)
            Text(
              '上次记录：${annotation.updatedAt}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

final class _FavoriteWordsLoadingSkeleton extends StatelessWidget {
  const _FavoriteWordsLoadingSkeleton({this.detail = false});

  final bool detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholderColor = colors.surfaceContainerHighest.withAlpha(150);
    return DecoratedBox(
      key: ValueKey(
        detail ? 'favorite-words-loading-detail' : 'favorite-words-loading',
      ),
      decoration: BoxDecoration(
        color: detail ? colors.surfaceContainerLow : null,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: detail ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Text(
              detail ? '正在准备词条详情' : '正在读取收藏词条',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: detail ? 8 : 10),
            if (detail) ...[
              _FavoriteWordsSkeletonBar(
                widthFactor: 0.42,
                height: 22,
                color: placeholderColor,
              ),
              const SizedBox(height: 8),
              _FavoriteWordsSkeletonBar(
                widthFactor: 0.72,
                height: 12,
                color: placeholderColor,
              ),
            ] else
              for (var index = 0; index < 3; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: placeholderColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _FavoriteWordsSkeletonBar(
                              widthFactor: index == 1 ? 0.56 : 0.68,
                              height: 11,
                              color: placeholderColor,
                            ),
                            const SizedBox(height: 7),
                            _FavoriteWordsSkeletonBar(
                              widthFactor: index == 2 ? 0.48 : 0.78,
                              height: 8,
                              color: placeholderColor,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

final class _FavoriteWordsSkeletonBar extends StatelessWidget {
  const _FavoriteWordsSkeletonBar({
    required this.widthFactor,
    required this.height,
    required this.color,
  });

  final double widthFactor;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: widthFactor,
    alignment: Alignment.centerLeft,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: SizedBox(height: height),
    ),
  );
}

class _DictionaryEntryDetail extends StatelessWidget {
  const _DictionaryEntryDetail({required this.entry, required this.onSpeak});

  final DictionaryEntryData entry;
  final Future<void> Function(String value) onSpeak;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              entry.ipa,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
            Text(entry.partOfSpeech),
          ],
        ),
        const SizedBox(height: 8),
        for (final meaning in entry.meanings) Text('• $meaning'),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(entry.example)),
                  IconButton(
                    tooltip: '朗读例句',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onSpeak(entry.example),
                    icon: const Icon(Icons.volume_up_outlined, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(entry.exampleTranslation),
              const SizedBox(height: 8),
              Text(
                '来源：${entry.source}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RichDictionaryEntryDetail extends StatelessWidget {
  const _RichDictionaryEntryDetail({
    required this.entry,
    required this.onSpeak,
  });

  final DictionaryEntry entry;
  final Future<void> Function(String value) onSpeak;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final candidate = entry.qualityStatus != 'published';
    final pronunciations = entry.pronunciationCandidates
        .where((item) => item.value.trim().isNotEmpty)
        .toList(growable: false);
    final senses = entry.senseCandidates;
    final examples = entry.exampleCandidates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (candidate)
          _DetailNotice(
            icon: Icons.fact_check_outlined,
            text: '以下补充内容来自候选词典数据，尚待编辑核验；请结合上下文判断。',
          ),
        if (candidate) const SizedBox(height: 12),
        if (pronunciations.isNotEmpty) ...[
          _SectionHeading(
            title: '发音',
            trailing: TextButton.icon(
              onPressed: () => onSpeak(entry.word),
              icon: const Icon(Icons.volume_up_outlined, size: 18),
              label: const Text('朗读'),
            ),
          ),
          for (final pronunciation in pronunciations)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '${pronunciation.dialect}  ${pronunciation.value}  ${pronunciation.notation}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          const SizedBox(height: 12),
        ],
        _SectionHeading(title: candidate && senses.isNotEmpty ? '释义候选' : '释义'),
        if (senses.isNotEmpty)
          for (final sense in senses) ...[
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '${sense.partOfSpeech}${sense.qualifier.isEmpty ? '' : ' · ${sense.qualifier}'}',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final gloss in sense.chineseGlosses)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('• $gloss'),
              ),
            for (final gloss in sense.englishGlosses)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  gloss,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (sense.usageTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Wrap(
                  spacing: 6,
                  children: sense.usageTags
                      .map((tag) => Chip(label: Text(tag)))
                      .toList(growable: false),
                ),
              ),
          ]
        else
          for (final meaning in entry.meanings) Text('• $meaning'),
        if (entry.variants.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeading(title: '词形'),
          Wrap(
            spacing: 8,
            children: entry.variants
                .map((variant) => Chip(label: Text(variant)))
                .toList(growable: false),
          ),
        ],
        if (entry.collocationCandidates.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeading(title: candidate ? '搭配候选' : '常见搭配'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: entry.collocationCandidates
                .map((phrase) => Chip(label: Text(phrase)))
                .toList(growable: false),
          ),
        ],
        if (entry.hasExample && examples.isEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeading(title: '例句'),
          Text(entry.example),
          const SizedBox(height: 4),
          Text(entry.exampleTranslation),
          Text(
            '来源：${entry.source}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (examples.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeading(title: candidate ? '例句候选' : '例句'),
          for (final example in examples)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Text(example.englishText)),
                      IconButton(
                        tooltip: '朗读例句',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onSpeak(example.englishText),
                        icon: const Icon(Icons.volume_up_outlined, size: 19),
                      ),
                    ],
                  ),
                  Text(example.chineseText),
                  const SizedBox(height: 6),
                  Text(
                    '来源：${example.sourceId} · ${example.englishUsername} / ${example.chineseUsername}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _DetailNotice extends StatelessWidget {
  const _DetailNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 330),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text(message),
      leading: const Icon(Icons.error_outline_rounded),
      actions: [TextButton(onPressed: onRetry, child: const Text('重试'))],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;

  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
