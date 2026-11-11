import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

enum _ScreenshotComparisonMode { text, image, imageOverlay }

final class _StaleSelectedWordTranslation {
  _StaleSelectedWordTranslation({required this.feedbackOperation});

  final int feedbackOperation;
  bool? cancellationAccepted;
  bool settled = false;
  String pendingFeedback = '';
}

Future<void> showScreenshotTranslationOverlayDetail(
  BuildContext context,
  ScreenshotTranslationOcrOverlayPair pair,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    scrollable: true,
    title: const Text('原图位置对照'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '原文',
            style: Theme.of(dialogContext).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          SelectableText(pair.block.text),
          const Divider(height: 24),
          Text(
            '译文',
            style: Theme.of(dialogContext).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          SelectableText(pair.translation),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('关闭'),
      ),
    ],
  ),
);

/// Presentation only: callbacks are sent to the main engine; no service or DB.
final class ScreenshotTranslationResultWindow extends StatefulWidget {
  const ScreenshotTranslationResultWindow({
    required this.session,
    required this.onCapture,
    required this.onRetranslate,
    this.onReverseDirection,
    required this.onHistory,
    this.onOpenModels,
    required this.onClose,
    this.onDrag,
    this.onToggleTopmost,
    this.onToggleCollapsed,
    this.onAddScreenshotWord,
    this.onLookupDictionary,
    this.onTranslateSelectedWord,
    this.onCancelSelectedWordTranslation,
    this.lookupHistoryStore,
    this.onSetPinnedRegion,
    this.onRefreshPinnedRegion,
    this.topmost = true,
    this.collapsed = false,
    super.key,
  });
  final ScreenshotTranslationSession? session;
  final VoidCallback onCapture;
  final ValueChanged<String> onRetranslate;
  final ValueChanged<String>? onReverseDirection;
  final VoidCallback onHistory;
  final VoidCallback? onOpenModels;
  final VoidCallback onClose;
  final VoidCallback? onDrag;
  final VoidCallback? onToggleTopmost;
  final VoidCallback? onToggleCollapsed;
  final Future<ScreenshotWordAddStatus> Function(ScreenshotWordRequest)?
  onAddScreenshotWord;
  final Future<ScreenshotDictionaryLookupResult?> Function(String word)?
  onLookupDictionary;
  final Future<String> Function(String word, String operationId)?
  onTranslateSelectedWord;
  final Future<bool> Function(String operationId)?
  onCancelSelectedWordTranslation;
  final ScreenshotDictionaryLookupHistoryStore? lookupHistoryStore;
  final Future<bool> Function(bool pinned)? onSetPinnedRegion;
  final Future<bool> Function()? onRefreshPinnedRegion;
  final bool topmost;
  final bool collapsed;

  @override
  State<ScreenshotTranslationResultWindow> createState() => _ResultState();
}

class _ResultState extends State<ScreenshotTranslationResultWindow> {
  static const _previewDecodeWidth = 1600;
  static const _previewDecodeHeight = 1200;
  static const _lookupHistoryOperationTimeout = Duration(seconds: 3);
  final _source = TextEditingController();
  bool _preview = false;
  bool _showTranslationOverlay = false;
  bool _copied = false;
  bool _addingWord = false;
  bool _lookingUpWord = false;
  bool _translatingSelectedWord = false;
  bool _wordTranslationNeedsConfiguration = false;
  int _wordOperation = 0;
  int _dictionaryOperation = 0;
  TextSelection? _dictionaryLookupSelection;
  TextSelection? _lastNonCollapsedSourceSelection;
  int _selectedWordTranslationOperation = 0;
  int _selectedWordTranslationRequestSequence = 0;
  String? _activeSelectedWordTranslationId;
  String? _modelFallbackWord;
  TextSelection? _modelFallbackSelection;
  String _lastObservedSourceText = '';
  String? _wordFeedback;
  final Map<String, _StaleSelectedWordTranslation>
  _staleSelectedWordTranslations = {};
  String? _regionFeedback;
  bool _regionActionBusy = false;
  ResizeImage? _previewImage;
  final List<ScreenshotDictionaryLookupHistoryRecord> _dictionaryLookupHistory =
      <ScreenshotDictionaryLookupHistoryRecord>[];
  int _lookupHistoryLoadGeneration = 0;

  ResizeImage _thumbnailProvider(Uint8List bytes) => ResizeImage(
    MemoryImage(bytes),
    width: _previewDecodeWidth,
    height: _previewDecodeHeight,
    policy: ResizeImagePolicy.fit,
  );

  void _evictPreview() {
    final image = _previewImage;
    if (image != null) {
      // ResizeImage itself is a provider; its ResizeImageKey is the cache key.
      // Resolve and evict that key so pending decodes cannot repopulate cache.
      unawaited(image.evict(cache: PaintingBinding.instance.imageCache));
    }
    _previewImage = null;
  }

  @override
  void initState() {
    super.initState();
    _source.text = widget.session?.recognizedText ?? '';
    _lastObservedSourceText = _source.text;
    _source.addListener(_onSourceChanged);
    unawaited(_loadDictionaryLookupHistory());
    if (widget.session?.imageBytes case final bytes?) {
      // The captured image is the reference for reviewing OCR layout. Show it
      // beside the recognized and translated text as soon as a capture exists.
      _preview = true;
      _previewImage = _thumbnailProvider(bytes);
    }
  }

