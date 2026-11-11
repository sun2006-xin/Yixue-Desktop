import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_coordinator.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_contract.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_translation_queue.dart';

void main() {
  group('multilingual subtitle translation directions', () {
    const expectedPairs = <(String, String, TranslationDirection)>[
      ('en', 'zh', TranslationDirection.englishToChinese),
      ('zh', 'en', TranslationDirection.chineseToEnglish),
      ('en', 'ja', TranslationDirection.englishToJapanese),
      ('ja', 'en', TranslationDirection.japaneseToEnglish),
      ('en', 'ko', TranslationDirection.englishToKorean),
      ('ko', 'en', TranslationDirection.koreanToEnglish),
      ('zh', 'ja', TranslationDirection.chineseToJapanese),
      ('ja', 'zh', TranslationDirection.japaneseToChinese),
      ('zh', 'ko', TranslationDirection.chineseToKorean),
      ('ko', 'zh', TranslationDirection.koreanToChinese),
      ('ja', 'ko', TranslationDirection.japaneseToKorean),
      ('ko', 'ja', TranslationDirection.koreanToJapanese),
      ('en', 'es', TranslationDirection.englishToSpanish),
      ('es', 'en', TranslationDirection.spanishToEnglish),
      ('zh', 'es', TranslationDirection.chineseToSpanish),
      ('es', 'zh', TranslationDirection.spanishToChinese),
      ('en', 'fr', TranslationDirection.englishToFrench),
      ('fr', 'en', TranslationDirection.frenchToEnglish),
      ('zh', 'fr', TranslationDirection.chineseToFrench),
      ('fr', 'zh', TranslationDirection.frenchToChinese),
      ('en', 'de', TranslationDirection.englishToGerman),
      ('de', 'en', TranslationDirection.germanToEnglish),
      ('zh', 'de', TranslationDirection.chineseToGerman),
      ('de', 'zh', TranslationDirection.germanToChinese),
      ('en', 'pt', TranslationDirection.englishToPortuguese),
      ('pt', 'en', TranslationDirection.portugueseToEnglish),
      ('zh', 'pt', TranslationDirection.chineseToPortuguese),
      ('pt', 'zh', TranslationDirection.portugueseToChinese),
      ('en', 'ru', TranslationDirection.englishToRussian),
      ('ru', 'en', TranslationDirection.russianToEnglish),
      ('zh', 'ru', TranslationDirection.chineseToRussian),
      ('ru', 'zh', TranslationDirection.russianToChinese),
    ];

    test('maps each distinct supported pair to one direction', () {
      expect(TranslationDirection.values, hasLength(32));

      for (final (source, target, expected) in expectedPairs) {
        final direction = TranslationDirection.fromLanguageCodes(
          source,
          target,
        );
        expect(direction, expected, reason: '$source -> $target');
        expect(direction!.sourceLanguageCode, source);
        expect(direction.targetLanguageCode, target);
        expect(direction.modelHint, '$source-$target');
      }

      expect(
        TranslationDirection.values.map((direction) => direction.name),
        containsAll(<String>['englishToChinese', 'chineseToEnglish']),
      );
    });

    test(
      'language selector targets only expose registered translation pairs',
      () {
        expect(
          TranslationDirection.targetLanguageCodesForSource('es'),
          <String>['en', 'zh'],
        );
        expect(
          TranslationDirection.targetLanguageCodesForSource('fr'),
          <String>['en', 'zh'],
        );
        expect(
          TranslationDirection.targetLanguageCodesForSource('ja'),
          containsAll(<String>['en', 'zh', 'ko']),
        );
        expect(
          TranslationDirection.targetLanguageCodesForSource('auto'),
          containsAll(<String>[
            'en',
            'zh',
            'ja',
            'ko',
            'es',
            'fr',
            'de',
            'pt',
            'ru',
          ]),
        );
      },
    );

    test('keeps canonical tags, readable labels, and provider names', () {
      final direction = TranslationDirection.fromLanguageCodes('ja', 'ko')!;

      expect(direction.sourceLanguageCode, 'ja');
      expect(direction.targetLanguageCode, 'ko');
      expect(direction.sourceLanguageName, '日语');
      expect(direction.targetLanguageName, '韩语');
      expect(direction.sourceLanguage, 'japanese');
      expect(direction.targetLanguage, 'korean');
      expect(direction.sourceLabel, '日语');
      expect(direction.targetLabel, '韩语');
      expect(direction.actionLabel, '日译韩');

      final spanishDirection = TranslationDirection.fromLanguageCodes(
        'es-MX',
        'zh-CN',
      )!;
      expect(spanishDirection.sourceLanguageName, '西班牙语');
      expect(spanishDirection.targetLanguageName, '中文（简体）');
      expect(spanishDirection.sourceLanguage, 'spanish');
      expect(spanishDirection.actionLabel, '西译中');

      expect(TranslationDirection.englishToChinese.sourceLanguageCode, 'en');
      expect(TranslationDirection.englishToChinese.targetLanguageCode, 'zh');
      expect(TranslationDirection.englishToChinese.sourceLanguage, 'english');
      expect(TranslationDirection.englishToChinese.targetLanguage, 'chinese');
      expect(TranslationDirection.englishToChinese.actionLabel, '英译中');

      for (final direction in TranslationDirection.values.skip(2)) {
        expect(direction.terminologyDirection, isNull, reason: direction.name);
      }
    });

    test('offers bundled bilingual models only for the legacy en-zh pair', () async {
      final service = QuickTranslationService(
        coreFactory: _EmptyCore.new,
        secrets: ProviderSecretStore(_MemorySecretBackend()),
        httpClientFactory: () => throw StateError('network must stay unused'),
        localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
        localModelPath: r'D:\models\yixue.opus-en-zh.int8',
        localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
      );

      final routes = await service.snapshotSubtitleRoutes();

      expect(
        routes[TranslationDirection.englishToChinese]?.kind,
        SubtitleTranslationRouteKind.bundledLocal,
      );
      expect(
        routes[TranslationDirection.chineseToEnglish]?.kind,
        SubtitleTranslationRouteKind.bundledLocal,
      );
      for (final direction in TranslationDirection.values.skip(2)) {
        expect(
          routes[direction]?.kind,
          SubtitleTranslationRouteKind.unavailable,
          reason:
              '${direction.sourceLanguageCode} -> '
              '${direction.targetLanguageCode} must not use a bilingual model',
        );
      }
    });

    test(
      'subtitle executor routes detected language and omits bilingual terms',
      () async {
        const profile = ProviderProfileData(
          id: 'local.compat',
          displayName: '本机兼容 Provider',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'multilingual-model',
          endpoint: 'http://127.0.0.1:8000/v1',
          assignedRoles: {ModelRole.translation},
        );
        final core = _ProfileCore(<ProviderProfileData>[profile]);
        final secrets = ProviderSecretStore(_MemorySecretBackend());
        Map<String, dynamic>? sentBody;
        final terminology = TranslationTerminologyController(
          initialValue: TranslationTerminology(<TranslationTermRule>[
            TranslationTermRule(
              id: 'legacy-zh-term',
              source: '東京',
              target: 'should-not-appear',
              direction: TerminologyDirection.chineseToEnglish,
            ),
          ]),
        );
        final service = QuickTranslationService(
          coreFactory: () => core,
          secrets: secrets,
          httpClientFactory: () => MockClient((request) async {
            sentBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response.bytes(
              utf8.encode('{"choices":[{"message":{"content":"도쿄 자막"}}]}'),
              200,
            );
          }),
          terminologyController: terminology,
        );
        addTearDown(() {
          service.dispose();
          terminology.dispose();
        });
        final executor = QuickTranslationSubtitleExecutor(
          service,
          routeSnapshots: service.snapshotSubtitleRoutes(),
        );

        final translated = await executor.translate(
          _request(
            sourceLanguageCode: 'ja',
            targetLanguageCode: 'ko',
            text: '東京',
          ),
        );

        final messages = sentBody!['messages'] as List<dynamic>;
        final systemPrompt =
            (messages.first as Map<String, dynamic>)['content'] as String;
        final userText =
            (messages.last as Map<String, dynamic>)['content'] as String;
        expect(translated, '도쿄 자막');
        expect(systemPrompt, contains('japanese to korean'));
        expect(systemPrompt, isNot(contains('should-not-appear')));
        expect(userText, '東京');
      },
    );

    test(
      'reports a missing subtitle route without calling a provider',
      () async {
        final service = QuickTranslationService(
          coreFactory: _EmptyCore.new,
          secrets: ProviderSecretStore(_MemorySecretBackend()),
          httpClientFactory: () => throw StateError(
            'an unavailable route must not make a network request',
          ),
          localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
          localModelPath: r'D:\models\yixue.opus-en-zh.int8',
          localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
        );
        addTearDown(service.dispose);
        final executor = QuickTranslationSubtitleExecutor(
          service,
          routeSnapshots: service.snapshotSubtitleRoutes(),
        );

        await expectLater(
          executor.translate(
            _request(sourceLanguageCode: 'ja', targetLanguageCode: 'en'),
          ),
          throwsA(
            isA<SubtitleTranslationFailure>().having(
              (error) => error.code,
              'code',
              'translation_route_unavailable',
            ),
          ),
        );
      },
    );

    test(
      'reports a missing route snapshot instead of dereferencing null',
      () async {
        final service = QuickTranslationService(
          coreFactory: _EmptyCore.new,
          secrets: ProviderSecretStore(_MemorySecretBackend()),
          httpClientFactory: () => throw StateError(
            'a missing route snapshot must not make a network request',
          ),
          localWorkerPath: r'D:\runtime\yixue_ct2_worker.exe',
          localModelPath: r'D:\models\yixue.opus-en-zh.int8',
          localChineseToEnglishModelPath: r'D:\models\yixue.opus-zh-en.int8',
        );
        addTearDown(service.dispose);
        final executor = QuickTranslationSubtitleExecutor(
          service,
          routeSnapshots: Future.value(
            <TranslationDirection, SubtitleTranslationRouteSnapshot>{},
          ),
        );

        await expectLater(
          executor.translate(
            _request(sourceLanguageCode: 'ja', targetLanguageCode: 'en'),
          ),
          throwsA(
            isA<SubtitleTranslationFailure>().having(
              (error) => error.code,
              'code',
              'translation_route_unavailable',
            ),
          ),
        );
      },
    );

    test(
      'normalizes regional and legacy codes, but rejects auto and unknown',
      () {
        expect(
          TranslationDirection.fromLanguageCodes('ja-JP', 'EN_us'),
          TranslationDirection.japaneseToEnglish,
        );
        expect(
          TranslationDirection.fromLanguageCodes('cmn-Hans-CN', 'ko-KR'),
          TranslationDirection.chineseToKorean,
        );
        expect(TranslationDirection.fromLanguageCodes('auto', 'en'), isNull);
        expect(TranslationDirection.fromLanguageCodes('und', 'en'), isNull);
        expect(TranslationDirection.fromLanguageCodes('xx', 'en'), isNull);
        expect(TranslationDirection.fromLanguageCodes('en', 'en'), isNull);
        expect(TranslationDirection.fromLanguageCodes('en', 'zh-Hant'), isNull);
      },
    );

    test(
      'routes automatic transcripts by their detected cue language',
      () async {
        final executor = _RecordingExecutor();
        final queue = SubtitleTranslationQueue(
          executor: executor,
          targetLanguageCode: 'en',
          requestIdFactory: () => 'auto-ja-to-en',
        );
        final transcript = TranscriptRevision(
          sessionId: 'session-1',
          captureAttemptId: 'attempt-1',
          segmentId: 'segment-1',
          sourceId: 'system-audio',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
          startMs: 0,
          endMs: 900,
          text: 'おはようございます。',
          // The runtime supplies the detected language for this finalized cue.
          languageCode: 'ja',
          revision: 0,
          isFinal: true,
        );

        final result = queue.enqueue(
          SubtitleSegment.fromTranscript(transcript),
        );
        final request = await executor.started.future.timeout(
          const Duration(seconds: 1),
        );

        expect(result.accepted, isTrue);
        expect(request.sourceLanguageCode, 'ja');
        expect(request.targetLanguageCode, 'en');
        expect(
          TranslationDirection.fromLanguageCodes(
            request.sourceLanguageCode,
            request.targetLanguageCode,
          ),
          TranslationDirection.japaneseToEnglish,
        );
        await queue.close();
      },
    );

    test('routes a finalized Chinese subtitle to English', () async {
      final executor = _RecordingExecutor();
      final queue = SubtitleTranslationQueue(
        executor: executor,
        targetLanguageCode: 'en',
        requestIdFactory: () => 'default-zh-to-en',
      );
      final coordinator = SubtitleSessionCoordinator(
        sessionId: 'session-zh-en',
        initialCaptureAttemptId: 'attempt-zh-en',
        translationQueue: queue,
      );
      expect(coordinator.markCapturing(), isTrue);
      final translatedStateFuture = coordinator.stateChanges.firstWhere(
        (state) => state.segments.any(
          (segment) =>
              segment.translationStatus == SubtitleTranslationStatus.translated,
        ),
      );

      final transcript = TranscriptRevision(
        sessionId: 'session-zh-en',
        captureAttemptId: 'attempt-zh-en',
        segmentId: 'segment-zh-en',
        sourceId: 'system-audio',
        sourceKind: SubtitleAudioSourceKind.systemOutput,
        startMs: 0,
        endMs: 900,
        text: '请问这个功能什么时候可以使用？',
        languageCode: 'zh',
        revision: 0,
        isFinal: true,
      );

      expect(coordinator.applyTranscriptRevision(transcript), isTrue);
      final request = await executor.started.future.timeout(
        const Duration(seconds: 1),
      );
      expect(request.sourceLanguageCode, 'zh');
      expect(request.targetLanguageCode, 'en');
      expect(
        TranslationDirection.fromLanguageCodes(
          request.sourceLanguageCode,
          request.targetLanguageCode,
        ),
        TranslationDirection.chineseToEnglish,
      );

      await translatedStateFuture.timeout(const Duration(seconds: 1));
      await coordinator.stop();
      expect(
        coordinator.currentState.segments.single.translationStatus,
        SubtitleTranslationStatus.translated,
      );
      expect(
        coordinator.currentState.segments.single.translatedText,
        'Good morning.',
      );
    });

    test(
      'keeps same-language auto cues without submitting a translation',
      () async {
        final executor = _RecordingExecutor();
        final queue = SubtitleTranslationQueue(
          executor: executor,
          targetLanguageCode: 'ja',
          requestIdFactory: () => 'auto-ja-to-ja',
        );
        final coordinator = SubtitleSessionCoordinator(
          sessionId: 'session-1',
          initialCaptureAttemptId: 'attempt-1',
          translationQueue: queue,
        );
        expect(coordinator.markCapturing(), isTrue);
        final transcript = TranscriptRevision(
          sessionId: 'session-1',
          captureAttemptId: 'attempt-1',
          segmentId: 'segment-1',
          sourceId: 'system-audio',
          sourceKind: SubtitleAudioSourceKind.systemOutput,
          startMs: 0,
          endMs: 900,
          text: 'おはようございます。',
          languageCode: 'ja',
          revision: 0,
          isFinal: true,
        );

        expect(coordinator.applyTranscriptRevision(transcript), isTrue);

        expect(
          coordinator.currentState.segments.single.translationStatus.name,
          'skippedSameLanguage',
        );
        expect(queue.pendingCount, 0);
        expect(executor.started.isCompleted, isFalse);
        await coordinator.stop();
      },
    );

    test('fails visibly when a transcript still says auto or und', () async {
      final service = QuickTranslationService(
        coreFactory: () =>
            throw StateError('unsupported input must stop early'),
        secrets: ProviderSecretStore(_MemorySecretBackend()),
        httpClientFactory: () => throw StateError('network must stay unused'),
      );
      final executor = QuickTranslationSubtitleExecutor(
        service,
        routeSnapshots: Future.value(
          const <TranslationDirection, SubtitleTranslationRouteSnapshot>{},
        ),
      );

      for (final language in <String>['auto', 'und']) {
        await expectLater(
          executor.translate(_request(sourceLanguageCode: language)),
          throwsA(
            isA<SubtitleTranslationFailure>().having(
              (error) => error.code,
              'code',
              'unsupported_language_pair',
            ),
          ),
        );
      }
    });
  });
}

SubtitleTranslationRequest _request({
  required String sourceLanguageCode,
  String targetLanguageCode = 'en',
  String text = 'recognized text',
}) => SubtitleTranslationRequest(
  requestId: 'request-1',
  sessionId: 'session-1',
  captureAttemptId: 'attempt-1',
  segmentId: 'segment-1',
  transcriptRevision: 0,
  text: text,
  sourceLanguageCode: sourceLanguageCode,
  targetLanguageCode: targetLanguageCode,
);

final class _RecordingExecutor implements SubtitleTranslationExecutor {
  final started = Completer<SubtitleTranslationRequest>();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async {
    started.complete(request);
    return 'Good morning.';
  }

  @override
  Future<void> cancel(String requestId) async {}
}

final class _MemorySecretBackend implements SecretBackend {
  @override
  Future<bool> containsKey(String key) async => false;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}

final class _EmptyCore implements AppCore {
  @override
  List<ProviderProfileData> listProviderProfiles() => const [];

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ProfileCore implements AppCore {
  const _ProfileCore(this.profiles);

  final List<ProviderProfileData> profiles;

  @override
  List<ProviderProfileData> listProviderProfiles() => profiles;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
