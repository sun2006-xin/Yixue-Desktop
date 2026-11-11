import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/provider_configuration_service.dart'
    show isLocalCompatibleEndpoint;
import 'package:yixue_app/core/supported_language_code.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_request_options.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/core/translation_format_protector.dart';
import 'package:yixue_app/core/translation_quality_guard.dart';

typedef HttpClientFactory = http.Client Function();
typedef QuickTranslationRunner = Future<String> Function(
  String sourceText,
  TranslationDirection direction,
);
typedef QuickTranslationRunnerWithOptions = Future<String> Function(
  String sourceText,
  TranslationDirection direction,
  TranslationRequestOptions options,
);

enum TranslationDirection {
  englishToChinese(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'zh',
    sourceLanguage: 'english',
    targetLanguage: 'chinese',
    sourceLabel: '英语（自动检测）',
    targetLabel: '中文（简体）',
    actionLabel: '英译中',
  ),
  chineseToEnglish(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'en',
    sourceLanguage: 'chinese',
    targetLanguage: 'english',
    sourceLabel: '中文（简体）',
    targetLabel: '英语',
    actionLabel: '中译英',
  ),
  englishToJapanese(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'ja',
    sourceLanguage: 'english',
    targetLanguage: 'japanese',
    sourceLabel: '英语',
    targetLabel: '日语',
    actionLabel: '英译日',
  ),
  japaneseToEnglish(
    sourceLanguageCode: 'ja',
    targetLanguageCode: 'en',
    sourceLanguage: 'japanese',
    targetLanguage: 'english',
    sourceLabel: '日语',
    targetLabel: '英语',
    actionLabel: '日译英',
  ),
  englishToKorean(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'ko',
    sourceLanguage: 'english',
    targetLanguage: 'korean',
    sourceLabel: '英语',
    targetLabel: '韩语',
    actionLabel: '英译韩',
  ),
  koreanToEnglish(
    sourceLanguageCode: 'ko',
    targetLanguageCode: 'en',
    sourceLanguage: 'korean',
    targetLanguage: 'english',
    sourceLabel: '韩语',
    targetLabel: '英语',
    actionLabel: '韩译英',
  ),
  chineseToJapanese(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'ja',
    sourceLanguage: 'chinese',
    targetLanguage: 'japanese',
    sourceLabel: '中文（简体）',
    targetLabel: '日语',
    actionLabel: '中译日',
  ),
  japaneseToChinese(
    sourceLanguageCode: 'ja',
    targetLanguageCode: 'zh',
    sourceLanguage: 'japanese',
    targetLanguage: 'chinese',
    sourceLabel: '日语',
    targetLabel: '中文（简体）',
    actionLabel: '日译中',
  ),
  chineseToKorean(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'ko',
    sourceLanguage: 'chinese',
    targetLanguage: 'korean',
    sourceLabel: '中文（简体）',
    targetLabel: '韩语',
    actionLabel: '中译韩',
  ),
  koreanToChinese(
    sourceLanguageCode: 'ko',
    targetLanguageCode: 'zh',
    sourceLanguage: 'korean',
    targetLanguage: 'chinese',
    sourceLabel: '韩语',
    targetLabel: '中文（简体）',
    actionLabel: '韩译中',
  ),
  japaneseToKorean(
    sourceLanguageCode: 'ja',
    targetLanguageCode: 'ko',
    sourceLanguage: 'japanese',
    targetLanguage: 'korean',
    sourceLabel: '日语',
    targetLabel: '韩语',
    actionLabel: '日译韩',
  ),
  koreanToJapanese(
    sourceLanguageCode: 'ko',
    targetLanguageCode: 'ja',
    sourceLanguage: 'korean',
    targetLanguage: 'japanese',
    sourceLabel: '韩语',
    targetLabel: '日语',
    actionLabel: '韩译日',
  ),
  englishToSpanish(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'es',
    sourceLanguage: 'english',
    targetLanguage: 'spanish',
    sourceLabel: '英语',
    targetLabel: '西班牙语',
    actionLabel: '英译西',
  ),
  spanishToEnglish(
    sourceLanguageCode: 'es',
    targetLanguageCode: 'en',
    sourceLanguage: 'spanish',
    targetLanguage: 'english',
    sourceLabel: '西班牙语',
    targetLabel: '英语',
    actionLabel: '西译英',
  ),
  chineseToSpanish(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'es',
    sourceLanguage: 'chinese',
    targetLanguage: 'spanish',
    sourceLabel: '中文（简体）',
    targetLabel: '西班牙语',
    actionLabel: '中译西',
  ),
  spanishToChinese(
    sourceLanguageCode: 'es',
    targetLanguageCode: 'zh',
    sourceLanguage: 'spanish',
    targetLanguage: 'chinese',
    sourceLabel: '西班牙语',
    targetLabel: '中文（简体）',
    actionLabel: '西译中',
  ),
  englishToFrench(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'fr',
    sourceLanguage: 'english',
    targetLanguage: 'french',
    sourceLabel: '英语',
    targetLabel: '法语',
    actionLabel: '英译法',
  ),
  frenchToEnglish(
    sourceLanguageCode: 'fr',
    targetLanguageCode: 'en',
    sourceLanguage: 'french',
    targetLanguage: 'english',
    sourceLabel: '法语',
    targetLabel: '英语',
    actionLabel: '法译英',
  ),
  chineseToFrench(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'fr',
    sourceLanguage: 'chinese',
    targetLanguage: 'french',
    sourceLabel: '中文（简体）',
    targetLabel: '法语',
    actionLabel: '中译法',
  ),
  frenchToChinese(
    sourceLanguageCode: 'fr',
    targetLanguageCode: 'zh',
    sourceLanguage: 'french',
    targetLanguage: 'chinese',
    sourceLabel: '法语',
    targetLabel: '中文（简体）',
    actionLabel: '法译中',
  ),
  englishToGerman(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'de',
    sourceLanguage: 'english',
    targetLanguage: 'german',
    sourceLabel: '英语',
    targetLabel: '德语',
    actionLabel: '英译德',
  ),
  germanToEnglish(
    sourceLanguageCode: 'de',
    targetLanguageCode: 'en',
    sourceLanguage: 'german',
    targetLanguage: 'english',
    sourceLabel: '德语',
    targetLabel: '英语',
    actionLabel: '德译英',
  ),
  chineseToGerman(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'de',
    sourceLanguage: 'chinese',
    targetLanguage: 'german',
    sourceLabel: '中文（简体）',
    targetLabel: '德语',
    actionLabel: '中译德',
  ),
  germanToChinese(
    sourceLanguageCode: 'de',
    targetLanguageCode: 'zh',
    sourceLanguage: 'german',
    targetLanguage: 'chinese',
    sourceLabel: '德语',
    targetLabel: '中文（简体）',
    actionLabel: '德译中',
  ),
  englishToPortuguese(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'pt',
    sourceLanguage: 'english',
    targetLanguage: 'portuguese',
    sourceLabel: '英语',
    targetLabel: '葡萄牙语',
    actionLabel: '英译葡',
  ),
  portugueseToEnglish(
    sourceLanguageCode: 'pt',
    targetLanguageCode: 'en',
    sourceLanguage: 'portuguese',
    targetLanguage: 'english',
    sourceLabel: '葡萄牙语',
    targetLabel: '英语',
    actionLabel: '葡译英',
  ),
  chineseToPortuguese(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'pt',
    sourceLanguage: 'chinese',
    targetLanguage: 'portuguese',
    sourceLabel: '中文（简体）',
    targetLabel: '葡萄牙语',
    actionLabel: '中译葡',
  ),
  portugueseToChinese(
    sourceLanguageCode: 'pt',
    targetLanguageCode: 'zh',
    sourceLanguage: 'portuguese',
    targetLanguage: 'chinese',
    sourceLabel: '葡萄牙语',
    targetLabel: '中文（简体）',
    actionLabel: '葡译中',
  ),
  englishToRussian(
    sourceLanguageCode: 'en',
    targetLanguageCode: 'ru',
    sourceLanguage: 'english',
    targetLanguage: 'russian',
    sourceLabel: '英语',
    targetLabel: '俄语',
    actionLabel: '英译俄',
  ),
  russianToEnglish(
    sourceLanguageCode: 'ru',
    targetLanguageCode: 'en',
    sourceLanguage: 'russian',
    targetLanguage: 'english',
    sourceLabel: '俄语',
    targetLabel: '英语',
    actionLabel: '俄译英',
  ),
  chineseToRussian(
    sourceLanguageCode: 'zh',
    targetLanguageCode: 'ru',
    sourceLanguage: 'chinese',
    targetLanguage: 'russian',
    sourceLabel: '中文（简体）',
    targetLabel: '俄语',
    actionLabel: '中译俄',
  ),
  russianToChinese(
    sourceLanguageCode: 'ru',
    targetLanguageCode: 'zh',
    sourceLanguage: 'russian',
    targetLanguage: 'chinese',
    sourceLabel: '俄语',
    targetLabel: '中文（简体）',
    actionLabel: '俄译中',
  );

