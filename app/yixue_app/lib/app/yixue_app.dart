import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/windows_app_close_controller.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_daily_plan_store.dart';
import 'package:yixue_app/core/home_focus_session_store.dart';
import 'package:yixue_app/core/home_user_profile_store.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/learning_speech_service.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/storage_policy.dart';
import 'package:yixue_app/core/ui_preference_store.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';
import 'package:yixue_app/features/shell/home_shell.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/vocabulary/favorite_words_workspace.dart';

class YixueApp extends StatefulWidget {
  const YixueApp({
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
    this.translationAnnotationLoader,
    this.translationAnnotationSaver,
    this.dictionaryLookupLoader,
    this.favoriteWordPageLoader,
    this.favoriteWordSetter,
    this.wordAnnotationLoader,
    this.wordAnnotationSaver,
    this.appearanceController,
    this.appearancePreferenceStore,
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
    this.showLaunchAnimation = false,
    this.launchVariant = YixueLaunchVariant.full,
    this.clock = DateTime.now,
  });

  final String? appDataDirectory;
  final SubtitleSessionStore? subtitleSessionStore;
  final AppCore Function()? coreFactory;
  final ClipboardReader? clipboardReader;
  final QuickTranslationRunner? quickTranslationRunner;
  final QuickTranslationRunnerWithOptions? quickTranslationRunnerWithOptions;
  final QuickTranslationCanceller? quickTranslationCanceller;
  final Future<String> Function(String text)? learningSummaryRunner;
  final LearningSpeechRecognizer? learningSpeechRecognizer;
  final LearningTextbookStore? textbookStore;
  final Future<List<TranslationHistoryEntryData>> Function()?
  translationHistoryLoader;
  final TranslationHistoryPageLoader? translationHistoryPageLoader;
  final TranslationHistoryExporter? translationHistoryExporter;
  final TranslationAnnotationLoader? translationAnnotationLoader;
  final TranslationAnnotationSaver? translationAnnotationSaver;
  final DictionaryLookupLoader? dictionaryLookupLoader;
  final FavoriteWordPageLoader? favoriteWordPageLoader;
  final Future<void> Function(String word, bool favorite)? favoriteWordSetter;
  final WordAnnotationLoader? wordAnnotationLoader;
  final WordAnnotationSaver? wordAnnotationSaver;
  final AppearanceController? appearanceController;
  final AppearancePreferenceStore? appearancePreferenceStore;
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
  final StoragePolicyStore? storagePolicyStore;
  final StorageUsageLoader? storageUsageLoader;
  final bool showLaunchAnimation;
  final YixueLaunchVariant launchVariant;
  final DateTime Function() clock;

  @override
  State<YixueApp> createState() => _YixueAppState();
}

