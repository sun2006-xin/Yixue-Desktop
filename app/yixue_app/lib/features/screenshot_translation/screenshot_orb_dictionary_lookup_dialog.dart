import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';

typedef ScreenshotOrbDictionarySaveToVocabulary = Future<bool> Function(
  String word,
  String sourceContext,
  String sourceTranslation,
  String sourceHistoryId,
);

/// A small dictionary window opened from the screenshot translation orb.
/// Lookup stays on the existing host dictionary service; this widget only
/// keeps and presents a bounded local history of successful queries.
final class ScreenshotOrbDictionaryLookupDialog extends StatefulWidget {
  const ScreenshotOrbDictionaryLookupDialog({
    required this.lookupDictionary,
    this.lookupHistoryStore,
    this.sourceContext,
    this.sourceRecognizedText,
    this.sourceTranslation,
    this.sourceHistoryId,
    this.saveToVocabulary,
    super.key,
  });

  final Future<DictionaryEntry?> Function(String word) lookupDictionary;
  final ScreenshotDictionaryLookupHistoryStore? lookupHistoryStore;

  /// OCR context supplied by the current screenshot session, if available.
  final String? sourceContext;
  final String? sourceRecognizedText;
  final String? sourceTranslation;
  final String? sourceHistoryId;
  final ScreenshotOrbDictionarySaveToVocabulary? saveToVocabulary;

  @override
  State<ScreenshotOrbDictionaryLookupDialog> createState() =>
      _ScreenshotOrbDictionaryLookupDialogState();
}