  const TranslationDirection({
    required this.sourceLanguageCode,
    required this.targetLanguageCode,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.sourceLabel,
    required this.targetLabel,
    required this.actionLabel,
  });

  /// Canonical language tags used by subtitle sessions and model catalogs.
  final String sourceLanguageCode;
  final String targetLanguageCode;

  /// Legacy English language names sent to existing translation Providers.
  final String sourceLanguage;
  final String targetLanguage;

  /// Localized display names for selectors and language metadata.
  String get sourceLanguageName => _languageName(sourceLanguageCode);
  String get targetLanguageName => _languageName(targetLanguageCode);

  final String sourceLabel;
  final String targetLabel;
  final String actionLabel;

  /// Pair hint retained for existing en-zh profiles and extended for catalogs.
  String get modelHint => '$sourceLanguageCode-$targetLanguageCode';

  /// Only the established English/Chinese directions use the built-in
  /// bilingual terminology rules. Other directions leave terms untouched.
  TerminologyDirection? get terminologyDirection => switch (this) {
    TranslationDirection.englishToChinese =>
      TerminologyDirection.englishToChinese,
    TranslationDirection.chineseToEnglish =>
      TerminologyDirection.chineseToEnglish,
    _ => null,
  };

  TranslationDirection get opposite => TranslationDirection.fromLanguageCodes(
    targetLanguageCode,
    sourceLanguageCode,
  )!;

  /// Resolves a supported non-identical pair from a language tag or legacy
  /// English name. Automatic (`auto`) and unknown (`und`) values are not
  /// routes; subtitle ASR must supply the detected language for each cue.
  static TranslationDirection? fromLanguageCodes(String source, String target) {
    final sourceCode = canonicalSupportedLanguageCode(source);
    final targetCode = canonicalSupportedLanguageCode(target);
    if (sourceCode == null ||
        targetCode == null ||
        sourceCode == targetCode ||
        (targetCode == 'zh' && isTraditionalChineseLanguageTag(target))) {
      return null;
    }
    for (final direction in TranslationDirection.values) {
      if (direction.sourceLanguageCode == sourceCode &&
          direction.targetLanguageCode == targetCode) {
        return direction;
      }
    }
    return null;
  }

  /// Lists target codes that have an explicit direction in this registry.
  ///
  /// Automatic source recognition can resolve to any registered direction,
  /// so its target list is the union of targets in the catalog. This reports
  /// product-level route coverage only; provider availability is resolved
  /// separately for the selected source/target pair.
  static List<String> targetLanguageCodesForSource(String source) {
    final normalizedSource = source.trim().toLowerCase();
    final directions = normalizedSource == 'auto'
        ? TranslationDirection.values
        : TranslationDirection.values.where(
            (direction) =>
                direction.sourceLanguageCode ==
                canonicalSupportedLanguageCode(source),
          );
    return List<String>.unmodifiable(
      directions.map((direction) => direction.targetLanguageCode).toSet(),
    );
  }

  static String _languageName(String code) => switch (code) {
    'en' => '英语',
    'zh' => '中文（简体）',
    'ja' => '日语',
    'ko' => '韩语',
    'es' => '西班牙语',
    'fr' => '法语',
    'de' => '德语',
    'pt' => '葡萄牙语',
    'ru' => '俄语',
    _ => code,
  };

  static TranslationDirection detect(
    String sourceText, {
    required TranslationDirection fallback,
  }) {
    var hanCharacters = 0;
    var latinLetters = 0;
    for (final rune in sourceText.runes) {
      if ((rune >= 0x3400 && rune <= 0x4DBF) ||
          (rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0xF900 && rune <= 0xFAFF)) {
        hanCharacters += 1;
      } else if ((rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A)) {
        latinLetters += 1;
      }
    }
    if (hanCharacters == 0 && latinLetters == 0) return fallback;
    return hanCharacters > 0 && hanCharacters >= latinLetters
        ? chineseToEnglish
        : englishToChinese;
  }
}

enum SubtitleTranslationRouteKind {
  localProfile,
  bundledLocal,
  remoteProfile,
  unavailable,
}

/// Provider choice captured for one live subtitle session.
///
/// The snapshot contains display-safe provider metadata only. Credentials stay
/// in the secure store and are resolved by the translation client at request
/// time; a missing or changed route fails instead of selecting another one.
final class SubtitleTranslationRouteSnapshot {
  const SubtitleTranslationRouteSnapshot._({
    required this.direction,
    required this.kind,
    this.profile,
    this.bundledModelPath,
    this.unavailableReasonCode,
  });