  @override
  void didUpdateWidget(covariant ScreenshotTranslationResultWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session?.imageBytes, widget.session?.imageBytes)) {
      _evictPreview();
      if (widget.session?.imageBytes case final bytes?) {
        if (oldWidget.session?.imageBytes == null) _preview = true;
        _previewImage = _thumbnailProvider(bytes);
      }
    }
    if (oldWidget.session?.id != widget.session?.id ||
        oldWidget.session?.recognizedText != widget.session?.recognizedText) {
      _source.text = widget.session?.recognizedText ?? '';
    }
    if (oldWidget.session?.id != widget.session?.id ||
        oldWidget.session?.recognizedText != widget.session?.recognizedText ||
        oldWidget.session?.translatedText != widget.session?.translatedText) {
      _wordOperation++;
      _dictionaryOperation++;
      _dictionaryLookupSelection = null;
      _lastNonCollapsedSourceSelection = null;
      _selectedWordTranslationOperation++;
      _addingWord = false;
      _lookingUpWord = false;
      _translatingSelectedWord = false;
      _wordTranslationNeedsConfiguration = false;
      _modelFallbackWord = null;
      _modelFallbackSelection = null;
      _wordFeedback = null;
    }
    if (oldWidget.session?.id != widget.session?.id) {
      // Keep the recent lookup snapshots when the capture window is reused.
      // Each item carries its source and translation text, so its context does
      // not depend on the current screenshot staying selected.
      // Keep the opt-in source-image comparison mode across recaptures. It
      // starts collapsed, so image decoding stays opt-in.
      _copied = false;
      _showTranslationOverlay = false;
    }
    if (!identical(oldWidget.lookupHistoryStore, widget.lookupHistoryStore)) {
      unawaited(_loadDictionaryLookupHistory());
    }
    if (oldWidget.session?.translatedText != widget.session?.translatedText) {
      _showTranslationOverlay = false;
      _copied = false;
    }
  }

  Future<void> _loadDictionaryLookupHistory() async {
    final generation = ++_lookupHistoryLoadGeneration;
    final dictionaryOperation = _dictionaryOperation;
    final store = widget.lookupHistoryStore;
    if (store == null) {
      _dictionaryLookupHistory.clear();
      return;
    }
    try {
      final history = await store.read().timeout(
        _lookupHistoryOperationTimeout,
      );
      if (!mounted || generation != _lookupHistoryLoadGeneration) {
        return;
      }
      setState(() {
        _dictionaryLookupHistory
          ..clear()
          ..addAll(history.take(screenshotDictionaryLookupHistoryLimit));
      });
    } on TimeoutException {
      if (!mounted || generation != _lookupHistoryLoadGeneration) {
        return;
      }
      if (dictionaryOperation != _dictionaryOperation) return;
      setState(() => _wordFeedback = '本机查词记录读取超时；查词功能仍可继续。');
    } catch (_) {
      if (!mounted || generation != _lookupHistoryLoadGeneration) {
        return;
      }
      if (dictionaryOperation != _dictionaryOperation) return;
      setState(() => _wordFeedback = '本机查词记录读取失败；查词功能仍可继续。');
    }
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceChanged);
    _cancelPendingSelectedWordTranslation();
    _evictPreview();
    _source.dispose();
    super.dispose();
  }

  void _onSourceChanged() {
    // Ignore a collapsed range while the lookup action takes focus. A new
    // non-empty range, however, means the user has moved to another OCR word.
    if (_source.text != _lastObservedSourceText) {
      _lastObservedSourceText = _source.text;
      _dictionaryOperation++;
      _dictionaryLookupSelection = null;
      _lastNonCollapsedSourceSelection = null;
      _selectedWordTranslationOperation++;
      _cancelPendingSelectedWordTranslation();
      if (_lookingUpWord) _lookingUpWord = false;
      if (_translatingSelectedWord) _translatingSelectedWord = false;
      _wordTranslationNeedsConfiguration = false;
      _modelFallbackWord = null;
      _modelFallbackSelection = null;
    } else {
      final fallbackSelection = _modelFallbackSelection;
      final currentSelection = _source.selection;
      if (_hasNonCollapsedSelection(currentSelection)) {
        if (_lookingUpWord &&
            !_sameSelectionRange(
              currentSelection,
              _dictionaryLookupSelection,
            )) {
          _dictionaryOperation++;
          _dictionaryLookupSelection = null;
          _lookingUpWord = false;
          _wordFeedback = '选词已改变，请重新查释义。';
        }
        _lastNonCollapsedSourceSelection = currentSelection;
      }
      if (_modelFallbackWord != null &&
          fallbackSelection != null &&
          _hasNonCollapsedSelection(currentSelection) &&
          !_sameSelectionRange(currentSelection, fallbackSelection)) {
        final hadPendingTranslation = _activeSelectedWordTranslationId != null;
        _selectedWordTranslationOperation++;
        _cancelPendingSelectedWordTranslation();
        _translatingSelectedWord = false;
        _wordTranslationNeedsConfiguration = false;
        _modelFallbackWord = null;
        _modelFallbackSelection = null;
        _wordFeedback = hadPendingTranslation ? _wordFeedback : '选词已改变，请重新查释义。';
      }
    }
    if (mounted) setState(() {});
  }

  void _cancelPendingSelectedWordTranslation() {
    final operationId = _activeSelectedWordTranslationId;
    if (operationId == null) return;
    _activeSelectedWordTranslationId = null;
    final operation = _selectedWordTranslationOperation;
    final stale = _StaleSelectedWordTranslation(feedbackOperation: operation);
    _staleSelectedWordTranslations[operationId] = stale;
    while (_staleSelectedWordTranslations.length > 16) {
      _staleSelectedWordTranslations.remove(
        _staleSelectedWordTranslations.keys.first,
      );
    }
    final cancel = widget.onCancelSelectedWordTranslation;
    if (cancel == null) {
      stale.cancellationAccepted = false;
      stale.pendingFeedback = '选词已改变，旧试译结果将忽略；请求可能仍在后台处理。';
      _wordFeedback = stale.pendingFeedback;
      return;
    }
    const cancelRequestedFeedback = '选词已改变，正在请求停止旧试译。';
    stale.pendingFeedback = '旧试译仍在处理中，完成后再查词。';
    _wordFeedback = cancelRequestedFeedback;
    unawaited(
      cancel(operationId).catchError((_) => false).then((cancelled) {
        stale.cancellationAccepted = cancelled;
        final currentFeedback = cancelled
            ? '旧试译已停止，请重新查词。'
            : stale.settled
            ? '旧试译已结束，请重新查词。'
            : stale.pendingFeedback;
        if (stale.settled) {
          _staleSelectedWordTranslations.remove(operationId);
        }
        if (!mounted ||
            _selectedWordTranslationOperation != operation ||
            _lookingUpWord ||
            _translatingSelectedWord ||
            _wordFeedback != cancelRequestedFeedback) {
          return;
        }
        setState(() => _wordFeedback = currentFeedback);
      }),
    );
  }

  void _markStaleSelectedWordTranslationSettled(String operationId) {
    final stale = _staleSelectedWordTranslations[operationId];
    if (stale == null) return;
    stale.settled = true;
    if (stale.cancellationAccepted == null) return;
    _staleSelectedWordTranslations.remove(operationId);
    if (stale.cancellationAccepted == true ||
        !mounted ||
        _selectedWordTranslationOperation != stale.feedbackOperation ||
        _lookingUpWord ||
        _translatingSelectedWord ||
        _wordFeedback != stale.pendingFeedback) {
      return;
    }
    setState(() => _wordFeedback = '旧试译已结束，请重新查词。');
  }

  bool get _busy => switch (widget.session?.status) {
    ScreenshotTranslationStatus.capturing ||
    ScreenshotTranslationStatus.recognizing ||
    ScreenshotTranslationStatus.translating => true,
    _ => false,
  };

  Future<void> _copy(String text, {bool translation = false}) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted && translation) setState(() => _copied = true);
  }

  String? get _selectedWord {
    final selection = _source.selection;
    if (!selection.isValid || selection.isCollapsed) return null;
    return englishWordAtSelection(_source.text, selection.start, selection.end);
  }

  String? get _selectedDictionaryTerm {
    final selection = _source.selection;
    if (!selection.isValid) return null;
    return dictionaryTermAtSelection(
      _source.text,
      selection.start,
      selection.end,
    );
  }

  bool _dictionaryLookupAvailable(ScreenshotTranslationSession? session) {
    if (session == null || session.recognizedText.trim().isEmpty) return false;
    return switch (session.status) {
      ScreenshotTranslationStatus.capturing ||
      ScreenshotTranslationStatus.recognizing ||
      ScreenshotTranslationStatus.translating => false,
      ScreenshotTranslationStatus.completed ||
      ScreenshotTranslationStatus.empty ||
      ScreenshotTranslationStatus.failed ||
      ScreenshotTranslationStatus.cancelled => true,
    };
  }

  Future<void> _addWord(
    String word, {
    required ScreenshotTranslationSession expectedSession,
  }) async {
    final session = widget.session;
    final save = widget.onAddScreenshotWord;
    if (session == null || save == null || _addingWord) return;
    if (session.status != ScreenshotTranslationStatus.completed ||
        session.id != expectedSession.id ||
        session.historyEntryId != expectedSession.historyEntryId ||
        session.recognizedText != expectedSession.recognizedText ||
        session.translatedText != expectedSession.translatedText) {
      setState(() => _wordFeedback = '结果已更新，请在当前 OCR 原文中重新选词。');
      return;
    }
    if (_source.text != session.recognizedText) {
      setState(() => _wordFeedback = '原文已修改，请重新翻译后加入截屏生词。');
      return;
    }
    final request = ScreenshotWordRequest(
      sessionId: session.id,
      word: word,
      recognizedText: _source.text,
      translatedText: session.translatedText ?? '',
      historyEntryId: session.historyEntryId ?? session.id,
    );
    final operation = ++_wordOperation;
    setState(() {
      _addingWord = true;
      _wordFeedback = '正在加入截屏生词…';
    });
    try {
      final status = await save(request);
      if (!mounted || _wordOperation != operation) return;
      setState(
        () => _wordFeedback = switch (status) {
          ScreenshotWordAddStatus.added => '已加入截屏生词',
          ScreenshotWordAddStatus.alreadyExists => '该词已在截屏生词中',
          ScreenshotWordAddStatus.meaningPending => '已加入截屏生词 · 尚未填写释义',
        },
      );
    } on ScreenshotWordRequestException catch (error) {
      if (!mounted || _wordOperation != operation) return;
      setState(
        () => _wordFeedback = switch (error.code) {
          'stale_session' => '结果已更新，请在当前 OCR 原文中重新选词。',
          'invalid_word_request' => '请选择一个有效的英文单词。',
          'wordbook_unavailable' => '截屏生词暂不可用，请从主窗口重试。',
          _ => '加入失败，请重试；原文与译文已保留。',
        },
      );
    } catch (_) {
      if (mounted && _wordOperation == operation) {
        setState(() => _wordFeedback = '加入失败，请重试；原文与译文已保留。');
      }
    } finally {
      if (mounted && _wordOperation == operation) {
        setState(() => _addingWord = false);
      }
    }
  }

  Future<void> _lookupWord(
    String word, {
    required ScreenshotTranslationSession expectedSession,
  }) async {
    final session = widget.session;
    final lookup = widget.onLookupDictionary;
    if (session == null || lookup == null || _lookingUpWord) return;
    if (!_dictionaryLookupAvailable(session) ||
        session.id != expectedSession.id ||
        session.recognizedText != expectedSession.recognizedText) {
      setState(() => _wordFeedback = '结果已更新，请在当前 OCR 原文中重新选词。');
      return;
    }
    final sourceSnapshot = _source.text;
    final currentSelection = _source.selection;
    final selectedRange = _hasNonCollapsedSelection(currentSelection)
        ? currentSelection
        : _lastNonCollapsedSourceSelection ?? currentSelection;
    _dictionaryLookupSelection = _hasNonCollapsedSelection(selectedRange)
        ? selectedRange
        : null;
    final operation = ++_dictionaryOperation;
    // A new selection makes any pending model translation obsolete. Ignore
    // its eventual completion rather than showing a result for the old word.
    _selectedWordTranslationOperation++;
    _cancelPendingSelectedWordTranslation();
    setState(() {
      _lookingUpWord = true;
      _translatingSelectedWord = false;
      _modelFallbackWord = null;
      _modelFallbackSelection = null;
      _wordTranslationNeedsConfiguration = false;
      _wordFeedback = '正在查询本地词典…';
    });
    try {
      final entry = await lookup(word);
      if (!mounted || _dictionaryOperation != operation) return;
      ScreenshotDictionaryLookupHistoryRecord? record;
      List<ScreenshotDictionaryLookupHistoryRecord>? persistedHistory;
      var historySaveFailed = false;
      var historySaveTimedOut = false;
      if (entry != null) {
        final lookupRecord = ScreenshotDictionaryLookupHistoryRecord(
          entry: entry,
          lookupQuery: word,
          sessionId: session.id,
          sourceContext: _lookupContext(
            word,
            sourceSnapshot,
            selection: selectedRange,
          ),
          recognizedTextSnapshot: sourceSnapshot,
          translationSnapshot: session.translatedText ?? '',
          recordedAt: DateTime.now().toUtc(),
        );
        record = lookupRecord;
        final store = widget.lookupHistoryStore;
        if (store != null) {
          try {
            persistedHistory = await store
                .add(lookupRecord)
                .timeout(_lookupHistoryOperationTimeout);
          } on TimeoutException {
            historySaveTimedOut = true;
          } catch (_) {
            historySaveFailed = true;
          }
        }
      }
      if (!mounted || _dictionaryOperation != operation) return;
      final historyNotice = entry == null
          ? null
          : _dictionaryHistoryNotice(
              hasStore: widget.lookupHistoryStore != null,
              saveTimedOut: historySaveTimedOut,
              saveFailed: historySaveFailed,
              saveConfirmed: persistedHistory != null,
            );
      if (record != null) {
        // A slow initial read must not later replace the just-added lookup.
        _lookupHistoryLoadGeneration++;
      }
      setState(() {
        _lookingUpWord = false;
        _wordFeedback = entry == null ? '本地词典暂未收录“$word”。' : historyNotice;
        _modelFallbackWord =
            entry == null && widget.onTranslateSelectedWord != null
            ? word
            : null;
        _modelFallbackSelection =
            entry == null && widget.onTranslateSelectedWord != null
            ? selectedRange
            : null;
        if (persistedHistory != null) {
          _dictionaryLookupHistory
            ..clear()
            ..addAll(persistedHistory);
        } else if (record != null) {
          _dictionaryLookupHistory.insert(0, record);
          if (_dictionaryLookupHistory.length >
              screenshotDictionaryLookupHistoryLimit) {
            _dictionaryLookupHistory.removeRange(
              screenshotDictionaryLookupHistoryLimit,
              _dictionaryLookupHistory.length,
            );
          }
        }
      });
      if (entry != null) {
        await _showDictionaryEntry(entry, historyNotice: historyNotice);
      }
    } on ScreenshotWordRequestException catch (error) {
      if (!mounted || _dictionaryOperation != operation) return;
      setState(() {
        _lookingUpWord = false;
        _wordFeedback = switch (error.code) {
          'stale_session' => '结果已更新，请在当前 OCR 原文中重新选词。',
          'dictionary_unavailable' => '本地词典暂不可用，请从主窗口重试。',
          'invalid_word_request' => '请选择一个有效的中英文词条。',
          _ => '查词失败，请重试；截图原文与译文已保留。',
        };
      });
    } catch (_) {
      if (!mounted || _dictionaryOperation != operation) return;
      setState(() {
        _lookingUpWord = false;
        _wordFeedback = '查词失败，请重试；截图原文与译文已保留。';
      });
    } finally {
      if (mounted && _dictionaryOperation == operation) {
        setState(() {
          _lookingUpWord = false;
          _dictionaryLookupSelection = null;
        });
      }
    }
  }

  bool _hasNonCollapsedSelection(TextSelection selection) =>
      selection.isValid && !selection.isCollapsed;

  bool _sameSelectionRange(TextSelection current, TextSelection? expected) =>
      expected != null &&
      _hasNonCollapsedSelection(current) &&
      _hasNonCollapsedSelection(expected) &&
      current.start == expected.start &&
      current.end == expected.end;

  Future<void> _translateSelectedWord(
    String word, {
    required ScreenshotTranslationSession expectedSession,
  }) async {
    final session = widget.session;
    final selectedRange = _modelFallbackSelection;
    final translate = widget.onTranslateSelectedWord;
    if (session == null || translate == null || _translatingSelectedWord) {
      return;
    }
    if (!_dictionaryLookupAvailable(session) ||
        session.id != expectedSession.id ||
        session.recognizedText != expectedSession.recognizedText ||
        _modelFallbackWord != word) {
      setState(() {
        _modelFallbackWord = null;
        _wordFeedback = '结果已更新，请在当前 OCR 原文中重新选词。';
      });
      return;
    }
    final sourceSnapshot = _source.text;

    final operation = ++_selectedWordTranslationOperation;
    final operationId =
        'screenshot-word-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_selectedWordTranslationRequestSequence}';
    _activeSelectedWordTranslationId = operationId;
    setState(() {
      _translatingSelectedWord = true;
      _wordTranslationNeedsConfiguration = false;
      _wordFeedback = '正在使用当前翻译服务试译“$word”…';
    });
    try {
      final translation = await translate(word, operationId);
      if (!mounted || _selectedWordTranslationOperation != operation) return;
      final latest = widget.session;
      if (latest == null ||
          latest.id != expectedSession.id ||
          latest.recognizedText != expectedSession.recognizedText ||
          _source.text != sourceSnapshot ||
          _modelFallbackWord != word) {
        setState(() {
          _translatingSelectedWord = false;
          _modelFallbackWord = null;
          _wordFeedback = '结果已更新，本次试译未显示。';
        });
        return;
      }
      setState(() {
        _translatingSelectedWord = false;
        _wordTranslationNeedsConfiguration = false;
      });
      final historyRecord = ScreenshotDictionaryLookupHistoryRecord.modelTrial(
        lookupQuery: word,
        sessionId: session.id,
        sourceContext: _lookupContext(
          word,
          sourceSnapshot,
          selection: selectedRange ?? const TextSelection.collapsed(offset: 0),
        ),
        recognizedTextSnapshot: sourceSnapshot,
        translationSnapshot: session.translatedText ?? '',
        modelTranslation: translation,
        recordedAt: DateTime.now().toUtc(),
      );
      final historyNotice = await _rememberModelTranslation(historyRecord);
      if (!mounted || _selectedWordTranslationOperation != operation) return;
      final latestAfterSave = widget.session;
      if (latestAfterSave == null ||
          latestAfterSave.id != expectedSession.id ||
          latestAfterSave.recognizedText != expectedSession.recognizedText ||
          _source.text != sourceSnapshot) {
        setState(() {
          _translatingSelectedWord = false;
          _modelFallbackWord = null;
          _wordFeedback = '截图结果已更新；本次试译已保存在查词记录中。';
        });
        return;
      }
      setState(() {
        _wordFeedback = historyNotice;
      });
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('模型试译 · 非词典释义'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  word,
                  style: Theme.of(dialogContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                SelectableText(translation),
                const SizedBox(height: 12),
                Text(
                  '此结果由当前翻译服务生成，不含词典音标、词性或经审校例句。',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } on ScreenshotWordRequestException catch (error) {
      if (!mounted || _selectedWordTranslationOperation != operation) return;
      setState(() {
        _translatingSelectedWord = false;
        _wordTranslationNeedsConfiguration =
            error.code == 'translation_unavailable';
        if (error.code == 'translation_timeout' ||
            error.code == 'translation_cancelled' ||
            error.code == 'translation_in_progress') {
          _modelFallbackWord = null;
          _modelFallbackSelection = null;
        }
        _wordFeedback = switch (error.code) {
          'stale_session' => '结果已更新，请在当前 OCR 原文中重新选词。',
          'translation_unavailable' => '当前翻译服务不可用，请先配置翻译服务。',
          'translation_timeout' => '试译等待超时；上一次请求可能仍在后台处理中。稍后重新查词后再试，原文与译文已保留。',
          'translation_cancelled' => '等待超时，已请求停止上一次试译；稍后重新查词再试，原文与译文已保留。',
          'translation_in_progress' => '上一次请求仍在后台处理中，暂不重复发送。完成后重新查词再试。',
          'empty_translation' => '翻译服务未返回内容，请重试。',
          _ => '模型试译失败，原文与译文已保留，请重试。',
        };
      });
    } catch (_) {
      if (!mounted || _selectedWordTranslationOperation != operation) return;
      setState(() {
        _translatingSelectedWord = false;
        _wordTranslationNeedsConfiguration = false;
        _wordFeedback = '模型试译失败，原文与译文已保留，请重试。';
      });
    } finally {
      _markStaleSelectedWordTranslationSettled(operationId);
      if (mounted && _selectedWordTranslationOperation == operation) {
        _activeSelectedWordTranslationId = null;
        setState(() => _translatingSelectedWord = false);
      }
    }
  }

  Future<String> _rememberModelTranslation(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    final store = widget.lookupHistoryStore;
    List<ScreenshotDictionaryLookupHistoryRecord>? persistedHistory;
    var saveFailed = false;
    var saveTimedOut = false;
    if (store != null) {
      // A pending initial read must not replace this newly added model result.
      _lookupHistoryLoadGeneration++;
      try {
        persistedHistory = await store
            .add(record)
            .timeout(_lookupHistoryOperationTimeout);
      } on TimeoutException {
        saveTimedOut = true;
      } catch (_) {
        saveFailed = true;
      }
    }
    if (!mounted) {
      return '模型试译已完成。';
    }
    setState(() {
      if (persistedHistory != null) {
        _dictionaryLookupHistory
          ..clear()
          ..addAll(persistedHistory);
      } else {
        _dictionaryLookupHistory.insert(0, record);
        if (_dictionaryLookupHistory.length >
            screenshotDictionaryLookupHistoryLimit) {
          _dictionaryLookupHistory.removeRange(
            screenshotDictionaryLookupHistoryLimit,
            _dictionaryLookupHistory.length,
          );
        }
      }
    });
    if (store == null) {
      return '模型试译已完成，结果暂存在当前浮窗；关闭后不会保留。';
    }
    if (saveTimedOut) {
      return '模型试译已完成，但查词记录保存超时；结果仍可在当前浮窗回看。';
    }
    if (saveFailed) {
      return '模型试译已完成，但查词记录保存失败；结果仍可在当前浮窗回看。';
    }
    return '模型试译已完成 · 结果已保存到查词记录（非词典释义）';
  }

  String? _dictionaryHistoryNotice({
    required bool hasStore,
    required bool saveTimedOut,
    required bool saveFailed,
    required bool saveConfirmed,
  }) {
    if (!hasStore || saveConfirmed) return null;
    if (saveTimedOut) {
      return '查词成功；本机查词记录保存超时，状态未确认。释义仍可查看。';
    }
    if (saveFailed) {
      return '查词成功，但本机查词记录保存失败；释义仍可查看。';
    }
    return null;
  }

  Future<void> _showDictionaryEntry(
    ScreenshotDictionaryLookupResult entry, {
    String? historyNotice,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(entry.word)),
            if (entry.ipa.isNotEmpty)
              Text(
                entry.ipa,
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (historyNotice != null) ...[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(dialogContext)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: Theme.of(dialogContext)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              historyNotice,
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (entry.partOfSpeech.isNotEmpty)
                  Text(
                    entry.partOfSpeech,
                    style: Theme.of(dialogContext).textTheme.labelLarge,
                  ),
                const SizedBox(height: 8),
                for (final meaning in entry.meanings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $meaning'),
                  ),
                if (entry.example.trim().isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(entry.example),
                  if (entry.exampleTranslation.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        entry.exampleTranslation,
                        style: TextStyle(
                          color: Theme.of(dialogContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                if (entry.variants.isNotEmpty ||
                    entry.collocations.isNotEmpty ||
                    entry.relations.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(
                    '扩展用法',
                    style: Theme.of(dialogContext).textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (entry.variants.isNotEmpty)
                    _dictionaryDetailLine(
                      dialogContext,
                      '词形',
                      entry.variants.join(' · '),
                    ),
                  if (entry.collocations.isNotEmpty)
                    _dictionaryDetailLine(
                      dialogContext,
                      '常用搭配',
                      entry.collocations.take(8).join(' · '),
                    ),
                  for (final relation in entry.relations.entries.take(6))
                    _dictionaryDetailLine(
                      dialogContext,
                      relation.key,
                      relation.value.take(8).join(' · '),
                    ),
                ],
                if (entry.examples.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(
                    '候选例句（待审核）',
                    style: Theme.of(dialogContext).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 7),
                  for (final example in entry.examples)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(example.englishText),
                          const SizedBox(height: 2),
                          Text(example.chineseText),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _dictionaryDetailLine(
    BuildContext context,
    String label,
    String value,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
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

  String _lookupContext(
    String term,
    String sourceText, {
    required TextSelection selection,
  }) {
    var index = -1;
    if (selection.isValid &&
        !selection.isCollapsed &&
        selection.start >= 0 &&
        selection.end <= sourceText.length) {
      final selected = sourceText.substring(selection.start, selection.end);
      final normalizedSelection = selected.trim();
      final selectedTerm = dictionaryTermAtInput(normalizedSelection);
      String normalize(String value) =>
          value.toLowerCase().replaceAll('’', "'");
      if (normalizedSelection.isNotEmpty &&
          selectedTerm != null &&
          normalize(selectedTerm) == normalize(term)) {
        index = selection.start + selected.indexOf(normalizedSelection);
      }
    }
    if (index < 0) {
      index = sourceText.toLowerCase().indexOf(term.toLowerCase());
    }
    if (index < 0) {
      return sourceText.length <= 100
          ? sourceText
          : '${sourceText.substring(0, 100)}…';
    }
    final start = math.max(0, index - 42).toInt();
    final end = math.min(sourceText.length, index + term.length + 42).toInt();
    return '${start > 0 ? '…' : ''}${sourceText.substring(start, end)}'
        '${end < sourceText.length ? '…' : ''}';
  }

  Future<void> _showDictionaryLookupHistory() async {
    final history = List<ScreenshotDictionaryLookupHistoryRecord>.unmodifiable(
      _dictionaryLookupHistory,
    );
    final currentSessionId = widget.session?.id;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('最近查词记录'),
        content: SizedBox(
          width: 480,
          height: 420,
          child: history.isEmpty
              ? const Center(child: Text('选中 OCR 原文中的词语并查词后，记录会显示在这里。'))
              : Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.lookupHistoryStore == null
                            ? '保留最近 24 条跨截图查词记录，直到关闭本浮窗；原文片段和译文均为查词时快照，未做词句级对齐。'
                            : '本机保留最近 24 条跨截图查词记录；关闭并重新打开浮窗后仍可查看。原文片段和译文是查词时快照，未做词句级对齐。',
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: history.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = history[index];
                          final query = item.lookupQuery.trim().isEmpty
                              ? item.entry.word
                              : item.lookupQuery.trim();
                          final hasDifferentHeadword =
                              query.toLowerCase() !=
                              item.entry.word.trim().toLowerCase();
                          return ListTile(
                            key: ValueKey(
                              'screenshot-lookup-history-${item.id}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              query,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item.sessionId == currentSessionId ? '当前截图' : '历史截图'}'
                                    '${item.isModelTranslation ? ' · 模型试译（非词典释义）' : ''}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall,
                                  ),
                                  if (hasDifferentHeadword)
                                    Text(
                                      '词头：${item.entry.word} · ${item.entry.partOfSpeech}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                  if (item.isModelTranslation &&
                                      item.modelTranslation != null)
                                    Text('模型试译：${item.modelTranslation}'),
                                  Text('原文片段：${item.sourceContext}'),
                                  if (item.translationSnapshot.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      '译文快照：${item.translationSnapshot}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            onTap: () async {
                              Navigator.of(dialogContext).pop();
                              await _showDictionaryLookupHistoryRecord(item);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDictionaryLookupHistoryRecord(
    ScreenshotDictionaryLookupHistoryRecord item,
  ) async {
    final sourceSnapshot = item.recognizedTextSnapshot.isEmpty
        ? item.sourceContext
        : item.recognizedTextSnapshot;
    final query = item.lookupQuery.trim().isEmpty
        ? item.entry.word
        : item.lookupQuery;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final screenSize = MediaQuery.sizeOf(dialogContext);
        return AlertDialog(
          title: Text(
            item.isModelTranslation ? '模型试译记录 · $query' : '查词记录 · $query',
          ),
          content: SizedBox(
            width: math.min(640.0, math.max(280.0, screenSize.width - 80)),
            height: math.min(500.0, math.max(220.0, screenSize.height * .45)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.isModelTranslation)
                  Text(
                    '模型试译结果 · 非词典释义',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  )
                else
                  Text(
                    '${item.entry.word}  ·  ${item.entry.partOfSpeech}',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                if (item.isModelTranslation &&
                    item.modelTranslation != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    item.modelTranslation!,
                    style: Theme.of(dialogContext).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '由当前翻译服务生成，仅供理解上下文；不包含词典音标、词性或审校例句。',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      if (!item.isModelTranslation) ...[
                        _dictionaryLookupSnapshotCard(
                          dialogContext,
                          item.entry,
                        ),
                        const SizedBox(height: 12),
                      ],
                      _lookupSnapshotCard(
                        dialogContext,
                        title: 'OCR 原文快照',
                        text: sourceSnapshot,
                      ),
                      const SizedBox(height: 12),
                      _lookupSnapshotCard(
                        dialogContext,
                        title: '完整译文快照',
                        text: item.translationSnapshot.isEmpty
                            ? '这次查询时没有可用译文。'
                            : item.translationSnapshot,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (!item.isModelTranslation)
              TextButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _showDictionaryEntry(item.entry);
                },
                child: const Text('词典释义'),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _dictionaryLookupSnapshotCard(
    BuildContext context,
    ScreenshotDictionaryLookupResult entry,
  ) {
    final colors = Theme.of(context).colorScheme;
    final extensionLines = <(String, String)>[
      if (entry.variants.isNotEmpty)
        ('词形', entry.variants.take(12).join(' · ')),
      if (entry.collocations.isNotEmpty)
        ('常用搭配', entry.collocations.take(8).join(' · ')),
      for (final relation in entry.relations.entries.take(6))
        (relation.key, relation.value.take(8).join(' · ')),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .48),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('词典释义快照', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text('${entry.word}  ·  ${entry.partOfSpeech}'),
          for (final meaning in entry.meanings.take(20))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('• $meaning'),
            ),
          if (entry.example.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(entry.example),
            if (entry.exampleTranslation.trim().isNotEmpty)
              Text(
                entry.exampleTranslation,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
          ],
          for (final line in extensionLines)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${line.$1}：${line.$2}'),
            ),
        ],
      ),
    );
  }

  Widget _lookupSnapshotCard(
    BuildContext context, {
    required String title,
    required String text,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .48),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SelectableText(text),
        ],
      ),
    );
  }

  Future<void> _setRegionPinned(bool pinned) async {
    final session = widget.session;
    final update = widget.onSetPinnedRegion;
    if (session?.bounds == null || update == null || _regionActionBusy) return;
    setState(() {
      _regionActionBusy = true;
      _regionFeedback = null;
    });
    try {
      final saved = await update(pinned);
      if (!mounted) return;
      setState(
        () => _regionFeedback = saved
            ? (pinned ? '固定区域已保存到本机设置。' : '已取消固定区域。')
            : '保存失败，请检查主窗口连接后重试。',
      );
    } finally {
      if (mounted) setState(() => _regionActionBusy = false);
    }
  }

  Future<void> _refreshPinnedRegion() async {
    final refresh = widget.onRefreshPinnedRegion;
    if (refresh == null || _regionActionBusy || _busy) return;
    setState(() {
      _regionActionBusy = true;
      _regionFeedback = null;
    });
    try {
      final started = await refresh();
      if (mounted && !started) {
        setState(() => _regionFeedback = '固定区域刷新失败，请重新框选或重试。');
      }
    } finally {
      if (mounted) setState(() => _regionActionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            _buildTitleBar(colors),
            if (!widget.collapsed) ...[
              _buildStatus(colors, session),
              if (session?.bounds != null)
                _buildPinnedRegionControls(colors, session!),
              if (session?.imageBytes != null) _buildComparisonMode(colors),
              if (_regionFeedback != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 5),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _regionFeedback!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              if (_wordFeedback != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _wordFeedback!,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (_modelFallbackWord != null &&
                          !_wordTranslationNeedsConfiguration &&
                          widget.onTranslateSelectedWord != null &&
                          session != null)
                        TextButton.icon(
                          key: const ValueKey(
                            'screenshot-model-word-translation',
                          ),
                          onPressed: _translatingSelectedWord
                              ? null
                              : () => _translateSelectedWord(
                                  _modelFallbackWord!,
                                  expectedSession: session,
                                ),
                          icon: _translatingSelectedWord
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.translate_rounded, size: 16),
                          label: Text(
                            _translatingSelectedWord ? '试译中' : '用当前服务试译',
                          ),
                        ),
                      if (_wordTranslationNeedsConfiguration &&
                          widget.onOpenModels != null)
                        TextButton(
                          key: const ValueKey(
                            'screenshot-word-open-model-settings',
                          ),
                          onPressed: widget.onOpenModels,
                          child: const Text('打开模型设置'),
                        ),
                    ],
                  ),
                ),
              Expanded(child: _buildResultBody(colors)),
              _buildActions(colors, session),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar(ColorScheme colors) => Container(
    height: 48,
    decoration: BoxDecoration(
      color: colors.surface,
      border: Border(bottom: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => widget.onDrag?.call(),
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.center_focus_weak_rounded,
                      color: colors.primary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      '截屏翻译',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  if (!widget.collapsed && widget.session != null)
                    _statusDot(colors),
                ],
              ),
            ),
          ),
        ),
        _windowAction(
          tooltip: widget.topmost ? '取消置顶' : '置顶',
          icon: widget.topmost ? Icons.push_pin : Icons.push_pin_outlined,
          color: widget.topmost ? colors.primary : colors.onSurfaceVariant,
          onPressed: widget.onToggleTopmost,
        ),
        _windowAction(
          tooltip: widget.collapsed ? '展开结果' : '收起结果',
          icon: widget.collapsed ? Icons.unfold_more : Icons.unfold_less,
          color: colors.onSurfaceVariant,
          onPressed: widget.onToggleCollapsed,
        ),
        _windowAction(
          tooltip: '关闭结果',
          icon: Icons.close,
          color: colors.onSurfaceVariant,
          onPressed: widget.onClose,
        ),
        const SizedBox(width: 4),
      ],
    ),
  );

  Widget _statusDot(ColorScheme colors) {
    final status = widget.session?.status;
    final color = switch (status) {
      ScreenshotTranslationStatus.completed => const Color(0xFF16866B),
      ScreenshotTranslationStatus.failed => colors.error,
      ScreenshotTranslationStatus.empty => const Color(0xFFB7791F),
      ScreenshotTranslationStatus.capturing ||
      ScreenshotTranslationStatus.recognizing ||
      ScreenshotTranslationStatus.translating => colors.primary,
      _ => colors.outline,
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _windowAction({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    onPressed: onPressed,
    icon: Icon(icon, size: 18, color: color),
  );

  Widget _buildStatus(
    ColorScheme colors,
    ScreenshotTranslationSession? session,
  ) {
    final failed = session?.status == ScreenshotTranslationStatus.failed;
    final empty = session?.status == ScreenshotTranslationStatus.empty;
    final sourceEdited =
        session?.status == ScreenshotTranslationStatus.completed &&
        _source.text != session?.recognizedText;
    final imageStatusMessage = _imageStatusMessage(session);
    final routeMessage = _routeDisclosure(session);
    final imageWarning =
        sourceEdited ||
        (imageStatusMessage != null &&
            session?.imageSaveStatus !=
                ScreenshotTranslationImageSaveStatus.saved &&
            session?.imageSaveStatus !=
                ScreenshotTranslationImageSaveStatus.saving);
    final background = failed
        ? colors.errorContainer.withValues(alpha: 0.62)
        : empty
        ? const Color(0xFFFFF4DC)
        : imageWarning
        ? const Color(0xFFFFF4DC)
        : colors.primaryContainer.withValues(alpha: 0.46);
    final foreground = failed
        ? colors.onErrorContainer
        : empty
        ? const Color(0xFF76510E)
        : imageWarning
        ? const Color(0xFF76510E)
        : colors.onSurfaceVariant;
    final icon = failed
        ? Icons.error_outline_rounded
        : empty
        ? Icons.info_outline_rounded
        : sourceEdited
        ? Icons.edit_note_rounded
        : _busy
        ? null
        : session?.status == ScreenshotTranslationStatus.completed
        ? Icons.check_circle_outline_rounded
        : Icons.auto_awesome_outlined;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 5),
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            if (_busy)
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(icon, size: 16, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _status(session),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.25,
                      color: foreground,
                      fontWeight: failed ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (routeMessage != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      routeMessage,
                      key: const ValueKey('screenshot-translation-route'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (imageStatusMessage != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      imageStatusMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: imageWarning
                            ? foreground
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (_shouldOpenModels(session) && widget.onOpenModels != null) ...[
              const SizedBox(width: 2),
              TextButton.icon(
                key: const ValueKey('screenshot-open-model-settings'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  minimumSize: const Size(0, 30),
                ),
                onPressed: widget.onOpenModels,
                icon: const Icon(Icons.settings_outlined, size: 15),
                label: const Text('模型设置'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonMode(ColorScheme colors) {
    final overlayAvailable = _translationOverlayPairs != null;
    final mode = !_preview
        ? _ScreenshotComparisonMode.text
        : _showTranslationOverlay && overlayAvailable
        ? _ScreenshotComparisonMode.imageOverlay
        : _ScreenshotComparisonMode.image;
    final unavailableReason = _translationAlignmentMessage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_ScreenshotComparisonMode>(
              key: const ValueKey('screenshot-comparison-mode'),
              showSelectedIcon: false,
              segments: <ButtonSegment<_ScreenshotComparisonMode>>[
                const ButtonSegment(
                  value: _ScreenshotComparisonMode.text,
                  icon: Icon(Icons.view_agenda_outlined, size: 16),
                  label: Text('文本对照'),
                ),
                const ButtonSegment(
                  value: _ScreenshotComparisonMode.image,
                  icon: Icon(Icons.image_outlined, size: 16),
                  label: Text('原图对照'),
                ),
                ButtonSegment(
                  value: _ScreenshotComparisonMode.imageOverlay,
                  icon: const Icon(Icons.translate_rounded, size: 16),
                  label: const Text('原图位置叠译'),
                  enabled: overlayAvailable,
                ),
              ],
              selected: <_ScreenshotComparisonMode>{mode},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                setState(() {
                  switch (selection.single) {
                    case _ScreenshotComparisonMode.text:
                      _preview = false;
                      _showTranslationOverlay = false;
                      break;
                    case _ScreenshotComparisonMode.image:
                      _preview = true;
                      _showTranslationOverlay = false;
                      break;
                    case _ScreenshotComparisonMode.imageOverlay:
                      if (!overlayAvailable) return;
                      _preview = true;
                      _showTranslationOverlay = true;
                      break;
                  }
                });
              },
            ),
          ),
          if (unavailableReason != null) ...[
            const SizedBox(height: 4),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        unavailableReason,
                        key: const ValueKey(
                          'screenshot-comparison-mode-unavailable-reason',
                        ),
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.2,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultBody(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final image = widget.session?.imageBytes == null
            ? null
            : _imageComparisonPane(colors);
        if (_preview && image != null && constraints.maxWidth < 1000) {
          return DefaultTabController(
            length: 3,
            child: Column(
              children: [
                SizedBox(
                  height: 34,
                  child: TabBar(
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    labelColor: colors.primary,
                    unselectedLabelColor: colors.onSurfaceVariant,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: const [
                      Tab(text: '原图'),
                      Tab(text: 'OCR 原文'),
                      Tab(text: '译文'),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: TabBarView(
                    children: [
                      image,
                      _sourcePane(colors),
                      _translationPane(colors),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        if (_preview && image != null) {
          return Row(
            children: [
              Expanded(flex: 5, child: image),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Container(width: 1, color: colors.outlineVariant),
              ),
              Expanded(flex: 5, child: _sourcePane(colors)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Container(width: 1, color: colors.outlineVariant),
              ),
              Expanded(flex: 5, child: _translationPane(colors)),
            ],
          );
        }
        if (constraints.maxWidth < 496) {
          return DefaultTabController(
            length: 2,
            child: Column(
              children: [
                SizedBox(
                  height: 34,
                  child: TabBar(
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicator: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    labelColor: colors.primary,
                    unselectedLabelColor: colors.onSurfaceVariant,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    tabs: const [
                      Tab(text: '原文'),
                      Tab(text: '译文'),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: TabBarView(
                    children: [_sourcePane(colors), _translationPane(colors)],
                  ),
                ),
              ],
            ),
          );
        }
        return Row(
          children: [
            Expanded(child: _sourcePane(colors)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Container(width: 1, color: colors.outlineVariant),
            ),
            Expanded(child: _translationPane(colors)),
          ],
        );
      },
    ),
  );

  List<ScreenshotTranslationOcrOverlayPair>? get _translationOverlayPairs {
    final session = widget.session;
    final translated = session?.translatedText;
    if (session == null ||
        session.status != ScreenshotTranslationStatus.completed ||
        translated == null ||
        translated.trim().isEmpty) {
      return null;
    }
    return pairScreenshotTranslationOverlay(
      recognizedText: session.recognizedText,
      translatedText: translated,
      layout: session.ocrLayout,
      translatedSourceBlockIndices: session.translatedSourceBlockIndices,
    );
  }

  String? get _translationAlignmentMessage {
    final session = widget.session;
    if (session == null ||
        session.imageBytes == null ||
        _translationOverlayPairs != null) {
      return null;
    }
    if (session.status != ScreenshotTranslationStatus.completed ||
        session.translatedText?.trim().isNotEmpty != true) {
      return '位置叠译暂不可用：需翻译完成并取得可靠的原图文字位置；可先用文本对照。';
    }
    if (session.ocrLayout == null) {
      return '位置叠译不可用：未取得可靠的原图文字位置；仍可查看完整原文和译文。';
    }
    return '位置叠译不可用：无法与原图文字区域可靠对齐；仍可查看完整原文和译文。';
  }

  Widget _imageComparisonPane(ColorScheme colors) {
    final overlayPairs = _translationOverlayPairs;
    return Container(
      key: const ValueKey('screenshot-result-image-comparison-pane'),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: _previewImage == null
          ? Text('截图预览不可用', style: TextStyle(color: colors.onSurfaceVariant))
          : Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final image = _previewImage;
                      if (image == null) {
                        return Text(
                          '截图预览不可用',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        );
                      }
                      final layout = widget.session?.ocrLayout;
                      if (layout == null) {
                        return InteractiveViewer(
                          minScale: .8,
                          maxScale: 5,
                          child: Image(
                            image: image,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => Text(
                              '截图预览无法显示',
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ),
                        );
                      }
                      final originalSize = Size(
                        layout.imageWidth.toDouble(),
                        layout.imageHeight.toDouble(),
                      );
                      final viewport = constraints.biggest;
                      final targetSize = Size(
                        viewport.width.isFinite && viewport.width > 0
                            ? viewport.width
                            : _previewDecodeWidth.toDouble(),
                        viewport.height.isFinite && viewport.height > 0
                            ? viewport.height
                            : _previewDecodeHeight.toDouble(),
                      );
                      final canvasSize = applyBoxFit(
                        BoxFit.contain,
                        originalSize,
                        targetSize,
                      ).destination;
                      if (canvasSize.width <= 0 || canvasSize.height <= 0) {
                        return Text(
                          '截图预览无法显示',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        );
                      }
                      final scale = canvasSize.width / originalSize.width;
                      return InteractiveViewer(
                        constrained: false,
                        minScale: .8,
                        maxScale: 5,
                        child: SizedBox(
                          width: canvasSize.width,
                          height: canvasSize.height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image(image: image, fit: BoxFit.fill),
                              if (_showTranslationOverlay &&
                                  overlayPairs != null)
                                for (
                                  var index = 0;
                                  index < overlayPairs.length;
                                  index++
                                )
                                  _buildTranslationOverlayBlock(
                                    pair: overlayPairs[index],
                                    index: index,
                                    scale: scale,
                                    canvasSize: canvasSize,
                                    colors: colors,
                                  ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (overlayPairs != null)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: Material(
                      color: colors.surface.withValues(alpha: .94),
                      borderRadius: BorderRadius.circular(9),
                      elevation: 2,
                      child: InkWell(
                        key: const ValueKey(
                          'screenshot-result-window-overlay-toggle',
                        ),
                        borderRadius: BorderRadius.circular(9),
                        onTap: () => setState(
                          () => _showTranslationOverlay =
                              !_showTranslationOverlay,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _showTranslationOverlay
                                    ? Icons.visibility_off_outlined
                                    : Icons.translate_rounded,
                                size: 15,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _showTranslationOverlay ? '隐藏叠译' : '显示叠译',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_showTranslationOverlay && overlayPairs != null)
                  Positioned(
                    left: 7,
                    bottom: 7,
                    child: IgnorePointer(
                      child: Material(
                        color: colors.surface.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(9),
                        elevation: 2,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 14,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 5),
                              const Text(
                                '译文可能省略 · 点按文字块查看全文',
                                key: ValueKey(
                                  'screenshot-result-overlay-full-text-hint',
                                ),
                                style: TextStyle(fontSize: 10.5),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Positioned _buildTranslationOverlayBlock({
    required ScreenshotTranslationOcrOverlayPair pair,
    required int index,
    required double scale,
    required Size canvasSize,
    required ColorScheme colors,
  }) {
    final bounds = screenshotTranslationOverlayBounds(
      block: pair.block,
      canvasSize: canvasSize,
      scale: scale,
    );
    if (bounds == null) return const Positioned(child: SizedBox.shrink());
    final textMetrics = screenshotTranslationOverlayTextMetrics(bounds);
    return Positioned.fromRect(
      rect: bounds,
      child: Tooltip(
        message: '点按查看完整原文与译文',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => unawaited(
              showScreenshotTranslationOverlayDetail(context, pair),
            ),
            child: DecoratedBox(
              key: ValueKey('screenshot-translation-overlay-block-$index'),
              decoration: BoxDecoration(
                color: const Color(0xE60B1523),
                border: Border.all(
                  color: colors.primary.withValues(alpha: .86),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: textMetrics.horizontalPadding,
                  vertical: textMetrics.verticalPadding,
                ),
                child: Text(
                  pair.translation,
                  maxLines: textMetrics.maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: textMetrics.fontSize,
                    height: 1.12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActions(
    ColorScheme colors,
    ScreenshotTranslationSession? session,
  ) => Container(
    decoration: BoxDecoration(
      color: colors.surface,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
    padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
    child: Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: session?.translatedText?.isNotEmpty == true
                ? () => _copy(session!.translatedText!, translation: true)
                : null,
            icon: Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 16,
            ),
            label: Text(_copied ? '已复制' : '复制译文'),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 7),
            ),
            onPressed: widget.onCapture,
            icon: const Icon(Icons.crop_free_rounded, size: 16),
            label: Text(session == null ? '开始截屏' : '重新截取'),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextButton.icon(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 3),
            ),
            onPressed: widget.onHistory,
            icon: const Icon(Icons.history_rounded, size: 17),
            label: const Text('查看历史'),
          ),
        ),
      ],
    ),
  );

  Widget _buildPinnedRegionControls(
    ColorScheme colors,
    ScreenshotTranslationSession session,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            session.regionPinned
                ? Icons.push_pin_rounded
                : Icons.crop_free_rounded,
            size: 17,
            color: colors.primary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  session.regionPinned ? '固定区域' : '当前选区',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                Text(
                  switch (session.regionContentChanged) {
                    true => '与上次同区域截图相比，内容已变化',
                    false => '与上次同区域截图相比，内容未变化',
                    null =>
                      session.regionPinned
                          ? '此区域已固定；刷新后可与本次结果比较'
                          : '可固定此区域，稍后按需刷新',
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (session.regionPinned)
            IconButton(
              tooltip: '刷新固定区域',
              visualDensity: VisualDensity.compact,
              onPressed: _regionActionBusy || _busy
                  ? null
                  : _refreshPinnedRegion,
              icon: _regionActionBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          TextButton(
            onPressed:
                _regionActionBusy || widget.onSetPinnedRegion == null || _busy
                ? null
                : () => _setRegionPinned(!session.regionPinned),
            child: Text(session.regionPinned ? '取消固定' : '固定此区'),
          ),
        ],
      ),
    ),
  );

  Widget _sourcePane(ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 35,
        child: Row(
          children: [
            Expanded(
              child: Text(
                'OCR 原文',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
            ),
            IconButton(
              tooltip: '复制原文',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              onPressed: _source.text.isEmpty
                  ? null
                  : () => _copy(_source.text),
              icon: const Icon(Icons.copy_rounded, size: 16),
            ),
            IconButton(
              tooltip: '查词记录 ${_dictionaryLookupHistory.length}',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              onPressed: _dictionaryLookupHistory.isEmpty
                  ? null
                  : _showDictionaryLookupHistory,
              icon: const Icon(Icons.history_rounded, size: 17),
            ),
            if (widget.onReverseDirection != null &&
                widget.session?.imageBytes != null)
              IconButton(
                key: const ValueKey('screenshot-result-reverse-direction'),
                tooltip: widget.session == null
                    ? '自动方向不准确？可反向重新翻译'
                    : '方向不准？改用${widget.session!.direction.opposite.actionLabel}重新翻译',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                onPressed:
                    !_busy &&
                        widget.session?.imageBytes != null &&
                        _source.text.trim().isNotEmpty
                    ? () => widget.onReverseDirection!(_source.text)
                    : null,
                icon: const Icon(Icons.swap_horiz_rounded, size: 17),
              ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed:
                  !_busy &&
                      widget.session?.imageBytes != null &&
                      _source.text.trim().isNotEmpty
                  ? () => widget.onRetranslate(_source.text)
                  : null,
              child: Text(
                widget.session?.status == ScreenshotTranslationStatus.failed
                    ? '重试翻译'
                    : '重新翻译',
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final hint = Row(
                  children: [
                    Icon(Icons.search_rounded, size: 15, color: colors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '选中 OCR 原文中的中文或英文词语，再点查释义。',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.2,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                );
                final lookupButton = TextButton.icon(
                  key: const ValueKey('screenshot-source-dictionary-lookup'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed:
                      _dictionaryLookupAvailable(widget.session) &&
                          _selectedDictionaryTerm != null &&
                          !_busy &&
                          !_lookingUpWord &&
                          widget.onLookupDictionary != null
                      ? () => _lookupWord(
                          _selectedDictionaryTerm!,
                          expectedSession: widget.session!,
                        )
                      : null,
                  icon: _lookingUpWord
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search_rounded, size: 15),
                  label: Text(
                    _selectedDictionaryTerm == null
                        ? '选词查释义'
                        : '查询“${_selectedDictionaryTerm!}”',
                    overflow: TextOverflow.ellipsis,
                  ),
                );
                if (constraints.maxWidth < 390) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      hint,
                      Align(
                        alignment: Alignment.centerRight,
                        child: lookupButton,
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: hint),
                    const SizedBox(width: 5),
                    lookupButton,
                  ],
                );
              },
            ),
          ),
        ),
      ),
      Expanded(
        child: TextField(
          controller: _source,
          expands: true,
          minLines: null,
          maxLines: null,
          readOnly: _busy || _addingWord || _lookingUpWord,
          contextMenuBuilder: (context, editable) {
            final word = _selectedWord;
            final term = _selectedDictionaryTerm;
            final session = widget.session;
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editable.contextMenuAnchors,
              buttonItems: [
                ...editable.contextMenuButtonItems,
                if (session != null &&
                    !_busy &&
                    !_addingWord &&
                    !_lookingUpWord &&
                    term != null &&
                    _dictionaryLookupAvailable(session) &&
                    widget.onLookupDictionary != null)
                  ContextMenuButtonItem(
                    label: '查词释义',
                    onPressed: () {
                      ContextMenuController.removeAny();
                      _lookupWord(term, expectedSession: session);
                    },
                  ),
                if (session != null &&
                    !_busy &&
                    !_addingWord &&
                    !_lookingUpWord &&
                    word != null &&
                    session.status == ScreenshotTranslationStatus.completed &&
                    _source.text == session.recognizedText &&
                    widget.onAddScreenshotWord != null)
                  ContextMenuButtonItem(
                    label: '加入截屏生词',
                    onPressed: () {
                      ContextMenuController.removeAny();
                      _addWord(word, expectedSession: session);
                    },
                  ),
              ],
            );
          },
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: colors.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: colors.primary, width: 1.4),
            ),
            contentPadding: const EdgeInsets.all(11),
            hintText: '识别文字将在这里显示，可校对后重新翻译。',
            hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          style: TextStyle(fontSize: 13, height: 1.45, color: colors.onSurface),
        ),
      ),
    ],
  );

  String get _displayedTranslationText =>
      widget.session?.translatedText ??
      (widget.session?.status == ScreenshotTranslationStatus.empty
          ? '未识别到文字，请重新截取清晰文字区域。'
          : '译文将在这里显示。');

  Widget _translationPane(ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 35,
        child: Row(
          children: [
            Text(
              '译文',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: '只可从 OCR 原文中选择英文单词添加到截屏生词',
              child: Icon(
                Icons.info_outline_rounded,
                size: 15,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.22),
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              _displayedTranslationText,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.onSurface,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  String _status(ScreenshotTranslationSession? session) {
    return switch (session?.status) {
      ScreenshotTranslationStatus.capturing => '拖动框选区域 · 按 Esc 取消',
      ScreenshotTranslationStatus.recognizing => '正在本机识别文字…',
      ScreenshotTranslationStatus.translating =>
        '正在翻译 · ${_directionStatus(session!)}',
      ScreenshotTranslationStatus.completed =>
        _source.text != session!.recognizedText
            ? '原文已编辑 · 重新翻译更新译文；仍可选词查释义'
            : '翻译完成 · ${_directionStatus(session)} · 已保存到本地文字历史',
      ScreenshotTranslationStatus.empty => '未识别到文字，请缩小选区或选择更清晰的文字。',
      ScreenshotTranslationStatus.failed =>
        session!.recognizedText.isEmpty
            ? screenshotTranslationErrorMessage(session.errorCode)
            : '${_directionStatus(session)} · ${screenshotTranslationErrorMessage(session.errorCode)}',
      ScreenshotTranslationStatus.cancelled => '已取消截屏，可重新截取。',
      null => '点击“开始截屏”选择要翻译的区域。',
    };
  }

  String _directionStatus(ScreenshotTranslationSession session) =>
      '${session.directionManuallyOverridden ? '手动切换' : '自动判定'}${session.direction.actionLabel}';

  String? _routeDisclosure(ScreenshotTranslationSession? session) {
    final route = session?.translationRoute;
    if (route == null) {
      return session?.status == ScreenshotTranslationStatus.translating
          ? '正在确认本次翻译的处理位置…'
          : null;
    }
    final name = route.displayName;
    return switch (route.kind) {
      TranslationExecutionRouteKind.localDictionary => '处理位置：本机词典 · 不联网',
      TranslationExecutionRouteKind.localModel =>
        '处理位置：本机模型${name == null ? '' : '「$name」'} · OCR 文字留在本机',
      TranslationExecutionRouteKind.localCompatibleApi =>
        '处理位置：本机兼容接口${name == null ? '' : '「$name」'} · 请求发往本机；服务可能联网',
      TranslationExecutionRouteKind.remoteProvider =>
        '处理位置：网络服务${name == null ? '' : '「$name」'} · 截图原图不会随请求发送',
      TranslationExecutionRouteKind.unavailable => '处理位置：未找到可用翻译服务 · OCR 文字未发送',
      TranslationExecutionRouteKind.unknown => '处理位置：当前服务未提供路线信息',
    };
  }

  bool _shouldOpenModels(ScreenshotTranslationSession? session) {
    if (session?.status != ScreenshotTranslationStatus.failed) return false;
    return switch (session?.errorCode) {
      'no_remote_provider' ||
      'ambiguous_translation_provider' ||
      'missing_credential' ||
      'local_core_unavailable' ||
      'local_core_error' => true,
      _ => false,
    };
  }

  String? _imageStatusMessage(ScreenshotTranslationSession? session) {
    final imageStatus = session?.imageSaveStatus;
    final imageMessage = session?.imageSaveMessage;
    if (imageMessage != null) return imageMessage;
    if (imageStatus == ScreenshotTranslationImageSaveStatus.saving) {
      return '原图正在保存到本地';
    }
    if (imageStatus == ScreenshotTranslationImageSaveStatus.saved) {
      return '原图已保存在本地';
    }
    return null;
  }
}

String screenshotTranslationErrorMessage(String? code) => switch (code) {
  'network_error' => '网络连接失败，原文已保留，请重试。',
  'request_timeout' => '翻译请求超时，原文已保留，请重试。',
  'no_remote_provider' ||
  'local_core_unavailable' => '请在译学“模型与服务”中配置当前方向的翻译服务。',
  'ambiguous_translation_provider' => '有多个启用的翻译配置，请到“模型与服务”选择唯一配置后重试。',
  'missing_credential' => '当前服务缺少密钥，本次没有发送 OCR 文字；请配置后重试。',
  'invalid_input' => '请保留 1 至 5000 字的原文后重新翻译。',
  'translation_in_progress' => '当前翻译服务正忙，请稍后重试。',
  'ocr_unavailable' => '本机 OCR 未就绪，请检查 OCR 配置后重新截取。',
  'ocr_timeout' => '本机 OCR 处理超时，请缩小截图区域后重试。',
  'ocr_output_limit' => '截图文字过多，请缩小选区或分段截图。',
  'ocr_failed' => '本机 OCR 处理失败，请检查截图内容或 OCR 配置后重试。',
  'region_invalid' => '固定区域已不可用，请重新框选并固定后再刷新。',
  'window_state_unavailable' => '无法确认译学窗口状态，本次未完成截屏，请稍后重试。',
  'capture_failed' => '截屏失败，请重新截取。',
  'cancelled' => '翻译已取消，原文已保留。',
  _ => '处理失败，请检查模型配置后重试。',
};
