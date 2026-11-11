import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/translation_execution_route.dart';
import 'package:yixue_app/core/translation_request_options.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';

class _MemorySecrets implements SecretBackend {
  final values = <String, String>{};
  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _Core
    implements
        AppCore,
        TranslationHistoryCore,
        LocalTranslationCore,
        ModelCatalogCore,
        DictionaryCore {
  _Core(this.profiles);
  final List<ProviderProfileData> profiles;
  CompletedTranslationData? saved;
  String? configuredModelPath;
  String? configuredWorkerPath;
  String? translatedSourceLanguage;
  String? translatedTargetLanguage;
  String? translatedSourceText;
  String? translatedRequestId;
  String localResponseText = '本地译文';
  var configureCount = 0;
  var disposed = false;
  Completer<LocalTranslationResultData>? pendingTranslation;
  String? cancelledTranslationId;
  bool acceptLocalCancellation = true;
  Completer<void>? configureLocalTranslationGate;
  var localTranslationCount = 0;
  final catalog = <ModelCatalogEntryData>[];
  final dictionary = <DictionaryEntryData>[];
  final dictionaryResultsByQuery = <String, List<DictionaryEntryData>>{};
  @override
  void recordCompletedTranslation(CompletedTranslationData translation) =>
      saved = translation;
  @override
  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 20}) =>
      const [];
  @override
  List<ProviderProfileData> listProviderProfiles() => profiles;
  @override
  void dispose() => disposed = true;
  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 1, coreVersion: 'test');
  @override
  void recordActivity(ActivityEventData activity) {}
  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      const HomeSnapshotData(
        learningMinutes: 0,
        readingPages: 0,
        masteredWords: 0,
        completedExercises: 0,
        recent: [],
      );
  @override
  void saveProviderProfile(ProviderProfileData profile) {}

  @override
  void deleteProviderProfile(String providerId) {}
  @override
  void saveModelCatalogEntry(ModelCatalogEntryData entry) => catalog.add(entry);
  @override
  List<ModelCatalogEntryData> listModelCatalogEntries() => catalog;

  @override
  void deleteModelCatalogEntry(String modelId) {
    catalog.removeWhere((entry) => entry.id == modelId);
  }

  @override
  List<DictionaryEntryData> lookupDictionary(String word, {int limit = 10}) =>
      (dictionaryResultsByQuery[word] ??
              dictionary.where((entry) => entry.word == word).toList())
          .take(limit)
          .toList();

  @override
  void saveDictionaryEntry(DictionaryEntryData entry) {
    dictionary.removeWhere((existing) => existing.id == entry.id);
    dictionary.add(entry);
  }

  @override
  List<String> listFavoriteWords() => const [];

  @override
  void setFavoriteWord(String word, bool favorite) {}

  @override
  Future<void> configureLocalTranslation({
    required String modelPath,
    required String workerPath,
  }) async {
    configureCount += 1;
    await configureLocalTranslationGate?.future;
    configuredModelPath = modelPath;
    configuredWorkerPath = workerPath;
  }

  @override
  Future<LocalTranslationResultData> translateLocal({
    required String id,
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    localTranslationCount += 1;
    translatedRequestId = id;
    translatedSourceText = sourceText;
    translatedSourceLanguage = sourceLanguage;
    translatedTargetLanguage = targetLanguage;
    if (pendingTranslation case final pending?) {
      return pending.future;
    }
    return LocalTranslationResultData(
      requestId: id,
      providerId: 'local.opus-en-zh',
      text: localResponseText,
    );
  }

  @override
  Future<bool> cancelLocalTranslation(String id) async {
    cancelledTranslationId = id;
    if (acceptLocalCancellation) {
      pendingTranslation?.completeError(
        const CoreBridgeException('cancelled', 'operation was cancelled'),
      );
    }
    return acceptLocalCancellation;
  }
}

class _LateCancellationCore extends _Core {
  _LateCancellationCore() : super([]);

  final oldTranslationStarted = Completer<void>();
  final nextTranslationStarted = Completer<void>();
  final oldTranslation = Completer<LocalTranslationResultData>();
  final nextTranslation = Completer<LocalTranslationResultData>();
  final cancellationResult = Completer<bool>();

  @override
  Future<LocalTranslationResultData> translateLocal({
    required String id,
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
  }) {
    if (id == 'old-local-operation') {
      oldTranslationStarted.complete();
      return oldTranslation.future;
    }
    if (id == 'next-local-operation') {
      nextTranslationStarted.complete();
      return nextTranslation.future;
    }
    throw StateError('Unexpected local translation request: $id');
  }

  @override
  Future<bool> cancelLocalTranslation(String id) => cancellationResult.future;
}

const _profile = ProviderProfileData(
  id: 'remote.example',
  displayName: 'Example',
  kind: ProviderProfileKind.remoteApi,
  enabled: true,
  modelId: 'translator-v1',
  endpoint: 'https://api.example.com/v1',
  assignedRoles: {ModelRole.translation},
);

const _localCompatibleProfile = ProviderProfileData(
  id: 'local.ollama',
  displayName: '本机 Ollama',
  kind: ProviderProfileKind.remoteApi,
  enabled: true,
  modelId: 'qwen3',
  endpoint: 'http://127.0.0.1:11434/v1',
);

const _localProfile = ProviderProfileData(
  id: 'local.opus-en-zh',
  displayName: '译学英中轻量模型',
  kind: ProviderProfileKind.localModel,
  enabled: true,
  modelId: 'yixue.opus-en-zh.int8',
  modelPath: r'D:\models\yixue.opus-en-zh.int8',
);

