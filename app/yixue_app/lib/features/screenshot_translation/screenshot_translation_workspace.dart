import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_result_window.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workbench_settings.dart';

typedef ScreenshotWordAddCallback = Future<bool> Function({
  required String word,
  required String sourceContext,
  required String sourceTranslation,
  required String sourceHistoryId,
});

typedef ScreenshotHistorySummarizer = Future<String> Function(String text);
typedef ScreenshotDictionaryLookup = Future<DictionaryEntry?> Function(
  String word,
);

final class _ScreenshotHistorySummary {
  const _ScreenshotHistorySummary({
    required this.text,
    required this.isPersistedLocally,
    this.persistenceError,
  });

  final String text;
  final bool isPersistedLocally;
  final String? persistenceError;
}

final class _ScreenshotTranslationParagraphPair {
  const _ScreenshotTranslationParagraphPair({
    required this.source,
    required this.translation,
  });

  final String source;
  final String translation;
}

/// Only pairs paragraphs when both text fields explicitly preserve the same
/// number of blank-line-separated groups. History has no OCR block geometry,
/// so this must never be presented as original-image coordinate alignment.
List<_ScreenshotTranslationParagraphPair>? _screenshotTranslationParagraphPairs(
  String source,
  String translation,
) {
  List<String> paragraphs(String value) => value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .trim()
      .split(RegExp(r'\n[ \t]*\n+'))
      .map((paragraph) => paragraph.trim())
      .where((paragraph) => paragraph.isNotEmpty)
      .toList(growable: false);

  final sourceParagraphs = paragraphs(source);
  final translatedParagraphs = paragraphs(translation);
  if (sourceParagraphs.length < 2 ||
      sourceParagraphs.length != translatedParagraphs.length) {
    return null;
  }
  return List<_ScreenshotTranslationParagraphPair>.unmodifiable([
    for (var index = 0; index < sourceParagraphs.length; index++)
      _ScreenshotTranslationParagraphPair(
        source: sourceParagraphs[index],
        translation: translatedParagraphs[index],
      ),
  ]);
}

List<ScreenshotTranslationOcrOverlayPair>? _screenshotHistoryOverlayPairs(
  TranslationHistoryEntryData entry,
) {
  final layout = ScreenshotTranslationOcrLayout.tryParse(
    entry.screenshotOcrLayout,
  );
  return pairScreenshotTranslationOverlay(
    recognizedText: entry.sourceText,
    translatedText: entry.translatedText,
    layout: layout,
    translatedSourceBlockIndices: entry.translatedSourceBlockIndices,
  );
}

/// Reads PNG dimensions from the fixed IHDR header without decoding pixels.
Size? screenshotTranslationPngSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(0, Endian.big) != 0x89504E47 ||
      header.getUint32(12, Endian.big) != 0x49484452) {
    return null;
  }
  final width = header.getUint32(16, Endian.big);
  final height = header.getUint32(20, Endian.big);
  if (width == 0 || height == 0) return null;
  return Size(width.toDouble(), height.toDouble());
}

/// Screenshot translation's history, article detail, and local controls.
///
/// The shell owns the runtime and controllers; this page only presents their
/// existing APIs. Keeping them injectable lets preview shells avoid touching
/// app-wide settings or user data.
final class ScreenshotTranslationWorkspace extends StatefulWidget {
  const ScreenshotTranslationWorkspace({
    required this.runtime,
    required this.onOpenModels,
    this.archiveController,
    this.desktopController,
    this.settingsRequestVersion = 0,
    this.onAddScreenshotWord,
    this.lookupDictionary,
    this.dictionaryLookupHistoryStore,
    this.summarizeHistory,
    super.key,
  });

  final ScreenshotTranslationRuntime runtime;
  final ScreenshotTranslationArchiveController? archiveController;
  final ScreenshotTranslationDesktopController? desktopController;
  final int settingsRequestVersion;
  final VoidCallback onOpenModels;
  final ScreenshotWordAddCallback? onAddScreenshotWord;
  final ScreenshotDictionaryLookup? lookupDictionary;
  final ScreenshotDictionaryLookupHistoryStore? dictionaryLookupHistoryStore;
  final ScreenshotHistorySummarizer? summarizeHistory;

  @override
  State<ScreenshotTranslationWorkspace> createState() =>
      _ScreenshotTranslationWorkspaceState();
}