  final TranslationDirection direction;
  final SubtitleTranslationRouteKind kind;
  final ProviderProfileData? profile;
  final String? bundledModelPath;

  /// Stable error code for a route that was explicitly configured but cannot
  /// be used. This lets callers explain the actual repair instead of guessing.
  final String? unavailableReasonCode;
}

final class QuickTranslationService {
  QuickTranslationService({
    required this.coreFactory,
    required this.secrets,
    required this.httpClientFactory,
    DateTime Function()? now,
    this.idFactory,
    this.localWorkerPath,
    this.localModelPath,
    this.localChineseToEnglishModelPath,
    this.dictionaryFallback,
    this.chineseDictionaryFallback,
    this.preferencesController,
    this.terminologyController,
    this.dictionaryPreferencesController,
    this.webSearchAdapter,
  }) : _now = now ?? DateTime.now;

  factory QuickTranslationService.platform({
    required AppCore Function() coreFactory,
    TranslationPreferencesController? preferencesController,
    TranslationTerminologyController? terminologyController,
    DictionaryPreferencesController? dictionaryPreferencesController,
    TranslationWebSearchAdapter? webSearchAdapter,
  }) => QuickTranslationService(
    coreFactory: coreFactory,
    secrets: ProviderSecretStore.platform(),
    httpClientFactory: http.Client.new,
    localWorkerPath:
        '${File(Platform.resolvedExecutable).parent.path}\\runtime\\yixue_ct2_worker.exe',
    localModelPath:
        '${File(Platform.resolvedExecutable).parent.path}\\models\\yixue.opus-en-zh.int8',
    localChineseToEnglishModelPath:
        '${File(Platform.resolvedExecutable).parent.path}\\models\\yixue.opus-zh-en.int8',
    dictionaryFallback: const LocalDictionaryService().lookup,
    chineseDictionaryFallback: const LocalDictionaryService().lookupChinese,
    preferencesController: preferencesController,
    terminologyController: terminologyController,
    dictionaryPreferencesController: dictionaryPreferencesController,
    webSearchAdapter: webSearchAdapter,
  );

  final AppCore Function() coreFactory;
  final ProviderSecretStore secrets;
  final HttpClientFactory httpClientFactory;
  final DateTime Function() _now;
  final String Function()? idFactory;
  final String? localWorkerPath;
  final String? localModelPath;
  final String? localChineseToEnglishModelPath;
  final DictionaryEntry? Function(String word)? dictionaryFallback;
  final DictionaryEntry? Function(String text)? chineseDictionaryFallback;
  final TranslationPreferencesController? preferencesController;
  final TranslationTerminologyController? terminologyController;
  final DictionaryPreferencesController? dictionaryPreferencesController;
  final TranslationWebSearchAdapter? webSearchAdapter;
  AppCore? _core;
  String? _configuredLocalModelPath;
  String? _configuredWorkerPath;
  String? _activeTranslationId;
  _QueuedTranslation? _activeTranslationSlot;
  Future<void> _translationTail = Future<void>.value();
  final Map<String, _QueuedTranslation> _queuedTranslations = {};
  http.Client? _activeHttpClient;
  var _cancelRequested = false;
  var _activeTranslationUsesLocalCore = false;
  var _activeLocalTranslationStarted = false;
  var _disposed = false;

