import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/app/app_build_info.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';
import 'package:yixue_app/core/app_data_directory.dart';
import 'package:yixue_app/core/dictionary_catalog.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/dictionary_pagination.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/dictionary_package_service.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_daily_plan_store.dart';
import 'package:yixue_app/core/home_focus_session_store.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/home_user_profile_store.dart';
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/learning_speech_service.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/local_data_export_service.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/streaming_asr_runtime.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/core/translation_history_export_service.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_request_options.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/storage_policy.dart' as yixue_storage;
import 'package:yixue_app/core/ui_preference_store.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';
import 'package:yixue_app/features/home/home_dashboard_page.dart';
import 'package:yixue_app/features/home/home_daily_stats_workspace.dart';
import 'package:yixue_app/features/home/home_planner_workspace.dart';
import 'package:yixue_app/features/home/home_focus_workspace.dart';
import 'package:yixue_app/features/learning/learning_workspace.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workspace.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_orb_dictionary_lookup_dialog.dart';
import 'package:yixue_app/features/settings/screenshot_translation_settings_card.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_host_exit.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_window_entry.dart';
import 'package:yixue_app/features/screenshot_translation/windows_native_screenshot_orb.dart';
import 'package:yixue_app/features/settings/appearance_settings_card.dart';
import 'package:yixue_app/features/settings/content_library_workspace.dart';
import 'package:yixue_app/features/settings/model_settings_page.dart';
import 'package:yixue_app/features/shell/window_title_bar.dart';
import 'package:yixue_app/features/simultaneous_interpretation/desktop_audio_capture.dart';
import 'package:yixue_app/features/simultaneous_interpretation/multilingual_asr_model_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/simultaneous_interpretation_page.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr_model_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_display_preferences.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_history_page.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_post_session_provider.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_post_session_service.dart';
import 'package:yixue_app/features/vocabulary/favorite_words_workspace.dart';

const _activeBlue = Color(0xFF1763D6);
typedef ClipboardReader = Future<String?> Function();
typedef TranslationHistoryLoader =
    Future<List<TranslationHistoryEntryData>> Function();
typedef TranslationHistoryPageLoader =
    Future<List<TranslationHistoryEntryData>> Function(int offset, int limit);
typedef TranslationHistoryExporter = Future<String?> Function(
  List<TranslationHistoryEntryData> history,
  List<TranslationAnnotationData> annotations,
);
typedef TranslationHistoryDeleter = Future<void> Function(List<String> ids);
typedef TranslationHistoryEntryDeleter = Future<void> Function(
  List<TranslationHistoryEntryData> entries,
);
typedef TranslationAnnotationLoader =
    Future<List<TranslationAnnotationData>> Function();
typedef TranslationAnnotationSaver = Future<void> Function(
  TranslationAnnotationData annotation,
);
typedef QuickTranslationCanceller = Future<bool> Function();
typedef DictionaryLookupLoader = Future<DictionaryEntry?> Function(String word);
typedef FavoriteWordsLoader = Future<List<String>> Function();
typedef FavoriteWordSetter = Future<void> Function(String word, bool favorite);
typedef LearningWordSetter = Future<void> Function(String word, bool enabled);
typedef WordAnnotationLoader = Future<WordAnnotationData?> Function(
  String word,
);
typedef WordAnnotationSaver = Future<void> Function(
  WordAnnotationData annotation,
);
typedef DictionaryPackagePicker = Future<XFile?> Function();
typedef DictionaryPackageTemplateExporter = Future<void> Function();
typedef DataExportDirectoryPicker = Future<String?> Function();
typedef StorageUsageLoader = Future<yixue_storage.StorageUsageData> Function();

const _previewHomeSnapshot = HomeSnapshotData(
  learningMinutes: 36,
  readingPages: 8,
  masteredWords: 12,
  completedExercises: 6,
  recent: [
    ActivityEventData(
      id: 'preview-reading',
      kind: ActivityKind.reading,
      title: 'Human–AI Collaboration.pdf',
      detail: '学习进度 · 第 12 节',
      durationSeconds: 1200,
      itemCount: 8,
      occurredAt: '2026-09-09T09:24:00+08:00',
    ),
    ActivityEventData(
      id: 'preview-screenshot',
      kind: ActivityKind.translation,
      title: '软件安装提示',
      detail: '截屏翻译 · 今天 09:24',
      durationSeconds: 0,
      itemCount: 1,
      occurredAt: '2026-09-09T09:20:00+08:00',
    ),
    ActivityEventData(
      id: 'preview-word',
      kind: ActivityKind.vocabulary,
      title: 'consistency',
      detail: '学习收藏 · 已复习 2 次',
      durationSeconds: 600,
      itemCount: 12,
      occurredAt: '2026-09-09T09:10:00+08:00',
    ),
  ],
);

final class _UnavailableSubtitleTranslationExecutor
    implements SubtitleTranslationExecutor {
  const _UnavailableSubtitleTranslationExecutor();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async {
    throw const SubtitleTranslationFailure('translation_unavailable');
  }

  @override
  Future<void> cancel(String requestId) async {}
}

class HomeShell extends StatefulWidget {
  const HomeShell({
    required this.appearanceController,
    super.key,
    this.appDataDirectory,
    this.subtitleSessionStore,
    this.coreFactory,
    this.clipboardReader,
    this.quickTranslationRunner,
    this.quickTranslationRunnerWithOptions,
    this.quickTranslationCanceller,
    this.learningSummaryRunner,
    this.learningSpeechRecognizer,
    this.textbookStore,
    this.translationHistoryLoader,
    this.translationHistoryPageLoader,
    this.translationHistoryExporter,
    this.translationHistoryDeleter,
    this.translationAnnotationLoader,
    this.translationAnnotationSaver,
    this.dictionaryLookupLoader,
    this.favoriteWordPageLoader,
    this.favoriteWordSetter,
    this.wordAnnotationLoader,
    this.wordAnnotationSaver,
    this.dictionaryPackagePicker,
    this.sidebarPreferenceStore,
    this.translationPreferencesStore,
    this.translationPreferencesController,
    this.translationTerminologyStore,
    this.translationTerminologyController,
    this.dictionaryPreferencesStore,
    this.dictionaryPreferencesController,
    this.homePlanStore,
    this.homeDailyPlanStore,
    this.homeFocusSessionStore,
    this.homeUserProfileStore,
    this.learningStore,
    this.storagePolicyStore,
    this.storageUsageLoader,
    this.dataExportDirectoryPicker,
    this.requestHostQuit,
    this.restoreHostWindow,
    this.clock = DateTime.now,
  });

  final String? appDataDirectory;
  final SubtitleSessionStore? subtitleSessionStore;
  final AppCore Function()? coreFactory;
  final ClipboardReader? clipboardReader;
  final QuickTranslationRunner? quickTranslationRunner;
  final QuickTranslationRunnerWithOptions? quickTranslationRunnerWithOptions;
  final QuickTranslationCanceller? quickTranslationCanceller;
  final LearningSummaryGenerator? learningSummaryRunner;
  final LearningSpeechRecognizer? learningSpeechRecognizer;
  final LearningTextbookStore? textbookStore;
  final TranslationHistoryLoader? translationHistoryLoader;
  final TranslationHistoryPageLoader? translationHistoryPageLoader;
  final TranslationHistoryExporter? translationHistoryExporter;
  final TranslationHistoryDeleter? translationHistoryDeleter;
  final TranslationAnnotationLoader? translationAnnotationLoader;
  final TranslationAnnotationSaver? translationAnnotationSaver;
  final DictionaryLookupLoader? dictionaryLookupLoader;
  final FavoriteWordPageLoader? favoriteWordPageLoader;
  final FavoriteWordSetter? favoriteWordSetter;
  final WordAnnotationLoader? wordAnnotationLoader;
  final WordAnnotationSaver? wordAnnotationSaver;
  final DictionaryPackagePicker? dictionaryPackagePicker;
  final AppearanceController appearanceController;
  final SidebarPreferenceStore? sidebarPreferenceStore;
  final TranslationPreferencesStore? translationPreferencesStore;
  final TranslationPreferencesController? translationPreferencesController;
  final TranslationTerminologyStore? translationTerminologyStore;
  final TranslationTerminologyController? translationTerminologyController;
  final DictionaryPreferencesStore? dictionaryPreferencesStore;
  final DictionaryPreferencesController? dictionaryPreferencesController;
  final HomePlanStore? homePlanStore;
  final FileHomeDailyPlanStore? homeDailyPlanStore;
  final HomeFocusSessionStore? homeFocusSessionStore;
  final HomeUserProfileStore? homeUserProfileStore;
  final LearningStore? learningStore;
  final yixue_storage.StoragePolicyStore? storagePolicyStore;
  final StorageUsageLoader? storageUsageLoader;
  final DataExportDirectoryPicker? dataExportDirectoryPicker;
  final Future<void> Function()? requestHostQuit;
  final Future<void> Function()? restoreHostWindow;
  final DateTime Function() clock;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _selectedIndex = 1;
  final _workspaceKey = GlobalKey();
  var _simultaneousCompactWindowMode = false;
  var _showSkeleton = false;
  var _sidebarExpanded = true;
  var _sidebarTemporarilyVisible = false;
  late final List<Widget?> _pageCache;
  late final LearningStore _learningStore;
  late final LearningRepository _screenshotWordRepository;
  var _learningDataRevision = 0;
  var _understandingUsageFocusRequestId = 0;
  QuickTranslationService? _ownedQuickTranslationService;
  late final ScreenshotTranslationRuntime _screenshotRuntime;
  ScreenshotTranslationArchiveController? _screenshotArchive;
  ScreenshotTranslationDesktopController? _screenshotDesktop;
  var _screenshotSettingsRequestVersion = 0;
  void Function()? _unregisterScreenshotExitCleanup;
  bool _screenshotExitRecovery = false;
  LearningSummaryService? _ownedLearningSummaryService;
  SubtitlePostSessionAiGenerator? _ownedSubtitlePostSessionGenerator;
  LearningSpeechRecognizer? _ownedLearningSpeechRecognizer;
  final _translationEditorKey = GlobalKey<_TranslationEditorState>();
  final _modelStatus = ValueNotifier<String>('本地优先 · 正在读取模型…');
  final _simultaneousActivityStatus = ValueNotifier<String?>(null);
  var _inMemoryHomePlan = const HomePlanData();
  Future<void>? _dailyPlanMigration;

  static const _items = <_NavigationItem>[
    _NavigationItem(0, '首页', Icons.home_outlined),
    _NavigationItem(1, '快速翻译', Icons.g_translate_rounded),
    _NavigationItem(2, '截屏翻译', Icons.center_focus_weak_rounded),
    _NavigationItem(
      3,
      '阅读器',
      Icons.chrome_reader_mode_outlined,
      integrated: false,
    ),
    _NavigationItem(4, '学习', Icons.menu_book_outlined),
    _NavigationItem(5, 'AI 同传', Icons.live_tv_outlined),
    _NavigationItem(6, '模型与服务', Icons.view_in_ar_outlined),
    _NavigationItem(7, '设置', Icons.settings_outlined),
  ];

  @override
  void initState() {
    super.initState();
    final coreFactory = widget.coreFactory;
    if (widget.quickTranslationRunner == null && coreFactory != null) {
      _ownedQuickTranslationService = QuickTranslationService.platform(
        coreFactory: coreFactory,
        preferencesController: widget.translationPreferencesController,
        terminologyController: widget.translationTerminologyController,
        dictionaryPreferencesController: widget.dictionaryPreferencesController,
      );
    }
    if (widget.learningSummaryRunner == null && coreFactory != null) {
      _ownedLearningSummaryService = LearningSummaryService(
        coreFactory: coreFactory,
      );
    }
    if (coreFactory != null) {
      _ownedSubtitlePostSessionGenerator = SubtitlePostSessionAiGenerator(
        coreFactory: coreFactory,
      );
    }
    final captureService = ScreenshotTranslationCaptureService();
    Future<String> runScreenshotTranslation(
      String source,
      TranslationDirection direction, {
      required String origin,
      required String historyEntryId,
      required String screenshotCaptureId,
      void Function(TranslationExecutionRoute route)? onRouteSelected,
    }) {
      final service = _ownedQuickTranslationService;
      if (service != null) {
        return service.translate(
          source,
          direction: direction,
          origin: origin,
          historyEntryId: historyEntryId,
          screenshotCaptureId: screenshotCaptureId,
          options: const TranslationRequestOptions(preserveLineBreaks: true),
          onRouteSelected: onRouteSelected,
        );
      }
      final injected = widget.quickTranslationRunner;
      if (injected != null) {
        onRouteSelected?.call(const TranslationExecutionRoute.unknown());
        return injected(source, direction);
      }
      onRouteSelected?.call(const TranslationExecutionRoute.unavailable());
      throw const QuickTranslationException('no_remote_provider');
    }

    Future<ScreenshotTranslationDocumentTranslation>
    runScreenshotDocumentTranslation(
      String source,
      ScreenshotTranslationOcrLayout layout,
      TranslationDirection direction, {
      required String origin,
      required String historyEntryId,
      required String screenshotCaptureId,
      required void Function(TranslationExecutionRoute route) onRouteSelected,
    }) async {
      final service = _ownedQuickTranslationService;
      final injected = widget.quickTranslationRunner;
      final layoutMatchesSource = layout.sourceText == source;
      final hasStandaloneWordBlock = layout.blocks.any((block) {
        final text = block.text.trim();
        return RegExp(r"^[A-Za-z]+(?:['’\u2019-][A-Za-z]+)?$").hasMatch(text) ||
            (text.runes.length <= 8 &&
                RegExp(r'^[\u3400-\u9FFF]+$').hasMatch(text));
      });
      if (service == null ||
          injected != null ||
          !layoutMatchesSource ||
          layout.blocks.length > screenshotTranslationMaxAlignedOcrBlocks ||
          hasStandaloneWordBlock) {
        return ScreenshotTranslationDocumentTranslation(
          translatedText: await runScreenshotTranslation(
            source,
            direction,
            origin: origin,
            historyEntryId: historyEntryId,
            screenshotCaptureId: screenshotCaptureId,
            onRouteSelected: onRouteSelected,
          ),
        );
      }

      final routeSnapshot = (await service.snapshotSubtitleRoutes())[direction];
      if (routeSnapshot == null ||
          routeSnapshot.kind == SubtitleTranslationRouteKind.unavailable) {
        onRouteSelected(const TranslationExecutionRoute.unavailable());
        throw QuickTranslationException(
          routeSnapshot?.unavailableReasonCode ?? 'no_remote_provider',
        );
      }
      String? bundledProviderId(String? modelPath) {
        if (modelPath == null || modelPath.trim().isEmpty) return null;
        final parts = modelPath
            .split(RegExp(r'[/\\]'))
            .where((part) => part.isNotEmpty)
            .toList(growable: false);
        return parts.isEmpty ? null : parts.last;
      }

      final providerId = switch (routeSnapshot.kind) {
        SubtitleTranslationRouteKind.remoteProfile => routeSnapshot.profile?.id,
        SubtitleTranslationRouteKind.localProfile => routeSnapshot.profile?.id,
        SubtitleTranslationRouteKind.bundledLocal => bundledProviderId(
          routeSnapshot.bundledModelPath,
        ),
        SubtitleTranslationRouteKind.unavailable => null,
      };
      if (providerId == null || providerId.trim().isEmpty) {
        onRouteSelected(const TranslationExecutionRoute.unavailable());
        throw const QuickTranslationException('no_remote_provider');
      }

      final safeMarkerNamespace = historyEntryId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '',
      );
      final boundedMarkerNamespace = safeMarkerNamespace.length > 80
          ? safeMarkerNamespace.substring(0, 80)
          : safeMarkerNamespace;
      final markup = buildScreenshotTranslationOcrMarkup(
        layout,
        markerNamespace: boundedMarkerNamespace.isEmpty
            ? 'capture'
            : boundedMarkerNamespace,
      );
      final translation = await translateScreenshotOcrMarkupOrFallback(
        layout: layout,
        markup: markup,
        translateMarkedText: (markedText) => service.translate(
          markedText,
          direction: direction,
          origin: origin,
          historyEntryId: '$historyEntryId-marked-document',
          screenshotCaptureId: screenshotCaptureId,
          options: const TranslationRequestOptions(preserveLineBreaks: true),
          onRouteSelected: onRouteSelected,
          operationId: '$historyEntryId-marked-document',
          recordHistory: false,
          subtitleRouteSnapshot: routeSnapshot,
        ),
        translateBlock: (sourceBlock, blockIndex) => service.translate(
          sourceBlock,
          direction: direction,
          origin: origin,
          historyEntryId: '$historyEntryId-block-$blockIndex',
          screenshotCaptureId: screenshotCaptureId,
          options: const TranslationRequestOptions(preserveLineBreaks: true),
          onRouteSelected: onRouteSelected,
          operationId: '$historyEntryId-block-$blockIndex',
          recordHistory: false,
          subtitleRouteSnapshot: routeSnapshot,
        ),
        translateWholeText: (sourceText) => service.translate(
          sourceText,
          direction: direction,
          origin: origin,
          historyEntryId: '$historyEntryId-document-fallback',
          screenshotCaptureId: screenshotCaptureId,
          options: const TranslationRequestOptions(preserveLineBreaks: true),
          onRouteSelected: onRouteSelected,
          operationId: '$historyEntryId-document-fallback',
          recordHistory: false,
          subtitleRouteSnapshot: routeSnapshot,
        ),
        shouldFallbackOnException:
            shouldFallbackScreenshotTranslationOnException,
      );

      final coreFactory = widget.coreFactory;
      if (coreFactory == null) {
        throw const QuickTranslationException('history_unavailable');
      }
      final core = coreFactory();
      try {
        if (core is! TranslationHistoryCore) {
          throw const QuickTranslationException('history_unavailable');
        }
        (core as TranslationHistoryCore).recordCompletedTranslation(
          CompletedTranslationData(
            id: historyEntryId,
            sourceText: source,
            translatedText: translation.translatedText,
            providerId: providerId,
            createdAt: DateTime.now().toIso8601String(),
            sourceLanguage: direction.sourceLanguage,
            targetLanguage: direction.targetLanguage,
            origin: origin,
            screenshotCaptureId: screenshotCaptureId,
            screenshotOcrLayout:
                translation.translatedSourceBlockIndices == null
                ? null
                : layout.toMap(),
            translatedSourceBlockIndices:
                translation.translatedSourceBlockIndices,
          ),
        );
      } finally {
        core.dispose();
      }
      return translation;
    }