void main() {
  test(
    'translation options can preserve OCR paragraphs despite saved preference',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final preferences = TranslationPreferencesController(
        initialValue: const TranslationPreferences(preserveLineBreaks: false),
      );
      addTearDown(preferences.dispose);
      String? systemPrompt;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        preferencesController: preferences,
        httpClientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final messages = body['messages'] as List<Object?>;
          systemPrompt =
              (messages.first as Map<String, dynamic>)['content'] as String;
          return http.Response.bytes(
            utf8.encode(
              '{"choices":[{"message":{"content":"第一段译文。\\n\\n第二段译文。"}}]}',
            ),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final result = await service.translate(
        'First paragraph.\n\nSecond paragraph.',
        options: const TranslationRequestOptions(preserveLineBreaks: true),
      );

      expect(result, '第一段译文。\n\n第二段译文。');
      expect(
        systemPrompt,
        contains('Preserve line breaks and paragraph structure.'),
      );
    },
  );

  test(
    'serializes translations instead of rejecting overlapping module work',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final firstResponse = Completer<http.Response>();
      final firstRequestStarted = Completer<void>();
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          if (requestCount == 1) {
            firstRequestStarted.complete();
            return firstResponse.future;
          }
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"第二条译文"}}]}'),
            200,
          );
        }),
        idFactory: () => 'queued-translation',
      );
      addTearDown(service.dispose);

      final first = service.translate(
        'first source',
        operationId: 'first-operation',
      );
      await firstRequestStarted.future;
      final second = service.translate(
        'second source',
        operationId: 'second-operation',
      );

      await Future<void>.delayed(Duration.zero);
      expect(requestCount, 1);

      firstResponse.complete(
        http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"第一条译文"}}]}'),
          200,
        ),
      );
      expect(await first, '第一条译文');
      expect(await second, '第二条译文');
      expect(requestCount, 2);
    },
  );

  test(
    'cancelling a queued translation does not unblock later work early',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final firstResponse = Completer<http.Response>();
      final firstRequestStarted = Completer<void>();
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          if (requestCount == 1) {
            firstRequestStarted.complete();
            return firstResponse.future;
          }
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"后续译文"}}]}'),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final first = service.translate('first source', operationId: 'active');
      await firstRequestStarted.future;
      final cancelled = service.translate(
        'cancelled source',
        operationId: 'cancelled-queued',
      );
      final cancelledExpectation = expectLater(
        cancelled,
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      final later = service.translate('later source', operationId: 'later');

      expect(await service.cancelTranslation('cancelled-queued'), isTrue);
      await cancelledExpectation;
      await Future<void>.delayed(Duration.zero);
      expect(requestCount, 1);

      firstResponse.complete(
        http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"第一条译文"}}]}'),
          200,
        ),
      );
      expect(await first, '第一条译文');
      expect(await later, '后续译文');
      expect(requestCount, 2);
    },
  );

  test(
    'does not silently route translation to a roleless remote provider',
    () async {
      final core = _Core([_localCompatibleProfile]);
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"不应发送"}}]}'),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final selectedRoutes = <TranslationExecutionRoute>[];

      final subtitleRoutes = await service.snapshotSubtitleRoutes();
      expect(
        subtitleRoutes[TranslationDirection.englishToChinese]!.kind,
        SubtitleTranslationRouteKind.unavailable,
      );
      await expectLater(
        service.translate(
          'Keep this translation on the selected provider.',
          origin: 'screenshot_translation',
          onRouteSelected: selectedRoutes.add,
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'no_remote_provider',
          ),
        ),
      );

      expect(
        selectedRoutes.single.kind,
        TranslationExecutionRouteKind.unavailable,
      );
      expect(requestCount, 0);
    },
  );

  test('preserves a missing API credential as the unavailable screenshot route reason', () async {
    final core = _Core([_profile]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('No request should be sent'),
    );
    addTearDown(service.dispose);

    final route = (await service
        .snapshotSubtitleRoutes())[TranslationDirection.englishToChinese]!;

    expect(route.kind, SubtitleTranslationRouteKind.unavailable);
    expect(route.unavailableReasonCode, 'missing_credential');
  });

  test(
    'unique explicit remote provider wins over a stale local catalog role',
    () async {
      final local = _localProfile.copyWith(
        assignedRoles: const {ModelRole.understanding},
      );
      final core = _Core([_profile, local])
        ..catalog.add(
          const ModelCatalogEntryData(
            id: 'catalog.stale-local-translation',
            path: r'D:\models\yixue.opus-en-zh.int8',
            displayName: '旧本地翻译模型',
            family: 'yixue_translation',
            readiness: 'ready_to_validate',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'english',
            targetLanguage: 'chinese',
          ),
        );
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient((request) async {
          requestCount += 1;
          return http.Response(
            '{"choices":[{"message":{"content":"科技改善生活。"}}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );
      addTearDown(service.dispose);
      final selectedRoutes = <TranslationExecutionRoute>[];

      final result = await service.translate(
        'Technology improves life.',
        onRouteSelected: selectedRoutes.add,
      );

      expect(result, '科技改善生活。');
      expect(requestCount, 1);
      expect(core.configureCount, 0);
      expect(
        selectedRoutes.single.kind,
        TranslationExecutionRouteKind.remoteProvider,
      );
      expect(core.saved?.providerId, _profile.id);
    },
  );

  test('fails closed instead of choosing local or remote when translation roles are ambiguous', () async {
    const remoteB = ProviderProfileData(
      id: 'remote.example.second',
      displayName: 'Second API',
      kind: ProviderProfileKind.remoteApi,
      enabled: true,
      modelId: 'translator-v2',
      endpoint: 'https://second.example.com/v1',
      assignedRoles: {ModelRole.translation},
    );
    final local = _localProfile.copyWith(
      assignedRoles: const {ModelRole.understanding},
    );
    final core = _Core([_profile, remoteB, local])
      ..catalog.add(
        const ModelCatalogEntryData(
          id: 'catalog.ambiguous-local-translation',
          path: r'D:\models\yixue.opus-en-zh.int8',
          displayName: '可回退的本地模型',
          family: 'yixue_translation',
          readiness: 'ready_to_validate',
          capabilities: ['translation'],
          assignedRoles: ['translation'],
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        ),
      );
    var requestCount = 0;
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => MockClient((_) async {
        requestCount += 1;
        return http.Response(
          '{"choices":[{"message":{"content":"不应使用"}}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\bundled-en-zh',
    );
    addTearDown(service.dispose);
    final selectedRoutes = <TranslationExecutionRoute>[];

    await expectLater(
      service.translate(
        'Technology improves life.',
        onRouteSelected: selectedRoutes.add,
      ),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'ambiguous_translation_provider',
        ),
      ),
    );

    expect(requestCount, 0);
    expect(core.configureCount, 0);
    expect(
      selectedRoutes.single.kind,
      TranslationExecutionRouteKind.unavailable,
    );
    final subtitleRoutes = await service.snapshotSubtitleRoutes();
    expect(
      subtitleRoutes[TranslationDirection.englishToChinese]!.kind,
      SubtitleTranslationRouteKind.unavailable,
    );
  });

  test(
    'fails closed when local and remote profiles both claim translation',
    () async {
      final local = _localProfile.copyWith(
        assignedRoles: const {ModelRole.translation},
      );
      final core = _Core([local, _profile]);
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response(
            '{"choices":[{"message":{"content":"不应使用"}}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );
      addTearDown(service.dispose);
      final selectedRoutes = <TranslationExecutionRoute>[];

      await expectLater(
        service.translate(
          'Technology improves life.',
          onRouteSelected: selectedRoutes.add,
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'ambiguous_translation_provider',
          ),
        ),
      );

      expect(requestCount, 0);
      expect(core.configureCount, 0);
      expect(
        selectedRoutes.single.kind,
        TranslationExecutionRouteKind.unavailable,
      );
    },
  );

  test(
    'disabled translation assignments do not create route conflicts',
    () async {
      final disabledLocal = _localProfile.copyWith(
        enabled: false,
        assignedRoles: const {ModelRole.translation},
      );
      final core = _Core([disabledLocal, _profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient((_) async {
          return http.Response(
            '{"choices":[{"message":{"content":"科技改善生活。"}}]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(service.dispose);

      final snapshot = await service.snapshotSubtitleRoutes();

      expect(
        snapshot[TranslationDirection.englishToChinese]!.kind,
        SubtitleTranslationRouteKind.remoteProfile,
      );
    },
  );

  test(
    'malformed provider JSON is not reported as a placeholder failure',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () =>
            MockClient((_) async => http.Response('not-json', 200)),
      );

      await expectLater(
        service.translate('The meeting starts now.'),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(core.saved, isNull);
      service.dispose();
    },
  );

  test(
    'live subtitle provider failure does not retry and block the queue',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response('unavailable', 503);
        }),
      );
      final routes = await service.snapshotSubtitleRoutes();
      final route = routes[TranslationDirection.englishToChinese]!;

      await expectLater(
        service.translateSubtitle(
          'The meeting starts now.',
          requestId: 'subtitle-retry-check',
          direction: TranslationDirection.englishToChinese,
          routeSnapshot: route,
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'remote_service_error',
          ),
        ),
      );
      expect(requestCount, 1);
      service.dispose();
    },
  );

  test(
    'roleless loopback API does not override bundled local translation',
    () async {
      final core = _Core([_localCompatibleProfile]);
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"千问译文"}}]}'),
            200,
          );
        }),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );

      await service.translate('Technology changes our lives.');

      expect(core.configuredModelPath, r'D:\models\bundled-en-zh');
      expect(requestCount, 0);
      service.dispose();
    },
  );

  test('screenshot translation does not use roleless Qwen when bundled local exists', () async {
    final core = _Core([_localCompatibleProfile]);
    var requestCount = 0;
    final selectedRoutes = <TranslationExecutionRoute>[];
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => MockClient((_) async {
        requestCount += 1;
        return http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"不应使用的云端译文"}}]}'),
          200,
        );
      }),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\bundled-en-zh',
    );

    await service.translate(
      'Recognized text from screenshot',
      origin: 'screenshot_translation',
      historyEntryId: 'screenshot-local-default',
      screenshotCaptureId: 'capture-local-default',
      onRouteSelected: selectedRoutes.add,
    );

    expect(
      selectedRoutes.single.kind,
      TranslationExecutionRouteKind.localModel,
    );
    expect(core.configuredModelPath, r'D:\models\bundled-en-zh');
    expect(core.saved?.origin, 'screenshot_translation');
    expect(core.saved?.screenshotCaptureId, 'capture-local-default');
    expect(requestCount, 0);
    service.dispose();
  });

  test(
    'subtitle snapshot prefers bundled local model over a roleless Qwen API',
    () async {
      final core = _Core([_localCompatibleProfile]);
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"千问译文"}}]}'),
            200,
          );
        }),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );

      final routes = await service.snapshotSubtitleRoutes();
      final route = routes[TranslationDirection.englishToChinese]!;

      expect(route.kind, SubtitleTranslationRouteKind.bundledLocal);
      expect(route.bundledModelPath, r'D:\models\bundled-en-zh');
      await service.translateSubtitle(
        'Technology changes our lives.',
        requestId: 'subtitle-default-local-route',
        direction: TranslationDirection.englishToChinese,
        routeSnapshot: route,
      );

      expect(core.configuredModelPath, r'D:\models\bundled-en-zh');
      expect(requestCount, 0);
      service.dispose();
    },
  );

  test(
    'explicitly assigned Qwen remains the subtitle translation provider',
    () async {
      const explicitlyAssignedQwen = ProviderProfileData(
        id: 'qwen.local',
        displayName: '千问本机接口',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'qwen3.5:4b',
        endpoint: 'http://127.0.0.1:11434/v1',
        assignedRoles: {ModelRole.translation},
      );
      final core = _Core([explicitlyAssignedQwen]);
      var requestCount = 0;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient((_) async {
          requestCount += 1;
          return http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"明确指定的千问译文"}}]}'),
            200,
          );
        }),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );

      final route = (await service
          .snapshotSubtitleRoutes())[TranslationDirection.englishToChinese]!;
      expect(route.kind, SubtitleTranslationRouteKind.remoteProfile);
      expect(route.profile?.id, explicitlyAssignedQwen.id);

      final result = await service.translateSubtitle(
        'The meeting starts now.',
        requestId: 'explicit-qwen-subtitle',
        direction: TranslationDirection.englishToChinese,
        routeSnapshot: route,
      );

      expect(result, '明确指定的千问译文');
      expect(requestCount, 1);
      expect(core.configuredModelPath, isNull);
      // Live subtitles deliberately do not create one translation-history row
      // per caption; the session history owns those lines instead.
      expect(core.saved, isNull);
      service.dispose();
    },
  );

  test('translation_origin_reaches_history_for_all_provider_routes', () async {
    for (final origin in ['quick_translation', 'screenshot_translation']) {
      for (final route in [
        'local',
        'remote',
        'dictionary',
        'chinese_dictionary',
      ]) {
        final core = _Core(
          route == 'local'
              ? [_localProfile]
              : route == 'remote'
              ? [_profile]
              : [],
        );
        final secrets = ProviderSecretStore(_MemorySecrets());
        if (route == 'remote') {
          await secrets.saveApiKey(_profile.id, 'test-key');
        }
        final service = QuickTranslationService(
          coreFactory: () => core,
          secrets: secrets,
          httpClientFactory: () => MockClient(
            (_) async => http.Response.bytes(
              utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
              200,
            ),
          ),
          localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
          dictionaryFallback: const LocalDictionaryService().lookup,
          chineseDictionaryFallback:
              const LocalDictionaryService().lookupChinese,
        );
        addTearDown(service.dispose);
        final selectedRoutes = <TranslationExecutionRoute>[];
        await service.translate(
          route == 'dictionary'
              ? 'hello'
              : route == 'chinese_dictionary'
              ? '你好'
              : 'Technology changes life.',
          direction: route == 'chinese_dictionary'
              ? TranslationDirection.chineseToEnglish
              : TranslationDirection.englishToChinese,
          origin: origin,
          onRouteSelected: selectedRoutes.add,
        );
        expect(selectedRoutes, hasLength(1));
        expect(selectedRoutes.single.kind, switch (route) {
          'local' => TranslationExecutionRouteKind.localModel,
          'remote' => TranslationExecutionRouteKind.remoteProvider,
          _ => TranslationExecutionRouteKind.localDictionary,
        });
        if (route == 'local') {
          expect(selectedRoutes.single.displayName, _localProfile.displayName);
        } else if (route == 'remote') {
          expect(selectedRoutes.single.displayName, _profile.displayName);
        }
        expect(
          core.saved?.origin,
          origin,
          reason: '$route must preserve origin',
        );
        expect(
          core.saved?.providerId,
          route == 'local'
              ? 'local.opus-en-zh'
              : route == 'remote'
              ? _profile.id
              : 'local.dictionary',
        );
      }
    }
  });

  test(
    'screenshot history ID reaches the local provider and history',
    () async {
      final core = _Core([_localProfile]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        idFactory: () => 'generated-translation-id',
      );

      await service.translate(
        'Technology changes life.',
        origin: 'screenshot_translation',
        historyEntryId: 'screenshot-session-42',
        screenshotCaptureId: 'screenshot-capture-42',
      );

      expect(core.translatedRequestId, 'screenshot-session-42');
      expect(core.saved?.id, 'screenshot-session-42');
      expect(core.saved?.screenshotCaptureId, 'screenshot-capture-42');
    },
  );

  test('classifies loopback compatible APIs as local routes', () async {
    for (final endpoint in [
      'http://localhost:11434/v1',
      'http://127.0.0.1:11434/v1',
      'http://127.0.0.2:11434/v1',
      'http://[::1]:11434/v1',
    ]) {
      final profile = ProviderProfileData(
        id: _localCompatibleProfile.id,
        displayName: _localCompatibleProfile.displayName,
        kind: _localCompatibleProfile.kind,
        enabled: true,
        modelId: _localCompatibleProfile.modelId,
        endpoint: endpoint,
        assignedRoles: const {ModelRole.translation},
      );
      final core = _Core([profile]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"本地译文"}}]}'),
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final selectedRoutes = <TranslationExecutionRoute>[];

      await service.translate(
        'Technology changes life.',
        onRouteSelected: selectedRoutes.add,
      );

      expect(
        selectedRoutes.single.kind,
        TranslationExecutionRouteKind.localCompatibleApi,
      );
      expect(selectedRoutes.single.displayName, '本机 Ollama');
      expect(selectedRoutes.single.toMap().containsKey('endpoint'), isFalse);
    }
  });

  test('keeps LAN compatible APIs on the network route', () async {
    const profile = ProviderProfileData(
      id: 'lan.compat',
      displayName: '局域网兼容服务',
      kind: ProviderProfileKind.remoteApi,
      enabled: true,
      modelId: 'qwen3',
      endpoint: 'http://192.168.1.8:11434/v1',
      assignedRoles: {ModelRole.translation},
    );
    final core = _Core([profile]);
    final secrets = ProviderSecretStore(_MemorySecrets());
    await secrets.saveApiKey(profile.id, 'test-key');
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: secrets,
      httpClientFactory: () => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"译文"}}]}'),
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final selectedRoutes = <TranslationExecutionRoute>[];

    await service.translate(
      'Technology changes life.',
      origin: 'screenshot_translation',
      onRouteSelected: selectedRoutes.add,
    );

    expect(
      selectedRoutes.single.kind,
      TranslationExecutionRouteKind.remoteProvider,
    );
    expect(selectedRoutes.single.toMap().containsKey('endpoint'), isFalse);
  });

  test('quick translation ignores an external history ID', () async {
    final core = _Core([_localProfile]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      idFactory: () => 'generated-quick-translation-id',
    );

    await service.translate(
      'Technology changes life.',
      historyEntryId: 'external-screenshot-id',
    );

    expect(core.translatedRequestId, 'generated-quick-translation-id');
    expect(core.saved?.id, 'generated-quick-translation-id');
  });

  test(
    'direct dictionary translation records the screenshot history ID',
    () async {
      final core = _Core([]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        dictionaryFallback: const LocalDictionaryService().lookup,
      );

      await service.translate(
        'hello',
        origin: 'screenshot_translation',
        historyEntryId: 'screenshot-dictionary-7',
      );

      expect(core.saved?.origin, 'screenshot_translation');
      expect(core.saved?.id, 'screenshot-dictionary-7');
    },
  );

  test('uses an explicitly assigned local translation provider', () async {
    final core = _Core([
      const ProviderProfileData(
        id: 'local.custom-translation',
        displayName: '自定义翻译模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'custom-translator',
        modelPath: r'D:\models\custom-translator',
        assignedRoles: {ModelRole.translation},
      ),
    ]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\bundled-en-zh',
    );

    await service.translate('Technology changes our lives.');

    expect(core.configuredModelPath, r'D:\models\custom-translator');
  });

  test('uses the local dictionary for a known single word', () async {
    final core = _Core([]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      dictionaryFallback: const LocalDictionaryService().lookup,
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    final result = await service.translate('hello');

    expect(result, '你好');
    expect(core.configuredModelPath, isNull);
    expect(core.saved?.providerId, 'local.dictionary');
    expect(core.dictionary.single.word, 'hello');
  });

  test('uses the local dictionary for a known Chinese single word', () async {
    final core = _Core([]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      chineseDictionaryFallback: const LocalDictionaryService().lookupChinese,
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    final result = await service.translate(
      '老师',
      direction: TranslationDirection.chineseToEnglish,
    );

    expect(result, 'teacher');
    expect(core.configuredModelPath, isNull);
    expect(core.saved?.providerId, 'local.dictionary');
    expect(core.dictionary.single.word, 'teacher');
  });

  test(
    'ignores a fuzzy English dictionary candidate and uses exact fallback',
    () async {
      final core = _Core([])
        ..dictionaryResultsByQuery['hello'] = [
          const DictionaryEntryData(
            id: 'licensed.helloish',
            word: 'helloish',
            ipa: '',
            partOfSpeech: 'adj.',
            meanings: ['近似但不匹配的词条'],
            example: '',
            exampleTranslation: '',
            source: 'licensed',
          ),
        ];
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        dictionaryFallback: const LocalDictionaryService().lookup,
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      );

      final result = await service.translate('hello');

      expect(result, '你好');
      expect(core.saved?.providerId, 'local.dictionary');
    },
  );

  test('uses an imported dictionary for a Chinese headword before bundled fallback', () async {
    final core = _Core([])
      ..dictionaryResultsByQuery['老师'] = [
        const DictionaryEntryData(
          id: 'licensed.educator',
          word: 'educator',
          ipa: '',
          partOfSpeech: 'n.',
          meanings: ['老师'],
          example: '',
          exampleTranslation: '',
          source: 'licensed · 用户词典',
        ),
      ];
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      chineseDictionaryFallback: const LocalDictionaryService().lookupChinese,
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    final result = await service.translate(
      '老师',
      direction: TranslationDirection.chineseToEnglish,
    );

    expect(result, 'educator');
    expect(core.saved?.providerId, 'local.dictionary');
  });

  test('uses the highest-priority enabled dictionary source', () async {
    final core = _Core([]);
    core.dictionary.addAll([
      const DictionaryEntryData(
        id: 'seed.hello',
        word: 'hello',
        ipa: '/həˈləʊ/',
        partOfSpeech: 'int.',
        meanings: ['内置你好'],
        example: 'Hello.',
        exampleTranslation: '你好。',
        source: 'yixue-basic',
      ),
      const DictionaryEntryData(
        id: 'licensed.hello',
        word: 'hello',
        ipa: '/həˈləʊ/',
        partOfSpeech: 'int.',
        meanings: ['授权你好'],
        example: 'Hello.',
        exampleTranslation: '你好。',
        source: 'licensed · 授权词典 · CC BY-NC',
      ),
    ]);
    final preferences = DictionaryPreferencesController(
      initialValue: const DictionaryPreferences(
        sources: [
          DictionarySourcePreference(
            id: 'licensed',
            displayName: '授权词典',
            license: 'CC BY-NC',
          ),
          DictionarySourcePreference(
            id: 'yixue-basic',
            displayName: '译学基础词典',
            license: '项目内置',
          ),
        ],
      ),
    );
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      dictionaryFallback: const LocalDictionaryService().lookup,
      dictionaryPreferencesController: preferences,
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    expect(await service.translate('hello'), '授权你好');
    expect(core.saved?.providerId, 'local.dictionary');
  });

  test('does not bypass a disabled built-in dictionary', () async {
    final core = _Core([]);
    final preferences = DictionaryPreferencesController(
      initialValue: const DictionaryPreferences(
        sources: [
          DictionarySourcePreference(
            id: 'yixue-basic',
            displayName: '译学基础词典',
            license: '项目内置',
            enabled: false,
          ),
        ],
      ),
    );
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      dictionaryFallback: const LocalDictionaryService().lookup,
      dictionaryPreferencesController: preferences,
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    final selectedRoutes = <TranslationExecutionRoute>[];
    await expectLater(
      service.translate('hello', onRouteSelected: selectedRoutes.add),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'no_remote_provider',
        ),
      ),
    );
    expect(
      selectedRoutes.single.kind,
      TranslationExecutionRouteKind.unavailable,
    );
  });

  test('detects Chinese input before selecting the local model', () {
    expect(
      TranslationDirection.detect(
        '老师',
        fallback: TranslationDirection.englishToChinese,
      ),
      TranslationDirection.chineseToEnglish,
    );
  });

  test('keeps the selected direction for numbers and punctuation only', () {
    expect(
      TranslationDirection.detect(
        '2026...',
        fallback: TranslationDirection.chineseToEnglish,
      ),
      TranslationDirection.chineseToEnglish,
    );
  });

  test('reuses the local model until the service is disposed', () async {
    final core = _Core([_localProfile]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    await service.translate('first');
    await service.translate('second');

    expect(core.configureCount, 1);
    expect(core.disposed, isFalse);
    service.dispose();
    expect(core.disposed, isTrue);
  });

  test('uses the bundled local model when no profile exists yet', () async {
    final core = _Core([]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      idFactory: () => 'translation-bundled-1',
    );

    final result = await service.translate('hello');

    expect(result, '本地译文');
    expect(core.configuredModelPath, r'D:\models\yixue.opus-en-zh.int8');
  });

  test(
    'uses the bundled Chinese to English model and forwards direction',
    () async {
      final core = _Core([]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
        localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
      );

      await service.translate(
        '学习打开大门。',
        direction: TranslationDirection.chineseToEnglish,
      );

      expect(core.configuredModelPath, r'D:\models\yixue.opus-zh-en.int8');
      expect(core.translatedSourceLanguage, 'chinese');
      expect(core.translatedTargetLanguage, 'english');
    },
  );

  test(
    'prepares a local subtitle model without adding translation history',
    () async {
      final core = _Core([])..localResponseText = 'Hello.';
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () => throw StateError('warm-up must stay local'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
        localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
      );
      final executor = QuickTranslationSubtitleExecutor(service);

      await executor.prepareForDirection(
        sourceLanguageCode: 'zh',
        targetLanguageCode: 'en',
      );

      expect(core.translatedSourceText, '你好。');
      expect(core.translatedSourceLanguage, 'chinese');
      expect(core.translatedTargetLanguage, 'english');
      expect(core.configuredModelPath, r'D:\models\yixue.opus-zh-en.int8');
      expect(core.saved, isNull);
      service.dispose();
    },
  );

  test(
    'uses the explicitly assigned API instead of a roleless local model',
    () async {
      final core = _Core([_profile, _localProfile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient(
          (_) async => http.Response(
            '{"choices":[{"message":{"content":"技术改变生活。"}}]}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        now: () => DateTime.parse('2026-09-09T12:00:00+08:00'),
        idFactory: () => 'translation-local-1',
      );

      final result = await service.translate('Technology changes life.');

      expect(result, '技术改变生活。');
      expect(core.configuredModelPath, isNull);
      expect(core.configuredWorkerPath, isNull);
      expect(core.saved?.providerId, _profile.id);
    },
  );

  test('uses the selected API when the local provider is disabled', () async {
    const local = ProviderProfileData(
      id: 'local.opus-en-zh',
      displayName: '译学英中轻量模型',
      kind: ProviderProfileKind.localModel,
      enabled: false,
      modelId: 'yixue.opus-en-zh.int8',
      modelPath: r'D:\models\yixue.opus-en-zh.int8',
    );
    final api = _profile;
    final core = _Core([local, api]);
    final secrets = ProviderSecretStore(_MemorySecrets());
    await secrets.saveApiKey(api.id, 'test-key');
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: secrets,
      httpClientFactory: () => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
          200,
        ),
      ),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    expect(await service.translate('Technology changes life.'), '技术改变生活。');
    expect(core.configuredModelPath, isNull);
    expect(core.saved?.providerId, api.id);
  });

  test('uses the selected API instead of the bundled model when no local profile is enabled', () async {
    final explicitlySelectedApi = ProviderProfileData(
      id: _profile.id,
      displayName: _profile.displayName,
      kind: _profile.kind,
      enabled: true,
      modelId: _profile.modelId,
      endpoint: _profile.endpoint,
      assignedRoles: const {ModelRole.translation},
    );
    final core = _Core([explicitlySelectedApi]);
    final secrets = ProviderSecretStore(_MemorySecrets());
    await secrets.saveApiKey(_profile.id, 'test-key');
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: secrets,
      httpClientFactory: () => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
          200,
        ),
      ),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
    );

    expect(await service.translate('Technology changes life.'), '技术改变生活。');
    expect(core.configuredModelPath, isNull);
    expect(core.saved?.providerId, _profile.id);
  });

  test('reports the remote provider before submitting OCR text', () async {
    final core = _Core([_profile]);
    final secrets = ProviderSecretStore(_MemorySecrets());
    await secrets.saveApiKey(_profile.id, 'test-key');
    final events = <String>[];
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: secrets,
      httpClientFactory: () => MockClient((_) async {
        events.add('request');
        return http.Response.bytes(
          utf8.encode('{"choices":[{"message":{"content":"可见 YXFMT 文本"}}]}'),
          200,
        );
      }),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    await service.translate(
      'visible OCR text',
      origin: 'screenshot_translation',
      onRouteSelected: (route) {
        events.add('route:${route.displayName}');
      },
    );

    expect(events, ['route:${_profile.displayName}', 'request']);
  });

  test('honors the persisted translation role selection', () async {
    final selectedPath = r'D:\models\custom-translator';
    final customProfile = ProviderProfileData(
      id: 'local.custom',
      displayName: '自定义英中模型',
      kind: ProviderProfileKind.localModel,
      enabled: true,
      modelId: 'custom-model',
      modelPath: selectedPath,
    );
    final core = _Core([_localProfile, customProfile])
      ..catalog.add(
        ModelCatalogEntryData(
          id: 'catalog.custom',
          path: selectedPath,
          displayName: '自定义英中模型',
          family: 'yixue_translation',
          readiness: 'ready_to_validate',
          capabilities: ['translation'],
          assignedRoles: ['translation'],
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        ),
      );
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );

    await service.translate('Technology changes life.');

    expect(core.configuredModelPath, selectedPath);
  });

  test(
    'ignores unsupported local understanding role when inferring translation',
    () async {
      final core = _Core([
        const ProviderProfileData(
          id: 'local-understanding',
          displayName: '本地理解模型',
          kind: ProviderProfileKind.localModel,
          enabled: true,
          modelId: 'yixue.en-zh-understanding',
          modelPath: r'D:\models\understanding',
          assignedRoles: {ModelRole.understanding},
        ),
        const ProviderProfileData(
          id: 'local-legacy',
          displayName: '旧翻译模型',
          kind: ProviderProfileKind.localModel,
          enabled: true,
          modelId: 'yixue.en-zh-legacy',
          modelPath: r'D:\models\legacy',
        ),
      ]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );

      await service.translate('Technology changes our lives.');

      expect(core.configuredModelPath, r'D:\models\legacy');
    },
  );

  test('legacy local understanding assignment does not block Japanese-to-Korean inference', () async {
    final core = _Core([
      const ProviderProfileData(
        id: 'local.legacy-understanding',
        displayName: '旧本地理解模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'legacy-understanding',
        modelPath: r'D:\models\understanding',
        assignedRoles: {ModelRole.understanding},
      ),
      const ProviderProfileData(
        id: 'local.ja-ko',
        displayName: '日译韩模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'yixue.ja-ko',
        modelPath: r'D:\models\yixue.ja-ko',
      ),
    ]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
    );
    addTearDown(service.dispose);

    final routes = await service.snapshotSubtitleRoutes();

    expect(
      routes[TranslationDirection.japaneseToKorean]!.kind,
      SubtitleTranslationRouteKind.localProfile,
    );
    expect(
      routes[TranslationDirection.japaneseToKorean]!.profile?.id,
      'local.ja-ko',
    );
  });

  test(
    'does not route a persisted English-to-Chinese model to Chinese-to-English',
    () async {
      final selectedPath = r'D:\models\custom-en-zh';
      final core =
          _Core([
              ProviderProfileData(
                id: 'local.custom-en-zh',
                displayName: '自定义英中模型',
                kind: ProviderProfileKind.localModel,
                enabled: true,
                modelId: 'custom-model',
                modelPath: selectedPath,
                assignedRoles: {ModelRole.translation},
              ),
            ])
            ..localResponseText = 'local translation'
            ..catalog.add(
              ModelCatalogEntryData(
                id: 'catalog.custom-en-zh',
                path: selectedPath,
                displayName: '自定义英中模型',
                family: 'transformers',
                readiness: 'runtime_required',
                capabilities: const ['translation'],
                assignedRoles: const ['translation'],
                sourceLanguage: 'english',
                targetLanguage: 'chinese',
              ),
            );
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
        localChineseToEnglishModelPath: r'D:\models\bundled-zh-en',
      );

      await service.translate(
        '你好',
        direction: TranslationDirection.chineseToEnglish,
      );

      expect(core.configuredModelPath, r'D:\models\bundled-zh-en');
    },
  );

  test(
    'routes separate explicitly enabled local models by translation direction',
    () async {
      const englishToChinesePath = r'D:\models\custom-en-zh';
      const chineseToEnglishPath = r'D:\models\custom-zh-en';
      const englishToChineseProfile = ProviderProfileData(
        id: 'local.custom-en-zh',
        displayName: '英译中模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'custom-en-zh',
        modelPath: englishToChinesePath,
        assignedRoles: {ModelRole.translation},
      );
      const chineseToEnglishProfile = ProviderProfileData(
        id: 'local.custom-zh-en',
        displayName: '中译英模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'custom-zh-en',
        modelPath: chineseToEnglishPath,
        assignedRoles: {ModelRole.translation},
      );
      final core = _Core([englishToChineseProfile, chineseToEnglishProfile])
        ..catalog.addAll([
          const ModelCatalogEntryData(
            id: 'catalog.custom-en-zh',
            path: englishToChinesePath,
            displayName: '英译中模型',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'english',
            targetLanguage: 'chinese',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.custom-zh-en',
            path: chineseToEnglishPath,
            displayName: '中译英模型',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'chinese',
            targetLanguage: 'english',
          ),
        ]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      );
      addTearDown(service.dispose);

      final routes = await service.snapshotSubtitleRoutes();
      expect(
        routes[TranslationDirection.englishToChinese]!.profile?.id,
        englishToChineseProfile.id,
      );
      expect(
        routes[TranslationDirection.chineseToEnglish]!.profile?.id,
        chineseToEnglishProfile.id,
      );

      await service.translate('Technology changes life.');
      expect(core.configuredModelPath, englishToChinesePath);
      core.localResponseText = 'Life is changing.';
      await service.translate(
        '生活在变化。',
        direction: TranslationDirection.chineseToEnglish,
      );
      expect(core.configuredModelPath, chineseToEnglishPath);
    },
  );

  test('fails closed when multiple catalog models match the same translation direction', () async {
    const firstPath = r'D:\models\custom-en-zh-a';
    const secondPath = r'D:\models\custom-en-zh-b';
    final core =
        _Core([
            const ProviderProfileData(
              id: 'local.catalog-a',
              displayName: '英中模型甲',
              kind: ProviderProfileKind.localModel,
              enabled: true,
              modelId: 'custom-a',
              modelPath: firstPath,
              assignedRoles: {ModelRole.translation},
            ),
            const ProviderProfileData(
              id: 'local.catalog-b',
              displayName: '英中模型乙',
              kind: ProviderProfileKind.localModel,
              enabled: true,
              modelId: 'custom-b',
              modelPath: secondPath,
              assignedRoles: {ModelRole.translation},
            ),
          ])
          ..catalog.addAll([
            const ModelCatalogEntryData(
              id: 'catalog.custom-en-zh-a',
              path: firstPath,
              displayName: '英中模型甲',
              family: 'transformers',
              readiness: 'runtime_required',
              capabilities: ['translation'],
              assignedRoles: ['translation'],
              sourceLanguage: 'english',
              targetLanguage: 'chinese',
            ),
            const ModelCatalogEntryData(
              id: 'catalog.custom-en-zh-b',
              path: secondPath,
              displayName: '英中模型乙',
              family: 'transformers',
              readiness: 'runtime_required',
              capabilities: ['translation'],
              assignedRoles: ['translation'],
              sourceLanguage: 'english',
              targetLanguage: 'chinese',
            ),
          ]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\bundled-en-zh',
      localChineseToEnglishModelPath: r'D:\models\bundled-zh-en',
    );
    addTearDown(service.dispose);
    final selectedRoutes = <TranslationExecutionRoute>[];

    await expectLater(
      service.translate(
        'Technology changes life.',
        onRouteSelected: selectedRoutes.add,
      ),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'ambiguous_translation_provider',
        ),
      ),
    );

    expect(core.configureCount, 0);
    expect(
      selectedRoutes.single.kind,
      TranslationExecutionRouteKind.unavailable,
    );
    final subtitleRoutes = await service.snapshotSubtitleRoutes();
    expect(
      subtitleRoutes[TranslationDirection.englishToChinese]!.kind,
      SubtitleTranslationRouteKind.unavailable,
    );
    expect(
      subtitleRoutes[TranslationDirection.chineseToEnglish]!.kind,
      SubtitleTranslationRouteKind.bundledLocal,
    );
    core.localResponseText = 'Life is changing.';
    await service.translateSubtitle(
      '生活在变化。',
      requestId: 'bundled-reverse-direction',
      direction: TranslationDirection.chineseToEnglish,
      routeSnapshot: subtitleRoutes[TranslationDirection.chineseToEnglish]!,
    );
    expect(core.configuredModelPath, r'D:\models\bundled-zh-en');
  });

  test(
    'skips an assigned catalog entry that is not configured locally',
    () async {
      final selectedPath = r'D:\models\configured-en-zh';
      final configuredProfile = ProviderProfileData(
        id: 'local.configured',
        displayName: '已配置翻译模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'configured-model',
        modelPath: selectedPath,
      );
      final core = _Core([configuredProfile])
        ..catalog.addAll([
          const ModelCatalogEntryData(
            id: 'catalog.missing',
            path: r'D:\models\missing-en-zh',
            displayName: '未配置翻译模型',
            family: 'yixue_translation',
            readiness: 'ready_to_validate',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
          ),
          ModelCatalogEntryData(
            id: 'catalog.configured',
            path: selectedPath,
            displayName: '已配置翻译模型',
            family: 'yixue_translation',
            readiness: 'ready_to_validate',
            capabilities: const ['translation'],
            assignedRoles: const ['translation'],
          ),
        ]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\bundled-en-zh',
      );

      await service.translate('Technology changes life.');

      expect(core.configuredModelPath, selectedPath);
    },
  );

  test('protects and restores formatting around local translation', () async {
    final core = _Core([])..localResponseText = '请在 YXFMT 打开文件，时间为 YXFMT。';
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      idFactory: () => 'translation-format-local-1',
    );

    final result = await service.translate('Open report_v2.3.pdf at 14:30.');

    expect(core.translatedSourceText, 'Open YXFMT at YXFMT.');
    expect(result, '请在 report_v2.3.pdf 打开文件，时间为 14:30。');
    expect(core.saved?.translatedText, result);
  });

  test(
    'applies a local directional terminology rule through placeholders',
    () async {
      final core = _Core([])..localResponseText = '推理 YXTERM 已就绪。';
      final terminology = TranslationTerminologyController(
        initialValue: const TranslationTerminology([
          TranslationTermRule(
            id: 'engine',
            source: 'inference engine',
            target: '推理引擎',
            direction: TerminologyDirection.englishToChinese,
          ),
        ]),
      );
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
        terminologyController: terminology,
      );

      final result = await service.translate('The inference engine is ready.');

      expect(core.translatedSourceText, 'The YXTERM is ready.');
      expect(result, '推理 推理引擎 已就绪。');
      expect(core.saved?.translatedText, result);
    },
  );

  test('rejects a model result that loses protected formatting', () async {
    final core = _Core([])..localResponseText = '模型删除了占位符。';
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
    );

    await expectLater(
      service.translate('Open v2.1.'),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'format_integrity_failed',
        ),
      ),
    );
    expect(core.saved, isNull);
  });

  test('rejects a locally generated collapsed repeated result', () async {
    final core = _Core([])..localResponseText = '哈哈哈哈哈哈哈哈';
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
    );

    await expectLater(
      service.translate('hello'),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'suspicious_model_output',
        ),
      ),
    );
    expect(core.saved, isNull);
  });

  test(
    'rejects an English result that was not translated to Chinese',
    () async {
      final core = _Core(const [])
        ..localResponseText = 'Technology changes the way we work.';
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      );

      await expectLater(
        service.translate('Technology changes life.'),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'suspicious_model_output',
          ),
        ),
      );
      expect(core.saved, isNull);
    },
  );

  test('rejects a Chinese result that was not translated to English', () async {
    final core = _Core(const [])..localResponseText = '技术正在改变我们的生活方式。';
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
    );

    await expectLater(
      service.translate(
        '技术改变生活。',
        direction: TranslationDirection.chineseToEnglish,
      ),
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'suspicious_model_output',
        ),
      ),
    );
    expect(core.saved, isNull);
  });

  test(
    'translates with enabled provider then records the successful result',
    () async {
      final core = _Core([_profile]);
      final secrets = ProviderSecretStore(_MemorySecrets());
      await secrets.saveApiKey(_profile.id, 'test-key');
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: secrets,
        httpClientFactory: () => MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('{"choices":[{"message":{"content":"技术改变生活。"}}]}'),
            200,
          ),
        ),
        now: () => DateTime.parse('2026-09-09T12:00:00+08:00'),
        idFactory: () => 'translation-1',
      );

      final result = await service.translate('Technology changes life.');

      expect(result, '技术改变生活。');
      expect(core.saved?.sourceText, 'Technology changes life.');
      expect(core.saved?.translatedText, '技术改变生活。');
      expect(core.saved?.providerId, _profile.id);
    },
  );

  test('protects and restores formatting around remote translation', () async {
    final core = _Core([_profile]);
    final secrets = ProviderSecretStore(_MemorySecrets());
    await secrets.saveApiKey(_profile.id, 'test-key');
    String? sentSource;
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: secrets,
      httpClientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        sentSource =
            (messages.last as Map<String, dynamic>)['content'] as String;
        return http.Response.bytes(
          utf8.encode(
            '{"choices":[{"message":{"content":"请阅读 YXFMT，版本为 YXFMT。"}}]}',
          ),
          200,
        );
      }),
      idFactory: () => 'translation-format-remote-1',
    );

    final result = await service.translate(
      'Read https://example.invalid/help in v2.1.',
    );

    expect(sentSource, 'Read YXFMT in YXFMT.');
    expect(result, '请阅读 https://example.invalid/help，版本为 v2.1。');
    expect(core.saved?.translatedText, result);
  });

  test('does not record a failed translation', () async {
    final core = _Core([]);
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () =>
          MockClient((_) async => http.Response('{}', 200)),
    );

    await expectLater(
      service.translate('hello'),
      throwsA(
        isA<QuickTranslationException>().having(
          (e) => e.code,
          'code',
          'no_remote_provider',
        ),
      ),
    );
    expect(core.saved, isNull);
  });

  test(
    'network-assisted mode never falls back without a search adapter',
    () async {
      final core = _Core([]);
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        dictionaryFallback: const LocalDictionaryService().lookup,
      );

      await expectLater(
        service.translate(
          'hello',
          options: const TranslationRequestOptions(webSearchEnabled: true),
        ),
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'web_search_unavailable',
          ),
        ),
      );
      expect(core.saved, isNull);
    },
  );

  test('cancels an active local translation without saving history', () async {
    final core = _Core([])
      ..pendingTranslation = Completer<LocalTranslationResultData>();
    final service = QuickTranslationService(
      coreFactory: () => core,
      secrets: ProviderSecretStore(_MemorySecrets()),
      httpClientFactory: () => throw StateError('API client must stay unused'),
      localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
      localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      idFactory: () => 'translation-cancel-1',
    );

    final translation = service.translate('cancel me');
    final cancelledResult = expectLater(
      translation,
      throwsA(
        isA<QuickTranslationException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(await service.cancelActiveTranslation(), isTrue);
    await cancelledResult;
    expect(core.cancelledTranslationId, 'translation-cancel-1');
    expect(core.saved, isNull);
  });

  test(
    'late local cancellation cannot cancel the next serialized translation',
    () async {
      final core = _LateCancellationCore();
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      );
      addTearDown(service.dispose);

      final oldTranslation = service.translate(
        'first local translation',
        operationId: 'old-local-operation',
      );
      await core.oldTranslationStarted.future;
      final lateCancellation = service.cancelTranslation('old-local-operation');
      final nextTranslation = service.translate(
        'next local translation',
        operationId: 'next-local-operation',
      );

      core.oldTranslation.complete(
        const LocalTranslationResultData(
          requestId: 'old-local-operation',
          providerId: 'local.test',
          text: '第一条正常完成',
        ),
      );
      expect(await oldTranslation, '第一条正常完成');
      await core.nextTranslationStarted.future;

      core.cancellationResult.complete(true);
      expect(await lateCancellation, isTrue);
      core.nextTranslation.complete(
        const LocalTranslationResultData(
          requestId: 'next-local-operation',
          providerId: 'local.test',
          text: '第二条也正常完成',
        ),
      );
      expect(await nextTranslation, '第二条也正常完成');
    },
  );

  test(
    'cancels a local translation while model configuration is still running',
    () async {
      final core = _Core([])..configureLocalTranslationGate = Completer<void>();
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      );
      addTearDown(service.dispose);

      final translation = service.translate(
        'cancel during model setup',
        operationId: 'cancel-during-local-config',
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        await service.cancelTranslation('cancel-during-local-config'),
        isTrue,
      );
      core.configureLocalTranslationGate!.complete();
      await expectLater(
        translation,
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(core.localTranslationCount, 0);
    },
  );

  test(
    'preserves an active local translation when cancellation is refused',
    () async {
      final core = _Core([])
        ..pendingTranslation = Completer<LocalTranslationResultData>()
        ..acceptLocalCancellation = false;
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
      );
      addTearDown(service.dispose);

      final translation = service.translate(
        'keep translating',
        operationId: 'local-cancel-refused',
      );
      await Future<void>.delayed(Duration.zero);

      expect(await service.cancelTranslation('local-cancel-refused'), isFalse);
      core.pendingTranslation!.complete(
        const LocalTranslationResultData(
          requestId: 'local-cancel-refused',
          providerId: 'local.test',
          text: '仍然完成的译文',
        ),
      );
      expect(await translation, '仍然完成的译文');
      expect(core.saved?.translatedText, '仍然完成的译文');
    },
  );

  test(
    'cancels a screenshot provider request with its session history ID',
    () async {
      final core = _Core([])
        ..pendingTranslation = Completer<LocalTranslationResultData>();
      final service = QuickTranslationService(
        coreFactory: () => core,
        secrets: ProviderSecretStore(_MemorySecrets()),
        httpClientFactory: () =>
            throw StateError('API client must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
        idFactory: () => 'generated-translation-id',
      );

      final translation = service.translate(
        'cancel screenshot translation',
        origin: 'screenshot_translation',
        historyEntryId: 'screenshot-session-cancel-9',
      );
      final cancelledResult = expectLater(
        translation,
        throwsA(
          isA<QuickTranslationException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(await service.cancelActiveTranslation(), isTrue);
      await cancelledResult;
      expect(core.cancelledTranslationId, 'screenshot-session-cancel-9');
      expect(core.saved, isNull);
    },
  );
}