  Future<String> translate(
    String sourceText, {
    TranslationDirection direction = TranslationDirection.englishToChinese,
    String origin = 'quick_translation',
    String? historyEntryId,
    String? screenshotCaptureId,
    TranslationRequestOptions options = const TranslationRequestOptions(),
    void Function(TranslationExecutionRoute route)? onRouteSelected,
    String? operationId,
    bool recordHistory = true,
    SubtitleTranslationRouteSnapshot? subtitleRouteSnapshot,
  }) async {
    if (origin != 'quick_translation' && origin != 'screenshot_translation') {
      throw const QuickTranslationException('invalid_origin');
    }
    if (_disposed) {
      throw const QuickTranslationException('service_disposed');
    }
    final source = sourceText.trim();
    if (source.isEmpty || source.length > 5000) {
      throw const QuickTranslationException('invalid_input');
    }
    if (operationId != null && operationId.trim().isEmpty) {
      throw const QuickTranslationException('invalid_input');
    }
    if (subtitleRouteSnapshot != null &&
        subtitleRouteSnapshot.direction != direction) {
      throw const QuickTranslationException('invalid_input');
    }
    final webSearchAdapter = this.webSearchAdapter;
    if (options.webSearchEnabled && webSearchAdapter == null) {
      throw const QuickTranslationException('web_search_unavailable');
    }
    final id =
        operationId ??
        (origin == 'screenshot_translation' && historyEntryId != null
            ? historyEntryId
            : idFactory?.call() ?? 'tr-${_now().microsecondsSinceEpoch}');
    await _acquireTranslationSlot(id);
    http.Client? httpClient;
    try {
      final core = _core ??= coreFactory();
      final startedAt = _now();
      final captureId = origin == 'screenshot_translation'
          ? screenshotCaptureId ?? historyEntryId ?? id
          : null;
      final terminologyDirection = direction.terminologyDirection;
      final terminologyInput = terminologyDirection == null
          ? null
          : terminologyController?.value.protect(source, terminologyDirection);
      final protectedInput = TranslationFormatProtector.protect(
        terminologyInput?.maskedText ?? source,
      );
      TranslationWebSearchContext? webSearchContext;
      if (options.webSearchEnabled) {
        webSearchContext = await webSearchAdapter!.retrieve(
          sourceText: source,
          sourceLanguage: direction.sourceLanguage,
          targetLanguage: direction.targetLanguage,
        );
        _throwIfCancelled();
      }
      if (!options.webSearchEnabled &&
          recordHistory &&
          subtitleRouteSnapshot == null) {
        final dictionaryTranslation = _lookupDictionaryTranslation(
          core,
          source,
          direction,
          id,
          startedAt,
          origin,
          captureId,
        );
        if (dictionaryTranslation != null) {
          onRouteSelected?.call(
            const TranslationExecutionRoute.localDictionary(),
          );
          return dictionaryTranslation;
        }
      }
      final profiles = core.listProviderProfiles();
      final explicitTranslationSelection = _selectExplicitTranslationProvider(
        core,
        profiles,
        direction,
      );
      if (explicitTranslationSelection.ambiguous) {
        onRouteSelected?.call(const TranslationExecutionRoute.unavailable());
        throw const QuickTranslationException('ambiguous_translation_provider');
      }
      if (subtitleRouteSnapshot != null &&
          !_subtitleRouteStillSelected(
            core,
            profiles,
            direction,
            subtitleRouteSnapshot,
          )) {
        throw const QuickTranslationException('provider_route_changed');
      }
      final explicitTranslationProvider = explicitTranslationSelection.profile;
      final localSelection = subtitleRouteSnapshot == null
          ? !explicitTranslationSelection.roleSelected
                ? _selectLocalProfile(core, profiles, direction)
                : explicitTranslationProvider == null
                ? (profile: null, roleSelected: true, ambiguous: false)
                : explicitTranslationProvider.kind ==
                      ProviderProfileKind.localModel
                ? _selectExplicitLocalProfile(
                    core,
                    explicitTranslationProvider,
                    direction,
                  )
                : (profile: null, roleSelected: true, ambiguous: false)
          : _localSelectionForSnapshot(profiles, subtitleRouteSnapshot);
      if (localSelection.ambiguous) {
        onRouteSelected?.call(const TranslationExecutionRoute.unavailable());
        throw const QuickTranslationException('ambiguous_translation_provider');
      }
      final localProfile = localSelection.profile;
      final bundledModelPath = _bundledModelPathFor(direction);
      final selectedLocalModelPath = subtitleRouteSnapshot == null
          ? localProfile?.modelPath ??
                (localSelection.roleSelected ? null : bundledModelPath)
          : switch (subtitleRouteSnapshot.kind) {
              SubtitleTranslationRouteKind.localProfile =>
                localProfile?.modelPath,
              SubtitleTranslationRouteKind.bundledLocal =>
                subtitleRouteSnapshot.bundledModelPath,
              SubtitleTranslationRouteKind.remoteProfile ||
              SubtitleTranslationRouteKind.unavailable => null,
            };
      final remoteProfile = subtitleRouteSnapshot == null
          ? explicitTranslationProvider?.kind == ProviderProfileKind.remoteApi
                ? _selectRemoteProfile(profiles)
                : null
          : subtitleRouteSnapshot.kind ==
                SubtitleTranslationRouteKind.remoteProfile
          ? _resolveSnapshotProfile(
              profiles,
              subtitleRouteSnapshot.profile,
              expectedKind: ProviderProfileKind.remoteApi,
            )
          : null;
      if (!options.webSearchEnabled &&
          (remoteProfile == null ||
              localProfile != null ||
              subtitleRouteSnapshot?.kind ==
                  SubtitleTranslationRouteKind.bundledLocal) &&
          selectedLocalModelPath != null &&
          localWorkerPath != null) {
        _activeTranslationUsesLocalCore = true;
        final localDisplayName = localProfile?.displayName.trim();
        final localRouteName = localProfile == null
            ? '译学内置本地模型'
            : localDisplayName == null || localDisplayName.isEmpty
            ? localProfile.modelId
            : localProfile.displayName;
        onRouteSelected?.call(
          TranslationExecutionRoute.localModel(localRouteName),
        );
        if (core is! LocalTranslationCore) {
          throw const QuickTranslationException('local_core_unavailable');
        }
        if (recordHistory && core is! TranslationHistoryCore) {
          throw const QuickTranslationException('local_core_unavailable');
        }
        final localCore = core as LocalTranslationCore;
        final historyCore = recordHistory
            ? core as TranslationHistoryCore
            : null;
        if (_configuredLocalModelPath != selectedLocalModelPath ||
            _configuredWorkerPath != localWorkerPath) {
          await localCore.configureLocalTranslation(
            modelPath: selectedLocalModelPath,
            workerPath: localWorkerPath!,
          );
          _configuredLocalModelPath = selectedLocalModelPath;
          _configuredWorkerPath = localWorkerPath;
        }
        _verifySubtitleRouteStillCurrent(
          core: core,
          direction: direction,
          snapshot: subtitleRouteSnapshot,
        );
        _throwIfCancelled();
        _activeLocalTranslationStarted = true;
        final result = await localCore.translateLocal(
          id: id,
          sourceText: protectedInput.maskedText,
          sourceLanguage: direction.sourceLanguage,
          targetLanguage: direction.targetLanguage,
        );
        _throwIfCancelled();
        final restoredFormat = protectedInput.restore(result.text);
        final translated =
            terminologyInput?.restore(restoredFormat) ?? restoredFormat;
        if (TranslationQualityGuard.isSuspicious(
          source,
          translated,
          targetLanguage: direction.targetLanguage,
        )) {
          throw const QuickTranslationException('suspicious_model_output');
        }
        historyCore?.recordCompletedTranslation(
          CompletedTranslationData(
            origin: origin,
            id: id,
            screenshotCaptureId: captureId,
            sourceText: source,
            translatedText: translated,
            providerId: result.providerId,
            createdAt: startedAt.toIso8601String(),
            sourceLanguage: direction.sourceLanguage,
            targetLanguage: direction.targetLanguage,
          ),
        );
        return translated;
      }
      final profile = remoteProfile;
      if (profile == null) {
        onRouteSelected?.call(const TranslationExecutionRoute.unavailable());
        throw QuickTranslationException(
          options.webSearchEnabled
              ? 'web_search_requires_remote_provider'
              : 'no_remote_provider',
        );
      }
      final route = isLocalCompatibleEndpoint(profile.endpoint)
          ? TranslationExecutionRoute.localCompatibleApi(profile.displayName)
          : TranslationExecutionRoute.remoteProvider(profile.displayName);
      onRouteSelected?.call(route);
      _activeTranslationUsesLocalCore = false;
      if (recordHistory && core is! TranslationHistoryCore) {
        throw const QuickTranslationException('history_unavailable');
      }
      final historyCore = recordHistory ? core as TranslationHistoryCore : null;
      _verifySubtitleRouteStillCurrent(
        core: core,
        direction: direction,
        snapshot: subtitleRouteSnapshot,
      );
      httpClient = httpClientFactory();
      _activeHttpClient = httpClient;
      final isLiveSubtitleRequest = subtitleRouteSnapshot != null;
      final rawTranslation =
          await OpenAiCompatibleTranslationClient(
            httpClient: httpClient,
            secrets: secrets,
            timeout:
                isLiveSubtitleRequest &&
                    !isLocalCompatibleEndpoint(profile.endpoint)
                ? const Duration(seconds: 20)
                : const Duration(seconds: 45),
            // A retry doubles the time a failed caption can block the serial
            // live subtitle queue. Keep interactive translations retryable,
            // while live subtitles fail promptly and remain manually retryable.
            maxRetries: isLiveSubtitleRequest ? 0 : 1,
            shouldAbort: () => _cancelRequested,
          ).translate(
            profile: profile,
            sourceText: protectedInput.maskedText,
            sourceLanguage: direction.sourceLanguage,
            targetLanguage: direction.targetLanguage,
            tone: preferencesController?.value.tone,
            preserveLineBreaks:
                options.preserveLineBreaks ??
                preferencesController?.value.preserveLineBreaks ??
                true,
            webSearchContext: webSearchContext,
            terminology: terminologyDirection == null
                ? const <TranslationTermRule>[]
                : terminologyController?.value.forDirection(
                        terminologyDirection,
                      ) ??
                      const <TranslationTermRule>[],
          );
      _throwIfCancelled();
      final restoredFormat = protectedInput.restore(rawTranslation);
      final translated =
          terminologyInput?.restore(restoredFormat) ?? restoredFormat;
      if (TranslationQualityGuard.isSuspicious(
        source,
        translated,
        targetLanguage: direction.targetLanguage,
      )) {
        throw const QuickTranslationException('suspicious_model_output');
      }
      historyCore?.recordCompletedTranslation(
        CompletedTranslationData(
          origin: origin,
          id: id,
          screenshotCaptureId: captureId,
          sourceText: source,
          translatedText: translated,
          providerId: profile.id,
          createdAt: startedAt.toIso8601String(),
          sourceLanguage: direction.sourceLanguage,
          targetLanguage: direction.targetLanguage,
        ),
      );
      return translated;
    } on QuickTranslationException {
      rethrow;
    } on TranslationFormatException {
      throw const QuickTranslationException('format_integrity_failed');
    } on FormatException {
      throw const QuickTranslationException('invalid_response');
    } on TranslationClientException catch (error) {
      if (_cancelRequested) {
        throw const QuickTranslationException('cancelled');
      }
      throw QuickTranslationException(error.code);
    } on CoreBridgeException catch (error) {
      if (_cancelRequested || error.code == 'cancelled') {
        throw const QuickTranslationException('cancelled');
      }
      throw const QuickTranslationException('local_core_error');
    } finally {
      httpClient?.close();
      _activeHttpClient = null;
      if (_activeTranslationId == id) {
        _activeTranslationId = null;
        _cancelRequested = false;
        _activeTranslationUsesLocalCore = false;
        _activeLocalTranslationStarted = false;
        _activeTranslationSlot?.release();
        _activeTranslationSlot = null;
      }
    }
  }