class _ScreenshotOrbDictionaryLookupDialogState
    extends State<ScreenshotOrbDictionaryLookupDialog> {
  static const _historyLimit = screenshotDictionaryLookupHistoryLimit;

  final _queryController = TextEditingController();
  var _lookupRequest = 0;
  var _historyRevision = 0;
  var _busy = false;
  var _historyExpanded = false;
  var _historyUnavailable = false;
  DictionaryEntry? _entry;
  ScreenshotDictionaryLookupHistoryRecord? _savedEntry;
  ScreenshotDictionaryLookupHistoryRecord? _currentLookupRecord;
  String? _feedback;
  var _savingWord = false;
  bool? _wordSaved;
  List<ScreenshotDictionaryLookupHistoryRecord> _history = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _lookupRequest++;
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final store = widget.lookupHistoryStore;
    if (store == null) return;
    final revision = _historyRevision;
    try {
      final history = await store.read();
      if (!mounted || revision != _historyRevision) return;
      setState(() => _history = history.take(_historyLimit).toList());
    } on Object {
      if (mounted && revision == _historyRevision) {
        setState(() => _historyUnavailable = true);
      }
    }
  }

  Future<void> _lookup([String? rawQuery]) async {
    final originalQuery = (rawQuery ?? _queryController.text).trim();
    final word = dictionaryTermAtInput(originalQuery);
    if (word == null) {
      setState(() {
        _entry = null;
        _savedEntry = null;
        _feedback = '请输入一个中文或英文单词；暂不支持句子查词。';
      });
      return;
    }

    final request = ++_lookupRequest;
    _queryController
      ..text = originalQuery
      ..selection = TextSelection.collapsed(offset: originalQuery.length);
    setState(() {
      _busy = true;
      _entry = null;
      _savedEntry = null;
      _currentLookupRecord = null;
      _wordSaved = null;
      _feedback = null;
    });

    try {
      final entry = await widget.lookupDictionary(word);
      if (!mounted || request != _lookupRequest) return;
      if (entry == null) {
        setState(() => _feedback = '本地词典暂未收录“$word”。');
        return;
      }

      final now = DateTime.now().toUtc();
      final record = ScreenshotDictionaryLookupHistoryRecord(
        entry: _snapshot(entry),
        recordId:
            '${now.microsecondsSinceEpoch}-${math.Random.secure().nextInt(0x7fffffff).toRadixString(16)}',
        lookupQuery: originalQuery,
        sessionId: _boundedSnapshot(widget.sourceHistoryId, 512),
        sourceContext: _boundedSnapshot(widget.sourceContext, 2000),
        recognizedTextSnapshot: _boundedSnapshot(
          widget.sourceRecognizedText,
          100000,
        ),
        translationSnapshot: _boundedSnapshot(widget.sourceTranslation, 200000),
        recordedAt: now,
      );
      final store = widget.lookupHistoryStore;
      List<ScreenshotDictionaryLookupHistoryRecord>? persistedHistory;
      final historyRevision = store == null
          ? _historyRevision
          : ++_historyRevision;
      if (store != null) {
        try {
          persistedHistory = await store.add(record);
        } on Object {
          // The state update below is applied only if no newer history
          // mutation has started while this write was pending.
        }
      }
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = entry;
        _savedEntry = null;
        _currentLookupRecord = record;
        _wordSaved = null;
        if (historyRevision == _historyRevision) {
          _historyUnavailable = store != null && persistedHistory == null;
          if (persistedHistory != null) {
            _history = persistedHistory.take(_historyLimit).toList();
          } else {
            _history = [record, ..._history].take(_historyLimit).toList();
          }
        }
        _feedback = store == null
            ? '查询成功；当前没有可用的本地历史目录。'
            : persistedHistory == null
            ? '查询成功；近期记录暂未保存，请检查本地数据目录。'
            : '已保存到最近查词。';
      });
    } on Object {
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = null;
        _savedEntry = null;
        _feedback = '查词失败，请检查本地词典配置后重试。';
      });
    } finally {
      if (mounted && request == _lookupRequest) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pasteAndLookup() async {
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = clipboard?.text?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _feedback = '剪贴板没有可用文字。');
        return;
      }
      _queryController.text = text;
      await _lookup(text);
    } on Object {
      if (mounted) setState(() => _feedback = '无法读取剪贴板，请手动输入。');
    }
  }

  void _showHistoryEntry(ScreenshotDictionaryLookupHistoryRecord record) {
    _lookupRequest++;
    setState(() {
      _busy = false;
      _queryController.text = record.lookupQuery;
      _entry = null;
      _savedEntry = record;
      _currentLookupRecord = record;
      _wordSaved = null;
      _feedback = _hasScreenshotContext(record)
          ? '截图查词 · ${_formatDate(record.recordedAt)}'
          : '独立查词 · ${_formatDate(record.recordedAt)}';
    });
  }

  Future<void> _removeHistoryRecord(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    final store = widget.lookupHistoryStore;
    if (store == null) {
      setState(() => _historyUnavailable = true);
      return;
    }
    final revision = ++_historyRevision;
    try {
      final history = await store.remove(record.id);
      if (!mounted || revision != _historyRevision) return;
      setState(() {
        _history = history.take(_historyLimit).toList(growable: false);
        if (_savedEntry?.id == record.id) _savedEntry = null;
        if (_currentLookupRecord?.id == record.id) {
          _currentLookupRecord = null;
        }
      });
    } catch (_) {
      if (mounted && revision == _historyRevision) {
        setState(() => _historyUnavailable = true);
      }
    }
  }

  Future<void> _clearHistory() async {
    final store = widget.lookupHistoryStore;
    if (store == null || _history.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空查词记录？'),
        content: const Text('只会清除本机的截图划词历史，不会删除词库或截图翻译记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空记录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final revision = ++_historyRevision;
    try {
      await store.clear();
      if (!mounted || revision != _historyRevision) return;
      setState(() {
        _history = const [];
        _savedEntry = null;
        _currentLookupRecord = null;
        _wordSaved = null;
        _historyUnavailable = false;
      });
    } catch (_) {
      if (mounted && revision == _historyRevision) {
        setState(() => _historyUnavailable = true);
      }
    }
  }

  String _boundedSnapshot(String? value, int maxLength) {
    final snapshot = value?.trim() ?? '';
    if (snapshot.length <= maxLength) return snapshot;
    return '${snapshot.substring(0, maxLength - 1)}…';
  }

  Future<void> _saveCurrentWord() async {
    final save = widget.saveToVocabulary;
    final word = _entry?.word ?? _savedEntry?.entry.word;
    if (save == null || word == null || _savingWord) return;
    final record = _savedEntry ?? _currentLookupRecord;
    final recognizedText =
        record?.recognizedTextSnapshot ?? widget.sourceRecognizedText ?? '';
    final recordContext = record?.sourceContext.trim() ?? '';
    final providedContext = widget.sourceContext?.trim() ?? '';
    final sourceContext = recordContext.isNotEmpty
        ? recordContext
        : providedContext.isNotEmpty
        ? providedContext
        : recognizedText;
    final sourceTranslation =
        record?.translationSnapshot ?? widget.sourceTranslation ?? '';
    final savedSessionId = record?.sessionId.trim() ?? '';
    final providedSessionId = widget.sourceHistoryId?.trim() ?? '';
    final sourceHistoryId = savedSessionId.isNotEmpty
        ? savedSessionId
        : providedSessionId.isNotEmpty
        ? providedSessionId
        : 'screenshot-dictionary:${record?.id ?? _lookupRequest}';
    setState(() => _savingWord = true);
    try {
      final added = await save(
        word,
        _boundedSnapshot(sourceContext, 2000),
        _boundedSnapshot(sourceTranslation, 200000),
        sourceHistoryId,
      );
      if (!mounted) return;
      setState(() {
        _wordSaved = added;
        _feedback = added ? '这个词已保存到学习词汇' : '这个词已在学习词汇中';
      });
    } catch (_) {
      if (mounted) setState(() => _feedback = '加入学习词汇失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingWord = false);
    }
  }

  bool _hasScreenshotContext(ScreenshotDictionaryLookupHistoryRecord record) =>
      record.sessionId.trim().isNotEmpty ||
      record.sourceContext.trim().isNotEmpty ||
      record.recognizedTextSnapshot.trim().isNotEmpty ||
      record.translationSnapshot.trim().isNotEmpty;

  ScreenshotDictionaryLookupResult _snapshot(DictionaryEntry entry) =>
      ScreenshotDictionaryLookupResult(
        word: entry.word,
        ipa: entry.ipa,
        partOfSpeech: entry.partOfSpeech,
        meanings: List.unmodifiable(entry.meanings),
        example: entry.example,
        exampleTranslation: entry.exampleTranslation,
        qualityStatus: entry.qualityStatus,
        examples: List.unmodifiable([
          for (final example in entry.exampleCandidates.take(5))
            ScreenshotDictionaryExample(
              englishText: example.englishText,
              chineseText: example.chineseText,
              reviewStatus: example.reviewStatus,
            ),
        ]),
        variants: List.unmodifiable(entry.variants),
        collocations: List.unmodifiable(entry.collocationCandidates),
        relations: Map.unmodifiable({
          for (final relation in entry.relationCandidates.entries)
            relation.key: List<String>.unmodifiable(relation.value),
        }),
      );

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(560.0, screen.width - 32),
        height: math.min(700.0, screen.height - 32),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
              child: Row(
                children: [
                  Icon(Icons.menu_book_rounded, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '划词查词',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭查词弹窗',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('screenshot-orb-dictionary-query'),
                    controller: _queryController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _lookup(),
                    decoration: InputDecoration(
                      hintText: '输入或粘贴一个中英文单词',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        tooltip: '粘贴并查词',
                        onPressed: _busy ? null : _pasteAndLookup,
                        icon: const Icon(Icons.content_paste_rounded),
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey(
                        'screenshot-orb-dictionary-submit',
                      ),
                      onPressed: _busy ? null : () => _lookup(),
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search_rounded),
                      label: Text(_busy ? '查询中' : '查词'),
                    ),
                  ),
                ],
              ),
            ),
            if (_feedback != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _feedback!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _historyUnavailable
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                children: [
                  if (_entry case final entry?)
                    _entryCard(
                      word: entry.word,
                      ipa: entry.ipa,
                      partOfSpeech: entry.partOfSpeech,
                      meanings: entry.meanings,
                      example: entry.example,
                      exampleTranslation: entry.exampleTranslation,
                      examples: _snapshot(entry).examples,
                      variants: entry.variants,
                      collocations: entry.collocationCandidates,
                      relations: entry.relationCandidates,
                    )
                  else if (_savedEntry case final record?)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _entryCard(
                          word: record.entry.word,
                          ipa: record.entry.ipa,
                          partOfSpeech: record.entry.partOfSpeech,
                          meanings: record.entry.meanings,
                          example: record.entry.example,
                          exampleTranslation: record.entry.exampleTranslation,
                          examples: record.entry.examples,
                          variants: record.entry.variants,
                          collocations: record.entry.collocations,
                          relations: record.entry.relations,
                        ),
                        const SizedBox(height: 10),
                        _historyContextCard(record),
                      ],
                    )
                  else if (!_busy && _feedback == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('输入单词后即可查看释义、音标和例句。'),
                    ),
                  const SizedBox(height: 10),
                  if ((_entry != null || _savedEntry != null) &&
                      widget.saveToVocabulary != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey(
                          'screenshot-orb-dictionary-save-word',
                        ),
                        onPressed: _savingWord ? null : _saveCurrentWord,
                        icon: _savingWord
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                _wordSaved == true
                                    ? Icons.bookmark_added_rounded
                                    : Icons.bookmark_add_outlined,
                              ),
                        label: Text(
                          _savingWord
                              ? '正在加入…'
                              : _wordSaved == true
                              ? '已加入学习词汇'
                              : _wordSaved == false
                              ? '已在学习词汇中'
                              : '加入学习词汇',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey(
                            'screenshot-orb-dictionary-history-toggle',
                          ),
                          onPressed: () => setState(
                            () => _historyExpanded = !_historyExpanded,
                          ),
                          icon: Icon(
                            _historyExpanded
                                ? Icons.expand_less_rounded
                                : Icons.history_rounded,
                          ),
                          label: Text(
                            _historyExpanded
                                ? '收起最近查词'
                                : '最近查词（${_history.length}）',
                          ),
                        ),
                      ),
                      if (_historyExpanded && _history.isNotEmpty)
                        IconButton(
                          key: const ValueKey(
                            'screenshot-orb-dictionary-history-clear',
                          ),
                          tooltip: '清空查词记录',
                          onPressed: _clearHistory,
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                    ],
                  ),
                  if (_historyExpanded) ...[
                    if (_historyUnavailable)
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: Text('本地查词历史暂不可用；当前结果仍可查看。'),
                      ),
                    if (_history.isEmpty && !_historyUnavailable)
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: Text('还没有查词记录。'),
                      ),
                    for (final record in _history)
                      ListTile(
                        key: ValueKey('screenshot-orb-lookup-history-${record.id}'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        leading: const Icon(Icons.history_rounded, size: 18),
                        title: Text(
                          '${record.lookupQuery} · ${record.entry.word}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              record.sourceContext.trim().isEmpty
                                  ? '独立查词 · 无截图上下文'
                                  : '原文：${record.sourceContext}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (record.translationSnapshot.trim().isNotEmpty)
                              Text(
                                '译文：${record.translationSnapshot}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            Text(
                              record.entry.meanings.take(2).join('；'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        onTap: () => _showHistoryEntry(record),
                        trailing: IconButton(
                          key: ValueKey(
                            'screenshot-orb-lookup-history-delete-${record.id}',
                          ),
                          tooltip: '删除 ${record.entry.word} 查词记录',
                          onPressed: () => _removeHistoryRecord(record),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyContextCard(ScreenshotDictionaryLookupHistoryRecord record) {
    final colors = Theme.of(context).colorScheme;
    final recognizedText = record.recognizedTextSnapshot.trim();
    final sourceContext = record.sourceContext.trim();
    final translation = record.translationSnapshot.trim();
    final hasContext = _hasScreenshotContext(record);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '查词上下文',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasContext ? '来自截图翻译记录' : '独立查词 · 未关联截图原文或译文',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (sourceContext.isNotEmpty) ...[
              const SizedBox(height: 10),
              _snapshotLine('原文上下文', sourceContext),
            ],
            if (recognizedText.isNotEmpty && recognizedText != sourceContext) ...[
              const SizedBox(height: 10),
              _snapshotLine('完整 OCR 原文', recognizedText),
            ],
            if (translation.isNotEmpty) ...[
              const SizedBox(height: 10),
              _snapshotLine('译文快照', translation),
            ],
          ],
        ),
      ),
    );
  }

  Widget _snapshotLine(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 3),
      SelectableText(value),
    ],
  );

  Widget _entryCard({
    required String word,
    required String ipa,
    required String partOfSpeech,
    required List<String> meanings,
    required String example,
    required String exampleTranslation,
    required List<ScreenshotDictionaryExample> examples,
    required List<String> variants,
    required List<String> collocations,
    required Map<String, List<String>> relations,
  }) =>
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                word,
                key: const ValueKey('screenshot-orb-dictionary-result'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (ipa.isNotEmpty || partOfSpeech.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  [ipa, partOfSpeech]
                      .where((value) => value.isNotEmpty)
                      .join(' · '),
                ),
              ],
              const SizedBox(height: 12),
              for (var index = 0; index < meanings.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text('${index + 1}. ${meanings[index]}'),
                ),
              if (example.isNotEmpty) ...[
                const Divider(height: 24),
                Text(
                  example,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
                if (exampleTranslation.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(exampleTranslation),
                ],
              ],
              if (examples.isNotEmpty) ...[
                const Divider(height: 24),
                Text(
                  '来源例句（待核对）',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                for (final item in examples.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.englishText),
                        if (item.chineseText.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            item.chineseText,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
              if (variants.isNotEmpty ||
                  collocations.isNotEmpty ||
                  relations.isNotEmpty) ...[
                const Divider(height: 24),
                Text(
                  '扩展用法',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (variants.isNotEmpty)
                  _dictionaryExtensionLine(
                    label: '词形',
                    value: variants.join(' · '),
                  ),
                if (collocations.isNotEmpty)
                  _dictionaryExtensionLine(
                    label: '常用搭配',
                    value: collocations.take(8).join(' · '),
                  ),
                for (final relation in relations.entries.take(6))
                  _dictionaryExtensionLine(
                    label: relation.key,
                    value: relation.value.take(8).join(' · '),
                  ),
              ],
            ],
          ),
        ),
      );

  Widget _dictionaryExtensionLine({
    required String label,
    required String value,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );
}