class _ScreenshotTranslationWorkspaceState
    extends State<ScreenshotTranslationWorkspace> {
  static const _dictionaryLookupHistoryOperationTimeout = Duration(seconds: 3);

  final _queryController = TextEditingController();
  final _historyScrollController = ScrollController();
  Timer? _searchTimer;
  String? _selectedEntryId;
  String? _loadedImageId;
  Future<Uint8List?>? _loadedImage;
  bool _settingsOpen = false;
  bool _archiveRecoveryLoading = false;
  int _archiveLoadGeneration = 0;
  bool _imageStatsLoadStarted = false;
  bool _compactDetailOpen = false;
  bool _showHistoryTranslationOverlay = true;
  String? _selectedWord;
  String? _selectedDictionaryTerm;
  bool _addingWord = false;
  bool _lookingUpWord = false;
  bool _dictionaryLookupHistoryLoading = false;
  bool _dictionaryLookupHistoryUnavailable = false;
  int _dictionaryLookupOperation = 0;
  int _dictionaryLookupHistoryLoadGeneration = 0;
  String? _resolvedLookupHistoryPath;
  ScreenshotDictionaryLookupHistoryStore? _resolvedLookupHistoryStore;
  final List<ScreenshotDictionaryLookupHistoryRecord> _dictionaryLookupHistory =
      <ScreenshotDictionaryLookupHistoryRecord>[];
  ScreenshotTranslationImageStats? _lastImageStats;
  final Map<String, _ScreenshotHistorySummary> _historySummaries =
      <String, _ScreenshotHistorySummary>{};
  final Map<String, String> _historySummaryErrors = <String, String>{};
  final Set<String> _summarizingHistoryIds = <String>{};
  final Set<String> _deletedSummaryEntryIds = <String>{};
  int _summaryWorkspaceGeneration = 0;

  @override
  void initState() {
    super.initState();
    _settingsOpen = widget.settingsRequestVersion > 0;
    _queryController.addListener(_scheduleSearch);
    _historyScrollController.addListener(_loadMoreWhenNearEnd);
    widget.archiveController?.addListener(_onArchiveChanged);
    widget.runtime.addListener(_onExternalChanged);
    widget.desktopController?.addListener(_onExternalChanged);
    unawaited(_loadDictionaryLookupHistory());
    _loadArchive();
  }

  @override
  void didUpdateWidget(covariant ScreenshotTranslationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    var reloadDictionaryLookupHistory = false;
    if (!identical(oldWidget.runtime, widget.runtime)) {
      oldWidget.runtime.removeListener(_onExternalChanged);
      widget.runtime.addListener(_onExternalChanged);
    }
    if (!identical(oldWidget.desktopController, widget.desktopController)) {
      oldWidget.desktopController?.removeListener(_onExternalChanged);
      widget.desktopController?.addListener(_onExternalChanged);
    }
    if (!identical(oldWidget.archiveController, widget.archiveController)) {
      oldWidget.archiveController?.removeListener(_onArchiveChanged);
      widget.archiveController?.addListener(_onArchiveChanged);
      _imageStatsLoadStarted = false;
      _selectedEntryId = null;
      _loadedImageId = null;
      _loadedImage = null;
      _summaryWorkspaceGeneration++;
      _historySummaries.clear();
      _historySummaryErrors.clear();
      _summarizingHistoryIds.clear();
      _deletedSummaryEntryIds.clear();
      reloadDictionaryLookupHistory = true;
      _loadArchive();
    }
    if (!identical(
      oldWidget.dictionaryLookupHistoryStore,
      widget.dictionaryLookupHistoryStore,
    )) {
      reloadDictionaryLookupHistory = true;
    }
    if (reloadDictionaryLookupHistory) {
      unawaited(_loadDictionaryLookupHistory());
    }
    if (widget.settingsRequestVersion != oldWidget.settingsRequestVersion) {
      _settingsOpen = true;
      unawaited(_ensureImageStatsLoaded());
    }
  }

  ScreenshotDictionaryLookupHistoryStore? get _dictionaryLookupHistoryStore {
    final injectedStore = widget.dictionaryLookupHistoryStore;
    if (injectedStore != null) return injectedStore;

    final imageStore = widget.archiveController?.imageStore;
    if (imageStore is! FileScreenshotTranslationImageStore) return null;
    final file = File(
      '${imageStore.rootDirectory.path}${Platform.pathSeparator}'
      'dictionary_lookup_history.json',
    );
    final path = file.absolute.path;
    if (_resolvedLookupHistoryPath != path) {
      _resolvedLookupHistoryPath = path;
      _resolvedLookupHistoryStore = FileScreenshotDictionaryLookupHistoryStore(
        file,
      );
    }
    return _resolvedLookupHistoryStore;
  }

  Future<void> _loadDictionaryLookupHistory() async {
    final generation = ++_dictionaryLookupHistoryLoadGeneration;
    final store = _dictionaryLookupHistoryStore;
    if (store == null) {
      _dictionaryLookupHistory.clear();
      _dictionaryLookupHistoryLoading = false;
      _dictionaryLookupHistoryUnavailable = false;
      return;
    }
    _dictionaryLookupHistoryLoading = true;
    _dictionaryLookupHistoryUnavailable = false;
    try {
      final records = await store.read().timeout(
        _dictionaryLookupHistoryOperationTimeout,
      );
      if (!mounted || generation != _dictionaryLookupHistoryLoadGeneration) {
        return;
      }
      setState(() {
        _dictionaryLookupHistory
          ..clear()
          ..addAll(records.take(screenshotDictionaryLookupHistoryLimit));
        _dictionaryLookupHistoryLoading = false;
        _dictionaryLookupHistoryUnavailable = false;
      });
    } on Object {
      if (!mounted || generation != _dictionaryLookupHistoryLoadGeneration) {
        return;
      }
      setState(() {
        _dictionaryLookupHistoryLoading = false;
        _dictionaryLookupHistoryUnavailable = true;
      });
    }
  }

  void _loadArchive() {
    final archive = widget.archiveController;
    if (archive == null) return;
    unawaited(_recoverThenLoadArchive(archive));
    if (_settingsOpen) unawaited(_ensureImageStatsLoaded());
  }

  Future<void> _recoverThenLoadArchive(
    ScreenshotTranslationArchiveController archive,
  ) async {
    final generation = ++_archiveLoadGeneration;
    if (mounted) setState(() => _archiveRecoveryLoading = true);
    try {
      await archive.recoverPendingImageDeletions();
    } on Object {
      // Keep history usable if local image recovery is unavailable. The image
      // store retains marked backups and read() can still serve a pending copy.
    }
    try {
      await archive.loadFirstPage();
    } finally {
      if (mounted && generation == _archiveLoadGeneration) {
        setState(() => _archiveRecoveryLoading = false);
      }
    }
  }

  Future<void> _ensureImageStatsLoaded() async {
    final archive = widget.archiveController;
    if (!_settingsOpen || archive == null || _imageStatsLoadStarted) return;
    _imageStatsLoadStarted = true;
    try {
      await archive.inspectImages();
    } catch (_) {
      _imageStatsLoadStarted = false;
    }
  }

  void _toggleSettings() {
    final opening = !_settingsOpen;
    setState(() => _settingsOpen = opening);
    if (opening) unawaited(_ensureImageStatsLoaded());
  }

  void _onArchiveChanged() {
    if (!mounted) return;
    final archive = widget.archiveController;
    final stats = archive?.imageStats;
    if (stats != _lastImageStats) {
      _lastImageStats = stats;
      _loadedImageId = null;
      _loadedImage = null;
    }
    setState(() {
      if (_selectedEntryId != null &&
          !(archive?.entries.any((entry) => entry.id == _selectedEntryId) ??
              false)) {
        _selectedEntryId = null;
        _selectedWord = null;
        _selectedDictionaryTerm = null;
      }
      if (archive?.entries.isEmpty == true) _compactDetailOpen = false;
    });
  }

  Future<void> _summarizeHistoryEntry(TranslationHistoryEntryData entry) async {
    final summarize = widget.summarizeHistory;
    if (summarize == null) {
      widget.onOpenModels();
      _showMessage(context, '请在“模型与服务”中为理解与总结配置一个模型。');
      return;
    }
    if (_summarizingHistoryIds.contains(entry.id)) return;
    final workspaceGeneration = _summaryWorkspaceGeneration;
    setState(() {
      _summarizingHistoryIds.add(entry.id);
      _historySummaryErrors.remove(entry.id);
    });
    try {
      final summary = (await summarize(entry.sourceText)).trim();
      if (!mounted ||
          workspaceGeneration != _summaryWorkspaceGeneration ||
          _deletedSummaryEntryIds.contains(entry.id)) {
        return;
      }
      if (summary.isEmpty) {
        throw const LearningSummaryException('invalid_response');
      }
      var persistedLocally = false;
      String? persistenceError;
      final archive = widget.archiveController;
      if (archive == null) {
        persistenceError = '本机历史存储不可用。';
      } else {
        try {
          final core = archive.coreFactory();
          try {
            if (core is! ScreenshotTranslationHistorySummaryCore) {
              persistenceError = '当前 Core 版本不支持保存历史摘要。';
            } else {
              (core as ScreenshotTranslationHistorySummaryCore)
                  .saveScreenshotTranslationSummary(
                    id: entry.id,
                    sourceText: entry.sourceText,
                    summaryText: summary,
                  );
              persistedLocally = true;
            }
          } finally {
            core.dispose();
          }
        } on CoreBridgeException catch (error) {
          persistenceError = error.code == 'unknown_command'
              ? '当前 Core 版本不支持保存历史摘要。'
              : '本机保存失败。';
        } catch (_) {
          persistenceError = '本机保存失败。';
        }
      }
      setState(
        () => _historySummaries[entry.id] = _ScreenshotHistorySummary(
          text: summary,
          isPersistedLocally: persistedLocally,
          persistenceError: persistenceError,
        ),
      );
      if (persistenceError != null) {
        _showMessage(context, '摘要已生成，但未能保存到本机；关闭后不会保留。');
      }
    } on LearningSummaryException catch (error) {
      if (mounted &&
          workspaceGeneration == _summaryWorkspaceGeneration &&
          !_deletedSummaryEntryIds.contains(entry.id)) {
        setState(() => _historySummaryErrors[entry.id] = error.message);
      }
    } catch (_) {
      if (mounted &&
          workspaceGeneration == _summaryWorkspaceGeneration &&
          !_deletedSummaryEntryIds.contains(entry.id)) {
        setState(() => _historySummaryErrors[entry.id] = '摘要生成失败，请稍后重试。');
      }
    } finally {
      if (workspaceGeneration == _summaryWorkspaceGeneration) {
        _summarizingHistoryIds.remove(entry.id);
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _copyHistorySummary(String summary) async {
    await Clipboard.setData(ClipboardData(text: summary));
    if (mounted) _showMessage(context, '摘要已复制');
  }

  void _onExternalChanged() {
    if (mounted) setState(() {});
  }

  void _captureFromWorkbench() {
    final desktop = widget.desktopController;
    unawaited(
      widget.runtime.startWorkbenchCapture(
        captureGuard: desktop == null
            ? null
            : (capture) => desktop.captureWithMainHidden(capture),
      ),
    );
  }

  void _scheduleSearch() {
    _searchTimer?.cancel();
    if (mounted) setState(() {});
    _searchTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      _selectedEntryId = null;
      _selectedWord = null;
      _selectedDictionaryTerm = null;
      _compactDetailOpen = false;
      final archive = widget.archiveController;
      if (archive != null) unawaited(archive.search(_queryController.text));
    });
  }

  void _loadMoreWhenNearEnd() {
    final archive = widget.archiveController;
    if (archive == null || !_historyScrollController.hasClients) return;
    if (_historyScrollController.position.extentAfter < 180 &&
        archive.hasMore &&
        !archive.isLoading) {
      unawaited(archive.loadNextPage());
    }
  }

  void _selectEntry(
    TranslationHistoryEntryData entry, {
    required bool compact,
  }) {
    setState(() {
      _selectedEntryId = entry.id;
      _selectedWord = null;
      _selectedDictionaryTerm = null;
      _compactDetailOpen = compact;
      if (_loadedImageId != entry.id) {
        _loadedImageId = entry.id;
        _loadedImage = null;
      }
    });
  }

  Future<Uint8List?>? _imageFuture(TranslationHistoryEntryData entry) {
    final archive = widget.archiveController;
    if (archive == null) return null;
    if (_loadedImageId != entry.id) {
      _loadedImageId = entry.id;
      _loadedImage = null;
    }
    return _loadedImage ??= archive.readImage(entry);
  }

  Future<void> _refresh() async {
    final archive = widget.archiveController;
    if (archive == null) return;
    await archive.loadFirstPage();
    if (_settingsOpen) await archive.inspectImages();
  }

  @override
  void dispose() {
    _dictionaryLookupOperation++;
    _dictionaryLookupHistoryLoadGeneration++;
    _searchTimer?.cancel();
    _queryController
      ..removeListener(_scheduleSearch)
      ..dispose();
    _historyScrollController
      ..removeListener(_loadMoreWhenNearEnd)
      ..dispose();
    widget.archiveController?.removeListener(_onArchiveChanged);
    widget.runtime.removeListener(_onExternalChanged);
    widget.desktopController?.removeListener(_onExternalChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 800;
        final dockSettings = _settingsOpen && constraints.maxWidth >= 1360;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 12 : 20,
            14,
            compact ? 12 : 20,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, compact),
              const SizedBox(height: 12),
              if (_sessionNeedsBanner) ...[
                _buildSessionBanner(context),
                const SizedBox(height: 10),
              ],
              Expanded(
                child: dockSettings
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildWorkbench(context, compact: false),
                          ),
                          const SizedBox(width: 14),
                          SizedBox(
                            width: 340,
                            child: _buildSettingsPane(context, compact: false),
                          ),
                        ],
                      )
                    : _settingsOpen
                    ? _buildSettingsPane(context, compact: compact)
                    : _buildWorkbench(context, compact: compact),
              ),
            ],
          ),
        );
      },
    );
  }

  bool get _sessionNeedsBanner {
    if (widget.runtime.windowError != null) return true;
    final status = widget.runtime.session?.status;
    return status == ScreenshotTranslationStatus.capturing ||
        status == ScreenshotTranslationStatus.recognizing ||
        status == ScreenshotTranslationStatus.translating ||
        status == ScreenshotTranslationStatus.completed ||
        status == ScreenshotTranslationStatus.failed ||
        status == ScreenshotTranslationStatus.empty ||
        status == ScreenshotTranslationStatus.cancelled;
  }

  Widget _buildHeader(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    final palette = YixueShellPalette.of(context);
    final desktop = widget.desktopController;
    final hotKey = desktop?.preferences.hotKey.label;
    final session = widget.runtime.session;
    final orbState = desktop?.orbRuntimeState;
    final chips = <Widget>[
      _StatusChip(
        icon: switch (orbState) {
          null => Icons.desktop_access_disabled_outlined,
          ScreenshotOrbRuntimeState.initializing ||
          ScreenshotOrbRuntimeState.starting ||
          ScreenshotOrbRuntimeState.closing => Icons.hourglass_top_rounded,
          ScreenshotOrbRuntimeState.visible => Icons.blur_on_rounded,
          ScreenshotOrbRuntimeState.disabled => Icons.blur_off_rounded,
          ScreenshotOrbRuntimeState.failed => Icons.error_outline_rounded,
        },
        label: switch (orbState) {
          null => '悬浮球：未连接',
          ScreenshotOrbRuntimeState.initializing => '悬浮球：初始化中',
          ScreenshotOrbRuntimeState.starting => '悬浮球：启动中',
          ScreenshotOrbRuntimeState.visible => '悬浮球：已显示',
          ScreenshotOrbRuntimeState.closing => '悬浮球：关闭中',
          ScreenshotOrbRuntimeState.disabled => '悬浮球：已关闭',
          ScreenshotOrbRuntimeState.failed =>
            desktop?.preferences.orbEnabled == false ? '悬浮球：关闭失败' : '悬浮球：启动失败',
        },
        isWarning: orbState == ScreenshotOrbRuntimeState.failed,
      ),
      _StatusChip(
        icon: Icons.keyboard_alt_outlined,
        label: hotKey == null ? '快捷键：未连接' : '快捷键 $hotKey',
        isWarning: desktop?.hotKeyError != null,
      ),
      _StatusChip(
        icon: Icons.image_outlined,
        label: desktop == null
            ? '原图设置：未连接'
            : desktop.preferences.saveScreenshotImages
            ? '原图自动保存：开'
            : '原图自动保存：关',
      ),
      if (session?.imageSaveStatus ==
          ScreenshotTranslationImageSaveStatus.saved)
        const _StatusChip(icon: Icons.save_outlined, label: '本次原图已保存'),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.selectedStart.withValues(alpha: 0.11),
            palette.selectedEnd.withValues(alpha: 0.08),
            theme.colorScheme.surface.withValues(alpha: 0.94),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 20,
          vertical: 14,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 12,
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 320 : 510),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? 0.22
                                : 0.10,
                          ),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.document_scanner_outlined,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '截屏翻译',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '本机识别 · 原图留在本地 · 文章与历史在这里对照',
                              maxLines: compact ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: hotKey == null ? '系统快捷键未连接' : '系统快捷键 $hotKey',
                      child: FilledButton.icon(
                        key: const ValueKey('screenshot-workbench-capture'),
                        onPressed:
                            Platform.isWindows &&
                                session?.status !=
                                    ScreenshotTranslationStatus.capturing
                            ? _captureFromWorkbench
                            : null,
                        icon: const Icon(Icons.crop_free_rounded),
                        label: const Text('框选翻译'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: session?.imageBytes != null
                          ? () => unawaited(widget.runtime.reopenResult())
                          : null,
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('恢复结果框'),
                    ),
                    TextButton.icon(
                      onPressed: widget.onOpenModels,
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('模型与服务'),
                    ),
                    IconButton(
                      key: const ValueKey(
                        'screenshot-workbench-toggle-settings',
                      ),
                      tooltip: _settingsOpen ? '返回工作台' : '截屏设置',
                      onPressed: _toggleSettings,
                      icon: Icon(
                        _settingsOpen
                            ? Icons.close_rounded
                            : Icons.settings_outlined,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionBanner(BuildContext context) {
    final session = widget.runtime.session;
    final windowError = widget.runtime.windowError;
    if (session == null && windowError == null) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final error =
        windowError != null ||
        session?.status == ScreenshotTranslationStatus.failed ||
        session?.status == ScreenshotTranslationStatus.empty ||
        session?.imageSaveStatus ==
            ScreenshotTranslationImageSaveStatus.failed ||
        session?.imageSaveStatus ==
            ScreenshotTranslationImageSaveStatus.cacheLimitReached;
    final message =
        windowError ??
        (session == null
            ? '结果窗口连接失败。'
            : switch (session.status) {
                ScreenshotTranslationStatus.capturing =>
                  '拖动框选屏幕上的文字，按 Esc 或右键取消。',
                ScreenshotTranslationStatus.recognizing => '正在本机识别文字。',
                ScreenshotTranslationStatus.translating => '正在翻译；您可以继续使用原应用。',
                ScreenshotTranslationStatus.completed =>
                  '最近一次截屏翻译已完成，可在下方历史中查看。',
                ScreenshotTranslationStatus.empty => '没有识别到文字，请重新截取更清晰的区域。',
                ScreenshotTranslationStatus.failed =>
                  screenshotTranslationErrorMessage(session.errorCode),
                ScreenshotTranslationStatus.cancelled => '已取消截屏。',
              });
    return Container(
      key: const ValueKey('screenshot-workbench-session-status'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: (error ? colors.error : colors.primary).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (error ? colors.error : colors.primary).withValues(
            alpha: 0.24,
          ),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            error ? Icons.info_outline_rounded : Icons.auto_awesome_outlined,
            size: 18,
            color: error ? colors.error : colors.primary,
          ),
          Text(message),
          if (session != null && session.imageSaveMessage != null)
            Text(
              session.imageSaveMessage!,
              style: TextStyle(color: error ? colors.error : colors.onSurface),
            ),
          if (session != null &&
              session.status == ScreenshotTranslationStatus.failed &&
              session.recognizedText.trim().isNotEmpty)
            TextButton(
              key: const ValueKey('screenshot-workbench-retry-translation'),
              onPressed: () =>
                  unawaited(widget.runtime.retranslate(session.recognizedText)),
              child: const Text('重试翻译'),
            ),
          if (windowError != null && session != null)
            TextButton(
              key: const ValueKey('screenshot-workbench-reopen-result'),
              onPressed: () => unawaited(widget.runtime.reopenResult()),
              child: const Text('重新打开结果框'),
            ),
          if (session != null &&
              widget.runtime.retryableImageSaves.any(
                (item) => item.captureId == session.id,
              ))
            TextButton(
              key: const ValueKey('screenshot-workbench-retry-current-image'),
              onPressed: () => unawaited(
                widget.runtime.retryImageSave(captureId: session.id),
              ),
              child: const Text('重试保存原图'),
            ),
          if (session?.status == ScreenshotTranslationStatus.failed &&
              session!.recognizedText.trim().isEmpty)
            TextButton(
              onPressed: _captureFromWorkbench,
              child: const Text('重新截取'),
            ),
        ],
      ),
    );
  }

  Widget _buildWorkbench(BuildContext context, {required bool compact}) {
    final archive = widget.archiveController;
    if (archive == null) return _buildArchiveNotConnected(context);
    if (compact) {
      final selected = _selectedEntry(archive);
      if (_compactDetailOpen && selected != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('screenshot-workbench-back-to-history'),
                onPressed: () => setState(() => _compactDetailOpen = false),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('返回历史'),
              ),
            ),
            Expanded(child: _buildDetail(context, selected, compact: true)),
          ],
        );
      }
      return _buildHistoryPanel(context, compact: true);
    }
    final selected = _selectedEntry(archive);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 284,
          child: _buildHistoryPanel(context, compact: false),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: selected == null
              ? _buildNoSelection(context)
              : _buildDetail(context, selected, compact: false),
        ),
      ],
    );
  }

  TranslationHistoryEntryData? _selectedEntry(
    ScreenshotTranslationArchiveController archive,
  ) {
    for (final entry in archive.entries) {
      if (entry.id == _selectedEntryId) return entry;
    }
    return archive.entries.isEmpty ? null : archive.entries.first;
  }

  Widget _buildArchiveNotConnected(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _PanelSurface(
      child: _EmptyState(
        icon: Icons.history_toggle_off_rounded,
        title: '截屏历史还未接入',
        description: '页面可以开始框选；历史归档由主窗口连接后会显示在这里。',
        action: FilledButton.icon(
          onPressed: () => unawaited(widget.runtime.openHistory()),
          icon: const Icon(Icons.history_rounded),
          label: const Text('打开完整翻译历史'),
        ),
        accent: colors.primary,
      ),
    );
  }

  Widget _buildHistoryPanel(BuildContext context, {required bool compact}) {
    final archive = widget.archiveController!;
    final colors = Theme.of(context).colorScheme;
    final recoveryOrPageLoading = _archiveRecoveryLoading || archive.isLoading;
    final loadingFirstPage = recoveryOrPageLoading && archive.entries.isEmpty;
    return _PanelSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 14 : 16, 14, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '截屏历史',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${archive.entries.length}${archive.hasMore ? '+' : ''}',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('screenshot-workbench-refresh-history'),
                  tooltip: '刷新历史',
                  onPressed: recoveryOrPageLoading
                      ? null
                      : () => unawaited(_refresh()),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: TextField(
              key: const ValueKey('screenshot-workbench-search'),
              controller: _queryController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: '搜索原文或译文',
                suffixIcon: _queryController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: _queryController.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (recoveryOrPageLoading && archive.entries.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: loadingFirstPage
                ? _HistoryLoading(dense: !compact)
                : archive.lastError != null && archive.entries.isEmpty
                ? _HistoryFailure(
                    dense: !compact,
                    onRetry: () => unawaited(_refresh()),
                  )
                : archive.entries.isEmpty
                ? _HistoryEmpty(
                    dense: !compact,
                    hasQuery: archive.query.isNotEmpty,
                    onCapture: _captureFromWorkbench,
                    onClear: archive.query.isEmpty
                        ? null
                        : () => _queryController.clear(),
                  )
                : ListView.builder(
                    key: const ValueKey('screenshot-workbench-history-list'),
                    controller: _historyScrollController,
                    padding: const EdgeInsets.fromLTRB(10, 3, 10, 12),
                    itemCount:
                        archive.entries.length +
                        (archive.hasMore || archive.isCapped ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= archive.entries.length) {
                        return _HistoryTail(
                          capped: archive.isCapped,
                          loading: archive.isLoading,
                          onLoadMore: () => unawaited(archive.loadNextPage()),
                        );
                      }
                      final entry = archive.entries[index];
                      return _HistoryRow(
                        entry: entry,
                        selected:
                            entry.id ==
                            (_selectedEntryId ?? archive.entries.first.id),
                        imageRetryAvailable: widget.runtime.retryableImageSaves
                            .any((item) => item.captureId == entry.captureId),
                        onTap: () => _selectEntry(entry, compact: compact),
                        onDelete: () => _confirmDelete(entry),
                      );
                    },
                  ),
          ),
          if (archive.isCapped)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(
                '历史数量已达到本地查询上限。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetail(
    BuildContext context,
    TranslationHistoryEntryData entry, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _PanelSurface(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 14 : 18, 12, 10, 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 8,
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 300 : 520),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.article_outlined,
                          size: 19,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatTimestamp(entry.createdAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${entry.sourceLanguage} → ${entry.targetLanguage} · ${entry.providerId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    Tooltip(
                      message: '将当前记录的 OCR 原文发送到已指定的理解与总结服务（本机或网络）；不会发送截图。',
                      child: TextButton.icon(
                        key: const ValueKey('screenshot-workbench-summarize'),
                        onPressed: _summarizingHistoryIds.contains(entry.id)
                            ? null
                            : () => _summarizeHistoryEntry(entry),
                        icon: _summarizingHistoryIds.contains(entry.id)
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome_rounded, size: 17),
                        label: Text(
                          _summarizingHistoryIds.contains(entry.id)
                              ? '总结中'
                              : (_historySummaries.containsKey(entry.id) ||
                                    entry.summaryText != null)
                              ? '重新总结'
                              : 'AI 总结',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '复制 OCR 原文',
                      onPressed: () =>
                          _copy(context, entry.sourceText, '原文已复制'),
                      icon: const Icon(Icons.content_copy_rounded),
                    ),
                    IconButton(
                      tooltip: '复制译文',
                      onPressed: () =>
                          _copy(context, entry.translatedText, '译文已复制'),
                      icon: const Icon(Icons.copy_all_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('screenshot-workbench-delete-entry'),
                      tooltip: '删除此条历史与对应原图',
                      onPressed: () => _confirmDelete(entry),
                      color: colors.error,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 12 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildImagePreview(context, entry),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final sideBySide = constraints.maxWidth >= 720;
                      final historyOverlayPairs =
                          _screenshotHistoryOverlayPairs(entry);
                      final paragraphPairs = historyOverlayPairs == null
                          ? _screenshotTranslationParagraphPairs(
                              entry.sourceText,
                              entry.translatedText,
                            )
                          : null;
                      final sourcePanel = _ArticlePanel(
                        title: 'OCR 原文',
                        language: entry.sourceLanguage,
                        text: entry.sourceText,
                        icon: Icons.text_snippet_outlined,
                        onCopy: () => _copy(context, entry.sourceText, '原文已复制'),
                        child: SelectableText(
                          entry.sourceText,
                          key: const ValueKey('screenshot-workbench-ocr-text'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.58,
                          ),
                          onSelectionChanged: (selection, _) =>
                              _onWordSelection(entry.sourceText, selection),
                        ),
                      );
                      final translationPanel = _ArticlePanel(
                        title: '译文',
                        language: entry.targetLanguage,
                        text: entry.translatedText,
                        icon: Icons.translate_rounded,
                        onCopy: () =>
                            _copy(context, entry.translatedText, '译文已复制'),
                        child: SelectableText(
                          entry.translatedText,
                          key: const ValueKey(
                            'screenshot-workbench-translation-text',
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.58,
                          ),
                          onSelectionChanged: (_, _) => _clearWordSelection(),
                        ),
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (historyOverlayPairs != null) ...[
                            Text(
                              '已恢复 ${historyOverlayPairs.length} 组 OCR 原图位置与对应译文；原图可切换位置叠译。',
                              key: const ValueKey(
                                'screenshot-workbench-history-alignment-note',
                              ),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (paragraphPairs != null) ...[
                            Text(
                              '段落对照 · 按文本换行分组，不代表原图坐标对齐',
                              key: const ValueKey(
                                'screenshot-workbench-paragraph-comparison-note',
                              ),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (
                              var index = 0;
                              index < paragraphPairs.length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(height: 8),
                              Container(
                                key: ValueKey(
                                  'screenshot-workbench-aligned-block-$index',
                                ),
                                child: sideBySide
                                    ? Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: _buildParagraphPanel(
                                              context,
                                              entry: entry,
                                              paragraph: paragraphPairs[index],
                                              index: index,
                                              source: true,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _buildParagraphPanel(
                                              context,
                                              entry: entry,
                                              paragraph: paragraphPairs[index],
                                              index: index,
                                              source: false,
                                            ),
                                          ),
                                        ],
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _buildParagraphPanel(
                                            context,
                                            entry: entry,
                                            paragraph: paragraphPairs[index],
                                            index: index,
                                            source: true,
                                          ),
                                          const SizedBox(height: 8),
                                          _buildParagraphPanel(
                                            context,
                                            entry: entry,
                                            paragraph: paragraphPairs[index],
                                            index: index,
                                            source: false,
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ] else if (sideBySide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: sourcePanel),
                                const SizedBox(width: 12),
                                Expanded(child: translationPanel),
                              ],
                            )
                          else ...[
                            sourcePanel,
                            const SizedBox(height: 12),
                            translationPanel,
                          ],
                          const SizedBox(height: 10),
                          _buildWordAction(context, entry),
                          const SizedBox(height: 10),
                          _buildHistorySummaryPanel(context, entry),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParagraphPanel(
    BuildContext context, {
    required TranslationHistoryEntryData entry,
    required _ScreenshotTranslationParagraphPair paragraph,
    required int index,
    required bool source,
  }) {
    final theme = Theme.of(context);
    final text = source ? paragraph.source : paragraph.translation;
    final language = source ? entry.sourceLanguage : entry.targetLanguage;
    final title = source ? '原文 · 段落 ${index + 1}' : '译文 · 段落 ${index + 1}';
    final textKey = source ? 'ocr' : 'translation';
    return _ArticlePanel(
      title: title,
      language: language,
      text: text,
      icon: source ? Icons.text_snippet_outlined : Icons.translate_rounded,
      onCopy: () => _copy(context, text, source ? '段落原文已复制' : '段落译文已复制'),
      child: SelectableText(
        text,
        key: ValueKey('screenshot-workbench-$textKey-block-$index'),
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.58),
        onSelectionChanged: source
            ? (selection, _) => _onWordSelection(text, selection)
            : (_, _) => _clearWordSelection(),
      ),
    );
  }

  Widget _buildHistorySummaryPanel(
    BuildContext context,
    TranslationHistoryEntryData entry,
  ) {
    final generatedSummary = _historySummaries[entry.id];
    final summary = generatedSummary?.text ?? entry.summaryText;
    final summaryPersisted =
        generatedSummary?.isPersistedLocally ?? (entry.summaryText != null);
    final persistenceError = generatedSummary?.persistenceError;
    final persistenceLabel = summary == null
        ? '生成成功后会保存到本机历史。'
        : summaryPersisted
        ? '摘要已保存在本机历史中。'
        : '摘要仅在本次查看中保留。';
    final error = _historySummaryErrors[entry.id];
    final loading = _summarizingHistoryIds.contains(entry.id);
    if (summary == null && error == null && !loading) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('screenshot-workbench-ai-summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.42),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: colors.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'AI 学习摘要',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (summary != null)
                IconButton(
                  key: const ValueKey('screenshot-workbench-copy-summary'),
                  tooltip: '复制摘要',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _copyHistorySummary(summary),
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
            ],
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('正在根据这条 OCR 原文整理重点…'),
                ],
              ),
            ),
          if (summary != null)
            SelectableText(
              summary,
              key: const ValueKey('screenshot-workbench-summary-text'),
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurface, height: 1.55),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      error,
                      style: TextStyle(color: colors.error, height: 1.4),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenModels,
                    child: const Text('模型与服务'),
                  ),
                ],
              ),
            ),
          if (persistenceError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '摘要已生成，但未能保存到本机：$persistenceError',
                style: TextStyle(color: colors.error, height: 1.4),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '只将 OCR 原文发送到当前指定的“理解与总结”服务（本机或网络），不发送截图。$persistenceLabel',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreview(
    BuildContext context,
    TranslationHistoryEntryData entry,
  ) {
    final colors = Theme.of(context).colorScheme;
    final future = _imageFuture(entry);
    if (future == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('screenshot-workbench-image-preview'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.tertiaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.crop_original_rounded,
              size: 19,
              color: colors.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FutureBuilder<Uint8List?>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Row(
                    children: [
                      Icon(Icons.hourglass_top_rounded, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        '正在读取本地原图…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  );
                }
                if (snapshot.hasError || snapshot.data == null) {
                  return _MissingImageNotice(
                    captureId: entry.captureId,
                    retryAvailable: widget.runtime.retryableImageSaves.any(
                      (item) => item.captureId == entry.captureId,
                    ),
                    runtime: widget.runtime,
                  );
                }
                final bytes = snapshot.data!;
                final pngSize = screenshotTranslationPngSize(bytes);
                final layout = ScreenshotTranslationOcrLayout.tryParse(
                  entry.screenshotOcrLayout,
                );
                final overlayPairs = _screenshotHistoryOverlayPairs(entry);
                final canOverlay =
                    pngSize != null &&
                    layout != null &&
                    overlayPairs != null &&
                    layout.imageWidth == pngSize.width.toInt() &&
                    layout.imageHeight == pngSize.height.toInt();
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 480.0;
                    final maxImageWidth = width.clamp(1.0, 320.0).toDouble();
                    final aspectRatio = pngSize == null
                        ? 16 / 9
                        : pngSize.width / pngSize.height;
                    const maxImageHeight = 260.0;
                    var imageWidth = maxImageWidth;
                    var imageHeight = imageWidth / aspectRatio;
                    if (imageHeight > maxImageHeight) {
                      imageHeight = maxImageHeight;
                      imageWidth = imageHeight * aspectRatio;
                    }
                    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
                    final thumbnail = ResizeImage(
                      MemoryImage(bytes),
                      width: (imageWidth * pixelRatio)
                          .round()
                          .clamp(1, 2048)
                          .toInt(),
                      height: (imageHeight * pixelRatio)
                          .round()
                          .clamp(1, 2048)
                          .toInt(),
                      policy: ResizeImagePolicy.fit,
                    );
                    final scale = layout == null
                        ? 0.0
                        : imageWidth / layout.imageWidth;
                    return InkWell(
                      key: const ValueKey(
                        'screenshot-workbench-image-preview-open',
                      ),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _showImageDialog(
                        context,
                        bytes,
                        layout: canOverlay ? layout : null,
                        overlayPairs: canOverlay ? overlayPairs : null,
                      ),
                      child: SizedBox(
                        width: width,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: SizedBox(
                                width: imageWidth,
                                height: imageHeight,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image(
                                      image: thumbnail,
                                      width: imageWidth,
                                      height: imageHeight,
                                      fit: BoxFit.fill,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                    if (_showHistoryTranslationOverlay &&
                                        canOverlay)
                                      for (
                                        var index = 0;
                                        index < overlayPairs.length;
                                        index++
                                      )
                                        _buildHistoryTranslationOverlayBlock(
                                          pair: overlayPairs[index],
                                          index: index,
                                          scale: scale,
                                          canvasSize: Size(
                                            imageWidth,
                                            imageHeight,
                                          ),
                                          colors: colors,
                                        ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (canOverlay)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  key: const ValueKey(
                                    'screenshot-workbench-history-overlay-toggle',
                                  ),
                                  onPressed: () => setState(
                                    () => _showHistoryTranslationOverlay =
                                        !_showHistoryTranslationOverlay,
                                  ),
                                  icon: Icon(
                                    _showHistoryTranslationOverlay
                                        ? Icons.visibility_off_outlined
                                        : Icons.translate_rounded,
                                    size: 16,
                                  ),
                                  label: Text(
                                    _showHistoryTranslationOverlay
                                        ? '隐藏位置叠译'
                                        : '显示位置叠译',
                                  ),
                                ),
                              ),
                            Text(
                              '本地原图',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            Text(
                              '点击放大 · 图片只保存在本机',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Positioned _buildHistoryTranslationOverlayBlock({
    required ScreenshotTranslationOcrOverlayPair pair,
    required int index,
    required double scale,
    required Size canvasSize,
    required ColorScheme colors,
    String keyPrefix = 'screenshot-history-translation-overlay',
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
            borderRadius: BorderRadius.circular(3),
            onTap: () => unawaited(
              showScreenshotTranslationOverlayDetail(context, pair),
            ),
            child: DecoratedBox(
              key: ValueKey('$keyPrefix-$index'),
              decoration: BoxDecoration(
                color: const Color(0xE60B1523),
                border: Border.all(color: colors.primary.withValues(alpha: .9)),
                borderRadius: BorderRadius.circular(3),
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

  void _showImageDialog(
    BuildContext context,
    Uint8List bytes, {
    ScreenshotTranslationOcrLayout? layout,
    List<ScreenshotTranslationOcrOverlayPair>? overlayPairs,
  }) {
    var showOverlay = _showHistoryTranslationOverlay;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final screenSize = MediaQuery.sizeOf(context);
          final dialogWidth = (screenSize.width - 56)
              .clamp(280.0, 1720.0)
              .toDouble();
          final dialogHeight = (screenSize.height - 56)
              .clamp(220.0, 1000.0)
              .toDouble();
          final canOverlay = layout != null && overlayPairs != null;
          return Dialog(
            key: const ValueKey('screenshot-workbench-image-dialog'),
            insetPadding: const EdgeInsets.all(28),
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final resolvedLayout = layout;
                        final resolvedOverlayPairs = overlayPairs;
                        if (resolvedLayout == null ||
                            resolvedOverlayPairs == null) {
                          return InteractiveViewer(
                            minScale: 0.6,
                            maxScale: 5,
                            child: Image.memory(bytes, fit: BoxFit.contain),
                          );
                        }
                        final originalSize = Size(
                          resolvedLayout.imageWidth.toDouble(),
                          resolvedLayout.imageHeight.toDouble(),
                        );
                        final canvasSize = applyBoxFit(
                          BoxFit.contain,
                          originalSize,
                          constraints.biggest,
                        ).destination;
                        if (canvasSize.width <= 0 ||
                            canvasSize.height <= 0 ||
                            !canvasSize.width.isFinite ||
                            !canvasSize.height.isFinite) {
                          return const Center(child: Text('原图预览暂不可用'));
                        }
                        final scale = canvasSize.width / originalSize.width;
                        return Center(
                          child: InteractiveViewer(
                            constrained: false,
                            minScale: 0.6,
                            maxScale: 5,
                            child: SizedBox(
                              width: canvasSize.width,
                              height: canvasSize.height,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.memory(bytes, fit: BoxFit.fill),
                                  if (showOverlay)
                                    for (
                                      var index = 0;
                                      index < resolvedOverlayPairs.length;
                                      index++
                                    )
                                      _buildHistoryTranslationOverlayBlock(
                                        pair: resolvedOverlayPairs[index],
                                        index: index,
                                        scale: scale,
                                        canvasSize: canvasSize,
                                        colors: Theme.of(context).colorScheme,
                                        keyPrefix: 'screenshot-history-image-dialog-translation-overlay',
                                      ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (canOverlay)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface
                            .withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(9),
                        elevation: 2,
                        child: TextButton.icon(
                          key: const ValueKey(
                            'screenshot-workbench-image-dialog-overlay-toggle',
                          ),
                          onPressed: () {
                            final next = !showOverlay;
                            setDialogState(() => showOverlay = next);
                            if (mounted) {
                              setState(
                                () => _showHistoryTranslationOverlay = next,
                              );
                            }
                          },
                          icon: Icon(
                            showOverlay
                                ? Icons.visibility_off_outlined
                                : Icons.translate_rounded,
                            size: 16,
                          ),
                          label: Text(showOverlay ? '隐藏位置叠译' : '显示位置叠译'),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      tooltip: '关闭原图预览',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _onWordSelection(String text, TextSelection selection) {
    if (!mounted) return;
    String? selected;
    String? selectedTerm;
    if (selection.isValid && !selection.isCollapsed) {
      final start = selection.start.clamp(0, text.length);
      final end = selection.end.clamp(0, text.length);
      if (start < end) {
        selected = englishWordAtSelection(text, start, end);
        selectedTerm = dictionaryTermAtSelection(text, start, end);
      }
    }
    if (_selectedWord != selected || _selectedDictionaryTerm != selectedTerm) {
      setState(() {
        _selectedWord = selected;
        _selectedDictionaryTerm = selectedTerm;
      });
    }
  }

  void _clearWordSelection() {
    if (!mounted ||
        (_selectedWord == null && _selectedDictionaryTerm == null)) {
      return;
    }
    setState(() {
      _selectedWord = null;
      _selectedDictionaryTerm = null;
    });
  }

  Widget _buildWordAction(
    BuildContext context,
    TranslationHistoryEntryData entry,
  ) {
    final callback = widget.onAddScreenshotWord;
    final colors = Theme.of(context).colorScheme;
    final selectionValid = _selectedWord != null;
    final dictionarySelectionValid = _selectedDictionaryTerm != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.44),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.bookmark_add_outlined, size: 18, color: colors.primary),
          Text(
            selectionValid
                ? '已选中 “$_selectedWord”'
                : dictionarySelectionValid
                ? '已选中 “$_selectedDictionaryTerm” · 可查本地释义'
                : '在 OCR 原文中选择英文词可加入生词；中英文词语均可查释义',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('screenshot-workbench-lookup-word'),
            onPressed:
                !dictionarySelectionValid ||
                    widget.lookupDictionary == null ||
                    _lookingUpWord
                ? null
                : () => _lookupSelectedWord(context, entry),
            icon: _lookingUpWord
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search_rounded),
            label: const Text('查词释义'),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('screenshot-workbench-add-word'),
            onPressed: !selectionValid || callback == null || _addingWord
                ? null
                : () => _addWord(context, entry, callback),
            icon: _addingWord
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('加入截屏生词'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('screenshot-workbench-lookup-history'),
            onPressed: _showDictionaryLookupHistory,
            icon: const Icon(Icons.history_rounded, size: 17),
            label: Text('最近查词 · ${_dictionaryLookupHistory.length}'),
          ),
          if (callback == null)
            Text(
              '学习集尚未接线',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          if (widget.lookupDictionary == null)
            Text(
              '本地词典尚未接线',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Future<void> _lookupSelectedWord(
    BuildContext context,
    TranslationHistoryEntryData historyEntry,
  ) async {
    final word = _selectedDictionaryTerm;
    final lookup = widget.lookupDictionary;
    if (word == null || lookup == null || _lookingUpWord) return;
    final operation = ++_dictionaryLookupOperation;
    setState(() => _lookingUpWord = true);
    try {
      final dictionaryEntry = await lookup(word);
      if (!mounted || operation != _dictionaryLookupOperation) return;
      if (!context.mounted) return;
      if (dictionaryEntry == null) {
        _showMessage(context, '本地词典暂未收录“$word”。');
        return;
      }
      final record = ScreenshotDictionaryLookupHistoryRecord(
        entry: _snapshotDictionaryEntry(dictionaryEntry),
        lookupQuery: word,
        sessionId: _boundedLookupSnapshot(historyEntry.id, 512),
        sourceContext: _screenshotDictionarySourceContext(
          word,
          historyEntry.sourceText,
        ),
        recognizedTextSnapshot: _boundedLookupSnapshot(
          historyEntry.sourceText,
          100000,
        ),
        translationSnapshot: _boundedLookupSnapshot(
          historyEntry.translatedText,
          200000,
        ),
        recordedAt: DateTime.now().toUtc(),
      );
      final store = _dictionaryLookupHistoryStore;
      List<ScreenshotDictionaryLookupHistoryRecord>? persistedHistory;
      if (store != null) {
        // A slower initial read must not replace this newly saved item.
        _dictionaryLookupHistoryLoadGeneration++;
        try {
          persistedHistory = await store
              .add(record)
              .timeout(_dictionaryLookupHistoryOperationTimeout);
        } on Object {
          _dictionaryLookupHistoryUnavailable = true;
        }
      }
      if (!mounted ||
          !context.mounted ||
          operation != _dictionaryLookupOperation) {
        return;
      }
      setState(() {
        _lookingUpWord = false;
        _dictionaryLookupHistoryLoading = false;
        _dictionaryLookupHistoryUnavailable =
            store != null && persistedHistory == null;
        if (persistedHistory != null) {
          _dictionaryLookupHistory
            ..clear()
            ..addAll(
              persistedHistory.take(screenshotDictionaryLookupHistoryLimit),
            );
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
      if (store != null && persistedHistory == null) {
        _showMessage(context, '查词成功，但本机查词记录暂未保存。');
      }
      await _showDictionaryEntry(context, record);
    } catch (_) {
      if (context.mounted) _showMessage(context, '查词失败，请检查本地词典后重试。');
    } finally {
      if (mounted && operation == _dictionaryLookupOperation) {
        setState(() => _lookingUpWord = false);
      }
    }
  }

  ScreenshotDictionaryLookupResult _snapshotDictionaryEntry(
    DictionaryEntry entry,
  ) => ScreenshotDictionaryLookupResult(
    word: _boundedLookupSnapshot(entry.word, 128),
    ipa: _boundedLookupSnapshot(entry.ipa, 512),
    partOfSpeech: _boundedLookupSnapshot(entry.partOfSpeech, 512),
    meanings: List.unmodifiable(
      entry.meanings
          .take(100)
          .map((value) => _boundedLookupSnapshot(value, 4000)),
    ),
    example: _boundedLookupSnapshot(entry.example, 10000),
    exampleTranslation: _boundedLookupSnapshot(entry.exampleTranslation, 10000),
    qualityStatus: _boundedLookupSnapshot(entry.qualityStatus, 128),
    examples: List.unmodifiable([
      for (final example in entry.exampleCandidates.take(5))
        ScreenshotDictionaryExample(
          englishText: _boundedLookupSnapshot(example.englishText, 10000),
          chineseText: _boundedLookupSnapshot(example.chineseText, 10000),
          reviewStatus: _boundedLookupSnapshot(example.reviewStatus, 128),
        ),
    ]),
    variants: List.unmodifiable(
      entry.variants
          .take(100)
          .map((value) => _boundedLookupSnapshot(value, 512)),
    ),
    collocations: List.unmodifiable(
      entry.collocationCandidates
          .take(100)
          .map((value) => _boundedLookupSnapshot(value, 512)),
    ),
    relations: Map.unmodifiable({
      for (final relation in entry.relationCandidates.entries.take(100))
        _boundedLookupSnapshot(relation.key, 128): List<String>.unmodifiable(
          relation.value
              .take(100)
              .map((value) => _boundedLookupSnapshot(value, 512)),
        ),
    }),
  );

  String _boundedLookupSnapshot(String value, int maxLength) {
    final snapshot = value.trim();
    if (snapshot.length <= maxLength) return snapshot;
    return '${snapshot.substring(0, maxLength - 1)}…';
  }

  Future<void> _showDictionaryLookupHistory() async {
    final selected = await showModalBottomSheet<ScreenshotDictionaryLookupHistoryRecord>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final persistent = _dictionaryLookupHistoryStore != null;
        final statusText = _dictionaryLookupHistoryUnavailable
            ? '本机查词记录读取或保存失败；当前工作区仍可查看本次记录。'
            : persistent
            ? '本机保留最近 ${screenshotDictionaryLookupHistoryLimit} 条查词记录；关闭并重新打开工作台后仍可查看。'
            : '当前没有可用的本地历史目录；记录只保留到工作台关闭。';
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '最近查词',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭查词记录',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child:
                      _dictionaryLookupHistoryLoading &&
                          _dictionaryLookupHistory.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _dictionaryLookupHistory.isEmpty
                      ? Center(
                          child: Text(
                            _dictionaryLookupHistoryUnavailable
                                ? '查词历史暂时无法读取。'
                                : '选择 OCR 原文中的词语并查词后，记录会显示在这里。',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          itemCount: _dictionaryLookupHistory.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final record = _dictionaryLookupHistory[index];
                            final entry = record.entry;
                            final meaning = record.entry.meanings.isEmpty
                                ? '暂无本地释义'
                                : entry.meanings.first;
                            final source = record.sourceContext.isNotEmpty
                                ? record.sourceContext
                                : record.recognizedTextSnapshot;
                            return ListTile(
                              key: ValueKey(
                                'screenshot-workbench-lookup-history-${record.sessionId}-${record.recordedAt.microsecondsSinceEpoch}',
                              ),
                              title: Text(
                                record.isModelTranslation
                                    ? '${record.lookupQuery} · 模型试译'
                                    : '${record.lookupQuery}  ·  ${entry.word}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${record.isModelTranslation ? '模型试译：${record.modelTranslation ?? '无结果'}' : meaning}\n$source',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              isThreeLine: true,
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () =>
                                  Navigator.of(sheetContext).pop(record),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  child: Text(
                    statusText,
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null && mounted) {
      await _showDictionaryEntry(context, selected);
    }
  }

  Future<void> _showDictionaryEntry(
    BuildContext context,
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    final entry = record.entry;
    final isModelTranslation = record.isModelTranslation;
    final hasExample =
        entry.example.trim().isNotEmpty ||
        entry.exampleTranslation.trim().isNotEmpty;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isModelTranslation ? '模型试译记录 · ${record.lookupQuery}' : entry.word,
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isModelTranslation) ...[
                  const Text(
                    '模型试译结果 · 非词典释义',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(record.modelTranslation ?? '无试译结果。'),
                  const SizedBox(height: 6),
                  Text(
                    '由当前翻译服务生成；不含词典音标、词性或审校例句。',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ] else ...[
                  if (entry.ipa.trim().isNotEmpty)
                    Text(
                      entry.ipa,
                      style: Theme.of(dialogContext).textTheme.bodyMedium,
                    ),
                  if (entry.partOfSpeech.trim().isNotEmpty) ...[
                    Text(
                      entry.partOfSpeech,
                      style: Theme.of(dialogContext).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (entry.meanings.isNotEmpty) ...[
                    const Text(
                      '释义',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    for (final meaning in entry.meanings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $meaning'),
                      ),
                  ],
                  if (hasExample) ...[
                    const SizedBox(height: 10),
                    const Text(
                      '例句',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    if (entry.example.trim().isNotEmpty) Text(entry.example),
                    if (entry.exampleTranslation.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(entry.exampleTranslation),
                    ],
                  ],
                  if (entry.examples.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text(
                      '来源例句候选 · 待审校',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    for (final example in entry.examples.take(3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${example.englishText}\n${example.chineseText}',
                        ),
                      ),
                  ],
                  if (entry.variants.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('词形变化：${entry.variants.join(' · ')}'),
                  ],
                  if (entry.collocations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('常见搭配：${entry.collocations.join(' · ')}'),
                  ],
                  if (entry.relations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final relation in entry.relations.entries)
                      Text('${relation.key}：${relation.value.join(' · ')}'),
                  ],
                  if (entry.meanings.isEmpty &&
                      !hasExample &&
                      entry.examples.isEmpty &&
                      entry.variants.isEmpty &&
                      entry.collocations.isEmpty &&
                      entry.relations.isEmpty)
                    const Text('本地词典没有可展示的释义或例句。'),
                ],
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  '查词时的原文片段',
                  style: Theme.of(dialogContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(record.sourceContext),
                if (record.recognizedTextSnapshot.trim().isNotEmpty &&
                    record.recognizedTextSnapshot != record.sourceContext) ...[
                  const SizedBox(height: 10),
                  Text(
                    '完整 OCR 原文快照',
                    style: Theme.of(dialogContext).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(record.recognizedTextSnapshot),
                ],
                if (record.translationSnapshot.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '对应译文快照',
                    style: Theme.of(dialogContext).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(record.translationSnapshot),
                ],
                const SizedBox(height: 8),
                Text(
                  isModelTranslation
                      ? '此为模型翻译快照，不等同于词典释义。'
                      : entry.qualityStatus == 'published'
                      ? '译学本地词典'
                      : '词典扩展资料可能仍待审校',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
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

  Future<void> _addWord(
    BuildContext context,
    TranslationHistoryEntryData entry,
    ScreenshotWordAddCallback callback,
  ) async {
    final word = _selectedWord;
    if (word == null) return;
    setState(() => _addingWord = true);
    try {
      final added = await callback(
        word: word,
        sourceContext: entry.sourceText,
        sourceTranslation: entry.translatedText,
        sourceHistoryId: entry.id,
      );
      if (context.mounted) {
        _showMessage(context, added ? '已加入截屏生词；词义可在复习时填写。' : '这个词已经在截屏生词中。');
      }
    } catch (_) {
      if (context.mounted) _showMessage(context, '加入失败，请检查学习数据后重试。');
    } finally {
      if (mounted) setState(() => _addingWord = false);
    }
  }

  Future<void> _confirmDelete(TranslationHistoryEntryData entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('删除这条截屏历史？'),
        content: const Text(
          'OCR 原文和译文记录将从历史中移除；已加入截屏生词的内容会保留。'
          '若其他译文版本仍引用同一张原图，原图会继续保留；删除最后一个版本时才清理原图。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除历史并清理无引用原图'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final archive = widget.archiveController;
    if (archive == null) return;
    final result = await archive.deleteEntry(entry);
    if (!mounted) return;
    if (result.historyDeleted) {
      _deletedSummaryEntryIds.add(entry.id);
      _historySummaries.remove(entry.id);
      _historySummaryErrors.remove(entry.id);
      _summarizingHistoryIds.remove(entry.id);
    }
    if (result.error is ScreenshotTranslationRetryCacheFullException) {
      _showMessage(
        context,
        ScreenshotTranslationRetryCacheFullException.userMessage,
      );
      return;
    }
    if (result.historyDeleted && result.imageCleanupPending) {
      _loadedImageId = null;
      _loadedImage = null;
      _showMessage(
        context,
        '历史已删除，但本次原图尚未清理。设置中的“清理所有已保存原图”会删除全部截图原图，并保留 OCR 与译文历史。',
      );
    } else if (result.historyDeleted && result.imageDeleted) {
      _loadedImageId = null;
      _loadedImage = null;
      _showMessage(context, '历史记录和对应原图已删除。');
    } else if (result.historyDeleted) {
      _showMessage(context, '这条历史已删除；为保留其他版本的数据，对应原图暂时保留。');
    } else if (result.imageDeleted && !result.historyDeleted) {
      _showMessage(context, '原图已删除，但历史记录未删除。请重试删除。');
    } else {
      _showMessage(context, '原图删除未完成，磁盘原图状态未确认；文字历史未删除。请重试删除。');
    }
  }

  Widget _buildNoSelection(BuildContext context) => _PanelSurface(
    child: _EmptyState(
      icon: Icons.touch_app_outlined,
      title: '选择一条截屏记录',
      description: '在左侧历史中选择记录，查看对应原图、OCR 原文和译文。',
      accent: Theme.of(context).colorScheme.primary,
    ),
  );

  Widget _buildSettingsPane(BuildContext context, {required bool compact}) {
    final desktop = widget.desktopController;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('screenshot-workbench-settings-back'),
              onPressed: () => setState(() => _settingsOpen = false),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('返回工作台'),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (desktop == null)
                _PanelSurface(
                  child: _EmptyState(
                    icon: Icons.desktop_access_disabled_outlined,
                    title: '桌面截屏设置不可用',
                    description: '悬浮球和系统级快捷键当前仅支持已接入的 Windows 桌面运行环境。',
                    accent: Theme.of(context).colorScheme.primary,
                  ),
                )
              else
                ScreenshotTranslationWorkbenchSettings(
                  controller: desktop,
                  archiveController: widget.archiveController,
                  runtime: widget.runtime,
                ),
              const SizedBox(height: 12),
              _PanelSurface(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hub_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '共享翻译服务',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '语言与 Provider 沿用快速翻译的共享设置。选区原图只在本机归档；翻译服务接收 OCR 文字用于翻译。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: widget.onOpenModels,
                        icon: const Icon(Icons.settings_suggest_outlined),
                        label: const Text('打开模型与服务设置'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _copy(BuildContext context, String text, String feedback) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _showMessage(context, feedback);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _PanelSurface extends StatelessWidget {
  const _PanelSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      boxShadow: [
        BoxShadow(
          color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.035),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: child,
  );
}

final class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    this.isWarning = false,
  });
  final IconData icon;
  final String label;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = isWarning ? colors.error : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (isWarning ? colors.error : colors.surfaceContainerHighest)
            .withValues(alpha: isWarning ? 0.08 : 0.58),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: (isWarning ? colors.error : colors.outlineVariant).withValues(
            alpha: 0.6,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

final class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.selected,
    required this.imageRetryAvailable,
    required this.onTap,
    required this.onDelete,
  });

  final TranslationHistoryEntryData entry;
  final bool selected;
  final bool imageRetryAvailable;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final border = selected
        ? colors.primary.withValues(alpha: 0.52)
        : colors.outlineVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.55)
            : colors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('screenshot-history-row-${entry.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 31,
                  height: 31,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary.withValues(alpha: 0.12)
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    Icons.crop_rounded,
                    size: 17,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatTimestamp(entry.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colors.onSurface,
                            ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        entry.sourceText.replaceAll(RegExp(r'\s+'), ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Icon(
                            imageRetryAvailable
                                ? Icons.sync_problem_rounded
                                : Icons.translate_rounded,
                            size: 14,
                            color: imageRetryAvailable
                                ? colors.error
                                : colors.primary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              imageRetryAvailable
                                  ? '原图保存待重试'
                                  : entry.translatedText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: imageRetryAvailable
                                        ? colors.error
                                        : colors.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除记录与原图',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: colors.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ArticlePanel extends StatelessWidget {
  const _ArticlePanel({
    required this.title,
    required this.language,
    required this.text,
    required this.icon,
    required this.onCopy,
    required this.child,
  });

  final String title;
  final String language;
  final String text;
  final IconData icon;
  final VoidCallback onCopy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                language,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              IconButton(
                tooltip: '复制$title',
                visualDensity: VisualDensity.compact,
                onPressed: onCopy,
                icon: const Icon(Icons.content_copy_rounded, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 9),
          DefaultTextStyle.merge(
            style: Theme.of(context).textTheme.bodyMedium!
                .copyWith(height: 1.58),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(child: child),
            ),
          ),
        ],
      ),
    );
  }
}

final class _MissingImageNotice extends StatelessWidget {
  const _MissingImageNotice({
    required this.captureId,
    required this.retryAvailable,
    required this.runtime,
  });
  final String captureId;
  final bool retryAvailable;
  final ScreenshotTranslationRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 9,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(
          Icons.image_not_supported_outlined,
          color: colors.onSurfaceVariant,
          size: 20,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            retryAvailable
                ? '原图未保存，OCR 原文和译文仍保留。'
                : '没有找到原图；可能未开启保存，或此前已清理。文字历史仍保留。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        if (retryAvailable)
          TextButton.icon(
            key: ValueKey('screenshot-workbench-retry-image-$captureId'),
            onPressed: () =>
                unawaited(runtime.retryImageSave(captureId: captureId)),
            icon: const Icon(Icons.sync_rounded),
            label: const Text('重试保存'),
          ),
      ],
    );
  }
}

final class _HistoryLoading extends StatelessWidget {
  const _HistoryLoading({required this.dense});
  final bool dense;
  @override
  Widget build(BuildContext context) => dense
      ? _CompactHistoryNotice(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取截屏历史',
          description: '本地记录仍保存在原处。',
          showProgress: true,
        )
      : const _EmptyState(
          icon: Icons.hourglass_top_rounded,
          title: '正在读取截屏历史',
          description: '记录仍保存在本地，稍等片刻。',
          showProgress: true,
        );
}

final class _HistoryFailure extends StatelessWidget {
  const _HistoryFailure({required this.dense, required this.onRetry});
  final bool dense;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final action = OutlinedButton.icon(
      style: _compactHistoryActionStyle,
      onPressed: onRetry,
      icon: const Icon(Icons.refresh_rounded),
      label: const Text('重新加载'),
    );
    return dense
        ? _CompactHistoryNotice(
            icon: Icons.cloud_off_outlined,
            title: '暂时无法读取历史',
            description: '检查本地存储后重试。',
            action: action,
            accent: Theme.of(context).colorScheme.error,
          )
        : _EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '暂时无法读取历史',
            description: '检查本地历史存储后重试；已有记录不会被修改。',
            action: action,
            accent: Theme.of(context).colorScheme.error,
          );
  }
}

final class _HistoryEmpty extends StatelessWidget {
  const _HistoryEmpty({
    required this.dense,
    required this.hasQuery,
    required this.onCapture,
    this.onClear,
  });
  final bool dense;
  final bool hasQuery;
  final VoidCallback onCapture;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) {
    final icon = hasQuery ? Icons.search_off_rounded : Icons.crop_free_rounded;
    final title = hasQuery ? '没有匹配的截屏记录' : '还没有截屏翻译';
    final description = hasQuery
        ? '换个原文或译文关键词再试，或清除搜索查看全部记录。'
        : '框选屏幕上的文字后，原图、OCR 原文和译文会归档在这里。';
    final action = hasQuery
        ? OutlinedButton.icon(
            style: _compactHistoryActionStyle,
            onPressed: onClear,
            icon: const Icon(Icons.backspace_outlined),
            label: const Text('清除搜索'),
          )
        : FilledButton.icon(
            key: const ValueKey('screenshot-workbench-empty-capture'),
            style: _compactHistoryActionStyle,
            onPressed: onCapture,
            icon: const Icon(Icons.crop_free_rounded),
            label: const Text('开始框选翻译'),
          );
    return dense
        ? _CompactHistoryNotice(
            icon: icon,
            title: title,
            description: description,
            action: action,
          )
        : _EmptyState(
            icon: icon,
            title: title,
            description: description,
            action: action,
            accent: Theme.of(context).colorScheme.primary,
          );
  }
}

const _compactHistoryActionStyle = ButtonStyle(
  visualDensity: VisualDensity.compact,
  minimumSize: WidgetStatePropertyAll(Size(0, 30)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
);

final class _CompactHistoryNotice extends StatelessWidget {
  const _CompactHistoryNotice({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.accent,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  final Color? accent;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = accent ?? colors.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            if (showProgress) ...[
              const SizedBox(height: 4),
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              ),
            ],
            const SizedBox(height: 5),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.3),
            ),
            if (action != null) ...[const SizedBox(height: 4), action!],
          ],
        ),
      ),
    );
  }
}

final class _HistoryTail extends StatelessWidget {
  const _HistoryTail({
    required this.capped,
    required this.loading,
    required this.onLoadMore,
  });
  final bool capped;
  final bool loading;
  final VoidCallback onLoadMore;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Center(
      child: capped
          ? Text('已达到本地历史读取上限。', style: Theme.of(context).textTheme.bodySmall)
          : loading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton.icon(
              onPressed: onLoadMore,
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('加载更多'),
            ),
    ),
  );
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.accent,
    this.showProgress = false,
  });
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  final Color? accent;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = accent ?? colors.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, size: 27, color: color),
              ),
              if (showProgress) ...[
                const SizedBox(height: 14),
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Text(
                description,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTimestamp(String value) {
  final parsed = DateTime.tryParse(value)?.toLocal();
  if (parsed == null) return value;
  String two(int number) => number.toString().padLeft(2, '0');
  return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} ${two(parsed.hour)}:${two(parsed.minute)}';
}

String _screenshotDictionarySourceContext(String term, String sourceText) {
  final normalized = sourceText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  for (final paragraph in normalized.split(RegExp(r'\n[ \t]*\n+'))) {
    if (dictionaryTermAppearsInText(term, paragraph)) {
      return _limitScreenshotDictionaryContext(paragraph, term);
    }
  }
  return _limitScreenshotDictionaryContext(sourceText, term);
}

String _limitScreenshotDictionaryContext(String context, String term) {
  const maximumLength = 2000;
  final value = context.trim();
  if (value.length <= maximumLength) return value;

  final occurrence = value.indexOf(term);
  final start = occurrence < 800 ? 0 : occurrence - 800;
  final end = start + maximumLength < value.length
      ? start + maximumLength
      : value.length;
  final prefix = start == 0 ? '' : '…';
  final suffix = end == value.length ? '' : '…';
  return '$prefix${value.substring(start, end)}$suffix';
}