  Future<void> _acquireTranslationSlot(String id) async {
    if (_disposed) {
      throw const QuickTranslationException('service_disposed');
    }
    if (_activeTranslationId == id || _queuedTranslations.containsKey(id)) {
      throw const QuickTranslationException('translation_in_progress');
    }

    final preceding = _translationTail;
    final slot = _QueuedTranslation(id: id, preceding: preceding);
    _translationTail = slot.released.future;
    _queuedTranslations[id] = slot;

    await Future.any<void>([preceding, slot.cancelled.future]);
    _queuedTranslations.remove(id);
    if (slot.isCancelled) {
      unawaited(_releaseQueuedSlotAfterPreceding(slot));
      throw const QuickTranslationException('cancelled');
    }
    if (_disposed) {
      slot.release();
      throw const QuickTranslationException('service_disposed');
    }

    _activeTranslationId = id;
    _activeTranslationSlot = slot;
    _cancelRequested = false;
    _activeTranslationUsesLocalCore = false;
    _activeLocalTranslationStarted = false;
  }

  Future<void> _releaseQueuedSlotAfterPreceding(_QueuedTranslation slot) async {
    await slot.preceding;
    slot.release();
  }

  Future<String> translateSubtitle(
    String sourceText, {
    required String requestId,
    required TranslationDirection direction,
    required SubtitleTranslationRouteSnapshot routeSnapshot,
  }) => translate(
    sourceText,
    direction: direction,
    operationId: requestId,
    recordHistory: false,
    subtitleRouteSnapshot: routeSnapshot,
  );

  Future<Map<TranslationDirection, SubtitleTranslationRouteSnapshot>>
  snapshotSubtitleRoutes() async {
    if (_disposed) {
      throw const QuickTranslationException('service_disposed');
    }
    final core = _core ??= coreFactory();
    final profiles = core.listProviderProfiles();
    final routes = <TranslationDirection, SubtitleTranslationRouteSnapshot>{};
    for (final direction in TranslationDirection.values) {
      routes[direction] = await _snapshotSubtitleRoute(
        core,
        profiles,
        direction,
      );
    }
    return Map<
      TranslationDirection,
      SubtitleTranslationRouteSnapshot
    >.unmodifiable(routes);
  }