    final screenshotImageStore =
        screenshotTranslationImageStoreForAppDataDirectory(
          widget.appDataDirectory,
        );
    _screenshotRuntime = ScreenshotTranslationRuntime(
      capture: captureService.captureRegion,
      captureAtBounds: captureService.captureAtBounds,
      pinnedRegion: () => _screenshotDesktop?.preferences.pinnedRegion,
      persistPinnedRegion: (bounds) async =>
          await _screenshotDesktop?.setPinnedRegion(bounds) ?? false,
      recognize: captureService.recognize,
      recognizeDocument: captureService.recognizeDocument,
      ocrCapabilitiesInspector: captureService.inspectOcrCapabilities,
      imageStore: screenshotImageStore,
      saveScreenshotImages: () =>
          _screenshotDesktop?.imagePersistenceEnabled ?? false,
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) {
            return runScreenshotTranslation(
              source,
              direction,
              origin: origin,
              historyEntryId: historyEntryId,
              screenshotCaptureId: screenshotCaptureId,
            );
          },
      translateWithRoute:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
            required onRouteSelected,
          }) => runScreenshotTranslation(
            source,
            direction,
            origin: origin,
            historyEntryId: historyEntryId,
            screenshotCaptureId: screenshotCaptureId,
            onRouteSelected: onRouteSelected,
          ),
      translateDocumentWithRoute:
          (
            source,
            layout,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
            required onRouteSelected,
          }) => runScreenshotDocumentTranslation(
            source,
            layout,
            direction,
            origin: origin,
            historyEntryId: historyEntryId,
            screenshotCaptureId: screenshotCaptureId,
            onRouteSelected: onRouteSelected,
          ),
      cancelTranslation: _cancelTranslation,
      onAddScreenshotWord: (request) => _saveScreenshotWord(
        word: request.word,
        sourceContext: request.recognizedText,
        sourceTranslation: request.translatedText,
        sourceHistoryId: request.historyEntryId,
      ),
      onLookupDictionary: _lookupDictionary,
      translateSelectedWord: _translateScreenshotSelectedWord,
      cancelSelectedWordTranslation: _cancelScreenshotSelectedWordTranslation,
      onOpenDictionaryLookup: _openScreenshotDictionaryLookup,
      createResultWindow: () async => ScreenshotTranslationWindowSession.create(
        parent: await WindowController.fromCurrentEngine(),
        role: ScreenshotTranslationWindowRole.result,
        onMessage: _handleScreenshotWindowMessage,
      ),
      onOpenHistory: () async {
        await windowManager.show();
        await windowManager.focus();
        if (mounted) await _openHistory();
      },
      onOpenModels: _openScreenshotModels,
    );
    final screenshotCoreFactory = widget.coreFactory;
    if (screenshotCoreFactory != null && screenshotImageStore != null) {
      _screenshotArchive = ScreenshotTranslationArchiveController(
        coreFactory: screenshotCoreFactory,
        imageStore: screenshotImageStore,
        purgeRetryableImageSave: _screenshotRuntime.purgeRetryableImageSave,
        purgeInvalidatedImageSaves:
            _screenshotRuntime.purgeInvalidatedImageSaves,
        beforeDeleteHistoryEntry: _screenshotRuntime.deleteHistoryEntry,
        beforeDeleteCaptureImage:
            _screenshotRuntime.prepareCaptureImageDeletion,
        cancelCaptureImageDeletion:
            _screenshotRuntime.cancelCaptureImageDeletion,
      );
    }
    // Only the main shell owns persistent settings and the global hotkey.
    // Tests/preview shells with no library path do not access user files.
    if (!kIsWeb &&
        Platform.isWindows &&
        widget.appDataDirectory?.trim().isNotEmpty == true) {
      _screenshotDesktop = ScreenshotTranslationDesktopController(
        store: FileScreenshotTranslationPreferencesStore(
          File(
            '${widget.appDataDirectory}\\screenshot-translation-preferences.json',
          ),
        ),
        hotKeys: MainEngineScreenshotHotKey(),
        createOrb: () async => WindowsScreenshotNativeOrb(
          onMessage: (message) async {
            await _screenshotDesktop!.handleMessage(message);
            await _handleScreenshotWindowMessage(message);
          },
        ),
        onCapture: _captureFromDesktopEntry,
        onOpenMain: _restoreScreenshotMain,
        onOpenSettings: _openScreenshotSettings,
        onHideMain: windowManager.hide,
        onReleaseSession: _screenshotRuntime.shutdown,
        onCloseChildren: () async =>
            ScreenshotTranslationWindowSession.closeAll(
              await WindowController.fromCurrentEngine(),
            ),
        onRequestHostExit: widget.requestHostQuit,
        onExit: resolveScreenshotHostExit(
          requestHostClose: widget.requestHostQuit,
          closeWindow: () async {
            await windowManager.setPreventClose(false);
            await windowManager.close();
          },
        ),
        onExitFailure: _showScreenshotExitRecovery,
      );
      _unregisterScreenshotExitCleanup = AppExitCleanupRegistry.register(
        _screenshotDesktop!.shutdown,
        name: 'screenshot.desktop',
      );
      unawaited(_initializeScreenshotDesktop());
    }
    if (widget.learningSpeechRecognizer == null) {
      _ownedLearningSpeechRecognizer = SystemLearningSpeechRecognizer();
    }
    _pageCache = List<Widget?>.filled(YixueWorkspace.values.length, null);
    _learningStore =
        widget.learningStore ??
        (widget.appDataDirectory == null
            ? MemoryLearningStore()
            : FileLearningStore(
                File('${widget.appDataDirectory}\\learning-workspace.json'),
              ));
    _screenshotWordRepository = LearningRepository(
      _learningStore,
      clock: widget.clock,
    );
    _pageCache[_selectedIndex] = _buildPage(_selectedIndex);
    // Opening the local core can synchronously touch the database. Let the
    // first workspace frame render before probing model status so a slow or
    // temporarily unavailable database cannot leave a blank startup window.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshModelStatus();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final archive = _screenshotArchive;
      if (!mounted || archive == null) return;
      unawaited(_recoverScreenshotArchiveAtStartup(archive));
    });
    unawaited(_restoreSidebarPreference());
    unawaited(_restoreTranslationPreferences());
    unawaited(_restoreTranslationTerminology());
    unawaited(_restoreDictionaryPreferences());
  }

  Future<void> _restoreScreenshotMain() async {
    final restoreHostWindow = widget.restoreHostWindow;
    if (restoreHostWindow != null) {
      await restoreHostWindow();
      return;
    }
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _recoverScreenshotArchiveAtStartup(
    ScreenshotTranslationArchiveController archive,
  ) async {
    try {
      await archive.recoverPendingImageDeletions();
    } on Object {
      // The marked backup stays available for a later retry from the archive.
    }
  }

  Future<void> _captureFromDesktopEntry() {
    final desktop = _screenshotDesktop;
    if (desktop == null) return _screenshotRuntime.startCapture();
    return _screenshotRuntime.startWorkbenchCapture(
      captureGuard: desktop.captureWithOrbHidden,
    );
  }

  Future<ScreenshotTranslationWindowMessage?> _handleScreenshotWindowMessage(
    ScreenshotTranslationWindowMessage message,
  ) async {
    if (message.type == 'captureRequested') {
      await _captureFromDesktopEntry();
      return null;
    }
    if (message.type == 'refreshPinnedRegionRequested') {
      ScreenshotTranslationWindowMessage ack(Map<String, Object?> payload) =>
          ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: message.requestId,
            payload: payload,
          );
      final session = _screenshotRuntime.session;
      final desktop = _screenshotDesktop;
      final expectedSessionId = message.payload['sessionId'];
      if (message.payload.length != 1 ||
          expectedSessionId is! String ||
          session == null ||
          session.id != expectedSessionId) {
        return ack(const {'errorCode': 'stale_session'});
      }
      if (desktop == null) {
        return ack(const {'errorCode': 'region_not_pinned'});
      }
      final bounds = desktop.preferences.pinnedRegion;
      if (bounds == null) return ack(const {'errorCode': 'region_not_pinned'});
      try {
        await windowManager.isVisible();
      } catch (_) {
        return ack(const {'errorCode': 'window_state_unavailable'});
      }
      Future<CapturedData?> captureGuard(
        Future<CapturedData?> Function() capture,
      ) async {
        final bool mainVisible;
        final bool mainMinimized;
        final bool mainFocused;
        try {
          mainVisible = await windowManager.isVisible();
          mainMinimized = mainVisible && await windowManager.isMinimized();
          mainFocused =
              mainVisible && !mainMinimized && await windowManager.isFocused();
        } catch (_) {
          throw const ScreenshotTranslationCaptureException(
            '无法确认译学窗口状态，请稍后重试。',
            code: 'window_state_unavailable',
          );
        }
        if (!mainVisible || mainMinimized) {
          return desktop.captureWithOrbHidden(capture);
        }
        return desktop.captureWithMainHidden(
          capture,
          restoreMain: () async {
            await windowManager.show(inactive: !mainFocused);
            if (mainFocused) await windowManager.focus();
          },
        );
      }

      final started = await _screenshotRuntime.startPinnedCapture(
        bounds: bounds,
        expectedSessionId: expectedSessionId,
        captureGuard: captureGuard,
      );
      if (started) return ack(const {'started': true});
      if (_screenshotRuntime.session?.id != expectedSessionId) {
        return ack(const {'errorCode': 'stale_session'});
      }
      if (desktop.preferences.pinnedRegion != bounds) {
        return ack(const {'errorCode': 'region_not_pinned'});
      }
      return ack(const {'errorCode': 'capture_in_progress'});
    }
    return _screenshotRuntime.handleMessage(message);
  }

  Future<void> _openScreenshotSettings() async {
    await _restoreScreenshotMain();
    if (!mounted) return;
    _select(2);
    setState(() {
      _screenshotSettingsRequestVersion++;
      _pageCache[2] = _buildPage(2);
    });
  }

  Future<void> _openScreenshotModels() async {
    await _restoreScreenshotMain();
    if (!mounted) return;
    _select(6);
  }

  Future<void> _openScreenshotDictionaryLookup({
    String? sourceContext,
    String? sourceRecognizedText,
    String? sourceTranslation,
    String? sourceHistoryId,
  }) async {
    await _restoreScreenshotMain();
    if (!mounted) return;
    final dataDirectory = widget.appDataDirectory?.trim();
    final ScreenshotDictionaryLookupHistoryStore? historyStore;
    if (dataDirectory == null || dataDirectory.isEmpty) {
      historyStore = null;
    } else {
      try {
        historyStore = FileScreenshotDictionaryLookupHistoryStore(
          File(
            joinAppDataPath(
              dataDirectory,
              'screenshot_translation/dictionary_lookup_history.json',
            ),
          ),
        );
      } on Object {
        await showDialog<void>(
          context: context,
          builder: (_) => ScreenshotOrbDictionaryLookupDialog(
            lookupDictionary: _lookupDictionary,
            saveToVocabulary: (word, source, translation, historyId) =>
                _addScreenshotWord(
                  word: word,
                  sourceContext: source,
                  sourceTranslation: translation,
                  sourceHistoryId: historyId,
                ),
            sourceContext: sourceContext,
            sourceRecognizedText: sourceRecognizedText,
            sourceTranslation: sourceTranslation,
            sourceHistoryId: sourceHistoryId,
          ),
        );
        return;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ScreenshotOrbDictionaryLookupDialog(
        lookupDictionary: _lookupDictionary,
        saveToVocabulary: (word, source, translation, historyId) =>
            _addScreenshotWord(
              word: word,
              sourceContext: source,
              sourceTranslation: translation,
              sourceHistoryId: historyId,
            ),
        lookupHistoryStore: historyStore,
        sourceContext: sourceContext,
        sourceRecognizedText: sourceRecognizedText,
        sourceTranslation: sourceTranslation,
        sourceHistoryId: sourceHistoryId,
      ),
    );
  }

  Future<bool> _addScreenshotWord({
    required String word,
    required String sourceContext,
    required String sourceTranslation,
    required String sourceHistoryId,
  }) async =>
      await _saveScreenshotWord(
        word: word,
        sourceContext: sourceContext,
        sourceTranslation: sourceTranslation,
        sourceHistoryId: sourceHistoryId,
      ) !=
      ScreenshotWordAddStatus.alreadyExists;

  Future<ScreenshotWordAddStatus> _saveScreenshotWord({
    required String word,
    required String sourceContext,
    required String sourceTranslation,
    required String sourceHistoryId,
  }) async {
    String? dictionaryMeaning;
    try {
      final entry = await _lookupDictionary(word);
      final meanings = entry?.meanings
          .map((meaning) => meaning.trim())
          .where((meaning) => meaning.isNotEmpty)
          .toList();
      if (meanings?.isNotEmpty ?? false) {
        dictionaryMeaning = meanings!.join('；');
      }
    } catch (_) {
      // Dictionary lookup is optional for screenshot capture. A local lookup
      // failure must not block saving the selected word and its source context.
    }
    final result = await _screenshotWordRepository.addScreenshotWord(
      word: word,
      sourceContext: sourceContext,
      sourceTranslation: sourceTranslation,
      sourceHistoryId: sourceHistoryId,
      dictionaryMeaning: dictionaryMeaning,
      now: widget.clock(),
    );
    // Refresh learning data after an external write while keeping visible
    // unsaved notes and the current review view intact.
    _refreshLearningPage();
    if (!result.added) return ScreenshotWordAddStatus.alreadyExists;
    final item = result.state.items.firstWhere(
      (item) =>
          item.setId == learningScreenshotWordsSetId &&
          normalizeLearningWord(item.word) == normalizeLearningWord(word),
    );
    return item.meaning?.trim().isNotEmpty == true
        ? ScreenshotWordAddStatus.added
        : ScreenshotWordAddStatus.meaningPending;
  }

  void _refreshLearningPage() {
    if (!mounted) return;
    setState(() {
      _learningDataRevision++;
      // A visible page keeps its State and refreshes only data. A hidden page
      // loads fresh data on next open.
      _pageCache[4] = _selectedIndex == 4 ? _buildPage(4) : null;
    });
  }

  Future<void> _showScreenshotExitRecovery() async {
    if (!mounted) return;
    setState(() => _screenshotExitRecovery = true);
    try {
      await windowManager.setPreventClose(true);
    } catch (_) {
      // Still expose the explicit retry action if close interception fails.
    }
    await _restoreScreenshotMain();
  }

  Future<void> _initializeScreenshotDesktop() async {
    try {
      await windowManager.setPreventClose(true);
      await _screenshotDesktop!.initialize();
    } catch (_) {
      _screenshotDesktop?.reportHostFailure();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_screenshotExitRecovery && _screenshotDesktop != null) {
      return ScreenshotTranslationExitRecovery(controller: _screenshotDesktop!);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final desktopWindow =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        return Scaffold(
          body: SafeArea(
            child: compact
                ? _workspaceColumn(desktopWindow)
                : _desktopWorkspace(desktopWindow),
          ),
          bottomNavigationBar: compact && !_simultaneousCompactWindowMode
              ? _CompactNavigation(
                  selectedIndex: _selectedIndex,
                  onSelected: _select,
                )
              : null,
        );
      },
    );
  }

  Widget _workspaceColumn(bool desktopWindow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (desktopWindow && !_simultaneousCompactWindowMode)
          const WindowTitleBar(),
        Expanded(child: SizedBox.expand(child: _workspace())),
      ],
    );
  }

  Widget _desktopWorkspace(bool desktopWindow) {
    if (_simultaneousCompactWindowMode) {
      return _workspaceColumn(desktopWindow);
    }
    final motionLevel = widget.appearanceController.value.motionLevel;
    final revealDuration = motionLevel == YixueMotionLevel.off
        ? Duration.zero
        : motionLevel == YixueMotionLevel.reduced
        ? const Duration(milliseconds: 90)
        : const Duration(milliseconds: 220);
    return Stack(
      children: [
        Row(
          children: [
            if (_sidebarExpanded)
              _DesktopSidebar(
                selectedIndex: _selectedIndex,
                onSelected: _select,
                onModeAction: _collapseSidebar,
              ),
            Expanded(child: _workspaceColumn(desktopWindow)),
          ],
        ),
        if (!_sidebarExpanded)
          Align(
            alignment: Alignment.centerLeft,
            child: MouseRegion(
              onEnter: (_) => _showTemporarySidebar(),
              child: GestureDetector(
                key: const ValueKey('sidebar-edge-reveal'),
                behavior: HitTestBehavior.opaque,
                onTap: _showTemporarySidebar,
                child: Container(
                  width: 20,
                  height: 104,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF199BE6), Color(0xFF2FD18A)],
                    ),
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x3312A7C5),
                        blurRadius: 14,
                        offset: Offset(3, 0),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.keyboard_double_arrow_right_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
              ),
            ),
          ),
        if (!_sidebarExpanded && _sidebarTemporarilyVisible)
          Positioned(
            key: const ValueKey('sidebar-temporary-overlay'),
            left: 0,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              onExit: (_) => _hideTemporarySidebar(),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: -1, end: 0),
                duration: revealDuration,
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Transform.translate(
                  offset: Offset(244 * value, 0),
                  child: child,
                ),
                child: Material(
                  color: Colors.transparent,
                  elevation: 18,
                  shadowColor: const Color(0x55021D31),
                  child: _DesktopSidebar(
                    selectedIndex: _selectedIndex,
                    onSelected: (index) {
                      _select(index);
                      _hideTemporarySidebar();
                    },
                    onModeAction: _pinSidebar,
                    temporary: true,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _collapseSidebar() {
    setState(() {
      _sidebarExpanded = false;
      _sidebarTemporarilyVisible = false;
    });
    unawaited(widget.sidebarPreferenceStore?.writeSidebarExpanded(false));
  }

  void _showTemporarySidebar() {
    if (_sidebarExpanded || _sidebarTemporarilyVisible) return;
    setState(() => _sidebarTemporarilyVisible = true);
  }

  void _hideTemporarySidebar() {
    if (!_sidebarTemporarilyVisible) return;
    setState(() => _sidebarTemporarilyVisible = false);
  }

  void _pinSidebar() {
    setState(() {
      _sidebarExpanded = true;
      _sidebarTemporarilyVisible = false;
    });
    unawaited(widget.sidebarPreferenceStore?.writeSidebarExpanded(true));
  }

  Future<void> _restoreSidebarPreference() async {
    final expanded = await widget.sidebarPreferenceStore?.readSidebarExpanded();
    if (!mounted || expanded == null || expanded == _sidebarExpanded) return;
    setState(() => _sidebarExpanded = expanded);
  }

  Future<void> _restoreTranslationPreferences() async {
    final store = widget.translationPreferencesStore;
    final controller = widget.translationPreferencesController;
    if (store == null || controller == null) return;
    final value = await store.read();
    if (value != null) controller.update(value);
  }

  Future<void> _updateTranslationPreferences(
    TranslationPreferences value,
  ) async {
    final controller = widget.translationPreferencesController;
    controller?.update(value);
    final store = widget.translationPreferencesStore;
    if (store != null) await store.write(value);
  }

  Future<void> _restoreTranslationTerminology() async {
    final store = widget.translationTerminologyStore;
    final controller = widget.translationTerminologyController;
    if (store == null || controller == null) return;
    final value = await store.read();
    if (value != null) controller.update(value);
  }

  Future<void> _updateTranslationTerminology(
    TranslationTerminology value,
  ) async {
    widget.translationTerminologyController?.update(value);
    final store = widget.translationTerminologyStore;
    if (store != null) await store.write(value);
  }

  Future<void> _restoreDictionaryPreferences() async {
    final store = widget.dictionaryPreferencesStore;
    final controller = widget.dictionaryPreferencesController;
    if (store == null || controller == null) return;
    final value = await store.read();
    if (value != null) controller.update(value);
  }

  Future<void> _updateDictionaryPreferences(DictionaryPreferences value) async {
    widget.dictionaryPreferencesController?.update(value);
    final store = widget.dictionaryPreferencesStore;
    if (store != null) await store.write(value);
  }

  Future<void> _clearPreferenceFile(String category) async {
    final root = Directory(
      widget.appDataDirectory ??
          resolveAppDataPath(
            configuredDirectory: Platform.environment['YIXUE_DATA_DIR'],
            executablePath: Platform.resolvedExecutable,
          ),
    );
    final fileName = switch (category) {
      'appearance_preferences' => 'appearance-preferences.json',
      'translation_preferences' => 'translation-preferences.json',
      'terminology' => 'translation-terminology.json',
      'ui_preferences' => 'ui-preferences.json',
      'dictionary_preferences' => 'dictionary-preferences.json',
      'home_plan' => 'home-plan.json',
      'textbook_courses' => 'learning-textbooks.json',
      _ => null,
    };
    if (fileName == null) return;
    final file = File('${root.path}${Platform.pathSeparator}$fileName');
    if (await file.exists()) await file.delete();
    if (category == 'terminology') {
      widget.translationTerminologyController?.update(
        const TranslationTerminology([]),
      );
    }
    if (category == 'translation_preferences') {
      widget.translationPreferencesController?.update(
        const TranslationPreferences(),
      );
    }
    if (category == 'dictionary_preferences') {
      widget.dictionaryPreferencesController?.update(
        const DictionaryPreferences(),
      );
    }
    if (category == 'home_plan') {
      _inMemoryHomePlan = const HomePlanData();
    }
  }

  Future<String?> _exportLocalData() async {
    final destinationPath =
        await (widget.dataExportDirectoryPicker?.call() ??
            getDirectoryPath(confirmButtonText: '选择导出位置'));
    if (destinationPath == null || destinationPath.trim().isEmpty) return null;
    final source = Directory(
      widget.appDataDirectory ??
          resolveAppDataPath(
            configuredDirectory: Platform.environment['YIXUE_DATA_DIR'],
            executablePath: Platform.resolvedExecutable,
          ),
    );
    final result = await LocalDataExportService.export(
      source: source,
      destinationParent: Directory(destinationPath),
    );
    return result.destination.path;
  }

  void _select(int index) {
    if (_simultaneousCompactWindowMode && index != _selectedIndex) return;
    if (_selectedIndex == index) return;
    final buildAfterFirstFrame = _pageCache[index] == null;
    final motionLevel = widget.appearanceController.value.motionLevel;
    if (!buildAfterFirstFrame || motionLevel == YixueMotionLevel.off) {
      setState(() {
        _selectedIndex = index;
        _showSkeleton = false;
      });
    } else {
      setState(() {
        _selectedIndex = index;
        _showSkeleton = true;
      });
    }
    if (buildAfterFirstFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedIndex != index || _pageCache[index] != null) {
          return;
        }
        setState(() => _pageCache[index] = _buildPage(index));
        // Keep the transition cover until the target workspace has produced
        // its first frame. Each workspace can then show its own real loading,
        // empty, or error state instead of an unrelated timed skeleton.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _selectedIndex != index || !_showSkeleton) return;
          setState(() => _showSkeleton = false);
        });
      });
    }
  }

  void _openUnderstandingUsageSettings() {
    if (_simultaneousCompactWindowMode && _selectedIndex != 6) return;
    setState(() {
      _understandingUsageFocusRequestId++;
      if (_pageCache[6] != null) {
        // Replacing the cached widget updates its request ID while retaining
        // ModelSettingsPage's State, so cached pages respond to every click.
        _pageCache[6] = _buildPage(6);
      }
    });
    // Reuse the regular page transition; a first visit is still built after
    // its transition frame, but its widget receives the new request ID.
    _select(6);
  }

  @override
  void dispose() {
    _unregisterScreenshotExitCleanup?.call();
    _screenshotDesktop?.dispose();
    _screenshotArchive?.dispose();
    _screenshotRuntime.dispose();
    _ownedQuickTranslationService?.dispose();
    _ownedLearningSummaryService?.close();
    _ownedSubtitlePostSessionGenerator?.close();
    unawaited(_ownedLearningSpeechRecognizer?.dispose());
    _modelStatus.dispose();
    _simultaneousActivityStatus.dispose();
    super.dispose();
  }

  void _refreshModelStatus() {
    final factory = widget.coreFactory;
    if (factory == null) {
      _modelStatus.value = '本地优先 · 预览核心';
      return;
    }
    AppCore? core;
    try {
      core = factory();
      final profiles = core.listProviderProfiles();
      final explicitlyAssigned = profiles
          .where(
            (profile) =>
                profile.enabled &&
                profile.assignedRoles.contains(ModelRole.translation),
          )
          .toList(growable: false);
      final active = explicitlyAssigned.length == 1
          ? explicitlyAssigned.single
          : null;
      if (explicitlyAssigned.length > 1) {
        _modelStatus.value = '已配置 ${explicitlyAssigned.length} 个翻译模型';
      } else if (active == null) {
        _modelStatus.value = '本地优先 · 内置英汉模型';
      } else {
        final mode = active.kind == ProviderProfileKind.localModel
            ? '本地模型'
            : '自定义接口';
        _modelStatus.value = '$mode · 当前：${active.displayName}';
      }
    } catch (_) {
      _modelStatus.value = '本地优先 · 状态暂不可用';
    } finally {
      try {
        core?.dispose();
      } catch (_) {
        _modelStatus.value = '本地优先 · 状态暂不可用';
      }
    }
  }

  Widget _workspace() {
    return Stack(
      key: _workspaceKey,
      children: [
        for (var index = 0; index < _pageCache.length; index++)
          if (_pageCache[index] != null)
            Positioned.fill(
              child: Offstage(
                key: ValueKey('workspace-$index'),
                offstage: index != _selectedIndex,
                child: TickerMode(
                  enabled: index == _selectedIndex,
                  child: _WorkspaceAppearance(
                    workspace: YixueWorkspace.values[index],
                    controller: widget.appearanceController,
                    child: _pageCache[index]!,
                  ),
                ),
              ),
            ),
        const Positioned.fill(
          child: _CustomThemeBackdrop(key: ValueKey('custom-theme-backdrop')),
        ),
        if (_showSkeleton)
          const Positioned.fill(
            child: _PageSkeleton(key: ValueKey('page-skeleton')),
          ),
        if (_selectedIndex != 5)
          ValueListenableBuilder<String?>(
            valueListenable: _simultaneousActivityStatus,
            builder: (context, status, _) {
              if (status == null) return const SizedBox.shrink();
              return Positioned(
                top: 14,
                right: 16,
                child: SimultaneousInterpretationActivityBanner(
                  status: _simultaneousActivityStatus,
                  onReturn: () => _select(5),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildPage(int index) => switch (index) {
    0 => HomeDashboardPage(
      loadSnapshot: _loadHomeSnapshot,
      loadWorkbenchSnapshot: _loadHomeWorkbenchSnapshot,
      loadLatestTranslation: _loadLatestTranslation,
      onContinueTranslation: _continueTranslation,
      onStartTranslation: _startQuickTranslation,
      onOpenRecent: _openRecentActivity,
      onOpenHistory: _openHistory,
      onOpenTodaySummary: _openTodaySummary,
      onOpenScreenshot: () => _select(2),
      onOpenLearning: () => _select(4),
      onOpenLive: () => _select(5),
      loadPlan: _loadHomePlan,
      savePlan: _saveHomePlan,
      loadDailyPlan: _loadHomeDailyPlan,
      loadDailyPlans: _loadHomeDailyPlans,
      onOpenPlanner: _openHomePlanner,
      onOpenPlannerDate: (date) =>
          unawaited(_openHomePlanner(initialDate: date)),
      loadResumeTask: () async => null,
      onOpenFocus: _openFocusWorkspace,
      loadUserProfile: _loadHomeUserProfile,
      saveUserProfile: _saveHomeUserProfile,
      clock: widget.clock,
    ),
    1 => _QuickTranslationPage(
      editorKey: _translationEditorKey,
      clipboardReader: widget.clipboardReader,
      onTranslate: _translate,
      onCancel: _cancelTranslation,
      loadHistory: _loadTranslationHistory,
      loadHistoryPage: _loadTranslationHistoryPage,
      exportHistory: _exportTranslationHistory,
      deleteHistory: _deleteTranslationHistoryEntries,
      screenshotDeleteResult: () => _screenshotArchive?.lastDeleteResult,
      loadAnnotations: _loadTranslationAnnotations,
      saveAnnotation: _saveTranslationAnnotation,
      lookupDictionary: _lookupDictionary,
      loadFavoriteWords: _loadFavoriteWords,
      loadFavoriteWordPage: _loadFavoriteWordPage,
      setFavoriteWord: _setFavoriteWord,
      loadWordAnnotation: _loadWordAnnotation,
      saveWordAnnotation: _saveWordAnnotation,
      onSetLearning: _setWordLearning,
      onImportDictionary: _importDictionaryPackage,
      onOpenDictionaryGuide: _showDictionaryGuide,
      translationPreferencesController: widget.translationPreferencesController,
      onOpenModels: () => _select(6),
      onOpenSettings: () => _select(7),
      onTranslateWithOptions: _translateWithOptions,
      modelStatus: _modelStatus,
    ),
    2 => ScreenshotTranslationWorkspace(
      runtime: _screenshotRuntime,
      archiveController: _screenshotArchive,
      desktopController: _screenshotDesktop,
      settingsRequestVersion: _screenshotSettingsRequestVersion,
      onOpenModels: () => _select(6),
      onAddScreenshotWord: _addScreenshotWord,
      lookupDictionary: _lookupDictionary,
      summarizeHistory:
          widget.learningSummaryRunner ??
          _ownedLearningSummaryService?.summarize,
    ),
    3 => const _NotIntegratedPage(
      title: '阅读器',
      detail: '暂未接入。阅读器正在独立开发，完成后再接入译学。',
    ),
    4 => LearningWorkspace(
      key: const ValueKey('learning-workspace'),
      dataRevision: _learningDataRevision,
      store: _learningStore,
      loadEntries: _loadLearningEntries,
      lookupDictionary: _lookupDictionary,
      loadFavoriteWords: _loadFavoriteWords,
      setFavoriteWord: _setFavoriteWord,
      loadWordAnnotation: _loadWordAnnotation,
      saveWordAnnotation: _saveWordAnnotation,
      recordActivity: _recordFocusActivity,
      onOpenFocus: _openFocusWorkspace,
      onOpenTranslation: () => _select(1),
      onOpenContentLibrary: (openTextbooks) =>
          _openContentLibrary(onOpenTextbooks: openTextbooks),
      onSummarize:
          widget.learningSummaryRunner ??
          _ownedLearningSummaryService?.summarize,
      onGenerateSentenceExercises:
          _ownedLearningSummaryService?.generateSentenceExercises,
      onOpenUnderstandingModelSettings: _openUnderstandingUsageSettings,
      onTranslateTextbook: (text) =>
          _translate(text, TranslationDirection.englishToChinese),
      speechRecognizer:
          widget.learningSpeechRecognizer ?? _ownedLearningSpeechRecognizer,
      textbookStore: widget.textbookStore,
      onSpeak: _speakDictionaryText,
      clock: widget.clock,
    ),
    5 => _buildSimultaneousInterpretationPage(),
    6 => ModelSettingsPage(
      coreFactory: widget.coreFactory,
      bundledModelRootPath:
          '${File(Platform.resolvedExecutable).parent.path}\\models',
      onConfigurationChanged: _refreshModelStatus,
      onOpenSimultaneousInterpretation: () => _select(5),
      focusUnderstandingUsageRequestId: _understandingUsageFocusRequestId,
    ),
    7 => _SettingsPage(
      appearanceController: widget.appearanceController,
      onOpenModels: () => _select(6),
      coreFactory: widget.coreFactory,
      modelStatus: _modelStatus,
      translationPreferencesController: widget.translationPreferencesController,
      onTranslationPreferencesChanged: _updateTranslationPreferences,
      translationTerminologyController: widget.translationTerminologyController,
      onTranslationTerminologyChanged: _updateTranslationTerminology,
      dictionaryPreferencesController: widget.dictionaryPreferencesController,
      onDictionaryPreferencesChanged: _updateDictionaryPreferences,
      onClearPreferenceFile: _clearPreferenceFile,
      onExportLocalData: _exportLocalData,
      appDataDirectory: widget.appDataDirectory,
      storagePolicyStore: widget.storagePolicyStore,
      storageUsageLoader: widget.storageUsageLoader,
      onOpenContentLibrary: () =>
          _openContentLibrary(onOpenTextbooks: () => _select(4)),
    ),
    _ => throw RangeError.index(index, YixueWorkspace.values),
  };

  Widget _buildSimultaneousInterpretationPage() {
    final sessionStore = widget.subtitleSessionStore;
    final appDataDirectory = widget.appDataDirectory;
    if (sessionStore == null ||
        appDataDirectory == null ||
        appDataDirectory.trim().isEmpty) {
      return const _PlaceholderPage(title: 'AI 同传', detail: '字幕资料库尚未启用。');
    }

    final modelStore = StreamingAsrModelStore(
      applicationDataDirectory: Directory(appDataDirectory),
    );
    final multilingualModelStore = MultilingualAsrModelStore(
      applicationDataDirectory: Directory(appDataDirectory),
    );
    return LiveSubtitleWorkbenchPage(
      capture: DesktopAudioCaptureAdapter(),
      appDataDirectory: appDataDirectory,
      asrRuntime: SherpaStreamingAsrRuntime(
        modelDirectory: modelStore.modelDirectory,
        multilingualModelDirectory: multilingualModelStore.modelDirectory,
      ),
      modelStore: modelStore,
      multilingualModelStore: multilingualModelStore,
      sessionStore: sessionStore,
      displayPreferencesStore: FileSubtitleDisplayPreferencesStore(
        File(
          joinAppDataPath(
            appDataDirectory,
            'subtitle-display-preferences.json',
          ),
        ),
      ),
      translationSetupLoader: _loadSubtitleTranslationSetup,
      onOpenHistory: () async {
        final reviewStore = FileSubtitlePostSessionReviewStore(
          Directory(
            joinAppDataPath(appDataDirectory, 'subtitle-post-session-reviews'),
          ),
        );
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SubtitleSessionHistoryPage(
              store: sessionStore,
              reviewStore: reviewStore,
              postSessionGenerator: _ownedSubtitlePostSessionGenerator,
              appDataDirectory: Directory(appDataDirectory),
            ),
          ),
        );
      },
      activityStatus: _simultaneousActivityStatus,
      onCompactModeChanged: (value) {
        if (mounted && _simultaneousCompactWindowMode != value) {
          setState(() => _simultaneousCompactWindowMode = value);
        }
      },
      workbenchMinimumWindowSize: const Size(960, 620),
    );
  }

  Future<LiveSubtitleTranslationSetup> _loadSubtitleTranslationSetup({
    required List<String> sourceLanguageCodes,
    required String targetLanguageCode,
  }) async {
    const unavailableExecutor = _UnavailableSubtitleTranslationExecutor();
    const unavailableSetup = LiveSubtitleTranslationSetup(
      executor: unavailableExecutor,
      routeKind: SubtitleTranslationRouteKind.unavailable,
      providerLabel: '不可用',
      detail: '当前翻译服务或语言方向不可用；同传不会改用其他 Provider。',
    );

    final hasInjectedTranslationRunner =
        widget.quickTranslationRunner != null ||
        widget.quickTranslationRunnerWithOptions != null;
    final service = _ownedQuickTranslationService;
    if (hasInjectedTranslationRunner || service == null) {
      return unavailableSetup;
    }

    try {
      final requestedRoutes = sourceLanguageCodes
          .toSet()
          .map((sourceLanguageCode) {
            final direction = _subtitleTranslationDirection(
              sourceLanguageCode,
              targetLanguageCode,
            );
            return (
              sourceLanguageCode: sourceLanguageCode,
              direction: direction,
            );
          })
          .toList(growable: false);
      if (requestedRoutes.isEmpty) return unavailableSetup;

      // Read the full direction table once. The same immutable map supplies
      // setup labels, remote-consent metadata, and the executor used for every
      // detected transcript language in Auto mode.
      final routeSnapshots = await service.snapshotSubtitleRoutes();
      final availableRoutes =
          <
            ({
              TranslationDirection direction,
              SubtitleTranslationRouteSnapshot route,
            })
          >[];
      final unavailableDirections = <String>[];
      for (final requested in requestedRoutes) {
        final direction = requested.direction;
        final route = direction == null ? null : routeSnapshots[direction];
        if (direction == null ||
            route == null ||
            route.kind == SubtitleTranslationRouteKind.unavailable) {
          final sourceLabel =
              direction?.sourceLanguageName ?? requested.sourceLanguageCode;
          unavailableDirections.add(
            '$sourceLabel→${_subtitleTranslationTargetLabel(targetLanguageCode)}',
          );
          continue;
        }
        availableRoutes.add((direction: direction, route: route));
      }
      if (availableRoutes.isEmpty) {
        return LiveSubtitleTranslationSetup(
          executor: unavailableExecutor,
          routeKind: SubtitleTranslationRouteKind.unavailable,
          providerLabel: '不可用',
          detail: unavailableDirections.isEmpty
              ? unavailableSetup.detail
              : '没有可用的字幕翻译方向：${unavailableDirections.join('、')}。',
        );
      }

      String providerLabelFor(SubtitleTranslationRouteSnapshot route) {
        final providerName = route.profile?.displayName.trim();
        if (providerName != null && providerName.isNotEmpty) {
          return providerName;
        }
        return switch (route.kind) {
          SubtitleTranslationRouteKind.localProfile => '本地 Provider',
          SubtitleTranslationRouteKind.bundledLocal => '内置本地模型',
          SubtitleTranslationRouteKind.remoteProfile => '远程 Provider',
          SubtitleTranslationRouteKind.unavailable => '不可用',
        };
      }

      final providerLabels = availableRoutes
          .map((entry) => providerLabelFor(entry.route))
          .toSet()
          .join('、');
      final remoteRoutes = availableRoutes
          .where(
            (entry) =>
                entry.route.kind == SubtitleTranslationRouteKind.remoteProfile,
          )
          .toList(growable: false);
      final remoteDestinations = remoteRoutes
          .map((entry) {
            final destination = _safeRemoteDestination(
              entry.route.profile?.endpoint,
            );
            return destination ?? providerLabelFor(entry.route);
          })
          .toSet()
          .join('、');
      final configuredDirectionDetails = availableRoutes
          .map(
            (entry) =>
                '${entry.direction.sourceLanguageName}→${entry.direction.targetLanguageName}（${providerLabelFor(entry.route)}）',
          )
          .join('、');
      final routeKind = remoteRoutes.isNotEmpty
          ? SubtitleTranslationRouteKind.remoteProfile
          : availableRoutes.any(
              (entry) =>
                  entry.route.kind == SubtitleTranslationRouteKind.localProfile,
            )
          ? SubtitleTranslationRouteKind.localProfile
          : SubtitleTranslationRouteKind.bundledLocal;
      final isAutoBatch = requestedRoutes.length > 1;
      final detail = isAutoBatch
          ? <String>[
              '自动识别不会作为翻译源；每条字幕按实际语种使用本次统一读取的路由快照。',
              '已配置方向及 Provider：$configuredDirectionDetails。',
              if (unavailableDirections.isNotEmpty)
                '未配置方向：${unavailableDirections.join('、')}；这些语种的字幕会单独提示翻译不可用，其他方向继续工作。',
              if (remoteRoutes.isNotEmpty) '只有已确认的字幕原文会发送到上述远程 Provider。',
              if (remoteRoutes.isEmpty) '已配置方向由本地 Provider 处理，不会上传到远程服务。',
            ].join('\n')
          : switch (availableRoutes.single.route.kind) {
              SubtitleTranslationRouteKind.localProfile ||
              SubtitleTranslationRouteKind.bundledLocal =>
                '确认字幕由本地 Provider 翻译，不会上传到远程服务。',
              SubtitleTranslationRouteKind.remoteProfile =>
                '仅确认后的原文字幕会发送到已配置的远程 Provider。',
              SubtitleTranslationRouteKind.unavailable =>
                '当前 Provider 不支持此语言方向；同传不会改用其他 Provider。',
            };
      return LiveSubtitleTranslationSetup(
        executor: QuickTranslationSubtitleExecutor(
          service,
          routeSnapshots: Future.value(routeSnapshots),
        ),
        routeKind: routeKind,
        providerLabel: providerLabels,
        remoteDestinationLabel: remoteDestinations.isEmpty
            ? null
            : remoteDestinations,
        detail: detail,
      );
    } catch (_) {
      return unavailableSetup;
    }
  }

  static TranslationDirection? _subtitleTranslationDirection(
    String sourceLanguageCode,
    String targetLanguageCode,
  ) => TranslationDirection.fromLanguageCodes(
    sourceLanguageCode,
    targetLanguageCode,
  );

  static String _subtitleTranslationTargetLabel(String languageCode) =>
      switch (languageCode) {
        'zh' => '中文',
        'en' => '英语',
        'ja' => '日语',
        'ko' => '韩语',
        _ => languageCode,
      };

  static String? _safeRemoteDestination(String? endpoint) {
    if (endpoint == null || endpoint.trim().isEmpty) return null;
    try {
      final uri = Uri.parse(endpoint.trim());
      final host = uri.host.trim();
      if (host.isEmpty) return null;
      return uri.hasPort ? '$host:${uri.port}' : host;
    } on FormatException {
      return null;
    }
  }

  void _startQuickTranslation(String text) {
    _translationEditorKey.currentState?.setSourceText(text);
    _select(1);
  }

  void _continueTranslation(TranslationHistoryEntryData entry) {
    _translationEditorKey.currentState?.setTranslation(
      entry.sourceText,
      entry.translatedText,
    );
    _select(1);
  }

  void _openRecentActivity(ActivityEventData activity) {
    switch (activity.kind) {
      case ActivityKind.translation:
        unawaited(_openRecentTranslation(activity));
      case ActivityKind.reading:
        _select(4);
      case ActivityKind.vocabulary:
        unawaited(_openFavoriteWordsFromHome());
      case ActivityKind.exercise:
      case ActivityKind.focus:
        _select(4);
      case ActivityKind.speaking:
        _select(5);
    }
  }

  Future<void> _openRecentTranslation(ActivityEventData activity) async {
    try {
      final history = await _loadTranslationHistory();
      TranslationHistoryEntryData? match;
      for (final entry in history) {
        if (entry.id == activity.id ||
            activity.id == 'translation:${entry.id}') {
          match = entry;
          break;
        }
      }
      if (!mounted) return;
      if (match != null) {
        _continueTranslation(match);
      } else {
        _startQuickTranslation(activity.title);
      }
    } catch (_) {
      if (mounted) _startQuickTranslation(activity.title);
    }
  }

  Future<void> _openHistory() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48 < 1120 ? size.width - 48 : 1120).toDouble();
    final height = (size.height - 48 < 760 ? size.height - 48 : 760).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: _TranslationHistoryWorkspace(
            loadHistory: _loadTranslationHistory,
            loadHistoryPage: _loadTranslationHistoryPage,
            exportHistory: _exportTranslationHistory,
            deleteHistory: _deleteTranslationHistoryEntries,
            screenshotDeleteResult: () => _screenshotArchive?.lastDeleteResult,
            loadAnnotations: _loadTranslationAnnotations,
            saveAnnotation: _saveTranslationAnnotation,
            onContinue: (entry) {
              Navigator.of(dialogContext).pop();
              _continueTranslation(entry);
            },
            onSpeak: _speakDictionaryText,
          ),
        ),
      ),
    );
  }

  Future<void> _openTodaySummary() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(620.0, 1180.0).toDouble();
    final height = (size.height - 48).clamp(620.0, 860.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: HomeDailyStatsWorkspace(
            loadSnapshot: () => _loadHomeWorkbenchSnapshot(recentLimit: 500),
            clock: widget.clock,
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    );
  }

  Future<void> _openFocusWorkspace() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(520.0, 820.0).toDouble();
    final height = (size.height - 48).clamp(560.0, 760.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: HomeFocusWorkspace(
            loadSession: () =>
                widget.homeFocusSessionStore?.read() ?? Future.value(null),
            saveSession: (session) async {
              await widget.homeFocusSessionStore?.write(session);
            },
            clearSession: () async {
              await widget.homeFocusSessionStore?.clear();
            },
            recordActivity: _recordFocusActivity,
            clock: widget.clock,
          ),
        ),
      ),
    );
  }

  Future<void> _openHomePlanner({DateTime? initialDate}) async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(760.0, 1220.0).toDouble();
    final height = (size.height - 48).clamp(620.0, 860.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: Scaffold(
            body: HomePlannerWorkspace(
              initialDate: initialDate ?? widget.clock(),
              loadPlan: _loadHomeDailyPlan,
              loadMonth: _loadHomeDailyMonth,
              savePlan: _saveHomeDailyPlan,
              clock: widget.clock,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
      ),
    );
    if (mounted) {
      final page = _pageCache[0];
      if (page is HomeDashboardPage) {
        setState(() {});
      }
    }
  }

  Future<void> _openFavoriteWordsFromHome() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(420.0, 1120.0).toDouble();
    final height = (size.height - 48).clamp(560.0, 760.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: FavoriteWordsWorkspace(
            loadPage: _loadFavoriteWordPage,
            setFavoriteWord: _setFavoriteWord,
            saveWordAnnotation: _saveWordAnnotation,
            setWordLearning: _setWordLearning,
            lookupRichEntry: _lookupDictionary,
            onSpeak: _speakDictionaryText,
            onContinueTranslation: (word) {
              Navigator.of(dialogContext).pop();
              _startQuickTranslation(word);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _speakDictionaryText(String value) async {
    final editor = _translationEditorKey.currentState;
    if (editor != null) await editor.speakText(value);
  }

  Future<List<DictionaryEntry>> _loadLearningEntries() async {
    final preferences = widget.dictionaryPreferencesController?.value;
    final localEntries = const LocalDictionaryService().entries
        .where(
          (entry) =>
              preferences == null ||
              preferences.isEnabled(dictionarySourceId(entry.source)),
        )
        .toList(growable: false);
    final factory = widget.coreFactory;
    if (factory == null) return localEntries;

    try {
      return await Future(() async {
        final core = factory();
        try {
          if (core is! DictionaryCore) return localEntries;
          final dictionary = core as DictionaryCore;
          final storedEntries = await loadStoredDictionaryEntries(dictionary);
          final orderedEntries =
              preferences?.sortEntries(storedEntries) ?? storedEntries;
          final seedByWord = <String, DictionaryEntry>{
            for (final entry in localEntries)
              normalizeLearningWord(entry.word): entry,
          };
          final entriesByWord = <String, DictionaryEntry>{};
          for (final entry in orderedEntries) {
            final normalized = normalizeLearningWord(entry.word);
            if (normalized.isEmpty) continue;
            entriesByWord.putIfAbsent(
              normalized,
              () => _toLearningDictionaryEntry(entry, seedByWord),
            );
          }
          for (final entry in localEntries) {
            entriesByWord.putIfAbsent(
              normalizeLearningWord(entry.word),
              () => entry,
            );
          }
          return List.unmodifiable(entriesByWord.values);
        } finally {
          core.dispose();
        }
      });
    } catch (_) {
      // A dictionary storage error should not make the local learning page
      // unusable; article lookups still use the configured lookup callback.
      return localEntries;
    }
  }

  Future<List<ContentSourceData>> _loadContentSources() async {
    final factory = widget.coreFactory;
    if (factory == null) return const [];
    return Future(() {
      final core = factory();
      try {
        if (core is! ContentSourceCore) return const <ContentSourceData>[];
        return (core as ContentSourceCore).listContentSources(limit: 100);
      } finally {
        core.dispose();
      }
    });
  }

  Future<List<LearningTextbookPackageData>> _loadTextbookPackages() {
    return widget.textbookStore?.read() ??
        Future.value(const <LearningTextbookPackageData>[]);
  }

  void _openContentLibrary({VoidCallback? onOpenTextbooks}) {
    final context = _workspaceKey.currentContext;
    if (!mounted || context == null) return;
    final openTextbooks = onOpenTextbooks ?? () => _select(4);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 920,
            height: 720,
            child: ContentLibraryWorkspace(
              loadDictionary: _loadLearningEntries,
              loadSources: _loadContentSources,
              loadTextbooks: _loadTextbookPackages,
              dictionaryPreferences:
                  widget.dictionaryPreferencesController?.value ??
                  const DictionaryPreferences(),
              onImportDictionary: _importDictionaryPackage,
              onOpenTextbooks: () {
                Navigator.of(dialogContext).pop();
                openTextbooks();
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setWordLearning(String word, bool enabled) async {
    await LearningRepository(
      _learningStore,
      clock: widget.clock,
    ).setWordEnabled(word, enabled: enabled, now: widget.clock());
    _refreshLearningPage();
  }

  Future<TranslationHistoryEntryData?> _loadLatestTranslation() async {
    final history = await _loadTranslationHistory();
    return history.isEmpty ? null : history.first;
  }

  Future<String> _translate(String sourceText, TranslationDirection direction) {
    return _translateWithOptions(
      sourceText,
      direction,
      const TranslationRequestOptions(),
    );
  }

  Future<String> _translateWithOptions(
    String sourceText,
    TranslationDirection direction,
    TranslationRequestOptions options,
  ) {
    final injectedWithOptions = widget.quickTranslationRunnerWithOptions;
    if (injectedWithOptions != null) {
      return injectedWithOptions(sourceText, direction, options);
    }
    final injected = widget.quickTranslationRunner;
    if (options.webSearchEnabled) {
      throw const QuickTranslationException('web_search_unavailable');
    }
    if (injected != null) return injected(sourceText, direction);
    final service = _ownedQuickTranslationService;
    if (service == null) {
      throw const QuickTranslationException('no_remote_provider');
    }
    return service.translate(
      sourceText,
      direction: direction,
      options: options,
    );
  }

  Future<bool> _cancelTranslation() {
    final injected = widget.quickTranslationCanceller;
    if (injected != null) return injected();
    final service = _ownedQuickTranslationService;
    if (service != null) return service.cancelActiveTranslation();
    return Future.value(widget.quickTranslationRunner != null);
  }

  Future<List<TranslationHistoryEntryData>> _loadTranslationHistory() {
    final injected = widget.translationHistoryLoader;
    if (injected != null) return injected();
    final factory = widget.coreFactory;
    if (factory == null) return Future.value(const []);
    return Future(() {
      final core = factory();
      try {
        if (core is! TranslationHistoryCore) return const [];
        return (core as TranslationHistoryCore).listTranslationHistory(
          limit: 500,
        );
      } finally {
        core.dispose();
      }
    });
  }

  Future<List<TranslationHistoryEntryData>> _loadTranslationHistoryPage(
    int offset,
    int limit,
  ) {
    final injected = widget.translationHistoryPageLoader;
    if (injected != null) return injected(offset, limit);
    final legacy = widget.translationHistoryLoader;
    if (legacy != null && offset == 0) return legacy();
    final factory = widget.coreFactory;
    if (factory == null) return Future.value(const []);
    return Future(() {
      final core = factory();
      try {
        if (core is PagedTranslationHistoryCore) {
          return (core as PagedTranslationHistoryCore)
              .listTranslationHistoryPage(limit: limit, offset: offset);
        }
        if (offset == 0 && core is TranslationHistoryCore) {
          return (core as TranslationHistoryCore).listTranslationHistory(
            limit: limit,
          );
        }
        return const <TranslationHistoryEntryData>[];
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _deleteTranslationHistory(List<String> ids) {
    final injected = widget.translationHistoryDeleter;
    if (injected != null) return injected(ids);
    final factory = widget.coreFactory;
    if (factory == null) {
      return Future.error(
        const CoreBridgeException(
          'history_delete_unavailable',
          '当前核心不支持选择删除翻译历史',
        ),
      );
    }
    return Future(() {
      final core = factory();
      try {
        if (core is! DeletableTranslationHistoryCore) {
          throw const CoreBridgeException(
            'history_delete_unavailable',
            '当前核心不支持选择删除翻译历史',
          );
        }
        (core as DeletableTranslationHistoryCore).deleteTranslationHistory(ids);
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _deleteTranslationHistoryEntries(
    List<TranslationHistoryEntryData> entries,
  ) async {
    if (entries.isEmpty) return;
    final screenshotEntries = entries
        .where(
          (entry) =>
              entry.origin ==
              ScreenshotTranslationArchiveController.screenshotOrigin,
        )
        .toList(growable: false);
    if (screenshotEntries.isEmpty) {
      await _deleteTranslationHistory(
        entries.map((entry) => entry.id).toList(growable: false),
      );
      return;
    }
    final archive = _screenshotArchive;
    if (archive == null) {
      throw const CoreBridgeException(
        'screenshot_image_delete_unavailable',
        '截屏原图删除协调暂不可用',
      );
    }
    await archive.deleteSelectedHistoryEntries(
      entries,
      deleteHistory: _deleteTranslationHistory,
    );
  }

  Future<String?> _exportTranslationHistory(
    List<TranslationHistoryEntryData> history,
    List<TranslationAnnotationData> annotations,
  ) async {
    final injected = widget.translationHistoryExporter;
    if (injected != null) return injected(history, annotations);
    final location = await getSaveLocation(
      suggestedName: 'yixue-translation-history.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: '译学翻译历史', extensions: ['json']),
      ],
    );
    if (location == null) return null;
    await TranslationHistoryExportService.write(
      path: location.path,
      history: history,
      annotations: annotations,
    );
    return location.path;
  }

  Future<List<TranslationAnnotationData>> _loadTranslationAnnotations() {
    final injected = widget.translationAnnotationLoader;
    if (injected != null) return injected();
    final factory = widget.coreFactory;
    if (factory == null) return Future.value(const []);
    return Future(() {
      final core = factory();
      try {
        if (core is! TranslationAnnotationCore) return const [];
        return (core as TranslationAnnotationCore).listTranslationAnnotations(
          limit: 500,
        );
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _saveTranslationAnnotation(
    TranslationAnnotationData annotation,
  ) async {
    final injected = widget.translationAnnotationSaver;
    if (injected != null) {
      await injected(annotation);
      return;
    }
    final factory = widget.coreFactory;
    if (factory == null) return;
    await Future(() {
      final core = factory();
      try {
        if (core is TranslationAnnotationCore) {
          (core as TranslationAnnotationCore).saveTranslationAnnotation(
            annotation,
          );
        }
      } finally {
        core.dispose();
      }
    });
  }

  Future<DictionaryEntry?> _lookupDictionary(String word) async {
    final normalized = word.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final injected = widget.dictionaryLookupLoader;
    if (injected != null) return injected(normalized);
    final factory = widget.coreFactory;
    if (factory == null) {
      if (widget.dictionaryPreferencesController != null &&
          !widget.dictionaryPreferencesController!.value.isEnabled(
            'yixue-basic',
          )) {
        return null;
      }
      const localDictionary = LocalDictionaryService();
      return localDictionary.lookup(normalized) ??
          localDictionary.lookupChinese(normalized);
    }
    return Future(() {
      final core = factory();
      try {
        if (core is DictionaryCore) {
          final dictionary = core as DictionaryCore;
          const localDictionary = LocalDictionaryService();
          final localSeedEnabled =
              widget.dictionaryPreferencesController == null ||
              widget.dictionaryPreferencesController!.value.isEnabled(
                'yixue-basic',
              );
          final localSeed = localSeedEnabled
              ? localDictionary.lookup(normalized) ??
                    localDictionary.lookupChinese(normalized)
              : null;
          final seedByWord = localSeed == null
              ? const <String, DictionaryEntry>{}
              : <String, DictionaryEntry>{
                  normalizeLearningWord(localSeed.word): localSeed,
                };
          final entries = dictionary.lookupDictionary(normalized, limit: 20);
          final ordered =
              widget.dictionaryPreferencesController?.value.sortEntries(
                entries,
              ) ??
              entries;
          final exactMatch = bestDictionaryEntryForTerm(
            normalized,
            ordered.map(
              (entry) => _toLearningDictionaryEntry(entry, seedByWord),
            ),
          );
          if (exactMatch != null) return exactMatch;
          if (localSeed != null) {
            dictionary.saveDictionaryEntry(_toDictionaryData(localSeed));
            return localSeed;
          }
          return null;
        }
        const localDictionary = LocalDictionaryService();
        return localDictionary.lookup(normalized) ??
            localDictionary.lookupChinese(normalized);
      } finally {
        core.dispose();
      }
    });
  }

  Future<String> _translateScreenshotSelectedWord(
    String word,
    String operationId,
  ) {
    final term = dictionaryTermAtInput(word);
    if (term == null) {
      throw const FormatException('请选择 OCR 原文中的一个中英文词语。');
    }
    final isEnglish = englishWordAtSelection(term, 0, term.length) != null;
    final service = _ownedQuickTranslationService;
    if (service != null &&
        widget.quickTranslationRunner == null &&
        widget.quickTranslationRunnerWithOptions == null) {
      return service.translate(
        term,
        direction: isEnglish
            ? TranslationDirection.englishToChinese
            : TranslationDirection.chineseToEnglish,
        origin: 'screenshot_translation',
        historyEntryId: operationId,
        screenshotCaptureId: operationId,
        operationId: operationId,
        recordHistory: false,
      );
    }
    return _translateWithOptions(
      term,
      isEnglish
          ? TranslationDirection.englishToChinese
          : TranslationDirection.chineseToEnglish,
      const TranslationRequestOptions(),
    );
  }

  Future<bool> _cancelScreenshotSelectedWordTranslation(String operationId) {
    if (widget.quickTranslationRunner != null ||
        widget.quickTranslationRunnerWithOptions != null) {
      return Future.value(false);
    }
    return _ownedQuickTranslationService?.cancelTranslation(operationId) ??
        Future.value(false);
  }

  Future<List<String>> _loadFavoriteWords() async {
    final factory = widget.coreFactory;
    if (factory == null) return const [];
    return Future(() {
      final core = factory();
      try {
        if (core is DictionaryCore) {
          return (core as DictionaryCore).listFavoriteWords();
        }
        return const <String>[];
      } finally {
        core.dispose();
      }
    });
  }

  Future<FavoriteWordPageData> _loadFavoriteWordPage({
    String query = '',
    int limit = 40,
    int offset = 0,
  }) async {
    final injected = widget.favoriteWordPageLoader;
    if (injected != null) {
      return injected(query: query, limit: limit, offset: offset);
    }
    final factory = widget.coreFactory;
    if (factory == null) {
      return const FavoriteWordPageData(records: [], hasMore: false);
    }
    return Future(() {
      final core = factory();
      try {
        if (core is PagedFavoriteWordCore) {
          return (core as PagedFavoriteWordCore).listFavoriteWordPage(
            query: query,
            limit: limit,
            offset: offset,
          );
        }
        if (core is! DictionaryCore) {
          return const FavoriteWordPageData(records: [], hasMore: false);
        }
        final dictionary = core as DictionaryCore;
        final normalizedQuery = query.trim().toLowerCase();
        final words = dictionary
            .listFavoriteWords()
            .where((word) => word.toLowerCase().contains(normalizedQuery))
            .toList(growable: false);
        final safeOffset = offset < words.length ? offset : words.length;
        final safeLimit = limit.clamp(1, 100).toInt();
        final pageWords = words.skip(safeOffset).take(safeLimit).toList();
        final records = <FavoriteWordRecordData>[];
        for (final word in pageWords) {
          final entries = dictionary.lookupDictionary(word, limit: 50);
          final annotation = core is WordAnnotationCore
              ? (core as WordAnnotationCore).getWordAnnotation(word)
              : null;
          records.add(
            FavoriteWordRecordData(
              word: word,
              favoritedAt: '',
              languagePair: 'en-zh',
              dictionaryEntries: entries,
              annotation: annotation,
            ),
          );
        }
        return FavoriteWordPageData(
          records: records,
          hasMore: safeOffset + pageWords.length < words.length,
        );
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _setFavoriteWord(String word, bool favorite) async {
    final injected = widget.favoriteWordSetter;
    if (injected != null) {
      await injected(word, favorite);
      return;
    }
    final factory = widget.coreFactory;
    if (factory == null) return;
    await Future(() {
      final core = factory();
      try {
        if (core is DictionaryCore) {
          (core as DictionaryCore).setFavoriteWord(word, favorite);
        }
      } finally {
        core.dispose();
      }
    });
  }

  Future<WordAnnotationData?> _loadWordAnnotation(String word) async {
    final injected = widget.wordAnnotationLoader;
    if (injected != null) return injected(word);
    final factory = widget.coreFactory;
    if (factory == null) return null;
    return Future(() {
      final core = factory();
      try {
        if (core is WordAnnotationCore) {
          return (core as WordAnnotationCore).getWordAnnotation(word);
        }
        return null;
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _saveWordAnnotation(WordAnnotationData annotation) async {
    final injected = widget.wordAnnotationSaver;
    if (injected != null) {
      await injected(annotation);
      return;
    }
    final factory = widget.coreFactory;
    if (factory == null) return;
    await Future(() {
      final core = factory();
      try {
        if (core is WordAnnotationCore) {
          (core as WordAnnotationCore).saveWordAnnotation(annotation);
        }
      } finally {
        core.dispose();
      }
    });
  }

  Future<void> _importDictionaryPackage() async {
    final picked =
        await (widget.dictionaryPackagePicker?.call() ??
            openFile(
              acceptedTypeGroups: [
                const XTypeGroup(label: '译学词典包', extensions: ['json']),
              ],
            ));
    if (picked == null || !mounted) return;
    try {
      final result = await const DictionaryPackageService().readFile(
        File(picked.path),
      );
      final factory = widget.coreFactory;
      if (factory == null) throw StateError('本地数据库未连接');
      await Future(() {
        final core = factory();
        try {
          if (core is! DictionaryCore) throw StateError('词典服务未连接');
          for (final entry in result.entries) {
            (core as DictionaryCore).saveDictionaryEntry(entry);
          }
        } finally {
          core.dispose();
        }
      });
      await _updateDictionaryPreferences(
        (widget.dictionaryPreferencesController?.value ??
                const DictionaryPreferences())
            .registerSource(
              id: result.packageId,
              displayName: result.displayName,
              license: result.license,
            ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导入“${result.displayName}”${result.entries.length}条词条，许可：${result.license}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('词典导入失败：${error.toString()}')));
    }
  }

  Future<void> _showDictionaryGuide() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _DictionaryPackageGuideDialog(
        onExportTemplate: _exportDictionaryTemplate,
      ),
    );
  }

  Future<void> _exportDictionaryTemplate() async {
    final location = await getSaveLocation(
      suggestedName: 'yixue-dictionary-template.en-zh.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: '译学词典包', extensions: ['json']),
      ],
    );
    if (location == null || !mounted) return;
    try {
      await File(location.path).writeAsString(
        '${DictionaryPackageService.templateJson}\n',
        flush: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('词典模板已保存到：${location.path}')));
    } on FileSystemException {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('词典模板保存失败，请检查文件权限')));
    }
  }

  static DictionaryEntry _toDictionaryEntry(DictionaryEntryData entry) =>
      DictionaryEntry(
        word: entry.word,
        ipa: entry.ipa,
        partOfSpeech: entry.partOfSpeech,
        meanings: entry.meanings,
        example: entry.example,
        exampleTranslation: entry.exampleTranslation,
        source: entry.source,
      );

  static DictionaryEntry _toLearningDictionaryEntry(
    DictionaryEntryData entry,
    Map<String, DictionaryEntry> seedByWord,
  ) {
    final stored = _toDictionaryEntry(entry);
    final seed = seedByWord[normalizeLearningWord(entry.word)];
    if (seed == null ||
        dictionarySourceId(seed.source) != dictionarySourceId(entry.source)) {
      return stored;
    }
    return DictionaryEntry(
      word: stored.word,
      ipa: stored.ipa.isEmpty ? seed.ipa : stored.ipa,
      partOfSpeech: stored.partOfSpeech.isEmpty
          ? seed.partOfSpeech
          : stored.partOfSpeech,
      meanings: stored.meanings.isEmpty ? seed.meanings : stored.meanings,
      example: stored.example.isEmpty ? seed.example : stored.example,
      exampleTranslation: stored.exampleTranslation.isEmpty
          ? seed.exampleTranslation
          : stored.exampleTranslation,
      coverageBands: seed.coverageBands,
      source: stored.source,
      exampleCandidates: seed.exampleCandidates,
      senseCandidates: seed.senseCandidates,
      partOfSpeechCandidates: seed.partOfSpeechCandidates,
      pronunciationCandidates: seed.pronunciationCandidates,
      learningTags: seed.learningTags,
      frequency: seed.frequency,
      qualityStatus: seed.qualityStatus,
      reviewFields: seed.reviewFields,
      candidateSourceIds: seed.candidateSourceIds,
      variants: seed.variants,
      collocationCandidates: seed.collocationCandidates,
      relationCandidates: seed.relationCandidates,
    );
  }

  static DictionaryEntryData _toDictionaryData(DictionaryEntry entry) =>
      DictionaryEntryData(
        id: 'seed.${entry.word.toLowerCase()}',
        word: entry.word,
        ipa: entry.ipa,
        partOfSpeech: entry.partOfSpeech,
        meanings: entry.meanings,
        example: entry.example,
        exampleTranslation: entry.exampleTranslation,
        source: entry.source,
      );

  Future<void> _recordFocusActivity(ActivityEventData activity) async {
    final factory = widget.coreFactory;
    if (factory == null) return;
    await Future(() {
      final core = factory();
      try {
        core.recordActivity(activity);
      } finally {
        core.dispose();
      }
    });
  }

  Future<HomeUserProfileData?> _loadHomeUserProfile() async {
    return widget.homeUserProfileStore?.read();
  }

  Future<void> _saveHomeUserProfile(HomeUserProfileData profile) async {
    await widget.homeUserProfileStore?.write(profile);
  }

  String _homeDateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime? _parseHomeDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null ||
        _homeDateKey(parsed) != value ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  Future<void> _ensureTodayDailyPlan() async {
    final store = widget.homeDailyPlanStore;
    if (store == null) return;
    final pending = _dailyPlanMigration;
    if (pending != null) {
      await pending;
      return;
    }
    final migration = () async {
      final today = DateTime(
        widget.clock().year,
        widget.clock().month,
        widget.clock().day,
      );
      final date = _homeDateKey(today);
      if (await store.read(date) != null) return;
      final legacy = await _loadHomePlan();
      await store.migrateLegacyIfMissing(
        legacy,
        localDate: date,
        updatedAt: widget.clock().toIso8601String(),
      );
    }();
    _dailyPlanMigration = migration;
    await migration;
  }

  Future<HomeDailyPlanData?> _loadHomeDailyPlan(String date) async {
    final store = widget.homeDailyPlanStore;
    final parsed = _parseHomeDate(date);
    if (store == null || parsed == null) return null;
    final today = DateTime(
      widget.clock().year,
      widget.clock().month,
      widget.clock().day,
    );
    if (DateUtils.isSameDay(parsed, today)) await _ensureTodayDailyPlan();
    return store.read(date);
  }

  Future<List<HomeDailyPlanData>> _loadHomeDailyPlans(
    DateTime start,
    DateTime end,
  ) async {
    final store = widget.homeDailyPlanStore;
    if (store == null) return const [];
    final today = DateTime(
      widget.clock().year,
      widget.clock().month,
      widget.clock().day,
    );
    if (!today.isBefore(DateTime(start.year, start.month, start.day)) &&
        !today.isAfter(DateTime(end.year, end.month, end.day))) {
      await _ensureTodayDailyPlan();
    }
    return store.readRange(start, end);
  }

  Future<List<HomeDailyPlanData>> _loadHomeDailyMonth(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final last = DateTime(month.year, month.month + 1, 0);
    return widget.homeDailyPlanStore?.readRange(first, last) ??
        Future.value(const []);
  }

  Future<void> _saveHomeDailyPlan(HomeDailyPlanData plan) async {
    await widget.homeDailyPlanStore?.write(plan);
  }

  Future<HomeSnapshotData> _loadHomeSnapshot() {
    final factory = widget.coreFactory;
    if (factory == null) return Future.value(_previewHomeSnapshot);
    return Future<HomeSnapshotData>(() {
      final core = factory();
      try {
        final now = DateTime.now();
        final localDate =
            '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
        return core.homeSnapshot(localDate, recentLimit: 3);
      } finally {
        core.dispose();
      }
    });
  }

  Future<HomeCoreSnapshotData?> _loadHomeWorkbenchSnapshot({
    int recentLimit = 6,
  }) {
    final factory = widget.coreFactory;
    if (factory == null) return Future.value(null);
    return Future<HomeCoreSnapshotData?>(() {
      final core = factory();
      try {
        if (core is! HomeWorkbenchCore) return null;
        final now = DateTime.now();
        final localDate =
            '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';
        return (core as HomeWorkbenchCore).homeWorkbenchSnapshot(
          localDate,
          recentLimit: recentLimit,
        );
      } finally {
        core.dispose();
      }
    });
  }

  Future<HomePlanData> _loadHomePlan() async {
    final store = widget.homePlanStore;
    if (store == null) return _inMemoryHomePlan;
    return await store.read() ?? const HomePlanData();
  }

  Future<void> _saveHomePlan(HomePlanData plan) async {
    _inMemoryHomePlan = plan;
    await widget.homePlanStore?.write(plan);
  }
}

class _CustomThemeBackdrop extends StatelessWidget {
  const _CustomThemeBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final custom = Theme.of(context).extension<YixueShellTheme>()?.custom;
    final path = custom?.usableBackgroundImagePath;
    if (path == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        // Keep the image atmospheric so text, controls and reading content
        // remain readable even when a user chooses a high-contrast photo.
        opacity: 0.075,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _WorkspaceAppearance extends StatelessWidget {
  const _WorkspaceAppearance({
    required this.workspace,
    required this.controller,
    required this.child,
  });

  final YixueWorkspace workspace;
  final AppearanceController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final override = controller.value.workspaceStyles[workspace];
        if (override == null) return child;
        final theme = switch (override) {
          YixueVisualStyle.vitality => AppTheme.vitality(),
          YixueVisualStyle.focus =>
            controller.value.officialTheme == YixueOfficialTheme.dark
                ? AppTheme.dark()
                : AppTheme.light(),
        };
        return Theme(data: theme, child: child);
      },
    );
  }
}

class _NavigationItem {
  const _NavigationItem(
    this.pageIndex,
    this.label,
    this.icon, {
    this.integrated = true,
  });
  final int pageIndex;
  final String label;
  final IconData icon;
  final bool integrated;
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.selectedIndex,
    required this.onSelected,
    required this.onModeAction,
    this.temporary = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onModeAction;
  final bool temporary;

  @override
  Widget build(BuildContext context) {
    final shell = YixueShellPalette.of(context);
    return AnimatedContainer(
      key: const ValueKey('desktop-sidebar'),
      width: 244,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [shell.sidebarTop, shell.sidebarBottom],
        ),
      ),
      child: Stack(
        children: [
          if (shell.isVitality)
            const Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: ValueKey('sidebar-vitality-glow'),
                  painter: _VitalityHorizonPainter(),
                ),
              ),
            ),
          AnimatedPositioned(
            key: const ValueKey('sidebar-moving-glass'),
            top: 90 + (selectedIndex * 58),
            left: 14,
            right: 14,
            height: 54,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: IgnorePointer(
              child: _SidebarSelectionGlass(
                selectedIndex: selectedIndex,
                isVitality: shell.isVitality,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 20, 8, 12),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 14, 18),
                  child: Row(
                    children: [
                      const _BrandMark(),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '译学',
                            style: TextStyle(
                              color: shell.sidebarForeground,
                              fontSize: 23,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '让世界，可以理解',
                            style: TextStyle(
                              color: shell.sidebarMuted,
                              fontSize: 9.5,
                              letterSpacing: 0.55,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                for (final item in _HomeShellState._items)
                  _SidebarButton(
                    item: item,
                    selected: item.pageIndex == selectedIndex,
                    onTap: () => onSelected(item.pageIndex),
                  ),
                const Spacer(),
                IconButton(
                  key: ValueKey(
                    temporary
                        ? 'sidebar-pin-button'
                        : 'sidebar-collapse-button',
                  ),
                  tooltip: temporary ? '固定侧栏' : '收起侧栏',
                  onPressed: onModeAction,
                  color: shell.sidebarForeground,
                  icon: Icon(
                    temporary
                        ? Icons.push_pin_outlined
                        : Icons.keyboard_double_arrow_left_rounded,
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

class _SidebarSelectionGlass extends StatefulWidget {
  const _SidebarSelectionGlass({
    required this.selectedIndex,
    required this.isVitality,
  });

  final int selectedIndex;
  final bool isVitality;

  @override
  State<_SidebarSelectionGlass> createState() => _SidebarSelectionGlassState();
}

class _SidebarSelectionGlassState extends State<_SidebarSelectionGlass>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 210),
      value: 1,
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.975, end: 1.015), weight: 58),
      TweenSequenceItem(tween: Tween(begin: 1.015, end: 1), weight: 42),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(covariant _SidebarSelectionGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shell = YixueShellPalette.of(context);
    return ScaleTransition(
      scale: _scale,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: widget.isVitality
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF126DDC),
                    Color(0xFF0D93C9),
                    Color(0xFF18BCA6),
                    Color(0xFF3DD57B),
                  ],
                  stops: [0, 0.56, 0.82, 1],
                )
              : LinearGradient(
                  colors: [shell.selectedStart, shell.selectedEnd],
                ),
          borderRadius: BorderRadius.circular(widget.isVitality ? 12 : 7),
          border: widget.isVitality
              ? Border.all(color: Colors.white.withValues(alpha: 0.58))
              : null,
          boxShadow: widget.isVitality
              ? const [
                  BoxShadow(
                    color: Color(0x5C16BBDD),
                    blurRadius: 20,
                    offset: Offset(0, 6),
                  ),
                  BoxShadow(
                    color: Color(0x423DE98C),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ]
              : const [],
        ),
        child: widget.isVitality
            ? const CustomPaint(painter: _HorizonGlassPainter())
            : null,
      ),
    );
  }
}

class _HorizonGlassPainter extends CustomPainter {
  const _HorizonGlassPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * 0.65;
    final silverLine = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x00FFFFFF), Color(0xEFFFFFFF), Color(0x00FFFFFF)],
        stops: [0, 0.58, 1],
      ).createShader(Rect.fromLTWH(0, horizonY - 1, size.width, 3))
      ..strokeWidth = 1.15;
    canvas.drawLine(
      Offset(7, horizonY),
      Offset(size.width - 7, horizonY),
      silverLine,
    );

    final gloss = Paint()
      ..shader =
          const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x52FFFFFF), Color(0x00FFFFFF)],
          ).createShader(
            Rect.fromLTWH(8, 3, size.width * 0.72, size.height * 0.48),
          );
    final highlight = Path()
      ..moveTo(12, 6)
      ..quadraticBezierTo(size.width * 0.58, -2, size.width - 18, 8)
      ..quadraticBezierTo(size.width * 0.55, 8, 12, 15)
      ..close();
    canvas.drawPath(highlight, gloss);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VitalityHorizonPainter extends CustomPainter {
  const _VitalityHorizonPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final risingField = Path()
      ..moveTo(size.width, size.height * 0.06)
      ..cubicTo(
        size.width * 0.92,
        size.height * 0.32,
        size.width * 0.78,
        size.height * 0.64,
        size.width * 0.18,
        size.height,
      )
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      risingField,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0x2637C9FF), Color(0x0637C9FF)],
        ).createShader(Offset.zero & size),
    );

    final risingEdge = Path()
      ..moveTo(size.width - 2, size.height * 0.05)
      ..cubicTo(
        size.width * 0.91,
        size.height * 0.34,
        size.width * 0.73,
        size.height * 0.69,
        size.width * 0.11,
        size.height,
      );
    canvas.drawPath(
      risingEdge,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x2564D9FF), Color(0xA43DE6A0)],
        ).createShader(Offset.zero & size)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );

    final glow = Paint()
      ..shader = const RadialGradient(
        center: Alignment(0.7, 0.9),
        radius: 0.85,
        colors: [Color(0x6635E99A), Color(0x0000A87B)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, glow);

    final horizon = Paint()
      ..color = const Color(0x7054E5B0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    canvas.drawArc(
      Rect.fromLTWH(-100, size.height - 225, size.width + 210, 260),
      0.06,
      2.85,
      false,
      horizon,
    );
    canvas.drawArc(
      Rect.fromLTWH(-170, size.height - 170, size.width + 350, 210),
      0.05,
      2.92,
      false,
      Paint()
        ..color = const Color(0x543CCBFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SidebarButton extends StatefulWidget {
  const _SidebarButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavigationItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final shell = YixueShellPalette.of(context);
    final itemColor = widget.item.integrated
        ? shell.sidebarForeground
        : shell.sidebarMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: _hovered ? 1.012 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              gradient: !widget.selected && _hovered
                  ? LinearGradient(colors: [shell.hoverStart, shell.hoverEnd])
                  : null,
              borderRadius: BorderRadius.circular(7),
              boxShadow: _hovered && !widget.selected && shell.isVitality
                  ? [
                      BoxShadow(
                        color: shell.sidebarGlow.withValues(alpha: 0.24),
                        blurRadius: 18,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : const [],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              child: Tooltip(
                message: widget.item.integrated
                    ? widget.item.label
                    : '阅读器暂未接入，点击查看状态',
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(7),
                  child: SizedBox(
                    height: 54,
                    child: Row(
                      children: [
                        const SizedBox(width: 20),
                        Icon(widget.item.icon, color: itemColor, size: 23),
                        const SizedBox(width: 16),
                        Text(
                          widget.item.label,
                          style: TextStyle(
                            color: itemColor,
                            fontSize: 16,
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        if (!widget.item.integrated) ...[
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              '未接入',
                              style: TextStyle(
                                color: itemColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactNavigation extends StatelessWidget {
  const _CompactNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  static const _pageIndexes = [0, 1, 2, 3, 4, 5];
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final compactIndex = _pageIndexes.indexOf(selectedIndex);
    return NavigationBar(
      selectedIndex: compactIndex < 0 ? 0 : compactIndex,
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      onDestinationSelected: (index) => onSelected(_pageIndexes[index]),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '首页',
        ),
        NavigationDestination(
          icon: Icon(Icons.g_translate_rounded),
          label: '快速翻译',
        ),
        NavigationDestination(
          icon: Icon(Icons.center_focus_weak_rounded),
          label: '截屏',
        ),
        NavigationDestination(
          icon: Icon(Icons.chrome_reader_mode_outlined),
          label: '阅读器',
        ),
        NavigationDestination(
          icon: Icon(Icons.menu_book_outlined),
          label: '学习',
        ),
        NavigationDestination(icon: Icon(Icons.live_tv_outlined), label: '同传'),
      ],
    );
  }
}

class _QuickTranslationPage extends StatefulWidget {
  const _QuickTranslationPage({
    required this.editorKey,
    this.clipboardReader,
    required this.onOpenModels,
    required this.onOpenSettings,
    required this.onTranslateWithOptions,
    required this.modelStatus,
    required this.onTranslate,
    required this.onCancel,
    required this.loadHistory,
    required this.loadHistoryPage,
    required this.exportHistory,
    this.deleteHistory,
    this.screenshotDeleteResult,
    required this.loadAnnotations,
    required this.saveAnnotation,
    required this.lookupDictionary,
    required this.loadFavoriteWords,
    required this.loadFavoriteWordPage,
    required this.setFavoriteWord,
    required this.loadWordAnnotation,
    required this.saveWordAnnotation,
    this.onSetLearning,
    required this.onImportDictionary,
    required this.onOpenDictionaryGuide,
    required this.translationPreferencesController,
  });

  final GlobalKey<_TranslationEditorState> editorKey;
  final ClipboardReader? clipboardReader;
  final VoidCallback onOpenModels;
  final VoidCallback onOpenSettings;
  final QuickTranslationRunnerWithOptions onTranslateWithOptions;
  final ValueListenable<String> modelStatus;
  final QuickTranslationRunner onTranslate;
  final QuickTranslationCanceller onCancel;
  final TranslationHistoryLoader loadHistory;
  final TranslationHistoryPageLoader loadHistoryPage;
  final TranslationHistoryExporter exportHistory;
  final TranslationHistoryEntryDeleter? deleteHistory;
  final ScreenshotTranslationArchiveDeleteResult? Function()?
  screenshotDeleteResult;
  final TranslationAnnotationLoader loadAnnotations;
  final TranslationAnnotationSaver saveAnnotation;
  final DictionaryLookupLoader lookupDictionary;
  final FavoriteWordsLoader loadFavoriteWords;
  final FavoriteWordPageLoader loadFavoriteWordPage;
  final FavoriteWordSetter setFavoriteWord;
  final WordAnnotationLoader loadWordAnnotation;
  final WordAnnotationSaver saveWordAnnotation;
  final LearningWordSetter? onSetLearning;
  final VoidCallback onImportDictionary;
  final VoidCallback onOpenDictionaryGuide;
  final TranslationPreferencesController? translationPreferencesController;

  @override
  State<_QuickTranslationPage> createState() => _QuickTranslationPageState();
}

class _QuickTranslationPageState extends State<_QuickTranslationPage> {
  late Future<List<TranslationHistoryEntryData>> _history;
  var _direction = TranslationDirection.englishToChinese;
  var _networkSearchEnabled = false;
  String? _pendingLookupTerm;
  final _learningPanelKey = GlobalKey<_LearningPanelState>();

  @override
  void initState() {
    super.initState();
    _history = widget.loadHistory();
    widget.translationPreferencesController?.addListener(_preferencesChanged);
    _applyPreferredDirection();
  }

  void _preferencesChanged() {
    if (!mounted) return;
    _applyPreferredDirection();
  }

  void _applyPreferredDirection() {
    final preference = widget.translationPreferencesController?.value.direction;
    final next = switch (preference) {
      PreferredDirection.chineseToEnglish =>
        TranslationDirection.chineseToEnglish,
      PreferredDirection.englishToChinese =>
        TranslationDirection.englishToChinese,
      _ => null,
    };
    if (next != null && next != _direction && mounted) {
      setState(() => _direction = next);
    }
  }

  @override
  void dispose() {
    widget.translationPreferencesController?.removeListener(
      _preferencesChanged,
    );
    super.dispose();
  }

  void _reloadHistory() {
    setState(() => _history = widget.loadHistory());
  }

  void _restoreHistory(TranslationHistoryEntryData entry) {
    final direction = entry.sourceLanguage == 'chinese'
        ? TranslationDirection.chineseToEnglish
        : TranslationDirection.englishToChinese;
    if (_direction != direction) setState(() => _direction = direction);
    widget.editorKey.currentState?.setTranslation(
      entry.sourceText,
      entry.translatedText,
    );
  }

  void _switchDirection() {
    widget.editorKey.currentState?.swapContents();
    setState(() => _direction = _direction.opposite);
  }

  void _toggleNetworkSearch() {
    setState(() => _networkSearchEnabled = !_networkSearchEnabled);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 20),
      child: Column(
        children: [
          _PageHeader(
            onOpenModels: widget.onOpenModels,
            onOpenSettings: widget.onOpenSettings,
            onToggleNetworkSearch: _toggleNetworkSearch,
            networkSearchEnabled: _networkSearchEnabled,
            onOpenHistory: _openHistory,
            onOpenLearningPanel: _openLearningPanel,
            modelStatus: widget.modelStatus,
            direction: _direction,
            onSwitchDirection: _switchDirection,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showLearningPanel = constraints.maxWidth >= 1050;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _TranslationEditor(
                        key: widget.editorKey,
                        clipboardReader: widget.clipboardReader,
                        onTranslate: widget.onTranslate,
                        onTranslateWithOptions: widget.onTranslateWithOptions,
                        requestOptions: TranslationRequestOptions(
                          webSearchEnabled: _networkSearchEnabled,
                        ),
                        onCancel: widget.onCancel,
                        onTranslationCompleted: _reloadHistory,
                        direction: _direction,
                        onDirectionDetected: (direction) {
                          if (_direction != direction) {
                            setState(() => _direction = direction);
                          }
                        },
                        onSourceChanged: _handleSourceChanged,
                        onWordSelected: _handleSelectedWord,
                      ),
                    ),
                    if (showLearningPanel) ...[
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 320,
                        child: _LearningPanel(
                          key: _learningPanelKey,
                          history: _history,
                          onHistorySelected: _restoreHistory,
                          onOpenHistory: _openHistory,
                          onOpenFavorites: _openFavoriteWords,
                          lookupDictionary: widget.lookupDictionary,
                          onTranslateLookup: _translateLookupTerm,
                          loadFavoriteWords: widget.loadFavoriteWords,
                          setFavoriteWord: widget.setFavoriteWord,
                          loadWordAnnotation: widget.loadWordAnnotation,
                          saveWordAnnotation: widget.saveWordAnnotation,
                          onSetLearning: widget.onSetLearning,
                          onImportDictionary: widget.onImportDictionary,
                          onOpenDictionaryGuide: widget.onOpenDictionaryGuide,
                          onSpeak: _speakDictionaryText,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _speakDictionaryText(String value) async {
    final editor = widget.editorKey.currentState;
    if (editor != null) await editor.speakText(value);
  }

  Future<String> _translateLookupTerm(String value) {
    final term = dictionaryTermAtInput(value);
    if (term == null) {
      throw const FormatException('请输入一个中英文单词。');
    }
    final isEnglish = englishWordAtSelection(term, 0, term.length) != null;
    return widget.onTranslateWithOptions(
      term,
      isEnglish
          ? TranslationDirection.englishToChinese
          : TranslationDirection.chineseToEnglish,
      const TranslationRequestOptions(),
    );
  }

  void _handleSourceChanged(String value) {
    final panelState = _learningPanelKey.currentState;
    if (panelState != null) {
      _pendingLookupTerm = null;
      panelState.scheduleLookup(value);
      return;
    }
    _pendingLookupTerm = dictionaryTermAtInput(value);
  }

  void _handleSelectedWord(String word) {
    final term = dictionaryTermAtInput(word);
    final panelState = _learningPanelKey.currentState;
    if (panelState != null) {
      _pendingLookupTerm = null;
      panelState.lookupWord(term ?? '');
      return;
    }
    _pendingLookupTerm = term;
    if (term == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('已选中“$term”，可打开查词。'),
        action: SnackBarAction(
          label: '打开查词',
          onPressed: () {
            _openLearningPanel();
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _openLearningPanel() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32 < 520 ? size.width - 32 : 520).toDouble();
    final height = (size.height - 32 < 720 ? size.height - 32 : 720).toDouble();
    final initialLookupTerm = _pendingLookupTerm;
    _pendingLookupTerm = null;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '翻译学习辅助',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭学习辅助',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _LearningPanel(
                  initialLookupTerm: initialLookupTerm,
                  history: _history,
                  onHistorySelected: (entry) {
                    Navigator.of(dialogContext).pop();
                    _restoreHistory(entry);
                  },
                  onOpenHistory: () {
                    Navigator.of(dialogContext).pop();
                    _openHistory();
                  },
                  onOpenFavorites: () {
                    Navigator.of(dialogContext).pop();
                    _openFavoriteWords();
                  },
                  lookupDictionary: widget.lookupDictionary,
                  onTranslateLookup: _translateLookupTerm,
                  loadFavoriteWords: widget.loadFavoriteWords,
                  setFavoriteWord: widget.setFavoriteWord,
                  loadWordAnnotation: widget.loadWordAnnotation,
                  saveWordAnnotation: widget.saveWordAnnotation,
                  onSetLearning: widget.onSetLearning,
                  onImportDictionary: widget.onImportDictionary,
                  onOpenDictionaryGuide: widget.onOpenDictionaryGuide,
                  onSpeak: _speakDictionaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFavoriteWords() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(420.0, 1120.0).toDouble();
    final height = (size.height - 48).clamp(560.0, 760.0).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: FavoriteWordsWorkspace(
            loadPage: widget.loadFavoriteWordPage,
            setFavoriteWord: widget.setFavoriteWord,
            saveWordAnnotation: widget.saveWordAnnotation,
            setWordLearning: widget.onSetLearning,
            lookupRichEntry: widget.lookupDictionary,
            onSpeak: _speakDictionaryText,
            onContinueTranslation: (word) {
              Navigator.of(dialogContext).pop();
              widget.editorKey.currentState?.setSourceText(word);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openHistory() async {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48 < 1120 ? size.width - 48 : 1120).toDouble();
    final height = (size.height - 48 < 760 ? size.height - 48 : 760).toDouble();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: _TranslationHistoryWorkspace(
            loadHistory: widget.loadHistory,
            loadHistoryPage: widget.loadHistoryPage,
            exportHistory: widget.exportHistory,
            deleteHistory: widget.deleteHistory,
            screenshotDeleteResult: widget.screenshotDeleteResult,
            loadAnnotations: widget.loadAnnotations,
            saveAnnotation: widget.saveAnnotation,
            onContinue: (entry) {
              Navigator.of(dialogContext).pop();
              _restoreHistory(entry);
            },
            onSpeak: _speakDictionaryText,
          ),
        ),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.onOpenModels,
    required this.onOpenSettings,
    required this.onOpenHistory,
    required this.onOpenLearningPanel,
    required this.onToggleNetworkSearch,
    required this.networkSearchEnabled,
    required this.modelStatus,
    required this.direction,
    required this.onSwitchDirection,
  });

  final VoidCallback onOpenModels;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenLearningPanel;
  final VoidCallback onToggleNetworkSearch;
  final bool networkSearchEnabled;
  final ValueListenable<String> modelStatus;
  final TranslationDirection direction;
  final VoidCallback onSwitchDirection;

  @override
  Widget build(BuildContext context) {
    final shell = YixueShellPalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The shell sidebar already consumes a substantial part of the
        // desktop window. Switch to the compact header before the remaining
        // workspace gets too narrow for the model badge and action buttons.
        final compact = constraints.maxWidth < 1000;
        final ultraCompact = constraints.maxWidth < 520;
        return AnimatedContainer(
          key: const ValueKey('quick-translation-header'),
          height: 64,
          duration: const Duration(milliseconds: 220),
          padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [shell.topStart, shell.topEnd]),
            border: Border.all(color: shell.topBorder),
            borderRadius: BorderRadius.circular(12),
            boxShadow: shell.isVitality
                ? const [
                    BoxShadow(
                      color: Color(0x2615B9B0),
                      blurRadius: 20,
                      offset: Offset(0, 5),
                    ),
                  ]
                : const [],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '快速翻译',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 23 : 27,
                    color: shell.topForeground,
                  ),
                ),
              ),
              if (!compact) ...[
                _ServiceStatusChip(
                  status: modelStatus,
                  onPressed: onOpenModels,
                ),
                const SizedBox(width: 10),
              ],
              if (compact && !ultraCompact) ...[
                _ServiceStatusChip(
                  status: modelStatus,
                  onPressed: onOpenModels,
                  maxTextWidth: 180,
                ),
                const SizedBox(width: 6),
              ],
              if (!compact)
                OutlinedButton.icon(
                  onPressed: onSwitchDirection,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: Text(direction.actionLabel),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: shell.topForeground,
                    side: BorderSide(
                      color: shell.topForeground.withValues(alpha: 0.34),
                    ),
                  ),
                ),
              if (!compact) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onOpenHistory,
                  icon: const Icon(Icons.history_rounded),
                  label: const Text('历史'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: shell.topForeground,
                    side: BorderSide(
                      color: shell.topForeground.withValues(alpha: 0.34),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('network-search-toggle'),
                  onPressed: onToggleNetworkSearch,
                  icon: Icon(
                    networkSearchEnabled
                        ? Icons.public_rounded
                        : Icons.travel_explore_rounded,
                  ),
                  label: Text(networkSearchEnabled ? '联网检索已开启' : '联网检索'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: shell.topForeground,
                    side: BorderSide(
                      color: shell.topForeground.withValues(alpha: 0.34),
                    ),
                    backgroundColor: networkSearchEnabled
                        ? shell.topForeground.withValues(alpha: 0.12)
                        : null,
                  ),
                ),
              ],
              if (compact && !ultraCompact)
                PopupMenuButton<String>(
                  key: const ValueKey('quick-translation-more-actions'),
                  tooltip: '更多快速翻译操作',
                  onSelected: (value) {
                    switch (value) {
                      case 'direction':
                        onSwitchDirection();
                      case 'history':
                        onOpenHistory();
                      case 'learning':
                        onOpenLearningPanel();
                      case 'network-search':
                        onToggleNetworkSearch();
                    }
                  },
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: shell.topForeground,
                  ),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'direction',
                      child: Text('切换方向：${direction.actionLabel}'),
                    ),
                    const PopupMenuItem(value: 'history', child: Text('翻译历史')),
                    const PopupMenuItem(value: 'learning', child: Text('学习辅助')),
                    const PopupMenuItem(
                      value: 'network-search',
                      child: Text('联网检索辅助翻译'),
                    ),
                  ],
                ),
              if (ultraCompact)
                IconButton(
                  key: const ValueKey('network-search-toggle'),
                  tooltip: networkSearchEnabled ? '关闭联网检索辅助翻译' : '开启联网检索辅助翻译',
                  onPressed: onToggleNetworkSearch,
                  icon: Icon(
                    networkSearchEnabled
                        ? Icons.public_rounded
                        : Icons.travel_explore_rounded,
                    color: shell.topForeground,
                  ),
                ),
              if (ultraCompact)
                IconButton(
                  key: const ValueKey('open-learning-panel'),
                  tooltip: '打开学习辅助',
                  onPressed: onOpenLearningPanel,
                  icon: Icon(
                    Icons.menu_book_outlined,
                    color: shell.topForeground,
                  ),
                ),
              if (ultraCompact)
                IconButton(
                  tooltip: '切换翻译方向：${direction.actionLabel}',
                  onPressed: onSwitchDirection,
                  icon: Icon(
                    Icons.swap_horiz_rounded,
                    color: shell.topForeground,
                  ),
                ),
              if (ultraCompact)
                IconButton(
                  tooltip: '翻译历史',
                  onPressed: onOpenHistory,
                  icon: Icon(Icons.history_rounded, color: shell.topForeground),
                ),
              IconButton(
                tooltip: '设置',
                onPressed: onOpenSettings,
                icon: Icon(Icons.settings_outlined, color: shell.topForeground),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TranslationEditor extends StatefulWidget {
  const _TranslationEditor({
    required this.onTranslate,
    required this.onTranslateWithOptions,
    required this.requestOptions,
    required this.onCancel,
    required this.onTranslationCompleted,
    required this.direction,
    required this.onDirectionDetected,
    required this.onSourceChanged,
    required this.onWordSelected,
    super.key,
    this.clipboardReader,
  });

  final ClipboardReader? clipboardReader;
  final QuickTranslationRunner onTranslate;
  final QuickTranslationRunnerWithOptions onTranslateWithOptions;
  final TranslationRequestOptions requestOptions;
  final QuickTranslationCanceller onCancel;
  final VoidCallback onTranslationCompleted;
  final TranslationDirection direction;
  final ValueChanged<TranslationDirection> onDirectionDetected;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<String> onWordSelected;

  @override
  State<_TranslationEditor> createState() => _TranslationEditorState();
}

class _TranslationEditorState extends State<_TranslationEditor> {
  final _sourceController = TextEditingController();
  final _translationController = TextEditingController();
  var _isTranslating = false;
  var _translationAttempt = 0;
  var _syncingContent = false;
  var _lastSourceText = '';
  var _lastSourceSelection = const TextSelection.collapsed(offset: 0);
  String? _errorMessage;

  void setSourceText(String text) {
    final value = text.length > 5000 ? text.substring(0, 5000) : text;
    _syncingContent = true;
    try {
      _sourceController.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    } finally {
      _syncingContent = false;
    }
  }

  void setTranslation(String sourceText, String translatedText) {
    setSourceText(sourceText);
    _translationController.text = translatedText;
    setState(() => _errorMessage = null);
  }

  void swapContents() {
    final source = _sourceController.text;
    final translated = _translationController.text;
    _syncingContent = true;
    try {
      _sourceController.text = translated;
      _translationController.text = source;
    } finally {
      _syncingContent = false;
    }
    setState(() => _errorMessage = null);
  }

  @override
  void initState() {
    super.initState();
    _sourceController.addListener(_sourceChanged);
  }

  @override
  void dispose() {
    _sourceController
      ..removeListener(_sourceChanged)
      ..dispose();
    _translationController.dispose();
    super.dispose();
  }

  void _sourceChanged() {
    final sourceText = _sourceController.text;
    final sourceSelection = _sourceController.selection;
    final textChanged = sourceText != _lastSourceText;
    final selectionChanged = sourceSelection != _lastSourceSelection;
    _lastSourceText = sourceText;
    _lastSourceSelection = sourceSelection;
    if (textChanged && !_syncingContent) _translationController.clear();
    if (textChanged) widget.onSourceChanged(sourceText);
    if (!_syncingContent && selectionChanged) {
      final word = dictionaryTermAtSelection(
        sourceText,
        sourceSelection.start,
        sourceSelection.end,
      );
      widget.onWordSelected(word ?? '');
    }
    final detected = TranslationDirection.detect(
      sourceText,
      fallback: widget.direction,
    );
    if (detected != widget.direction) {
      widget.onDirectionDetected(detected);
    }
    setState(() {});
  }

  Future<void> _paste() async {
    final text = widget.clipboardReader == null
        ? (await Clipboard.getData(Clipboard.kTextPlain))?.text
        : await widget.clipboardReader!.call();
    if (!mounted || text == null || text.isEmpty) return;
    final value = text.length > 5000 ? text.substring(0, 5000) : text;
    _sourceController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyL &&
        HardwareKeyboard.instance.isControlPressed) {
      _clear();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_sourceController.text.trim().isNotEmpty && !_isTranslating) {
        unawaited(_translate());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _clear() {
    _sourceController.clear();
    _translationController.clear();
    setState(() => _errorMessage = null);
  }

  Future<void> _translate() async {
    if (_isTranslating || _sourceController.text.trim().isEmpty) return;
    final direction = TranslationDirection.detect(
      _sourceController.text,
      fallback: widget.direction,
    );
    if (direction != widget.direction) {
      widget.onDirectionDetected(direction);
    }
    setState(() {
      _isTranslating = true;
      _errorMessage = null;
      // Never leave an older result visible while a new request is pending.
      // A failed retry must not look like a successful translation.
      _translationController.clear();
    });
    final attempt = ++_translationAttempt;
    try {
      final translated = await widget.onTranslateWithOptions(
        _sourceController.text,
        direction,
        widget.requestOptions,
      );
      if (!mounted || attempt != _translationAttempt) return;
      _translationController.text = translated;
      widget.onTranslationCompleted();
    } on QuickTranslationException catch (error) {
      if (!mounted || attempt != _translationAttempt) return;
      if (error.code == 'cancelled') return;
      _errorMessage = _translationErrorMessage(error.code);
    } catch (_) {
      if (!mounted || attempt != _translationAttempt) return;
      _errorMessage = '翻译失败，请检查模型配置和网络后重试';
    } finally {
      if (mounted && attempt == _translationAttempt) {
        setState(() => _isTranslating = false);
      }
    }
  }

  Future<void> _cancelTranslation() async {
    if (!_isTranslating) return;
    _translationAttempt += 1;
    await widget.onCancel();
    if (!mounted) return;
    setState(() {
      _isTranslating = false;
      _errorMessage = null;
    });
  }

  String _translationErrorMessage(String code) => switch (code) {
    'ambiguous_translation_provider' => '有多个启用的翻译配置，请到「模型与服务」选择唯一翻译模型后重试',
    'no_remote_provider' => '本地翻译模型当前不可用；请在「模型与服务」中检查或更换模型',
    'web_search_unavailable' => '联网检索尚未配置适配器，本次没有发送内容；请先到「模型与服务」配置检索能力',
    'web_search_requires_remote_provider' =>
      '当前联网辅助需要可接收检索参考的模型接口，请在「模型与服务」选择兼容接口',
    'local_core_unavailable' => '当前版本缺少本地翻译组件，请重新安装完整版本',
    'local_core_error' => '本地模型暂时无法使用，请检查模型文件或重新安装',
    'service_disposed' => '翻译服务已关闭，请重新打开译学',
    'missing_credential' => '当前模型缺少 API 密钥，请到「模型与服务」补充',
    'request_timeout' => '请求超时，请稍后重试',
    'network_error' => '网络连接失败，请检查网络后重试',
    'remote_service_error' => '模型服务暂时不可用，请检查配置或稍后重试',
    'invalid_response' => '模型返回了无法识别的结果，请更换模型后重试',
    'format_integrity_failed' => '模型改坏了原文中的格式内容，本次结果未保存，请重试或更换模型',
    'suspicious_model_output' => '模型输出疑似重复或退化，本次结果未保存，请更换翻译模型',
    'invalid_input' => '请输入不超过 5000 字的内容',
    _ => '翻译失败，请检查模型配置和网络后重试',
  };

  Future<void> _copyText(String value) async {
    if (value.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制到剪贴板'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  Future<void> _speakText(String value) async {
    final text = value.trim();
    if (text.isEmpty || !Platform.isWindows) return;
    final encoded = base64UrlEncode(utf8.encode(text));
    await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
$bytes = [Convert]::FromBase64String($env:YIXUE_SPEECH_TEXT)
$text = [Text.Encoding]::UTF8.GetString($bytes)
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$synth.Speak($text)
$synth.Dispose()
''',
      ],
      environment: {'YIXUE_SPEECH_TEXT': encoded},
    );
  }

  Future<void> speakText(String value) => _speakText(value);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.outline),
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0C172033),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 600) {
                    return Column(
                      children: [
                        Expanded(
                          child: _LanguagePane(
                            title: widget.direction.sourceLabel,
                            editable: true,
                            hint: '输入单词、句子或一段文字…',
                            controller: _sourceController,
                            characterCount: _sourceController.text.length,
                            onCopy: () => _copyText(_sourceController.text),
                            onSpeak: () => _speakText(_sourceController.text),
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _LanguagePane(
                            title: widget.direction.targetLabel,
                            editable: false,
                            hint: _isTranslating ? '正在翻译…' : '译文将在这里显示',
                            controller: _translationController,
                            busy: _isTranslating,
                            statusMessage: _errorMessage,
                            onSpeak: () =>
                                _speakText(_translationController.text),
                            onCopy: () =>
                                _copyText(_translationController.text),
                          ),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: _LanguagePane(
                          title: widget.direction.sourceLabel,
                          editable: true,
                          hint: '输入单词、句子或一段文字…',
                          controller: _sourceController,
                          characterCount: _sourceController.text.length,
                          onCopy: () => _copyText(_sourceController.text),
                          onSpeak: () => _speakText(_sourceController.text),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _LanguagePane(
                          title: widget.direction.targetLabel,
                          editable: false,
                          hint: _isTranslating ? '正在翻译…' : '译文将在这里显示',
                          controller: _translationController,
                          busy: _isTranslating,
                          statusMessage: _errorMessage,
                          onSpeak: () =>
                              _speakText(_translationController.text),
                          onCopy: () => _copyText(_translationController.text),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.outline),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _HoverActionButton(
                    primary: true,
                    onPressed: _isTranslating
                        ? _cancelTranslation
                        : _sourceController.text.trim().isEmpty
                        ? null
                        : _translate,
                    icon: _isTranslating
                        ? Icons.stop_circle_outlined
                        : Icons.translate_rounded,
                    label: _isTranslating ? '取消翻译' : '翻 译   Enter',
                  ),
                  const SizedBox(width: 12),
                  _HoverActionButton(onPressed: _clear, label: '清 空   Ctrl+L'),
                  const SizedBox(width: 12),
                  _HoverActionButton(onPressed: _paste, label: '粘 贴   Ctrl+V'),
                  const SizedBox(width: 20),
                  const Icon(Icons.check_box_rounded, color: _activeBlue),
                  const SizedBox(width: 6),
                  const Text('自动换行'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HoverActionButton extends StatefulWidget {
  const _HoverActionButton({
    required this.onPressed,
    required this.label,
    this.icon,
    this.primary = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool primary;

  @override
  State<_HoverActionButton> createState() => _HoverActionButtonState();
}

class _HoverActionButtonState extends State<_HoverActionButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: enabled ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedScale(
        scale: _hovered ? 1.025 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            gradient: widget.primary && enabled
                ? LinearGradient(
                    colors: _hovered
                        ? const [Color(0xFF1677FF), Color(0xFF11B8C8)]
                        : const [Color(0xFF155FD1), Color(0xFF176FD8)],
                  )
                : null,
            color: widget.primary
                ? (enabled ? null : const Color(0xFFD7DEE8))
                : (_hovered ? colors.surfaceContainer : colors.surface),
            border: widget.primary ? null : Border.all(color: colors.outline),
            borderRadius: BorderRadius.circular(7),
            boxShadow: _hovered
                ? const [
                    BoxShadow(
                      color: Color(0x24146FD8),
                      blurRadius: 14,
                      offset: Offset(0, 5),
                    ),
                  ]
                : const [],
          ),
          child: widget.primary
              ? FilledButton.icon(
                  onPressed: widget.onPressed,
                  icon: Icon(widget.icon ?? Icons.arrow_forward_rounded),
                  label: Text(widget.label),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                  ),
                )
              : OutlinedButton(
                  onPressed: widget.onPressed,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide.none,
                    backgroundColor: Colors.transparent,
                  ),
                  child: Text(widget.label),
                ),
        ),
      ),
    );
  }
}

class _LanguagePane extends StatelessWidget {
  const _LanguagePane({
    required this.title,
    required this.editable,
    required this.hint,
    this.controller,
    this.characterCount = 0,
    this.busy = false,
    this.statusMessage,
    this.onCopy,
    this.onSpeak,
  });

  final String title;
  final bool editable;
  final String hint;
  final TextEditingController? controller;
  final int characterCount;
  final bool busy;
  final String? statusMessage;
  final VoidCallback? onCopy;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const Divider(height: 1),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: TextField(
            controller: controller,
            enabled: editable,
            maxLength: editable ? 5000 : null,
            expands: true,
            minLines: null,
            maxLines: null,
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              disabledBorder: InputBorder.none,
              counterText: '',
              contentPadding: const EdgeInsets.all(24),
            ),
            style: const TextStyle(fontSize: 17, height: 1.65),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              IconButton(
                tooltip: '朗读',
                onPressed: onSpeak,
                icon: const Icon(Icons.volume_up_outlined),
              ),
              IconButton(
                tooltip: '复制',
                onPressed: onCopy,
                icon: const Icon(Icons.copy_outlined),
              ),
              const Spacer(),
              if (statusMessage != null)
                Flexible(
                  child: Text(
                    statusMessage!,
                    key: const ValueKey('translation-error'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                )
              else
                Text(editable ? '$characterCount / 5000' : '双语对照'),
            ],
          ),
        ),
      ],
    );
  }
}

class _LearningPanel extends StatefulWidget {
  const _LearningPanel({
    this.initialLookupTerm,
    required this.history,
    required this.onHistorySelected,
    this.onOpenHistory,
    this.onOpenFavorites,
    required this.lookupDictionary,
    required this.onTranslateLookup,
    required this.loadFavoriteWords,
    required this.setFavoriteWord,
    required this.loadWordAnnotation,
    required this.saveWordAnnotation,
    this.onSetLearning,
    required this.onImportDictionary,
    required this.onOpenDictionaryGuide,
    required this.onSpeak,
    super.key,
  });

  final String? initialLookupTerm;
  final Future<List<TranslationHistoryEntryData>> history;
  final ValueChanged<TranslationHistoryEntryData> onHistorySelected;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenFavorites;
  final DictionaryLookupLoader lookupDictionary;
  final Future<String> Function(String term) onTranslateLookup;
  final FavoriteWordsLoader loadFavoriteWords;
  final FavoriteWordSetter setFavoriteWord;
  final WordAnnotationLoader loadWordAnnotation;
  final WordAnnotationSaver saveWordAnnotation;
  final LearningWordSetter? onSetLearning;
  final VoidCallback onImportDictionary;
  final VoidCallback onOpenDictionaryGuide;
  final Future<void> Function(String value) onSpeak;

  @override
  State<_LearningPanel> createState() => _LearningPanelState();
}

class _LearningPanelState extends State<_LearningPanel> {
  final _queryController = TextEditingController();
  final _noteController = TextEditingController();
  DictionaryEntry? _entry;
  late Future<List<String>> _favorites;
  var _isFavorite = false;
  var _addedToLearning = false;
  var _savingNote = false;
  var _lookupBusy = false;
  var _lookupTranslationBusy = false;
  String? _lookupTranslation;
  String? _lookupTranslationError;
  String? _lookupError;
  String? _lookupBusyTerm;
  Timer? _lookupDebounce;
  var _lookupRequest = 0;
  var _lookupHasRun = false;

  @override
  void initState() {
    super.initState();
    _favorites = widget.loadFavoriteWords();
    final initialTerm = dictionaryTermAtInput(widget.initialLookupTerm ?? '');
    if (initialTerm != null) {
      _queryController.text = initialTerm;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_lookup(initialTerm));
      });
    }
  }

  void _onDictionaryQueryChanged(String value) {
    _lookupRequest++;
    _lookupDebounce?.cancel();
    _noteController.clear();
    setState(() {
      _entry = null;
      _isFavorite = false;
      _addedToLearning = false;
      _lookupBusy = false;
      _lookupBusyTerm = null;
      _lookupTranslationBusy = false;
      _lookupTranslation = null;
      _lookupTranslationError = null;
      _lookupError = null;
      _lookupHasRun = false;
    });
    scheduleLookup(value);
  }

  Future<void> _lookup(String value) async {
    _lookupDebounce?.cancel();
    final normalized = dictionaryTermAtInput(value);
    if (normalized == null) {
      _lookupRequest++;
      if (mounted) {
        setState(() {
          _lookupHasRun = false;
          _entry = null;
          _isFavorite = false;
          _addedToLearning = false;
          _noteController.clear();
          _lookupBusy = false;
          _lookupBusyTerm = null;
          _lookupError = '请输入一个中文或英文单词后查询。';
        });
      }
      return;
    }
    if (_lookupBusy && _lookupBusyTerm == normalized) return;
    final request = ++_lookupRequest;
    setState(() {
      _lookupBusy = true;
      _lookupBusyTerm = normalized;
      _lookupHasRun = true;
      _lookupError = null;
      _lookupTranslation = null;
      _lookupTranslationError = null;
    });
    try {
      final entry = await widget.lookupDictionary(normalized);
      if (!mounted || request != _lookupRequest) return;
      final favorites = await _favorites.then(
        (words) => words,
        onError: (Object _, StackTrace _) => const <String>[],
      );
      if (!mounted || request != _lookupRequest) return;
      WordAnnotationData? annotation;
      if (entry != null) {
        try {
          annotation = await widget.loadWordAnnotation(entry.word);
        } on Object {
          // A lookup remains useful when the optional learning note store is
          // temporarily unavailable.
        }
      }
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = entry;
        _isFavorite =
            entry != null && favorites.contains(entry.word.toLowerCase());
        _noteController.text = annotation?.note ?? '';
        _addedToLearning = annotation?.addedToLearning ?? false;
      });
    } on Object {
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = null;
        _isFavorite = false;
        _addedToLearning = false;
        _lookupError = '查词失败；请检查本地词典配置后重试。';
      });
    } finally {
      if (mounted && request == _lookupRequest) {
        setState(() {
          _lookupBusy = false;
          _lookupBusyTerm = null;
        });
      }
    }
  }

  Future<void> _translateUnknownTerm() async {
    final request = _lookupRequest;
    final term = dictionaryTermAtInput(_queryController.text);
    if (term == null || _lookupTranslationBusy) return;
    setState(() {
      _lookupTranslationBusy = true;
      _lookupTranslation = null;
      _lookupTranslationError = null;
    });
    try {
      final translated = await widget.onTranslateLookup(term);
      if (!mounted || request != _lookupRequest) return;
      final result = translated.trim();
      setState(() {
        if (result.isEmpty) {
          _lookupTranslationError = '当前翻译模型没有返回译文，请检查模型配置后重试。';
        } else {
          _lookupTranslation = result;
        }
      });
    } on Object {
      if (!mounted || request != _lookupRequest) return;
      setState(() => _lookupTranslationError = '当前翻译服务暂不可用，请检查模型配置后重试。');
    } finally {
      if (mounted && request == _lookupRequest) {
        setState(() => _lookupTranslationBusy = false);
      }
    }
  }

  void scheduleLookup(String value) {
    final word = value.trim();
    _lookupDebounce?.cancel();
    if (dictionaryTermAtInput(word) == null) {
      _lookupRequest++;
      _clearEntry();
      return;
    }
    _lookupDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) {
        final term = dictionaryTermAtInput(word);
        if (term == null) return;
        _queryController.text = term;
        unawaited(_lookup(term));
      }
    });
  }

  void lookupWord(String word) {
    _lookupDebounce?.cancel();
    final normalized = dictionaryTermAtInput(word);
    if (normalized == null) {
      _lookupRequest++;
      _clearEntry();
      return;
    }
    _queryController.text = normalized;
    unawaited(_lookup(normalized));
  }

  void _clearEntry() {
    if (_entry == null &&
        !_isFavorite &&
        _queryController.text.isEmpty &&
        !_lookupBusy &&
        !_lookupTranslationBusy &&
        _lookupTranslation == null &&
        _lookupTranslationError == null &&
        _lookupError == null) {
      return;
    }
    _queryController.clear();
    _noteController.clear();
    setState(() {
      _entry = null;
      _isFavorite = false;
      _addedToLearning = false;
      _lookupBusy = false;
      _lookupBusyTerm = null;
      _lookupHasRun = false;
      _lookupTranslationBusy = false;
      _lookupTranslation = null;
      _lookupTranslationError = null;
      _lookupError = null;
    });
  }

  Future<void> _toggleFavorite() async {
    final entry = _entry;
    if (entry == null) return;
    final next = !_isFavorite;
    try {
      await widget.setFavoriteWord(entry.word, next);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('收藏状态保存失败，请检查本地存储后重试。'),
          action: SnackBarAction(
            label: '重试',
            onPressed: () {
              _toggleFavorite();
            },
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _isFavorite = next;
      _favorites = widget.loadFavoriteWords();
    });
  }

  Future<void> _saveWordAnnotation({bool? addedToLearning}) async {
    final entry = _entry;
    if (entry == null || _savingNote) return;
    final nextAddedToLearning = addedToLearning ?? _addedToLearning;
    setState(() => _savingNote = true);
    try {
      await widget.onSetLearning?.call(entry.word, nextAddedToLearning);
      await widget.saveWordAnnotation(
        WordAnnotationData(
          word: entry.word,
          note: _noteController.text,
          addedToLearning: nextAddedToLearning,
          updatedAt: DateTime.now().toIso8601String(),
        ),
      );
      if (!mounted) return;
      setState(() => _addedToLearning = nextAddedToLearning);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(nextAddedToLearning ? '已加入学习，笔记已保存在本地' : '单词笔记已保存在本地'),
          duration: const Duration(milliseconds: 900),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('保存失败，请检查本地存储后重试。'),
          action: SnackBarAction(
            label: '重试',
            onPressed: () {
              _saveWordAnnotation(addedToLearning: nextAddedToLearning);
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingNote = false);
    }
  }

  String _dictionaryQualityLabel(DictionaryEntry entry) {
    switch (entry.qualityStatus) {
      case 'assistant_verified':
        return '质量状态：译学 AI 已核对 · 可用于查询';
      case 'assistant_verified_with_gaps':
        return '质量状态：译学 AI 已核对 · 有字段待补齐';
      case 'published':
        return '质量状态：译学已审校';
      case 'published_with_assistant_enrichment':
        return '质量状态：译学基础已审校 · AI 来源已核对';
      case 'published_with_candidate_enrichment':
        return '质量状态：译学基础已审校 · 扩展候选待审校';
      default:
        return '质量状态：开放候选 · 待审校';
    }
  }

  Widget _buildUnknownTermResult() {
    final theme = Theme.of(context);
    final term = _queryController.text.trim();
    final error = _lookupError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          error ??
              (_lookupHasRun
                  ? '本地词典暂未收录“$term”。'
                  : term.trim().isEmpty
                  ? '输入英文单词或最多 6 个中文汉字；停顿后自动查词。'
                  : '停顿后会自动查询，也可按 Enter 或点击搜索。'),
          style: error == null
              ? null
              : TextStyle(color: theme.colorScheme.error),
        ),
        if (_lookupHasRun) ...[
          if (_lookupTranslation case final translation?)
            Container(
              key: const ValueKey('dictionary-translation-result'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: .38,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: '当前模型试译：',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: translation),
                  ],
                ),
              ),
            ),
          if (_lookupTranslationError case final translationError?) ...[
            const SizedBox(height: 6),
            Text(
              translationError,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 6),
          OutlinedButton.icon(
            key: const ValueKey('dictionary-translate-term'),
            onPressed: _lookupTranslationBusy ? null : _translateUnknownTerm,
            icon: _lookupTranslationBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.translate_rounded),
            label: Text(_lookupTranslationBusy ? '正在试译…' : '用当前翻译模型试译'),
          ),
          Text(
            '查不到释义时按需试译；远程服务按模型配置执行。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  String _dictionaryCandidateLabel(DictionaryEntry entry, String field) {
    final assistantChecked = entry.qualityStatus.startsWith(
      'assistant_verified',
    );
    return '$field（${assistantChecked ? '来源已核对' : '待审校'}）';
  }

  String _dictionaryQualityShortLabel(DictionaryEntry entry) =>
      switch (entry.qualityStatus) {
        'published' => '已审校',
        'assistant_verified' => '来源已核对',
        'assistant_verified_with_gaps' => '有字段待补',
        'published_with_assistant_enrichment' => '扩展已核对',
        'published_with_candidate_enrichment' => '候选待审校',
        _ => '待审校',
      };

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    _queryController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    return ListView(
      key: const ValueKey('quick-learning-sidebar'),
      children: [
        _InfoCard(
          title: '词语解释',
          icon: Icons.menu_book_outlined,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryController,
                        key: const ValueKey('dictionary-query'),
                        decoration: const InputDecoration(
                          hintText: '输入英文单词或最多 6 个中文汉字',
                          isDense: true,
                        ),
                        onChanged: _onDictionaryQueryChanged,
                        onSubmitted: _lookup,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) => _lookupDebounce?.cancel(),
                      child: SizedBox(
                        width: 92,
                        height: 40,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('dictionary-query-submit'),
                          onPressed: () => _lookup(_queryController.text),
                          icon: _lookupBusy
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.search_rounded, size: 18),
                          label: Text(_lookupBusy ? '查询中' : '查词'),
                        ),
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: PopupMenuButton<String>(
                    key: const ValueKey('dictionary-tools-menu'),
                    tooltip: '词典工具',
                    onSelected: (action) {
                      if (action == 'guide') {
                        widget.onOpenDictionaryGuide();
                      } else {
                        widget.onImportDictionary();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem<String>(
                        value: 'guide',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.help_outline_rounded),
                          title: Text('格式说明与模板'),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'import',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.file_upload_outlined),
                          title: Text('导入授权词典包'),
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.tune_rounded, size: 17),
                          SizedBox(width: 6),
                          Text('词典工具'),
                          SizedBox(width: 3),
                          Icon(Icons.expand_more_rounded, size: 17),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (entry == null)
                  _lookupBusy
                      ? const LinearProgressIndicator(minHeight: 2)
                      : _lookupError != null
                      ? _buildUnknownTermResult()
                      : _queryController.text.trim().isNotEmpty
                      ? _buildUnknownTermResult()
                      : const Text('停顿后自动查本地词典；也可按 Enter 或点搜索。查不到可用当前模型试译。')
                else ...[
                  Text(
                    entry.word,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: _activeBlue,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Row(
                    children: [
                      if (entry.ipa.trim().isNotEmpty)
                        Text(
                          entry.ipa,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(color: const Color(0xFF566573)),
                        ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '朗读单词',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onSpeak(entry.word),
                        icon: const Icon(Icons.volume_up_outlined, size: 19),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (entry.partOfSpeech.trim().isNotEmpty)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(entry.partOfSpeech),
                        ),
                      Tooltip(
                        message: _dictionaryQualityLabel(entry),
                        child: Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.verified_outlined, size: 15),
                          label: Text(_dictionaryQualityShortLabel(entry)),
                        ),
                      ),
                    ],
                  ),
                  if (entry.meanings.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      '释义',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    for (var index = 0; index < entry.meanings.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${index + 1}.',
                              style: const TextStyle(
                                color: _activeBlue,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(entry.meanings[index])),
                          ],
                        ),
                      ),
                  ],
                  if (entry.hasCandidateMetadata ||
                      entry.reviewFields.isNotEmpty)
                    Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: ExpansionTile(
                        key: const ValueKey('dictionary-entry-usage-details'),
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 8),
                        leading: const Icon(Icons.tune_rounded, size: 19),
                        title: const Text('用法、词形与来源'),
                        subtitle: const Text('扩展候选会标明核对状态'),
                        children: [
                          if (entry.reviewFields.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '待补齐字段：${entry.reviewFields.take(6).join(' · ')}',
                                  style: const TextStyle(
                                    color: Color(0xFF65717E),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          if (entry.hasCandidateSenses) ...[
                            const SizedBox(height: 8),
                            Text(
                              _dictionaryCandidateLabel(entry, '分层义项'),
                              style: TextStyle(
                                color: Color(0xFF52606D),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 3),
                            for (final sense in entry.senseCandidates.take(4))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  [
                                    if (sense.partOfSpeech.isNotEmpty)
                                      sense.partOfSpeech,
                                    if (sense.englishGlosses.isNotEmpty)
                                      sense.englishGlosses.join('；'),
                                    if (sense.chineseGlosses.isNotEmpty)
                                      sense.chineseGlosses.join('；'),
                                    if (sense.usageTags.isNotEmpty)
                                      '用法：${sense.usageTags.join(' · ')}',
                                    if (sense.qualifier.isNotEmpty)
                                      '限定：${sense.qualifier}',
                                    '来源：${sense.sourceId}',
                                  ].join(' · '),
                                  style: const TextStyle(
                                    color: Color(0xFF65717E),
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                          ],
                          if (entry.partOfSpeechCandidates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_dictionaryCandidateLabel(entry, '词性候选')}：${entry.partOfSpeechCandidates.take(6).map((item) => '${item.value} · ${item.sourceId}').join(' / ')}',
                              style: const TextStyle(
                                color: Color(0xFF65717E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (entry.pronunciationCandidates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_dictionaryCandidateLabel(entry, '音标候选')}：${entry.pronunciationCandidates.take(4).map((item) => [item.dialect.isEmpty ? '未标注' : item.dialect, item.value, if (item.sourceWord.isNotEmpty) '来源词 ${item.sourceWord}'].join(' ')).join(' / ')}',
                              style: const TextStyle(
                                color: Color(0xFF65717E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (entry.learningTags.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_dictionaryCandidateLabel(entry, '学习标签候选')}：${entry.learningTags.take(8).join(' · ')}',
                              style: const TextStyle(
                                color: Color(0xFF65717E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (entry.variants.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              '${_dictionaryCandidateLabel(entry, '词形候选')}：${entry.variants.take(8).join(' · ')}',
                              style: const TextStyle(
                                color: Color(0xFF65717E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (entry.collocationCandidates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_dictionaryCandidateLabel(entry, '搭配候选')}：${entry.collocationCandidates.take(5).join(' · ')}',
                              style: const TextStyle(
                                color: Color(0xFF65717E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: _isFavorite ? '取消收藏' : '收藏单词',
                      icon: Icon(
                        _isFavorite
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        color: _isFavorite ? _activeBlue : null,
                      ),
                      onPressed: _toggleFavorite,
                    ),
                  ),
                  TextField(
                    controller: _noteController,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 4_000,
                    decoration: const InputDecoration(
                      labelText: '我的笔记',
                      hintText: '写下自己的例句、工作含义或易错点…',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        icon: _savingNote
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined, size: 17),
                        label: const Text('保存笔记'),
                        onPressed: _savingNote ? null : _saveWordAnnotation,
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _addedToLearning
                              ? Icons.school_rounded
                              : Icons.add_task_rounded,
                          size: 17,
                        ),
                        label: Text(_addedToLearning ? '已加入学习' : '加入学习'),
                        onPressed: _savingNote
                            ? null
                            : () => _saveWordAnnotation(
                                addedToLearning: !_addedToLearning,
                              ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: '例句',
          icon: Icons.chat_bubble_outline_rounded,
          child: entry == null
              ? const Text('查询单词后显示本地例句。')
              : entry.hasExample
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(entry.example)),
                        IconButton(
                          tooltip: '朗读例句',
                          onPressed: () => widget.onSpeak(entry.example),
                          icon: const Icon(Icons.volume_up_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(entry.exampleTranslation),
                    if (entry.exampleIsOpenCandidate) ...[
                      const SizedBox(height: 8),
                      const Text(
                        '开放来源例句候选 · 待人工审校',
                        style: TextStyle(
                          color: Color(0xFF65717E),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                )
              : entry.sourceExampleCandidates.isNotEmpty
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(entry.sourceExampleCandidates.first),
                        ),
                        IconButton(
                          tooltip: '朗读例句',
                          onPressed: () => widget.onSpeak(
                            entry.sourceExampleCandidates.first,
                          ),
                          icon: const Icon(Icons.volume_up_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '开放来源英文例句候选 · 待审校 · 暂无译学译文',
                      style: TextStyle(color: Color(0xFF65717E), fontSize: 12),
                    ),
                  ],
                )
              : const Text('基础词目已收录，双语例句正在逐条补充。'),
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: '已收藏单词',
          icon: Icons.bookmark_border_rounded,
          headerKey: const ValueKey('quick-favorites-header'),
          onHeaderTap: widget.onOpenFavorites,
          child: FutureBuilder<List<String>>(
            future: _favorites,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator(minHeight: 2);
              }
              final favorites = snapshot.data ?? const <String>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (favorites.isEmpty)
                    const Text('查询后点击书签，即可保存到本地。')
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final word in favorites)
                          ActionChip(
                            label: Text(word),
                            onPressed: () {
                              _queryController.text = word;
                              _lookup(word);
                            },
                          ),
                      ],
                    ),
                  if (widget.onOpenFavorites != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('quick-favorites-open-all'),
                        onPressed: widget.onOpenFavorites,
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('查看全部收藏'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: '翻译历史',
          icon: Icons.history_rounded,
          headerKey: const ValueKey('quick-history-header'),
          onHeaderTap: widget.onOpenHistory,
          child: FutureBuilder<List<TranslationHistoryEntryData>>(
            future: widget.history,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator(minHeight: 2);
              }
              if (snapshot.hasError) {
                return const Text('历史读取失败，请稍后重试');
              }
              final entries = snapshot.data ?? const [];
              if (entries.isEmpty) {
                return const Text('完成一次翻译后，记录会安全保存在本地。');
              }
              return Column(
                children: [
                  for (final entry in entries.take(5))
                    Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          entry.sourceText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.originLabel} · ${entry.translatedText}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 13,
                        ),
                        onTap: () => widget.onHistorySelected(entry),
                      ),
                    ),
                  if (widget.onOpenHistory != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const ValueKey('quick-history-open-all'),
                        onPressed: widget.onOpenHistory,
                        child: const Text('查看全部历史'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TranslationHistoryWorkspace extends StatefulWidget {
  const _TranslationHistoryWorkspace({
    required this.loadHistory,
    this.loadHistoryPage,
    this.exportHistory,
    this.deleteHistory,
    this.screenshotDeleteResult,
    required this.loadAnnotations,
    required this.saveAnnotation,
    required this.onContinue,
    required this.onSpeak,
  });

  final TranslationHistoryLoader loadHistory;
  final TranslationHistoryPageLoader? loadHistoryPage;
  final TranslationHistoryExporter? exportHistory;
  final TranslationHistoryEntryDeleter? deleteHistory;
  final ScreenshotTranslationArchiveDeleteResult? Function()?
  screenshotDeleteResult;
  final TranslationAnnotationLoader loadAnnotations;
  final TranslationAnnotationSaver saveAnnotation;
  final ValueChanged<TranslationHistoryEntryData> onContinue;
  final Future<void> Function(String value) onSpeak;

  @override
  State<_TranslationHistoryWorkspace> createState() =>
      _TranslationHistoryWorkspaceState();
}

enum _HistoryFilter { all, favorites, learning }

class _TranslationHistoryWorkspaceState
    extends State<_TranslationHistoryWorkspace> {
  static const _pageSize = 50;
  static const _maximumExportEntries = 5000;
  static const _maximumBulkSelectEntries = 50000;
  final _searchController = TextEditingController();
  final _noteController = TextEditingController();
  final _scrollController = ScrollController();
  var _history = const <TranslationHistoryEntryData>[];
  var _annotations = <String, TranslationAnnotationData>{};
  TranslationHistoryEntryData? _selected;
  var _filter = _HistoryFilter.all;
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = false;
  var _exporting = false;
  var _selectingAll = false;
  final _selectedIds = <String>{};
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<TranslationHistoryEntryData> history;
      var hasMore = false;
      if (widget.loadHistoryPage != null) {
        history = await widget.loadHistoryPage!(0, _pageSize);
        hasMore = history.length >= _pageSize;
      } else {
        history = await widget.loadHistory();
      }
      final annotations = await widget.loadAnnotations();
      final nextAnnotations = <String, TranslationAnnotationData>{
        for (final annotation in annotations)
          annotation.translationId: annotation,
      };
      if (!mounted) return;
      final selectedId = _selected?.id;
      final selected = history.where((entry) => entry.id == selectedId);
      final nextSelected = selected.isNotEmpty
          ? selected.first
          : history.isEmpty
          ? null
          : history.first;
      setState(() {
        _history = history;
        _annotations = nextAnnotations;
        _selected = nextSelected;
        _hasMore = hasMore;
        _loadingMore = false;
        _loading = false;
      });
      _syncNote(nextSelected);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '历史读取失败，请检查本地数据库后重试';
      });
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.loadHistoryPage;
    if (loader == null || !_hasMore || _loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final page = await loader(_history.length, _pageSize);
      if (!mounted) return;
      final knownIds = _history.map((entry) => entry.id).toSet();
      final additions = page
          .where((entry) => knownIds.add(entry.id))
          .toList(growable: false);
      setState(() {
        _history = [..._history, ...additions];
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('更多历史读取失败，请稍后重试')));
    }
  }

  Future<void> _exportAll() async {
    final exporter = widget.exportHistory;
    if (exporter == null || _exporting || _loading) return;
    setState(() => _exporting = true);
    try {
      final allHistory = <TranslationHistoryEntryData>[..._history];
      var hasMore = _hasMore;
      var offset = allHistory.length;
      var truncated = false;
      final loader = widget.loadHistoryPage;
      while (loader != null && hasMore && offset < _maximumExportEntries) {
        final page = await loader(offset, _pageSize);
        if (page.isEmpty) {
          hasMore = false;
          break;
        }
        final knownIds = allHistory.map((entry) => entry.id).toSet();
        allHistory.addAll(page.where((entry) => knownIds.add(entry.id)));
        offset += page.length;
        hasMore = page.length >= _pageSize;
      }
      truncated = hasMore && offset >= _maximumExportEntries;
      final path = await exporter(
        List.unmodifiable(allHistory),
        List.unmodifiable(_annotations.values),
      );
      if (!mounted || path == null) return;
      final suffix = truncated ? '（已达到本地导出上限 $_maximumExportEntries 条）' : '';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('翻译历史已导出$suffix：$path')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('翻译历史导出失败，请检查保存位置和权限')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _syncNote(TranslationHistoryEntryData? entry) {
    _noteController.text = entry == null
        ? ''
        : _annotations[entry.id]?.note ?? '';
  }

  TranslationAnnotationData? _annotationFor(
    TranslationHistoryEntryData? entry,
  ) => entry == null ? null : _annotations[entry.id];

  List<TranslationHistoryEntryData> get _visibleHistory {
    final query = _searchController.text.trim().toLowerCase();
    return _history
        .where((entry) => _matchesHistoryEntry(entry, query))
        .toList(growable: false);
  }

  bool _matchesHistoryEntry(TranslationHistoryEntryData entry, String query) {
    final annotation = _annotationFor(entry);
    final matchesFilter = switch (_filter) {
      _HistoryFilter.all => true,
      _HistoryFilter.favorites => annotation?.favorite == true,
      _HistoryFilter.learning =>
        annotation?.addedToLearning == true ||
            annotation?.note.trim().isNotEmpty == true,
    };
    if (!matchesFilter) return false;
    if (query.isEmpty) return true;
    return entry.sourceText.toLowerCase().contains(query) ||
        entry.translatedText.toLowerCase().contains(query) ||
        entry.providerId.toLowerCase().contains(query) ||
        (annotation?.note.toLowerCase().contains(query) ?? false);
  }

  void _selectEntry(TranslationHistoryEntryData entry) {
    setState(() {
      _selected = entry;
      _syncNote(entry);
    });
  }

  void _toggleHistorySelection(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  Future<void> _toggleSelectAllVisible() async {
    final visibleNow = _visibleHistory;
    if (visibleNow.isEmpty ||
        _selectingAll ||
        _loading ||
        _loadingMore ||
        _exporting ||
        _saving) {
      return;
    }
    final allVisibleSelected = visibleNow.every(
      (entry) => _selectedIds.contains(entry.id),
    );
    if (allVisibleSelected) {
      setState(() {
        _selectedIds.clear();
      });
      return;
    }

    setState(() => _selectingAll = true);
    try {
      final allHistory = <TranslationHistoryEntryData>[..._history];
      final loader = widget.loadHistoryPage;
      var hasMore = _hasMore;
      var offset = allHistory.length;
      if (loader == null && hasMore) {
        throw StateError('history_pagination_unavailable');
      }
      while (loader != null && hasMore) {
        if (offset >= _maximumBulkSelectEntries) {
          throw StateError('bulk_selection_limit_reached');
        }
        final page = await loader(offset, _pageSize);
        if (page.isEmpty) {
          hasMore = false;
          break;
        }
        final knownIds = allHistory.map((entry) => entry.id).toSet();
        allHistory.addAll(page.where((entry) => knownIds.add(entry.id)));
        offset += page.length;
        hasMore = page.length >= _pageSize;
      }
      if (!mounted) return;
      final query = _searchController.text.trim().toLowerCase();
      final matchingIds = allHistory
          .where((entry) => _matchesHistoryEntry(entry, query))
          .map((entry) => entry.id)
          .toList(growable: false);
      setState(() {
        _history = List.unmodifiable(allHistory);
        _hasMore = false;
        _selectedIds.addAll(matchingIds);
        _selectingAll = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _selectingAll = false);
      final String message;
      if (error is StateError &&
          error.message == 'history_pagination_unavailable') {
        message = '当前核心不能读取尚未加载的历史，无法全选；请更新核心后重试。';
      } else if (error is StateError &&
          error.message == 'bulk_selection_limit_reached') {
        message = '匹配记录超过单次全选上限；请缩小搜索范围后重试。';
      } else {
        message = '全选历史失败；请刷新后重试。';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _deleteSelectedHistory() async {
    if (_selectedIds.isEmpty || _saving || _selectingAll) return;
    final deleter = widget.deleteHistory;
    if (deleter == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前核心暂不支持选择删除，请先更新核心版本')));
      return;
    }
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除选中的历史？'),
        content: Text('将删除 $count 条翻译原文、译文及对应标注；其他学习记录不受影响。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final selectedEntries = _history
        .where((entry) => _selectedIds.contains(entry.id))
        .toList(growable: false);
    if (selectedEntries.length != count) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('所选历史已变化，请刷新后重试')));
      return;
    }
    final includesScreenshotHistory = selectedEntries.any(
      (entry) =>
          entry.origin ==
          ScreenshotTranslationArchiveController.screenshotOrigin,
    );
    setState(() => _saving = true);
    try {
      await deleter(selectedEntries);
      final screenshotDelete = includesScreenshotHistory
          ? widget.screenshotDeleteResult?.call()
          : null;
      if (!mounted) return;
      _selectedIds.clear();
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            screenshotDelete?.imageCleanupPending == true
                ? '已删除 $count 条翻译历史，但部分原图尚未清理。设置中的“清理所有已保存原图”会删除全部截图原图，并保留 OCR 与译文历史。'
                : includesScreenshotHistory
                ? '已删除 $count 条翻译历史；仍被其他版本引用的原图会保留。'
                : '已删除 $count 条翻译历史',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final screenshotDelete = includesScreenshotHistory
          ? widget.screenshotDeleteResult?.call()
          : null;
      final cacheFull =
          error is ScreenshotTranslationRetryCacheFullException ||
          screenshotDelete?.error
              is ScreenshotTranslationRetryCacheFullException;
      final message = cacheFull
          ? ScreenshotTranslationRetryCacheFullException.userMessage
          : screenshotDelete?.imageCleanupPending == true
          ? '历史已删除，但部分原图尚未清理。设置中的“清理所有已保存原图”会删除全部截图原图，并保留 OCR 与译文历史。'
          : screenshotDelete?.imageDeleted == true &&
                screenshotDelete?.historyDeleted == false
          ? '部分原图已清理，文字历史仍保留；请刷新后重试。'
          : '删除未完成，文字历史保持原样；请刷新后重试。';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSelectedAnnotation({
    bool? favorite,
    bool? addedToLearning,
  }) async {
    final entry = _selected;
    if (entry == null || _saving) return;
    final current = _annotationFor(entry);
    final next = TranslationAnnotationData(
      translationId: entry.id,
      note: _noteController.text,
      favorite: favorite ?? current?.favorite ?? false,
      addedToLearning: addedToLearning ?? current?.addedToLearning ?? false,
      updatedAt: DateTime.now().toIso8601String(),
    );
    setState(() => _saving = true);
    try {
      await widget.saveAnnotation(next);
      if (!mounted) return;
      setState(() => _annotations[entry.id] = next);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('翻译标注已保存在本地'),
          duration: Duration(milliseconds: 900),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _directionLabel(TranslationHistoryEntryData entry) {
    if (entry.sourceLanguage == 'chinese' ||
        entry.targetLanguage == 'english') {
      return '中译英';
    }
    return '英译中';
  }

  Widget _buildHistoryList(BuildContext context) {
    final entries = _visibleHistory;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: FilledButton.tonalIcon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新读取'),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _history.isEmpty ? '完成一次翻译后，这里会保留完整记录。' : '没有符合条件的历史记录。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('history-list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 20),
      itemCount: entries.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        if (index == entries.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: OutlinedButton.icon(
              key: const ValueKey('history-load-more'),
              onPressed: _loadingMore ? null : _loadMore,
              icon: _loadingMore
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: Text(_loadingMore ? '正在读取…' : '加载更多历史'),
            ),
          );
        }
        final entry = entries[index];
        final annotation = _annotationFor(entry);
        final selected = _selected?.id == entry.id;
        final checked = _selectedIds.contains(entry.id);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _selectEntry(entry),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.fromLTRB(12, 11, 10, 10),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        key: ValueKey('history-select-${entry.id}'),
                        value: checked,
                        onChanged: (value) =>
                            _toggleHistorySelection(entry.id, value ?? false),
                      ),
                      Expanded(
                        child: Text(
                          entry.sourceText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (annotation?.favorite == true)
                        const Icon(
                          Icons.bookmark_rounded,
                          size: 17,
                          color: _activeBlue,
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    entry.translatedText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _HistoryMetaChip(label: entry.originLabel),
                      _HistoryMetaChip(label: _directionLabel(entry)),
                      _HistoryMetaChip(label: entry.createdAt),
                      if (annotation?.addedToLearning == true)
                        const _HistoryMetaChip(label: '已加入学习'),
                      if (annotation?.note.trim().isNotEmpty == true)
                        const _HistoryMetaChip(label: '有笔记'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetail(BuildContext context) {
    final entry = _selected;
    if (entry == null) {
      return const Center(child: Text('选择一条历史记录查看详情'));
    }
    final annotation = _annotationFor(entry);
    final favorite = annotation?.favorite ?? false;
    final learning = annotation?.addedToLearning ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Chip(label: Text(entry.originLabel)),
              Chip(
                avatar: const Icon(Icons.swap_horiz_rounded, size: 17),
                label: Text(_directionLabel(entry)),
              ),
              Chip(
                avatar: const Icon(Icons.schedule_rounded, size: 16),
                label: Text(entry.createdAt),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '模型：${entry.providerId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          _HistoryTextCard(
            title: '原文',
            text: entry.sourceText,
            onSpeak: () => widget.onSpeak(entry.sourceText),
          ),
          const SizedBox(height: 12),
          _HistoryTextCard(
            title: '译文',
            text: entry.translatedText,
            onSpeak: () => widget.onSpeak(entry.translatedText),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => widget.onContinue(entry),
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('继续翻译'),
              ),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _saveSelectedAnnotation(favorite: !favorite),
                icon: Icon(
                  favorite
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                ),
                label: Text(favorite ? '取消收藏' : '收藏这次翻译'),
              ),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () => _saveSelectedAnnotation(addedToLearning: !learning),
                icon: Icon(
                  learning ? Icons.school_rounded : Icons.add_task_rounded,
                ),
                label: Text(learning ? '已加入学习' : '加入学习'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _noteController,
            minLines: 4,
            maxLines: 8,
            maxLength: 4_000,
            decoration: const InputDecoration(
              labelText: '这次翻译的笔记',
              hintText: '记录专业语境、自己的改译、易错点或后续学习计划…',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: _saving ? null : _saveSelectedAnnotation,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存标注'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '翻译历史',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '原文、译文、模型和你的学习标注都保存在本地',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('history-export'),
                  tooltip: '导出本地历史',
                  onPressed:
                      _loading || _exporting || widget.exportHistory == null
                      ? null
                      : _exportAll,
                  icon: _exporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_download_outlined),
                ),
                Builder(
                  builder: (context) {
                    final visible = _visibleHistory;
                    final allVisibleSelected =
                        visible.isNotEmpty &&
                        visible.every(
                          (entry) => _selectedIds.contains(entry.id),
                        );
                    return Tooltip(
                      message: allVisibleSelected
                          ? '清空所有已选历史'
                          : '选中全部筛选结果，包括尚未加载的历史',
                      child: TextButton.icon(
                        key: const ValueKey('history-select-all-visible'),
                        onPressed:
                            _loading ||
                                _loadingMore ||
                                _exporting ||
                                _selectingAll ||
                                _saving
                            ? null
                            : _toggleSelectAllVisible,
                        icon: _selectingAll
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                allVisibleSelected
                                    ? Icons.deselect_rounded
                                    : Icons.select_all_rounded,
                                size: 18,
                              ),
                        label: Text(
                          _selectingAll
                              ? '正在全选…'
                              : allVisibleSelected
                              ? '清空已选'
                              : '全选筛选结果',
                        ),
                      ),
                    );
                  },
                ),
                if (_selectedIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '${_selectedIds.length} 条已选',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                IconButton(
                  key: const ValueKey('history-delete-selected'),
                  tooltip: '删除选中的历史',
                  onPressed: _selectedIds.isEmpty || _saving || _selectingAll
                      ? null
                      : _deleteSelectedHistory,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                IconButton(
                  tooltip: '刷新历史',
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '搜索原文、译文、模型或笔记',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('全部'),
                        selected: _filter == _HistoryFilter.all,
                        onSelected: (_) =>
                            setState(() => _filter = _HistoryFilter.all),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('收藏'),
                        selected: _filter == _HistoryFilter.favorites,
                        onSelected: (_) =>
                            setState(() => _filter = _HistoryFilter.favorites),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('学习标注'),
                        selected: _filter == _HistoryFilter.learning,
                        onSelected: (_) =>
                            setState(() => _filter = _HistoryFilter.learning),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 360, child: _buildHistoryList(context)),
                VerticalDivider(width: 1, color: colors.outlineVariant),
                Expanded(child: _buildDetail(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _noteController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _HistoryMetaChip extends StatelessWidget {
  const _HistoryMetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}

class _HistoryTextCard extends StatelessWidget {
  const _HistoryTextCard({
    required this.title,
    required this.text,
    required this.onSpeak,
  });

  final String title;
  final String text;
  final VoidCallback onSpeak;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(16, 12, 10, 14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: _activeBlue, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: '朗读',
              onPressed: onSpeak,
              icon: const Icon(Icons.volume_up_outlined, size: 20),
            ),
          ],
        ),
        SelectableText(text, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}

class _DictionaryPackageGuideDialog extends StatelessWidget {
  const _DictionaryPackageGuideDialog({required this.onExportTemplate});

  final DictionaryPackageTemplateExporter onExportTemplate;

  Future<void> _copyTemplate(BuildContext context) async {
    await Clipboard.setData(
      const ClipboardData(text: DictionaryPackageService.templateJson),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('词典模板已复制到剪贴板')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final coverage = DictionaryCoverageReport.fromRuntimeDictionary(
      const LocalDictionaryService().entries,
    );
    return AlertDialog(
      title: const Text('词典包说明与导入方法'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('词典包是给右侧词语解释和学习页补充资料的本地文件。它不是翻译模型，也不会单独提高整句翻译质量。'),
              const SizedBox(height: 16),
              Text(
                '当前词典',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: 0.22),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '内置基础词典 · ${coverage.totalEntries} 条',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '其中 ${coverage.publishedEntries} 条是译学自写并已配例句的质量切片；其余为可追溯的四六级开放基础词目，先提供音标、词性和基础释义，例句与富语义将继续补齐。',
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '用户词典 · 可扩展',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    const Text('可导入你自己制作、公开许可或已经获授权的词典包；导入后保存在本机数据库，不会上传。'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '覆盖进度（当前实际收录）',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              _DictionaryCoverageSummary(report: coverage),
              const SizedBox(height: 16),
              Text(
                '怎么导入',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const _DictionaryGuideStep(
                number: '1',
                title: '保存模板',
                detail: '点击底部“保存可编辑模板”，用文本编辑器打开保存出来的 .json 文件。',
              ),
              const _DictionaryGuideStep(
                number: '2',
                title: '填写自己的数据',
                detail: '修改词典名称、真实许可证和 entries；不要把示例许可证原样留下。',
              ),
              const _DictionaryGuideStep(
                number: '3',
                title: '按 UTF-8 JSON 保存',
                detail: '不要选择 Word、PDF、Excel、模型目录或压缩包；当前版本只接受一个 .json 文件。',
              ),
              const _DictionaryGuideStep(
                number: '4',
                title: '回到快速翻译导入',
                detail: '点击“导入授权词典包”。成功后，词条会参与右侧查询，并显示词典名称和许可信息。',
              ),
              const SizedBox(height: 12),
              Text(
                '每条词条必须包含',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: const [
                  Chip(label: Text('word 单词')),
                  Chip(label: Text('ipa 音标')),
                  Chip(label: Text('part_of_speech 词性')),
                  Chip(label: Text('meanings 释义')),
                  Chip(label: Text('example 英文例句')),
                  Chip(label: Text('example_translation 中文例句')),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '导入前请确认',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(DictionaryPackageService.importGuidance),
              const SizedBox(height: 12),
              const Text(
                '开放数据也要看许可：后续我们会把已审查的开放词典整理成官方词典包；在审查完成前，请不要把网上随手下载的词库直接随软件分发。',
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.outline),
                ),
                child: SelectableText(
                  DictionaryPackageService.templateJson,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _copyTemplate(context),
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('复制模板'),
        ),
        OutlinedButton.icon(
          onPressed: onExportTemplate,
          icon: const Icon(Icons.save_alt_outlined),
          label: const Text('保存可编辑模板'),
        ),
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _DictionaryCoverageSummary extends StatelessWidget {
  const _DictionaryCoverageSummary({required this.report});

  final DictionaryCoverageReport report;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        children: [
          for (final profile in dictionaryCoverageProfiles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_coverageStatusLabel(profile.status)} · 当前${report.countFor(profile.id, publishedOnly: false)}条 · 已审校${report.countFor(profile.id)}条',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (report.countFor(profile.id) > 0)
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 18,
                      color: colors.tertiary,
                    )
                  else
                    Icon(
                      Icons.schedule_outlined,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('dictionary-scope-evidence'),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.outline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cetEnglishDictionaryScopeAudit.statusLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cetEnglishDictionaryScopeAudit.detail,
                        style: Theme.of(context).textTheme.bodySmall,
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

  String _coverageStatusLabel(DictionaryCoverageStatus status) {
    return switch (status) {
      DictionaryCoverageStatus.seed => '已随包提供',
      DictionaryCoverageStatus.building => '建设中',
      DictionaryCoverageStatus.planned => '建设目标，尚未完成覆盖',
    };
  }
}

class _DictionaryGuideStep extends StatelessWidget {
  const _DictionaryGuideStep({
    required this.number,
    required this.title,
    required this.detail,
  });

  final String number;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(detail),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.icon,
    required this.child,
    this.headerKey,
    this.onHeaderTap,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Key? headerKey;
  final VoidCallback? onHeaderTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onHeaderTap == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: _buildHeader(),
            )
          else
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: headerKey,
                onTap: onHeaderTap,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                ),
                child: Semantics(
                  button: true,
                  label: '打开$title',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: _buildHeader(),
                  ),
                ),
              ),
            ),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(icon, color: _activeBlue, size: 20),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const Spacer(),
        const Icon(Icons.expand_less_rounded, size: 18),
      ],
    );
  }
}

class _ServiceStatusChip extends StatelessWidget {
  const _ServiceStatusChip({
    required this.status,
    required this.onPressed,
    this.maxTextWidth = 260,
  });

  final ValueListenable<String> status;
  final VoidCallback onPressed;
  final double maxTextWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: status,
      builder: (context, _) => Tooltip(
        message: '查看模型与服务：${status.value}',
        child: Material(
          color: colors.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.circle, size: 9, color: Color(0xFF16A765)),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxTextWidth),
                    child: Text(
                      status.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageSkeleton extends StatelessWidget {
  const _PageSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.55, end: 1),
      duration: const Duration(milliseconds: 180),
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SkeletonBlock(width: 230, height: 34),
            const SizedBox(height: 22),
            Expanded(
              child: Row(
                children: [
                  const Expanded(child: _SkeletonBlock()),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 300,
                    child: Column(
                      children: const [
                        Expanded(child: _SkeletonBlock()),
                        SizedBox(height: 12),
                        Expanded(child: _SkeletonBlock()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.surfaceContainer,
            colors.surface,
            colors.surfaceContainer,
          ],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.appearanceController,
    required this.onOpenModels,
    required this.coreFactory,
    required this.modelStatus,
    required this.translationPreferencesController,
    required this.onTranslationPreferencesChanged,
    this.translationTerminologyController,
    required this.onTranslationTerminologyChanged,
    this.dictionaryPreferencesController,
    required this.onDictionaryPreferencesChanged,
    required this.onClearPreferenceFile,
    required this.onExportLocalData,
    this.appDataDirectory,
    this.storagePolicyStore,
    this.storageUsageLoader,
    required this.onOpenContentLibrary,
  });

  final AppearanceController appearanceController;
  final VoidCallback onOpenModels;
  final AppCore Function()? coreFactory;
  final ValueListenable<String> modelStatus;
  final TranslationPreferencesController? translationPreferencesController;
  final Future<void> Function(TranslationPreferences value)
  onTranslationPreferencesChanged;
  final TranslationTerminologyController? translationTerminologyController;
  final Future<void> Function(TranslationTerminology value)
  onTranslationTerminologyChanged;
  final DictionaryPreferencesController? dictionaryPreferencesController;
  final Future<void> Function(DictionaryPreferences value)
  onDictionaryPreferencesChanged;
  final Future<void> Function(String category) onClearPreferenceFile;
  final Future<String?> Function() onExportLocalData;
  final String? appDataDirectory;
  final yixue_storage.StoragePolicyStore? storagePolicyStore;
  final StorageUsageLoader? storageUsageLoader;
  final VoidCallback onOpenContentLibrary;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('settings-scroll'),
      padding: const EdgeInsets.all(32),
      children: [
        Text(
          '设置',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 20),
        AppearanceSettingsCard(controller: appearanceController),
        const SizedBox(height: 14),
        _TranslationPreferencesCard(
          controller: translationPreferencesController,
          onChanged: onTranslationPreferencesChanged,
        ),
        const SizedBox(height: 14),
        _TerminologySettingsCard(
          controller: translationTerminologyController,
          onChanged: onTranslationTerminologyChanged,
        ),
        const SizedBox(height: 14),
        _DictionarySourcesSettingsCard(
          controller: dictionaryPreferencesController,
          onChanged: onDictionaryPreferencesChanged,
        ),
        const SizedBox(height: 14),
        _SettingsCard(
          key: const ValueKey('settings-content-library'),
          icon: Icons.library_books_outlined,
          title: '内容库',
          value: '词典、文章、教材集中管理',
          detail: '查看本地数量、来源、许可证和当前可用的学习资料。',
          onTap: onOpenContentLibrary,
        ),
        const SizedBox(height: 14),
        _SettingsCard(
          icon: Icons.verified_user_outlined,
          title: '数据与隐私',
          value: '内容默认保存在本地',
          detail: '截屏翻译原图默认保存在本地；可在截屏翻译页关闭新图保存或清理已有原图。网络 Provider 接收 OCR 文字用于翻译，不会收到截图原图。密钥由系统安全存储保护。',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _DataManagementDialog(
              coreFactory: coreFactory,
              clearPreferenceFile: onClearPreferenceFile,
              exportData: onExportLocalData,
              dataPath: appDataDirectory,
              storagePolicyStore: storagePolicyStore,
              storageUsageLoader: storageUsageLoader,
            ),
          ),
        ),
        const SizedBox(height: 14),
        ValueListenableBuilder<String>(
          valueListenable: modelStatus,
          builder: (context, status, _) => _SettingsCard(
            icon: Icons.memory_rounded,
            title: '模型与处理',
            value: status,
            detail: '本地模型和自定义 API 的启用状态集中显示在“模型与服务”。',
            onTap: onOpenModels,
          ),
        ),
        const SizedBox(height: 14),
        _SettingsCard(
          icon: Icons.menu_book_outlined,
          title: '使用方法与声明',
          value: '本地优先 · 透明可控',
          detail: '查看快速翻译、模型、数据、许可和用户准则。',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const _AboutYixueDialog(),
          ),
        ),
        const SizedBox(height: 14),
        const _SettingsCard(
          icon: Icons.info_outline_rounded,
          title: '版本与构建',
          value: AppBuildInfo.label,
          detail: '预览版附带 Git 标识，便于定位每一次界面与交互反馈。',
        ),
        const SizedBox(height: 14),
        _SettingsCard(
          icon: Icons.system_update_alt_rounded,
          title: '更新与安装',
          value: '预览版 · 本地安装包',
          detail: '更新程序时保留 D 盘个人数据；当前阶段使用新的完整安装包覆盖程序目录。',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const _UpdateInfoDialog(),
          ),
        ),
      ],
    );
  }
}

class _TranslationPreferencesCard extends StatelessWidget {
  const _TranslationPreferencesCard({
    required this.controller,
    required this.onChanged,
  });

  final TranslationPreferencesController? controller;
  final Future<void> Function(TranslationPreferences value) onChanged;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return const _SettingsCard(
        icon: Icons.tune_rounded,
        title: '翻译偏好',
        value: '跟随当前方向 · 自然表达',
        detail: '偏好存储将在应用数据目录启用后显示。',
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final preferences = controller.value;
        return Material(
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune_rounded, color: _activeBlue),
                    const SizedBox(width: 10),
                    Text(
                      '翻译偏好',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text('偏好只保存在本地，并会影响快速翻译的默认方向和后续翻译提示。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<PreferredDirection>(
                  key: const ValueKey('translation-direction-preference'),
                  initialValue: preferences.direction,
                  decoration: const InputDecoration(
                    labelText: '默认语言方向',
                    helperText: '影响快速翻译的初始方向；自动检测仍会按输入内容判断。',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: PreferredDirection.auto,
                      child: Text('自动检测'),
                    ),
                    DropdownMenuItem(
                      value: PreferredDirection.englishToChinese,
                      child: Text('英译中'),
                    ),
                    DropdownMenuItem(
                      value: PreferredDirection.chineseToEnglish,
                      child: Text('中译英'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(
                        onChanged(preferences.copyWith(direction: value)),
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<TranslationTone>(
                  key: const ValueKey('translation-tone-preference'),
                  initialValue: preferences.tone,
                  decoration: const InputDecoration(
                    labelText: '翻译语气',
                    helperText: '影响快速翻译及后续文章翻译提示；不改变原文。',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: TranslationTone.natural,
                      child: Text('自然通顺'),
                    ),
                    DropdownMenuItem(
                      value: TranslationTone.formal,
                      child: Text('正式专业'),
                    ),
                    DropdownMenuItem(
                      value: TranslationTone.concise,
                      child: Text('简洁直接'),
                    ),
                    DropdownMenuItem(
                      value: TranslationTone.learning,
                      child: Text('学习解释友好'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(onChanged(preferences.copyWith(tone: value)));
                    }
                  },
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('translation-line-breaks-preference'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text('保留原文换行'),
                  subtitle: const Text('影响快速翻译和文章翻译，保护段落、列表和代码块的可读性'),
                  value: preferences.preserveLineBreaks,
                  onChanged: (value) {
                    unawaited(
                      onChanged(
                        preferences.copyWith(preserveLineBreaks: value),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AboutYixueDialog extends StatelessWidget {
  const _AboutYixueDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('译学 · 使用方法与声明'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _AboutSection(
                title: '关于译学',
                body: '译学由花鱼鱼设计，初衷是让更多人免费使用可靠、尊重隐私的翻译与学习工具。标语：让世界可以理解。',
              ),
              _AboutSection(
                title: '创作者声明与授权边界',
                body: '创作者：花鱼鱼。译学坚持免费、隐私优先和帮助更多人学习的初衷。未经创作者书面授权，不得将译学品牌、Logo、官方主题或完整产品包装用于商业获利、冒充自有产品或删除署名；第三方模型、词典、字体和素材仍须遵守各自许可证与使用条款。',
              ),
              _AboutSection(
                title: '快速使用',
                body: '在快速翻译输入文字，按 Enter 或点击翻译；右侧可查询本地词典、查看例句、收藏单词和恢复历史。需要更高质量时，请在模型与服务中选择已经验证的模型。',
              ),
              _AboutSection(
                title: '本地与网络边界',
                body: '默认使用本地模型，文章、历史、词典和学习记录保存在你选择的数据目录。只有主动选择 API 模型时，文本才会发送给对应服务；API 密钥由系统安全存储管理。',
              ),
              _AboutSection(
                title: '模型与许可',
                body: '随包英汉翻译模型及其运行时保留原作者、来源和许可证记录。已发现的通用模型不等于已经接入或通过翻译质量验证，模型页面会分别显示候选、已校验和当前使用状态。',
              ),
              _AboutSection(
                title: '用户准则',
                body: '请遵守当地法律、第三方内容许可和模型使用条款。译学不承诺机器译文在所有专业场景中无误，正式工作请人工复核；用户的私密数据不会默认进入训练集。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text(body),
        ],
      ),
    );
  }
}

class _TerminologySettingsCard extends StatelessWidget {
  const _TerminologySettingsCard({
    required this.controller,
    required this.onChanged,
  });

  final TranslationTerminologyController? controller;
  final Future<void> Function(TranslationTerminology value) onChanged;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return const _SettingsCard(
        icon: Icons.spellcheck_rounded,
        title: '专业术语',
        value: '本地规则未连接',
        detail: '可为固定词汇指定你希望使用的译法。',
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _SettingsCard(
        icon: Icons.spellcheck_rounded,
        title: '专业术语',
        value: '${controller.value.rules.length} 条本地规则',
        detail: '固定专业词汇译法，优先应用于快速翻译并保存在本地。',
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _TerminologyDialog(
            initial: controller.value,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _TerminologyDialog extends StatefulWidget {
  const _TerminologyDialog({required this.initial, required this.onChanged});

  final TranslationTerminology initial;
  final Future<void> Function(TranslationTerminology value) onChanged;

  @override
  State<_TerminologyDialog> createState() => _TerminologyDialogState();
}

class _TerminologyDialogState extends State<_TerminologyDialog> {
  late List<TranslationTermRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = [...widget.initial.rules];
  }

  Future<void> _save(List<TranslationTermRule> rules) async {
    setState(() => _rules = rules);
    await widget.onChanged(TranslationTerminology(List.unmodifiable(rules)));
  }

  Future<void> _addRule([TranslationTermRule? existing]) async {
    final source = TextEditingController(text: existing?.source);
    final target = TextEditingController(text: existing?.target);
    var direction =
        existing?.direction ?? TerminologyDirection.englishToChinese;
    final result = await showDialog<TranslationTermRule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: Text(existing == null ? '新增术语规则' : '编辑术语规则'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<TerminologyDirection>(
                  initialValue: direction,
                  decoration: const InputDecoration(labelText: '翻译方向'),
                  items: const [
                    DropdownMenuItem(
                      value: TerminologyDirection.englishToChinese,
                      child: Text('英译中'),
                    ),
                    DropdownMenuItem(
                      value: TerminologyDirection.chineseToEnglish,
                      child: Text('中译英'),
                    ),
                  ],
                  onChanged: (value) => setLocalState(() => direction = value!),
                ),
                TextField(
                  controller: source,
                  decoration: const InputDecoration(labelText: '原词'),
                ),
                TextField(
                  controller: target,
                  decoration: const InputDecoration(labelText: '固定译法'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (source.text.trim().isEmpty || target.text.trim().isEmpty) {
                  return;
                }
                Navigator.pop(
                  context,
                  TranslationTermRule(
                    id:
                        existing?.id ??
                        'term-${DateTime.now().microsecondsSinceEpoch}',
                    source: source.text.trim(),
                    target: target.text.trim(),
                    direction: direction,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    source.dispose();
    target.dispose();
    if (result == null || !mounted) return;
    final next = [..._rules];
    final index = next.indexWhere((rule) => rule.id == result.id);
    if (index >= 0) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _save(next);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('专业术语'),
    content: SizedBox(
      width: 560,
      child: _rules.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有规则。添加后，快速翻译会优先使用你的固定译法。'),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: _rules.length,
              itemBuilder: (context, index) {
                final rule = _rules[index];
                return ListTile(
                  title: Text('${rule.source}  →  ${rule.target}'),
                  subtitle: Text(
                    rule.direction == TerminologyDirection.englishToChinese
                        ? '英译中'
                        : '中译英',
                  ),
                  onTap: () => _addRule(rule),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _save([..._rules]..removeAt(index)),
                  ),
                );
              },
            ),
    ),
    actions: [
      TextButton(onPressed: () => _addRule(), child: const Text('新增规则')),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

class _DictionarySourcesSettingsCard extends StatelessWidget {
  const _DictionarySourcesSettingsCard({
    required this.controller,
    required this.onChanged,
  });

  final DictionaryPreferencesController? controller;
  final Future<void> Function(DictionaryPreferences value) onChanged;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return const _SettingsCard(
        icon: Icons.library_books_outlined,
        title: '词典来源',
        value: '本地词典未连接',
        detail: '可管理内置词典和你导入的授权词典。',
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final sources = controller.value.sources;
        final enabled = sources.where((source) => source.enabled).length;
        return _SettingsCard(
          icon: Icons.library_books_outlined,
          title: '词典来源',
          value: '$enabled/${sources.length} 个来源已启用',
          detail: '顺序越靠前优先级越高；关闭后不参与快速翻译和学习查词。',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _DictionarySourcesDialog(
              initial: controller.value,
              onChanged: onChanged,
            ),
          ),
        );
      },
    );
  }
}

class _DictionarySourcesDialog extends StatefulWidget {
  const _DictionarySourcesDialog({
    required this.initial,
    required this.onChanged,
  });

  final DictionaryPreferences initial;
  final Future<void> Function(DictionaryPreferences value) onChanged;

  @override
  State<_DictionarySourcesDialog> createState() =>
      _DictionarySourcesDialogState();
}

class _DictionarySourcesDialogState extends State<_DictionarySourcesDialog> {
  late DictionaryPreferences _preferences;

  @override
  void initState() {
    super.initState();
    _preferences = widget.initial;
  }

  Future<void> _update(DictionaryPreferences value) async {
    setState(() => _preferences = value);
    await widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final sources = _preferences.sources;
    return AlertDialog(
      title: const Text('词典来源'),
      content: SizedBox(
        width: 620,
        child: sources.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂未登记词典来源。你可以从快速翻译右侧导入授权词典包。'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 15,
                      child: Text('${index + 1}'),
                    ),
                    title: Text(source.displayName),
                    subtitle: Text('${source.id} · ${source.license}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '上移优先级',
                          onPressed: index == 0
                              ? null
                              : () => _update(_preferences.move(source.id, -1)),
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        IconButton(
                          tooltip: '下移优先级',
                          onPressed: index == sources.length - 1
                              ? null
                              : () => _update(_preferences.move(source.id, 1)),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                        Switch.adaptive(
                          key: ValueKey('dictionary-source-${source.id}'),
                          value: source.enabled,
                          onChanged: (enabled) => _update(
                            _preferences.setEnabled(source.id, enabled),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: _activeBlue),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 7),
                    Text(value, style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                      detail,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 12),
                const Icon(Icons.chevron_right_rounded),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DataManagementDialog extends StatefulWidget {
  const _DataManagementDialog({
    required this.coreFactory,
    required this.clearPreferenceFile,
    required this.exportData,
    this.dataPath,
    this.storagePolicyStore,
    this.storageUsageLoader,
  });

  final AppCore Function()? coreFactory;
  final Future<void> Function(String category) clearPreferenceFile;
  final Future<String?> Function() exportData;
  final String? dataPath;
  final yixue_storage.StoragePolicyStore? storagePolicyStore;
  final StorageUsageLoader? storageUsageLoader;

  @override
  State<_DataManagementDialog> createState() => _DataManagementDialogState();
}

class _DataManagementDialogState extends State<_DataManagementDialog> {
  static const categories = <({String id, String title, String detail})>[
    (
      id: 'translation_history',
      title: '翻译历史',
      detail: '清除快速翻译、截屏翻译的文字历史与对应首页活动；历史不包含截图。',
    ),
    (id: 'reading_documents', title: '阅读文档', detail: '清除导入文章、阅读位置和已保存译文。'),
    (id: 'learning_records', title: '学习记录', detail: '清除学习题目与作答记录。'),
    (id: 'dictionary', title: '词典与收藏', detail: '清除本地词条和已收藏单词。'),
    (id: 'activity', title: '活动统计', detail: '清除首页的学习、阅读和翻译统计。'),
    (
      id: 'file_appearance_preferences',
      title: '外观主题配置',
      detail: '清除自定义主题和外观选择文件；下次启动恢复默认外观。',
    ),
    (
      id: 'file_translation_preferences',
      title: '翻译偏好配置',
      detail: '清除方向、语气和换行偏好；下次启动恢复默认设置。',
    ),
    (id: 'file_terminology', title: '专业术语规则', detail: '清除你保存的固定译法规则。'),
    (
      id: 'file_ui_preferences',
      title: '界面偏好配置',
      detail: '清除侧栏展开/收起选择；下次启动恢复默认展开。',
    ),
    (
      id: 'file_dictionary_preferences',
      title: '词典来源配置',
      detail: '清除词典来源启停和优先级；词典词条本身不会删除。',
    ),
    (
      id: 'file_home_plan',
      title: '首页学习计划',
      detail: '清除首页目标、每日任务和学习日安排；历史活动统计不会删除。',
    ),
    (
      id: 'file_textbook_courses',
      title: '教材与课程包',
      detail: '清除导入的教材课程包和教材学习进度；不会删除内置自写课程。',
    ),
  ];

  var _storagePolicy = yixue_storage.StoragePolicy.unlimited();
  var _storageUsage = yixue_storage.StorageUsageData();
  var _storagePolicyLoading = true;
  var _storageUsageLoading = true;

  String get _dataPath =>
      widget.dataPath ??
      resolveAppDataPath(
        configuredDirectory: Platform.environment['YIXUE_DATA_DIR'],
        executablePath: Platform.resolvedExecutable,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_restoreStoragePolicy());
    unawaited(_refreshStorageUsage());
  }

  Future<void> _restoreStoragePolicy() async {
    yixue_storage.StoragePolicy? saved;
    try {
      saved = await widget.storagePolicyStore?.read();
    } catch (_) {
      saved = null;
    }
    if (!mounted) return;
    setState(() {
      _storagePolicy = saved ?? yixue_storage.StoragePolicy.unlimited();
      _storagePolicyLoading = false;
    });
  }

  Future<void> _refreshStorageUsage() async {
    try {
      final injected = widget.storageUsageLoader;
      if (injected != null) {
        final usage = await injected();
        if (!mounted) return;
        setState(() {
          _storageUsage = usage;
          _storageUsageLoading = false;
        });
        return;
      }
      final core = widget.coreFactory?.call();
      try {
        if (core is StorageUsageCore) {
          final usage = (core as StorageUsageCore).storageUsage();
          if (!mounted) return;
          setState(() {
            _storageUsage = usage;
            _storageUsageLoading = false;
          });
          return;
        }
      } finally {
        core?.dispose();
      }
    } catch (_) {
      // An older core may not expose usage yet. The manager remains usable and
      // never deletes data silently.
    }
    if (mounted) setState(() => _storageUsageLoading = false);
  }

  Future<void> _editStorageQuota(yixue_storage.StorageCategory category) async {
    final result = await showDialog<_StorageQuotaResult>(
      context: context,
      builder: (_) => _StorageQuotaDialog(
        category: category,
        initialQuota: _storagePolicy.quotaFor(category),
      ),
    );
    if (result == null || !mounted) return;
    final previous = _storagePolicy;
    final next = previous.setQuota(category, result.bytes);
    setState(() => _storagePolicy = next);
    try {
      await widget.storagePolicyStore?.write(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${category.title}容量已设置为${yixue_storage.formatStorageQuota(result.bytes)}',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _storagePolicy = previous);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('容量策略保存失败：$error')));
    }
  }

  Widget _buildStoragePolicySection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '存储容量策略',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text('默认所有类别不限制。容量由你决定；本轮先保存策略并显示占用，后续写入模块接入时会给出提示，不会自动删除旧数据。'),
        const SizedBox(height: 4),
        Text(
          '下方占用是 SQLite 单文件内的逻辑估算，不等同于磁盘分区精确占用。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '当前数据库内容逻辑估算合计：${yixue_storage.formatStorageBytes(_storageUsage.totalBytes)}',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (_storagePolicyLoading || _storageUsageLoading) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: 8),
        for (final category in yixue_storage.StorageCategory.values)
          _StorageQuotaTile(
            category: category,
            usedBytes: _storageUsage.forCategory(category),
            quotaBytes: _storagePolicy.quotaFor(category),
            onEdit: () => _editStorageQuota(category),
          ),
      ],
    );
  }

  Future<void> _openFolder() async {
    final directory = Directory(_dataPath);
    if (!await directory.exists()) await directory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [directory.path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [directory.path]);
    } else {
      await Process.start('xdg-open', [directory.path]);
    }
  }

  Future<void> _export() async {
    try {
      final path = await widget.exportData();
      if (path != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('本地数据已导出到：$path')));
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出位置无效：${error.message}')));
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：${error.message}')));
      }
    }
  }

  Future<void> _clear(
    ({String id, String title, String detail}) category,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除${category.title}？'),
        content: Text('${category.detail}\n\n此操作只影响本机数据，模型配置不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (category.id.startsWith('file_')) {
      try {
        await widget.clearPreferenceFile(category.id.substring('file_'.length));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('${category.title}已清除')));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('清除失败：$error')));
        }
      }
      return;
    }
    final core = widget.coreFactory?.call();
    if (core is! LocalDataCore) {
      core?.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前运行核心不支持本地数据管理')));
      }
      return;
    }
    final dataCore = core as LocalDataCore;
    final appCore = core;
    try {
      dataCore.clearUserData(category.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${category.title}已清除')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清除失败：$error')));
      }
    } finally {
      appCore!.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本地数据管理'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('所有内容默认保存在本机，不会自动上传。'),
              const SizedBox(height: 12),
              SelectableText(
                '数据位置：$_dataPath',
                style: const TextStyle(fontSize: 12),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _openFolder,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('打开数据文件夹'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('export-local-data'),
                    onPressed: _export,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('导出本地数据'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildStoragePolicySection(context),
              const Divider(),
              for (final category in categories)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(category.title),
                  subtitle: Text(category.detail),
                  trailing: TextButton(
                    onPressed: () => _clear(category),
                    child: const Text('删除'),
                  ),
                ),
              const SizedBox(height: 8),
              const Text(
                '模型文件和 API 密钥不在上述删除范围内。API 密钥由系统安全存储单独管理。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _StorageQuotaTile extends StatelessWidget {
  const _StorageQuotaTile({
    required this.category,
    required this.usedBytes,
    required this.quotaBytes,
    required this.onEdit,
  });

  final yixue_storage.StorageCategory category;
  final int usedBytes;
  final int? quotaBytes;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('storage-quota-${category.id}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(category.title),
      subtitle: Text(
        '${category.description}\n占用估算：${yixue_storage.formatStorageBytes(usedBytes)}  /  ${yixue_storage.formatStorageQuota(quotaBytes)}',
      ),
      trailing: TextButton(
        key: ValueKey('storage-quota-edit-${category.id}'),
        onPressed: onEdit,
        child: const Text('设置'),
      ),
    );
  }
}

class _StorageQuotaResult {
  const _StorageQuotaResult(this.bytes);

  final int? bytes;
}

enum _StorageQuotaMode { unlimited, preset, custom }

class _StorageQuotaDialog extends StatefulWidget {
  const _StorageQuotaDialog({
    required this.category,
    required this.initialQuota,
  });

  final yixue_storage.StorageCategory category;
  final int? initialQuota;

  @override
  State<_StorageQuotaDialog> createState() => _StorageQuotaDialogState();
}

class _StorageQuotaDialogState extends State<_StorageQuotaDialog> {
  static const _megabyte = 1024 * 1024;
  static const _maxCustomMegabytes = 16 * 1024 * 1024;
  static const _presets = <int>[
    64 * _megabyte,
    256 * _megabyte,
    1024 * _megabyte,
    4 * 1024 * _megabyte,
  ];

  late _StorageQuotaMode _mode;
  late int _preset;
  late final TextEditingController _customController;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuota;
    if (initial == null) {
      _mode = _StorageQuotaMode.unlimited;
      _preset = _presets.first;
    } else if (_presets.contains(initial)) {
      _mode = _StorageQuotaMode.preset;
      _preset = initial;
    } else {
      _mode = _StorageQuotaMode.custom;
      _preset = _presets.first;
    }
    _customController = TextEditingController(
      text: initial == null ? '' : ((initial / _megabyte).ceil()).toString(),
    );
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _save() {
    switch (_mode) {
      case _StorageQuotaMode.unlimited:
        Navigator.of(context).pop(const _StorageQuotaResult(null));
      case _StorageQuotaMode.preset:
        Navigator.of(context).pop(_StorageQuotaResult(_preset));
      case _StorageQuotaMode.custom:
        final megabytes = int.tryParse(_customController.text.trim());
        if (megabytes == null ||
            megabytes < 0 ||
            megabytes > _maxCustomMegabytes) {
          setState(() => _errorMessage = '请输入 0 到 16 TB 之间的整数 MB 容量。');
          return;
        }
        Navigator.of(context).pop(_StorageQuotaResult(megabytes * _megabyte));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('设置${widget.category.title}容量'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.category.description),
              const SizedBox(height: 8),
              SegmentedButton<_StorageQuotaMode>(
                segments: const [
                  ButtonSegment(
                    value: _StorageQuotaMode.unlimited,
                    label: Text('不限制'),
                  ),
                  ButtonSegment(
                    value: _StorageQuotaMode.preset,
                    label: Text('预设'),
                  ),
                  ButtonSegment(
                    value: _StorageQuotaMode.custom,
                    label: Text('自定义容量'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) {
                  setState(() => _mode = selection.single);
                },
              ),
              const SizedBox(height: 6),
              Text(
                _mode == _StorageQuotaMode.unlimited
                    ? '默认选项，不自动清理数据。'
                    : _mode == _StorageQuotaMode.preset
                    ? '选择一个常用容量上限。'
                    : '按 MB 输入，最大 16 TB。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_mode == _StorageQuotaMode.preset)
                DropdownButtonFormField<int>(
                  key: const ValueKey('storage-quota-preset'),
                  initialValue: _preset,
                  decoration: const InputDecoration(labelText: '预设容量'),
                  items: [
                    for (final value in _presets)
                      DropdownMenuItem(
                        value: value,
                        child: Text(yixue_storage.formatStorageBytes(value)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _preset = value);
                  },
                ),
              if (_mode == _StorageQuotaMode.custom)
                TextField(
                  key: const ValueKey('storage-quota-custom-mb'),
                  controller: _customController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                  ),
                  decoration: const InputDecoration(
                    labelText: '容量（MB）',
                    suffixText: 'MB',
                  ),
                ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('storage-quota-save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _UpdateInfoDialog extends StatelessWidget {
  const _UpdateInfoDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('更新与安装'),
    content: const SizedBox(
      width: 560,
      child: Text(
        '当前预览版采用完整本地安装包，模型和推理运行时随包提供，不要求额外安装 Ollama 或 Python。\n\n'
        '更新时只替换程序、运行时和官方模型文件，不覆盖 D 盘 user-data 中的翻译历史、词典、术语、学习记录和外观配置。正式版将增加带哈希和签名校验的增量更新。',
      ),
    ),
    actions: [
      TextButton(
        onPressed: Navigator.of(context).pop,
        child: const Text('知道了'),
      ),
    ],
  );
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Text(detail, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _NotIntegratedPage extends StatelessWidget {
  const _NotIntegratedPage({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            key: const ValueKey('reader-placeholder-card'),
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chrome_reader_mode_outlined,
                  size: 36,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(height: 20),
                Text(
                  '暂未接入',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      key: ValueKey('sidebar-brand-mark'),
      width: 54,
      height: 54,
      child: YixueBrandMark(),
    );
  }
}