class _YixueAppState extends State<YixueApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final AppearanceController _appearance;
  late final WindowsAppCloseController _windowCloseController;
  late final bool _ownsAppearance;
  late final TranslationPreferencesController _translationPreferences;
  late final bool _ownsTranslationPreferences;
  late final TranslationTerminologyController _translationTerminology;
  late final bool _ownsTranslationTerminology;
  late final DictionaryPreferencesController _dictionaryPreferences;
  late final bool _ownsDictionaryPreferences;

  @override
  void initState() {
    super.initState();
    final appDataDirectory = widget.appDataDirectory;
    AppExitCleanupRegistry.configureDiagnosticFile(
      appDataDirectory == null
          ? null
          : File(
              [
                appDataDirectory,
                'diagnostics',
                'dart-exit-cleanup.log',
              ].join(Platform.pathSeparator),
            ),
    );
    _windowCloseController = WindowsAppCloseController(
      navigatorKey: _navigatorKey,
      processExit: Platform.isWindows ? () => exit(0) : null,
      nativeCleanupWatchdogSignal: Platform.isWindows
          ? signalWindowsUiCleanupWatchdogStart
          : null,
      preferenceStore: widget.appDataDirectory == null
          ? null
          : FileWindowsAppClosePreferenceStore(
              File(
                '${widget.appDataDirectory}${Platform.pathSeparator}windows-close-preference.json',
              ),
            ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_attachWindowCloseController());
    });
    _ownsAppearance = widget.appearanceController == null;
    _appearance = widget.appearanceController ?? AppearanceController();
    widget.appearancePreferenceStore?.read().then((saved) {
      if (saved == null || !mounted) return;
      _appearance.restore(saved);
    });
    _appearance.addListener(_saveAppearance);
    _ownsTranslationPreferences =
        widget.translationPreferencesController == null;
    _translationPreferences =
        widget.translationPreferencesController ??
        TranslationPreferencesController();
    _ownsTranslationTerminology =
        widget.translationTerminologyController == null;
    _translationTerminology =
        widget.translationTerminologyController ??
        TranslationTerminologyController();
    widget.translationTerminologyStore?.read().then((saved) {
      if (saved == null || !mounted) return;
      _translationTerminology.update(saved);
    });
    _ownsDictionaryPreferences = widget.dictionaryPreferencesController == null;
    _dictionaryPreferences =
        widget.dictionaryPreferencesController ??
        DictionaryPreferencesController();
    widget.dictionaryPreferencesStore?.read().then((saved) {
      if (saved == null || !mounted) return;
      _dictionaryPreferences.update(saved);
    });
  }

  Future<void> _attachWindowCloseController() async {
    try {
      await _windowCloseController.attach();
    } catch (error, stackTrace) {
      debugPrint('Could not enable the Windows close prompt: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void dispose() {
    unawaited(_windowCloseController.detach());
    _appearance.removeListener(_saveAppearance);
    if (_ownsAppearance) _appearance.dispose();
    if (_ownsTranslationPreferences) _translationPreferences.dispose();
    if (_ownsTranslationTerminology) _translationTerminology.dispose();
    if (_ownsDictionaryPreferences) _dictionaryPreferences.dispose();
    super.dispose();
  }

  void _saveAppearance() {
    final store = widget.appearancePreferenceStore;
    if (store != null) {
      store.write(_appearance.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appearance,
      builder: (context, _) {
        final appearance = _appearance.value;
        final dark =
            appearance.customTheme?.isDark == true ||
            appearance.officialTheme == YixueOfficialTheme.dark;
        return MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          title: '译学',
          theme: appearance.customTheme != null
              ? AppTheme.custom(appearance.customTheme!)
              : appearance.officialTheme == YixueOfficialTheme.vitality
              ? AppTheme.vitality()
              : AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          themeAnimationDuration: switch (appearance.motionLevel) {
            YixueMotionLevel.full => const Duration(milliseconds: 220),
            YixueMotionLevel.reduced => const Duration(milliseconds: 90),
            YixueMotionLevel.off => Duration.zero,
          },
          home: LaunchGate(
            motionLevel: widget.showLaunchAnimation
                ? appearance.motionLevel
                : YixueMotionLevel.off,
            variant: widget.launchVariant,
            child: HomeShell(
              requestHostQuit: _windowCloseController.requestQuit,
              restoreHostWindow: _windowCloseController.restoreMainWindow,
              appDataDirectory: widget.appDataDirectory,
              subtitleSessionStore: widget.subtitleSessionStore,
              coreFactory: widget.coreFactory,
              clipboardReader: widget.clipboardReader,
              quickTranslationRunner: widget.quickTranslationRunner,
              quickTranslationRunnerWithOptions:
                  widget.quickTranslationRunnerWithOptions,
              quickTranslationCanceller: widget.quickTranslationCanceller,
              learningSummaryRunner: widget.learningSummaryRunner,
              learningSpeechRecognizer: widget.learningSpeechRecognizer,
              textbookStore: widget.textbookStore,
              translationHistoryLoader: widget.translationHistoryLoader,
              translationHistoryPageLoader: widget.translationHistoryPageLoader,
              translationHistoryExporter: widget.translationHistoryExporter,
              translationAnnotationLoader: widget.translationAnnotationLoader,
              translationAnnotationSaver: widget.translationAnnotationSaver,
              dictionaryLookupLoader: widget.dictionaryLookupLoader,
              favoriteWordPageLoader: widget.favoriteWordPageLoader,
              favoriteWordSetter: widget.favoriteWordSetter,
              wordAnnotationLoader: widget.wordAnnotationLoader,
              wordAnnotationSaver: widget.wordAnnotationSaver,
              appearanceController: _appearance,
              sidebarPreferenceStore: widget.sidebarPreferenceStore,
              translationPreferencesStore: widget.translationPreferencesStore,
              translationPreferencesController: _translationPreferences,
              translationTerminologyStore: widget.translationTerminologyStore,
              translationTerminologyController: _translationTerminology,
              dictionaryPreferencesStore: widget.dictionaryPreferencesStore,
              dictionaryPreferencesController: _dictionaryPreferences,
              homePlanStore: widget.homePlanStore,
              homeDailyPlanStore: widget.homeDailyPlanStore,
              homeFocusSessionStore: widget.homeFocusSessionStore,
              homeUserProfileStore: widget.homeUserProfileStore,
              learningStore: widget.learningStore,
              storagePolicyStore: widget.storagePolicyStore,
              storageUsageLoader: widget.storageUsageLoader,
              clock: widget.clock,
            ),
          ),
        );
      },
    );
  }
}