  Future<SubtitleTranslationRouteSnapshot> _snapshotSubtitleRoute(
    AppCore core,
    List<ProviderProfileData> profiles,
    TranslationDirection direction,
  ) async {
    const unavailable = SubtitleTranslationRouteKind.unavailable;
    final explicitTranslationSelection = _selectExplicitTranslationProvider(
      core,
      profiles,
      direction,
    );
    if (explicitTranslationSelection.ambiguous) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: unavailable,
        unavailableReasonCode: 'ambiguous_translation_provider',
      );
    }
    if (explicitTranslationSelection.roleSelected &&
        explicitTranslationSelection.profile == null) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: unavailable,
        unavailableReasonCode: 'no_remote_provider',
      );
    }

    final explicitTranslationProvider = explicitTranslationSelection.profile;
    if (explicitTranslationProvider != null) {
      final selected = explicitTranslationProvider;
      if (selected.kind == ProviderProfileKind.remoteApi) {
        if (!await _remoteCredentialAvailable(selected)) {
          return SubtitleTranslationRouteSnapshot._(
            direction: direction,
            kind: unavailable,
            unavailableReasonCode: 'missing_credential',
          );
        }
        return SubtitleTranslationRouteSnapshot._(
          direction: direction,
          kind: SubtitleTranslationRouteKind.remoteProfile,
          profile: _copyProviderProfile(selected),
        );
      }
      if (localWorkerPath == null) {
        return SubtitleTranslationRouteSnapshot._(
          direction: direction,
          kind: unavailable,
          unavailableReasonCode: 'local_core_unavailable',
        );
      }
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: SubtitleTranslationRouteKind.localProfile,
        profile: _copyProviderProfile(selected),
      );
    }

    if (explicitTranslationSelection.roleSelected) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: unavailable,
        unavailableReasonCode: 'no_remote_provider',
      );
    }

    final localSelection = _selectLocalProfile(core, profiles, direction);
    if (localSelection.ambiguous) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: unavailable,
        unavailableReasonCode: 'ambiguous_translation_provider',
      );
    }
    final localProfile = localSelection.profile;
    if (localProfile != null && localWorkerPath != null) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: SubtitleTranslationRouteKind.localProfile,
        profile: _copyProviderProfile(localProfile),
      );
    }
    final bundledModelPath = _bundledModelPathFor(direction);
    if (bundledModelPath != null && localWorkerPath != null) {
      return SubtitleTranslationRouteSnapshot._(
        direction: direction,
        kind: SubtitleTranslationRouteKind.bundledLocal,
        bundledModelPath: bundledModelPath,
      );
    }
    return SubtitleTranslationRouteSnapshot._(
      direction: direction,
      kind: unavailable,
      unavailableReasonCode: 'no_remote_provider',
    );
  }

  Future<bool> _remoteCredentialAvailable(ProviderProfileData profile) async {
    if (isLocalCompatibleEndpoint(profile.endpoint)) return true;
    try {
      await secrets.resolveApiKey(profile.id);
      return true;
    } on ProviderCredentialException {
      return false;
    }
  }

  ({ProviderProfileData? profile, bool roleSelected, bool ambiguous})
  _localSelectionForSnapshot(
    List<ProviderProfileData> profiles,
    SubtitleTranslationRouteSnapshot snapshot,
  ) {
    switch (snapshot.kind) {
      case SubtitleTranslationRouteKind.localProfile:
        return (
          profile: _resolveSnapshotProfile(
            profiles,
            snapshot.profile,
            expectedKind: ProviderProfileKind.localModel,
          ),
          roleSelected: true,
          ambiguous: false,
        );
      case SubtitleTranslationRouteKind.bundledLocal:
        return (profile: null, roleSelected: false, ambiguous: false);
      case SubtitleTranslationRouteKind.remoteProfile:
      case SubtitleTranslationRouteKind.unavailable:
        return (profile: null, roleSelected: true, ambiguous: false);
    }
  }

  ProviderProfileData _resolveSnapshotProfile(
    List<ProviderProfileData> profiles,
    ProviderProfileData? snapshot, {
    required ProviderProfileKind expectedKind,
  }) {
    if (snapshot == null || snapshot.kind != expectedKind) {
      throw const QuickTranslationException('provider_route_changed');
    }
    for (final profile in profiles) {
      if (profile.id == snapshot.id &&
          profile.enabled &&
          _sameProviderProfile(profile, snapshot)) {
        return profile;
      }
    }
    throw const QuickTranslationException('provider_route_changed');
  }

  bool _subtitleRouteStillSelected(
    AppCore core,
    List<ProviderProfileData> profiles,
    TranslationDirection direction,
    SubtitleTranslationRouteSnapshot snapshot,
  ) {
    final explicitTranslationSelection = _selectExplicitTranslationProvider(
      core,
      profiles,
      direction,
    );
    if (explicitTranslationSelection.ambiguous ||
        (explicitTranslationSelection.roleSelected &&
            explicitTranslationSelection.profile == null)) {
      return false;
    }
    final explicitTranslationProvider = explicitTranslationSelection.profile;
    if (snapshot.direction != direction) return false;

    switch (snapshot.kind) {
      case SubtitleTranslationRouteKind.localProfile:
        final expected = snapshot.profile;
        if (expected == null) return false;
        if (explicitTranslationSelection.roleSelected) {
          if (explicitTranslationProvider == null) return false;
          return explicitTranslationProvider.kind ==
                  ProviderProfileKind.localModel &&
              _sameProviderProfile(explicitTranslationProvider, expected) &&
              _profileMatchesDirection(
                core,
                explicitTranslationProvider,
                direction,
              );
        }
        final currentSelection = _selectLocalProfile(core, profiles, direction);
        if (currentSelection.ambiguous) return false;
        final current = currentSelection.profile;
        if (current == null) return false;
        return _sameProviderProfile(current, expected);
      case SubtitleTranslationRouteKind.bundledLocal:
        if (explicitTranslationSelection.roleSelected) return false;
        final local = _selectLocalProfile(core, profiles, direction);
        final currentPath = _bundledModelPathFor(direction);
        return !local.ambiguous &&
            local.profile == null &&
            localWorkerPath != null &&
            currentPath == snapshot.bundledModelPath;
      case SubtitleTranslationRouteKind.remoteProfile:
        final expected = snapshot.profile;
        return explicitTranslationSelection.roleSelected &&
            explicitTranslationProvider != null &&
            explicitTranslationProvider.kind == ProviderProfileKind.remoteApi &&
            expected != null &&
            _sameProviderProfile(explicitTranslationProvider, expected);
      case SubtitleTranslationRouteKind.unavailable:
        return false;
    }
  }

  void _verifySubtitleRouteStillCurrent({
    required AppCore core,
    required TranslationDirection direction,
    required SubtitleTranslationRouteSnapshot? snapshot,
  }) {
    if (snapshot == null) return;
    if (!_subtitleRouteStillSelected(
      core,
      core.listProviderProfiles(),
      direction,
      snapshot,
    )) {
      throw const QuickTranslationException('provider_route_changed');
    }
  }

  static ProviderProfileData _copyProviderProfile(ProviderProfileData source) =>
      ProviderProfileData(
        id: source.id,
        displayName: source.displayName,
        kind: source.kind,
        enabled: source.enabled,
        modelId: source.modelId,
        endpoint: source.endpoint,
        modelPath: source.modelPath,
        secretRef: source.secretRef,
        assignedRoles: Set<ModelRole>.unmodifiable(source.assignedRoles),
      );

  static bool _sameProviderProfile(
    ProviderProfileData left,
    ProviderProfileData right,
  ) =>
      left.id == right.id &&
      left.displayName == right.displayName &&
      left.kind == right.kind &&
      left.enabled == right.enabled &&
      left.modelId == right.modelId &&
      left.endpoint == right.endpoint &&
      left.modelPath == right.modelPath &&
      left.secretRef == right.secretRef &&
      left.assignedRoles.length == right.assignedRoles.length &&
      left.assignedRoles.containsAll(right.assignedRoles);

  String? _lookupDictionaryTranslation(
    AppCore core,
    String source,
    TranslationDirection direction,
    String id,
    DateTime startedAt,
    String origin,
    String? screenshotCaptureId,
  ) {
    if (core is! TranslationHistoryCore) {
      return null;
    }
    final history = core as TranslationHistoryCore;
    final DictionaryCore? dictionary = core is DictionaryCore
        ? core as DictionaryCore
        : null;
    final allowBundledDictionary =
        dictionaryPreferencesController == null ||
        dictionaryPreferencesController!.value.isEnabled('yixue-basic');
    DictionaryEntry? entry;
    var shouldPersist = false;

    final isEnglishHeadword =
        direction == TranslationDirection.englishToChinese &&
        RegExp(r"^[A-Za-z]+(?:['’\-][A-Za-z]+)*$").hasMatch(source);
    final isChineseHeadword =
        direction == TranslationDirection.chineseToEnglish &&
        RegExp(r'^[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]{1,6}$')
            .hasMatch(source);
    if (isEnglishHeadword || isChineseHeadword) {
      // Query the user's enabled dictionary sources in either direction.
      // They may return fuzzy candidates, so only accept an exact headword or
      // exact Chinese meaning match before considering the bundled fallback.
      final stored =
          dictionary?.lookupDictionary(source, limit: 20) ??
          const <DictionaryEntryData>[];
      final ordered =
          dictionaryPreferencesController?.value.sortEntries(stored) ?? stored;
      entry = bestDictionaryEntryForTerm(
        source,
        ordered.map(_fromDictionaryData),
      );
      if (entry == null && allowBundledDictionary) {
        entry = isChineseHeadword
            ? chineseDictionaryFallback?.call(source)
            : dictionaryFallback?.call(source.toLowerCase());
        shouldPersist = entry != null;
      }
    }
    if (entry == null || entry.meanings.isEmpty) return null;
    if (shouldPersist && dictionary != null) {
      dictionary.saveDictionaryEntry(_toDictionaryData(entry));
    }
    final translated = direction == TranslationDirection.chineseToEnglish
        ? entry.word
        : entry.meanings.first;
    history.recordCompletedTranslation(
      CompletedTranslationData(
        origin: origin,
        id: id,
        screenshotCaptureId: screenshotCaptureId,
        sourceText: source,
        translatedText: translated,
        providerId: 'local.dictionary',
        createdAt: startedAt.toIso8601String(),
        sourceLanguage: direction.sourceLanguage,
        targetLanguage: direction.targetLanguage,
      ),
    );
    return translated;
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
        source: 'yixue-basic',
      );

  static DictionaryEntry _fromDictionaryData(DictionaryEntryData entry) =>
      DictionaryEntry(
        word: entry.word,
        ipa: entry.ipa,
        partOfSpeech: entry.partOfSpeech,
        meanings: entry.meanings,
        example: entry.example,
        exampleTranslation: entry.exampleTranslation,
        source: entry.source,
      );

  Future<bool> cancelTranslation(String operationId) async {
    if (_activeTranslationId != operationId) {
      final queued = _queuedTranslations[operationId];
      if (queued == null) return false;
      queued.cancel();
      return true;
    }
    final core = _core;
    if (_activeTranslationUsesLocalCore) {
      if (core is! LocalTranslationCore) return false;
      if (!_activeLocalTranslationStarted) {
        // Configuration / model warm-up has not submitted a native request yet.
        // Remember cancellation locally so the request cannot start afterward.
        _cancelRequested = true;
        return true;
      }
      final accepted = await (core as LocalTranslationCore)
          .cancelLocalTranslation(operationId);
      // The translation may finish while the native worker is acknowledging
      // cancellation. A queued request can become active during that await, so
      // never apply the old request's cancellation to shared active state.
      if (!accepted) return false;
      if (_activeTranslationId != operationId) return true;
    }
    _cancelRequested = true;
    _activeHttpClient?.close();
    return true;
  }

  Future<bool> cancelActiveTranslation() async {
    final id = _activeTranslationId;
    if (id == null) return false;
    return cancelTranslation(id);
  }

  ({ProviderProfileData? profile, bool roleSelected, bool ambiguous})
  _selectLocalProfile(
    AppCore core,
    List<ProviderProfileData> profiles,
    TranslationDirection direction,
  ) {
    final localProfiles = profiles
        .where(
          (candidate) =>
              candidate.enabled &&
              candidate.kind == ProviderProfileKind.localModel,
        )
        .toList(growable: false);
    if (core case final ModelCatalogCore catalogCore) {
      final catalogEntries = catalogCore.listModelCatalogEntries();
      final directionalAssignments = localProfiles
          .where((profile) {
            final path = profile.modelPath?.toLowerCase();
            if (path == null) return false;
            return catalogEntries.any(
              (entry) =>
                  entry.path.toLowerCase() == path &&
                  entry.assignedRoles.contains(
                    ModelRole.translation.wireName,
                  ) &&
                  _catalogEntryMatchesDirection(entry, direction) &&
                  (entry.sourceLanguage != null ||
                      path.contains(direction.modelHint)),
            );
          })
          .toList(growable: false);
      if (directionalAssignments.length > 1) {
        return (profile: null, roleSelected: true, ambiguous: true);
      }
      if (directionalAssignments.length == 1) {
        return (
          profile: directionalAssignments.single,
          roleSelected: true,
          ambiguous: false,
        );
      }

      // Keep a single language-agnostic catalog assignment usable, but don't
      // guess if several configured models claim the same fallback path.
      final genericAssignments = localProfiles
          .where((profile) {
            final path = profile.modelPath?.toLowerCase();
            if (path == null) return false;
            final hasOtherDirectionHint = TranslationDirection.values.any(
              (candidate) =>
                  candidate != direction && path.contains(candidate.modelHint),
            );
            if (hasOtherDirectionHint) return false;
            return catalogEntries.any(
              (entry) =>
                  entry.path.toLowerCase() == path &&
                  entry.assignedRoles.contains(
                    ModelRole.translation.wireName,
                  ) &&
                  entry.sourceLanguage == null &&
                  entry.targetLanguage == null,
            );
          })
          .toList(growable: false);
      if (genericAssignments.length > 1) {
        return (profile: null, roleSelected: true, ambiguous: true);
      }
      if (genericAssignments.length == 1) {
        return (
          profile: genericAssignments.single,
          roleSelected: true,
          ambiguous: false,
        );
      }
    } else {
      final explicitlyAssigned = localProfiles
          .where(
            (profile) =>
                profile.assignedRoles.contains(ModelRole.translation) &&
                _profileMatchesDirection(core, profile, direction),
          )
          .toList(growable: false);
      if (explicitlyAssigned.length > 1) {
        return (profile: null, roleSelected: true, ambiguous: true);
      }
      if (explicitlyAssigned.length == 1) {
        return (
          profile: explicitlyAssigned.single,
          roleSelected: true,
          ambiguous: false,
        );
      }
    }
    final inferredAssignments = localProfiles
        .where((profile) {
          // Inference is only for roleless local profiles. In particular, a
          // legacy unsupported `understanding` assignment must neither make
          // that profile a translation candidate nor block direction-based
          // selection of another roleless local translation model.
          if (profile.assignedRoles.isNotEmpty ||
              !profile.modelId.toLowerCase().contains(direction.modelHint)) {
            return false;
          }
          final catalogEntries = core is ModelCatalogCore
              ? (core as ModelCatalogCore).listModelCatalogEntries().where(
                  (entry) =>
                      entry.path.toLowerCase() ==
                      profile.modelPath?.toLowerCase(),
                )
              : const <ModelCatalogEntryData>[];
          return catalogEntries.isEmpty ||
              catalogEntries.any(
                (entry) => _catalogEntryMatchesDirection(entry, direction),
              );
        })
        .toList(growable: false);
    if (inferredAssignments.length > 1) {
      return (profile: null, roleSelected: false, ambiguous: true);
    }
    if (inferredAssignments.length == 1) {
      return (
        profile: inferredAssignments.single,
        roleSelected: false,
        ambiguous: false,
      );
    }
    return (profile: null, roleSelected: false, ambiguous: false);
  }

  List<ProviderProfileData> _enabledTranslationProviders(
    List<ProviderProfileData> profiles,
  ) => profiles
      .where(
        (profile) =>
            profile.enabled &&
            profile.assignedRoles.contains(ModelRole.translation),
      )
      .toList(growable: false);

  ({ProviderProfileData? profile, bool roleSelected, bool ambiguous})
  _selectExplicitTranslationProvider(
    AppCore core,
    List<ProviderProfileData> profiles,
    TranslationDirection direction,
  ) {
    final assigned = _enabledTranslationProviders(profiles);
    if (assigned.isEmpty) {
      return (profile: null, roleSelected: false, ambiguous: false);
    }
    if (assigned.length == 1) {
      final selected = assigned.single;
      if (selected.kind == ProviderProfileKind.localModel &&
          _explicitLocalProfileDirection(core, selected, direction) == false) {
        // A local model can be explicitly selected for only one direction.
        // Let the local selector continue so the bundled on-device model can
        // serve the opposite direction without involving a remote provider.
        return (profile: null, roleSelected: false, ambiguous: false);
      }
      return (profile: selected, roleSelected: true, ambiguous: false);
    }
    if (assigned.any(
      (profile) => profile.kind != ProviderProfileKind.localModel,
    )) {
      return (profile: null, roleSelected: true, ambiguous: true);
    }

    final directionMatches = assigned
        .where(
          (profile) =>
              _explicitLocalProfileDirection(core, profile, direction) == true,
        )
        .toList(growable: false);
    if (directionMatches.length > 1) {
      return (profile: null, roleSelected: true, ambiguous: true);
    }
    if (directionMatches.length == 1) {
      return (
        profile: directionMatches.single,
        roleSelected: true,
        ambiguous: false,
      );
    }

    final genericMatches = assigned
        .where(
          (profile) =>
              _explicitLocalProfileDirection(core, profile, direction) == null,
        )
        .toList(growable: false);
    if (genericMatches.length > 1) {
      return (profile: null, roleSelected: true, ambiguous: true);
    }
    if (genericMatches.length == 1) {
      return (
        profile: genericMatches.single,
        roleSelected: true,
        ambiguous: false,
      );
    }

    // The explicitly assigned local models cover other directions. Leave this
    // direction unassigned so the caller can use its bundled local fallback;
    // never substitute a different assigned model or enable a cloud provider.
    return (profile: null, roleSelected: false, ambiguous: false);
  }

  /// Returns true for a catalog-confirmed direction, false for a catalog-
  /// confirmed different direction, and null for a language-agnostic model.
  bool? _explicitLocalProfileDirection(
    AppCore core,
    ProviderProfileData profile,
    TranslationDirection direction,
  ) {
    final path = profile.modelPath?.toLowerCase();
    if (path == null) return null;
    final hintedDirection = _directionHintInPath(path);
    final catalogEntries = core is ModelCatalogCore
        ? (core as ModelCatalogCore)
              .listModelCatalogEntries()
              .where((entry) => entry.path.toLowerCase() == path)
              .toList(growable: false)
        : const <ModelCatalogEntryData>[];
    if (catalogEntries.isEmpty) {
      return hintedDirection == null ? null : hintedDirection == direction;
    }

    var hasDirectionalMetadata = hintedDirection != null;
    var hasGenericMetadata = false;
    for (final entry in catalogEntries) {
      final source = entry.sourceLanguage?.trim().toLowerCase();
      final target = entry.targetLanguage?.trim().toLowerCase();
      if (source == null && target == null) {
        if (hintedDirection == null) {
          hasGenericMetadata = true;
        } else if (hintedDirection == direction) {
          return true;
        }
        continue;
      }
      hasDirectionalMetadata = true;
      if (_catalogEntryMatchesDirection(entry, direction)) return true;
    }
    if (hasGenericMetadata) return null;
    return hasDirectionalMetadata ? false : null;
  }

  TranslationDirection? _directionHintInPath(String path) {
    for (final direction in TranslationDirection.values) {
      if (path.contains(direction.modelHint)) return direction;
    }
    return null;
  }

  ({ProviderProfileData? profile, bool roleSelected, bool ambiguous})
  _selectExplicitLocalProfile(
    AppCore core,
    ProviderProfileData selected,
    TranslationDirection direction,
  ) {
    if (_profileMatchesDirection(core, selected, direction)) {
      return (profile: selected, roleSelected: true, ambiguous: false);
    }
    return (profile: null, roleSelected: true, ambiguous: false);
  }

  ProviderProfileData? _selectRemoteProfile(
    List<ProviderProfileData> profiles,
  ) {
    final explicitlyAssigned = _enabledTranslationProviders(profiles);
    if (explicitlyAssigned.length != 1 ||
        explicitlyAssigned.single.kind != ProviderProfileKind.remoteApi) {
      return null;
    }
    // External APIs must be deliberately assigned to translation. If any
    // enabled local or remote profile also claims the route, fail closed.
    return explicitlyAssigned.single;
  }

  bool _profileMatchesDirection(
    AppCore core,
    ProviderProfileData profile,
    TranslationDirection direction,
  ) {
    final path = profile.modelPath?.toLowerCase();
    if (path == null || core is! ModelCatalogCore) return true;
    final entries = (core as ModelCatalogCore)
        .listModelCatalogEntries()
        .where((entry) => entry.path.toLowerCase() == path)
        .toList(growable: false);
    if (entries.isEmpty) return true;
    return entries.any(
      (entry) => _catalogEntryMatchesDirection(entry, direction),
    );
  }

  bool _catalogEntryMatchesDirection(
    ModelCatalogEntryData entry,
    TranslationDirection direction,
  ) {
    final source = entry.sourceLanguage?.trim().toLowerCase();
    final target = entry.targetLanguage?.trim().toLowerCase();
    if (source == null && target == null) return true;
    if (source == null || target == null) return false;
    return TranslationDirection.fromLanguageCodes(source, target) == direction;
  }

  String? _bundledModelPathFor(TranslationDirection direction) =>
      switch (direction) {
        TranslationDirection.englishToChinese => localModelPath,
        TranslationDirection.chineseToEnglish => localChineseToEnglishModelPath,
        _ => null,
      };

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const QuickTranslationException('cancelled');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelRequested = true;
    for (final queued in _queuedTranslations.values.toList(growable: false)) {
      queued.cancel();
    }
    _activeHttpClient?.close();
    final activeId = _activeTranslationId;
    final core = _core;
    if (activeId != null) {
      if (core case final LocalTranslationCore localCore) {
        localCore.cancelLocalTranslation(activeId);
      }
    }
    _core?.dispose();
    _core = null;
  }
}

final class _QueuedTranslation {
  _QueuedTranslation({required this.id, required this.preceding});

  final String id;
  final Future<void> preceding;
  final Completer<void> cancelled = Completer<void>();
  final Completer<void> released = Completer<void>();
  var isCancelled = false;

  void cancel() {
    isCancelled = true;
    if (!cancelled.isCompleted) cancelled.complete();
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

final class QuickTranslationException implements Exception {
  const QuickTranslationException(this.code);
  final String code;
  @override
  String toString() => 'QuickTranslationException($code)';
}
