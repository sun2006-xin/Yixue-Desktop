import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

void main() {
  test('native core response decoding normalizes malformed payload errors', () {
    expect(
      () => decodeCoreResponseForTesting('{broken'),
      throwsA(
        isA<CoreBridgeException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(
      () => decodeCoreResponseForTesting('[]'),
      throwsA(
        isA<CoreBridgeException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(
      () => decodeCoreResponseForTesting(
        '{"ok":false,"error":{"code":7,"message":false}}',
      ),
      throwsA(
        isA<CoreBridgeException>()
            .having((error) => error.code, 'code', 'core_error')
            .having(
              (error) => error.message,
              'message',
              'native core operation failed',
            ),
      ),
    );
  });

  test('missing_origin_defaults_to_quick_translation', () {
    final legacy = <String, dynamic>{
      'id': 'legacy',
      'source_language': 'english',
      'target_language': 'chinese',
      'source_text': 'Hello',
      'translated_text': '你好',
      'provider_id': 'local.dictionary',
      'created_at': '2026-10-06T12:00:00Z',
    };
    expect(
      TranslationHistoryEntryData.fromJson(legacy).origin,
      'quick_translation',
    );
    expect(TranslationHistoryEntryData.fromJson(legacy).captureId, 'legacy');
    final screenshot = TranslationHistoryEntryData.fromJson({
      ...legacy,
      'origin': 'screenshot_translation',
    });
    expect(screenshot.origin, 'screenshot_translation');
    expect(screenshot.captureId, 'legacy');
    final versionedScreenshot = TranslationHistoryEntryData.fromJson({
      ...legacy,
      'id': 'legacy-v2',
      'origin': 'screenshot_translation',
      'screenshot_capture_id': 'legacy',
    });
    expect(versionedScreenshot.captureId, 'legacy');
    expect(
      const CompletedTranslationData(
        id: 'legacy',
        sourceText: 'Hello',
        translatedText: '你好',
        providerId: 'local.dictionary',
        createdAt: '2026-10-06T12:00:00Z',
      ).toJson()['origin'],
      'quick_translation',
    );
    expect(
      const CompletedTranslationData(
        id: 'screenshot',
        sourceText: 'Hello',
        translatedText: '你好',
        providerId: 'local.dictionary',
        createdAt: '2026-10-06T12:00:00Z',
        origin: 'screenshot_translation',
        screenshotCaptureId: 'screenshot-capture',
      ).toJson()['origin'],
      'screenshot_translation',
    );
    expect(
      const CompletedTranslationData(
        id: 'screenshot-v2',
        sourceText: 'Hello',
        translatedText: '你好',
        providerId: 'local.dictionary',
        createdAt: '2026-10-06T12:00:00Z',
        origin: 'screenshot_translation',
        screenshotCaptureId: 'screenshot-capture',
      ).toJson()['screenshot_capture_id'],
      'screenshot-capture',
    );
  });

  test('screenshot translation history preserves optional OCR alignment', () {
    final layout = <String, Object?>{
      'version': 1,
      'coordinateSpace': 'image_pixels',
      'imageWidth': 1,
      'imageHeight': 1,
      'sourceText': 'Hello world',
      'blocks': [
        {'text': 'Hello world', 'left': 0, 'top': 0, 'width': 1, 'height': 1},
      ],
    };
    const indices = <int>[0];
    final draft = const CompletedTranslationData(
      id: 'screenshot-aligned',
      sourceText: 'Hello world',
      translatedText: '你好，世界',
      providerId: 'local-test',
      createdAt: '2026-10-07T08:30:00.000Z',
      origin: 'screenshot_translation',
      screenshotCaptureId: 'capture-1',
    );
    final encoded = CompletedTranslationData(
      id: draft.id,
      sourceText: draft.sourceText,
      translatedText: draft.translatedText,
      providerId: draft.providerId,
      createdAt: draft.createdAt,
      origin: draft.origin,
      screenshotCaptureId: draft.screenshotCaptureId,
      screenshotOcrLayout: layout,
      translatedSourceBlockIndices: indices,
    ).toJson();
    expect(encoded['screenshot_ocr_layout'], layout);
    expect(encoded['translated_source_block_indices'], indices);

    final decoded = TranslationHistoryEntryData.fromJson({
      'id': draft.id,
      'source_language': 'english',
      'target_language': 'chinese',
      'source_text': draft.sourceText,
      'translated_text': draft.translatedText,
      'provider_id': draft.providerId,
      'created_at': draft.createdAt,
      'origin': 'screenshot_translation',
      'screenshot_capture_id': 'capture-1',
      ...encoded,
    });
    expect(decoded.screenshotOcrLayout, layout);
    expect(decoded.translatedSourceBlockIndices, indices);

    final legacy = TranslationHistoryEntryData.fromJson({
      'id': 'legacy',
      'source_language': 'english',
      'target_language': 'chinese',
      'source_text': 'Hello world',
      'translated_text': '你好，世界',
      'provider_id': 'local-test',
      'created_at': '2026-10-07T08:30:00.000Z',
      'origin': 'screenshot_translation',
    });
    expect(legacy.screenshotOcrLayout, isNull);
    expect(legacy.translatedSourceBlockIndices, isNull);
  });

  test('favorite word page data decodes dictionary and note details', () {
    final page = FavoriteWordPageData.fromJson({
      'has_more': false,
      'records': [
        {
          'word': 'consistency',
          'favorited_at': '2026-09-14 12:00:00',
          'language_pair': 'en-zh',
          'dictionary_entries': [
            {
              'id': 'seed.consistency',
              'word': 'consistency',
              'ipa': '/kənˈsɪstənsi/',
              'part_of_speech': 'n.',
              'meanings': ['一致性'],
              'example': 'Consistency is the key to success.',
              'example_translation': '一致性是成功的关键。',
              'source': 'yixue-basic',
            },
          ],
          'annotation': {
            'word': 'consistency',
            'note': '写作常用',
            'added_to_learning': true,
            'updated_at': '2026-09-14T12:00:00+08:00',
          },
        },
      ],
    });

    expect(page.hasMore, isFalse);
    expect(page.records.single.word, 'consistency');
    expect(
      page.records.single.dictionaryEntries.single.example,
      contains('key'),
    );
    expect(page.records.single.annotation?.addedToLearning, isTrue);
  });

  test('native bridge reads health from the real Rust DLL', () {
    if (!Platform.isWindows) {
      return;
    }

    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(
      libraryPath,
      isNotNull,
      reason: 'YIXUE_CORE_DLL must point to the test DLL',
    );

    final bridge = NativeCoreBridge.open(path: libraryPath!);
    final health = bridge.health();

    expect(health.schemaVersion, 1);
    expect(health.coreVersion, '0.1.0');
  });

  test('persistent native engine saves provider metadata across reopen', () {
    if (!Platform.isWindows) {
      return;
    }

    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(
      libraryPath,
      isNotNull,
      reason: 'YIXUE_CORE_DLL must point to the test DLL',
    );
    final directory = Directory.systemTemp.createTempSync('yixue-dart-engine-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final databasePath = '${directory.path}\\yixue.db';

    final first = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: databasePath,
    );
    first.saveProviderProfile(
      const ProviderProfileData(
        id: 'remote.openai-compatible',
        displayName: 'OpenAI compatible',
        kind: ProviderProfileKind.remoteApi,
        enabled: true,
        modelId: 'translation-model',
        endpoint: 'https://api.example.com/v1',
        secretRef: 'yixue.provider.remote.openai-compatible.api-key',
        assignedRoles: {ModelRole.translation, ModelRole.understanding},
      ),
    );
    first.dispose();

    final reopened = NativeCoreBridge.open(
      path: libraryPath,
      databasePath: databasePath,
    );
    addTearDown(reopened.dispose);
    final profiles = reopened.listProviderProfiles();

    expect(profiles, hasLength(1));
    expect(profiles.single.id, 'remote.openai-compatible');
    expect(
      profiles.single.secretRef,
      'yixue.provider.remote.openai-compatible.api-key',
    );
    expect(profiles.single.assignedRoles, {
      ModelRole.translation,
      ModelRole.understanding,
    });
  });

  test('persistent native engine restores discovered model roles', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync('yixue-catalog-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final databasePath = '${directory.path}\\yixue.db';
    final first = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: databasePath,
    );
    first.saveModelCatalogEntry(
      const ModelCatalogEntryData(
        id: 'catalog.qwen.1234',
        path: r'D:\models\Qwen3.5-4B',
        displayName: 'Qwen3.5-4B',
        family: 'qwen',
        readiness: 'runtime_required',
        capabilities: ['translation', 'summarization'],
        assignedRoles: ['understanding'],
      ),
    );
    first.dispose();

    final reopened = NativeCoreBridge.open(
      path: libraryPath,
      databasePath: databasePath,
    );
    addTearDown(reopened.dispose);
    final models = reopened.listModelCatalogEntries();

    expect(models, hasLength(1));
    expect(models.single.displayName, 'Qwen3.5-4B');
    expect(models.single.assignedRoles, ['understanding']);
  });

  test('persistent native engine returns recorded home activity', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync('yixue-home-engine-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    bridge.recordActivity(
      const ActivityEventData(
        id: 'reading-1',
        kind: ActivityKind.reading,
        title: 'Paper.pdf',
        detail: '阅读器 · 第 8 页',
        durationSeconds: 1380,
        itemCount: 8,
        occurredAt: '2026-09-09T09:00:00+08:00',
      ),
    );
    final snapshot = bridge.homeSnapshot('2026-09-09');

    expect(snapshot.learningMinutes, 23);
    expect(snapshot.readingPages, 8);
    expect(snapshot.recent.single.title, 'Paper.pdf');
  });

  test('persistent native engine returns the versioned workbench summary', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-workbench-engine-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    bridge.recordActivity(
      const ActivityEventData(
        id: 'translation-1',
        kind: ActivityKind.translation,
        title: 'Technology changes life.',
        durationSeconds: 12,
        itemCount: 4,
        occurredAt: '2026-09-15T09:00:00+08:00',
      ),
    );
    bridge.recordActivity(
      const ActivityEventData(
        id: 'focus-1',
        kind: ActivityKind.focus,
        title: '深度学习',
        durationSeconds: 1500,
        itemCount: 1,
        occurredAt: '2026-09-15T10:00:00+08:00',
      ),
    );

    final snapshot = bridge.homeWorkbenchSnapshot('2026-09-15');

    expect(snapshot.localDate, '2026-09-15');
    expect(
      snapshot.summary.translationCount,
      const HomeMetricData.available(1),
    );
    expect(
      snapshot.summary.translationUnits,
      const HomeMetricData.available(4),
    );
    expect(snapshot.summary.focusSeconds, const HomeMetricData.available(1500));
    expect(snapshot.summary.readingArticles, const HomeMetricData.available(0));
    expect(snapshot.details.map((item) => item.id), [
      'focus-1',
      'translation-1',
    ]);
    expect(snapshot.recent.map((item) => item.id), [
      'focus-1',
      'translation-1',
    ]);
  });

  test('home workbench snapshot decodes optional details and source ids', () {
    final snapshot = HomeCoreSnapshotData.fromJson({
      'local_date': '2026-09-16',
      'summary': {
        'schema_version': 1,
        for (final key in [
          'translation_count',
          'translation_units',
          'learned_words',
          'reading_articles',
          'reading_units',
          'favorite_sentences',
          'favorite_words',
          'speaking_seconds',
          'focus_seconds',
          'focus_sessions',
        ])
          key: {'available': true, 'value': 0},
      },
      'recent': [
        {
          'id': 'recent-1',
          'kind': 'translation',
          'title': 'hello',
          'detail': null,
          'source_id': null,
          'duration_seconds': 1,
          'item_count': 1,
          'occurred_at': '2026-09-16T09:00:00+08:00',
        },
      ],
      'details': [
        {
          'id': 'reading-1',
          'kind': 'reading',
          'title': 'Paper.pdf',
          'detail': '阅读器 · 第 3 段',
          'source_id': 'source-1',
          'duration_seconds': 120,
          'item_count': 3,
          'occurred_at': '2026-09-16T09:10:00+08:00',
        },
      ],
    });

    expect(snapshot.recent.single.sourceId, isNull);
    expect(snapshot.details.single.sourceId, 'source-1');
    expect(snapshot.details.single.itemCount, 3);
  });

  test('older workbench snapshot falls back to recent as details', () {
    final snapshot = HomeCoreSnapshotData.fromJson({
      'local_date': '2026-09-16',
      'summary': {
        'schema_version': 1,
        for (final key in [
          'translation_count',
          'translation_units',
          'learned_words',
          'reading_articles',
          'reading_units',
          'favorite_sentences',
          'favorite_words',
          'speaking_seconds',
          'focus_seconds',
          'focus_sessions',
        ])
          key: {'available': true, 'value': 0},
      },
      'recent': [
        {
          'id': 'recent-1',
          'kind': 'focus',
          'title': '专注',
          'detail': null,
          'duration_seconds': 60,
          'item_count': 1,
          'occurred_at': '2026-09-16T09:00:00+08:00',
        },
      ],
    });

    expect(snapshot.details.map((item) => item.id), ['recent-1']);
  });

  test('persistent native engine lists completed translation history', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-history-engine-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    bridge.recordCompletedTranslation(
      const CompletedTranslationData(
        id: 'translation-1',
        sourceText: 'Technology changes life.',
        translatedText: '技术改变生活。',
        providerId: 'remote.example',
        createdAt: '2026-09-09T12:00:00+08:00',
      ),
    );

    final history = bridge.listTranslationHistory(limit: 10);
    expect(history, hasLength(1));
    expect(history.single.sourceText, 'Technology changes life.');
    expect(history.single.translatedText, '技术改变生活。');
  });

  test('persistent native engine validates screenshot history by exact ID', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-screenshot-history-validation-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    bridge.recordCompletedTranslation(
      const CompletedTranslationData(
        id: 'screenshot-lookup',
        sourceText: 'Exact OCR source',
        translatedText: '精确 OCR 原文',
        providerId: 'local.test',
        createdAt: '2026-10-08T12:00:00+08:00',
        origin: 'screenshot_translation',
      ),
    );
    bridge.recordCompletedTranslation(
      const CompletedTranslationData(
        id: 'quick-lookup',
        sourceText: 'Exact OCR source',
        translatedText: '普通翻译',
        providerId: 'local.test',
        createdAt: '2026-10-08T12:01:00+08:00',
      ),
    );

    expect(
      bridge.validateScreenshotTranslationHistory(
        id: 'screenshot-lookup',
        sourceText: 'Exact OCR source',
      ),
      isTrue,
    );
    expect(
      bridge.validateScreenshotTranslationHistory(
        id: 'screenshot-lookup',
        sourceText: 'different text',
      ),
      isFalse,
    );
    expect(
      bridge.validateScreenshotTranslationHistory(
        id: 'quick-lookup',
        sourceText: 'Exact OCR source',
      ),
      isFalse,
    );
    expect(
      bridge.validateScreenshotTranslationHistory(
        id: 'missing-lookup',
        sourceText: 'Exact OCR source',
      ),
      isFalse,
    );
  });

  test(
    'persistent native engine saves and reloads screenshot history summaries',
    () {
      if (!Platform.isWindows) return;
      final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
      expect(libraryPath, isNotNull);
      final directory = Directory.systemTemp.createTempSync(
        'yixue-screenshot-summary-bridge-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final databasePath = '${directory.path}\\yixue.db';
      final bridge = NativeCoreBridge.open(
        path: libraryPath!,
        databasePath: databasePath,
      );
      try {
        bridge.recordCompletedTranslation(
          const CompletedTranslationData(
            id: 'summary-history',
            sourceText: 'Exact OCR source',
            translatedText: '原译文',
            providerId: 'local.test',
            createdAt: '2026-10-09T12:00:00+08:00',
            origin: 'screenshot_translation',
          ),
        );
        bridge.saveScreenshotTranslationSummary(
          id: 'summary-history',
          sourceText: 'Exact OCR source',
          summaryText: '本地学习摘要',
        );
      } finally {
        bridge.dispose();
      }

      final reopened = NativeCoreBridge.open(
        path: libraryPath,
        databasePath: databasePath,
      );
      addTearDown(reopened.dispose);
      final history = reopened.listTranslationHistory(limit: 10);
      expect(history, hasLength(1));
      expect(history.single.summaryText, '本地学习摘要');
    },
  );

  test(
    'persistent native engine finds screenshot capture image references',
    () {
      if (!Platform.isWindows) return;
      final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
      expect(libraryPath, isNotNull);
      final directory = Directory.systemTemp.createTempSync(
        'yixue-screenshot-image-reference-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final bridge = NativeCoreBridge.open(
        path: libraryPath!,
        databasePath: '${directory.path}\\yixue.db',
      );
      addTearDown(bridge.dispose);

      bridge.recordCompletedTranslation(
        const CompletedTranslationData(
          id: 'capture-new-version',
          sourceText: 'Screenshot source',
          translatedText: '截图原文',
          providerId: 'local.test',
          createdAt: '2026-10-09T12:00:00+08:00',
          origin: 'screenshot_translation',
          screenshotCaptureId: 'shared-capture',
        ),
      );
      bridge.recordCompletedTranslation(
        const CompletedTranslationData(
          id: 'legacy-capture',
          sourceText: 'Legacy screenshot source',
          translatedText: '旧截图原文',
          providerId: 'local.test',
          createdAt: '2026-10-09T12:01:00+08:00',
          origin: 'screenshot_translation',
        ),
      );
      bridge.recordCompletedTranslation(
        const CompletedTranslationData(
          id: 'quick-capture',
          sourceText: 'Quick translation source',
          translatedText: '普通翻译',
          providerId: 'local.test',
          createdAt: '2026-10-09T12:02:00+08:00',
        ),
      );

      expect(
        bridge.referencedScreenshotCaptureIds([
          'shared-capture',
          'legacy-capture',
          'quick-capture',
          'missing-capture',
        ]).toSet(),
        {'shared-capture', 'legacy-capture'},
      );
    },
  );

  test('persistent native engine supports an offset history page', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-history-page-engine-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    for (var index = 0; index < 3; index++) {
      bridge.recordCompletedTranslation(
        CompletedTranslationData(
          id: 'translation-page-$index',
          sourceText: 'Sentence $index.',
          translatedText: '句子 $index。',
          providerId: 'local.test',
          createdAt: '2026-09-14T12:0$index:00+08:00',
        ),
      );
    }

    final page = bridge.listTranslationHistoryPage(limit: 1, offset: 1);
    expect(page, hasLength(1));
    expect(page.single.id, 'translation-page-1');
  });

  test('persistent native engine pages dictionary entries beyond fifty', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-dictionary-page-engine-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    expect(
      () => bridge.listDictionaryEntryPage(offset: -1),
      throwsA(isA<RangeError>()),
    );
    expect(
      () => bridge.listDictionaryEntryPage(offset: 0x100000000),
      throwsA(isA<RangeError>()),
    );

    for (var index = 0; index < 107; index++) {
      bridge.saveDictionaryEntry(
        DictionaryEntryData(
          id: 'dictionary-page-$index',
          word: 'pageword-${index.toString().padLeft(3, '0')}',
          ipa: '/peɪdʒ/',
          partOfSpeech: 'n.',
          meanings: ['释义 $index'],
          example: 'A page turns slowly.',
          exampleTranslation: '页面慢慢翻开。',
          source: index < 100 ? 'disabled-source' : 'enabled-source',
        ),
      );
    }

    final thirdPage = bridge.listDictionaryEntryPage(limit: 50, offset: 100);
    expect(thirdPage.entries, hasLength(7));
    expect(thirdPage.entries.first.source, 'enabled-source');
    expect(thirdPage.hasMore, isFalse);
  });

  test('persistent native engine filters history before applying the page', () {
    if (!Platform.isWindows) return;
    final libraryPath = Platform.environment['YIXUE_CORE_DLL'];
    expect(libraryPath, isNotNull);
    final directory = Directory.systemTemp.createTempSync(
      'yixue-filtered-history-page-engine-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final bridge = NativeCoreBridge.open(
      path: libraryPath!,
      databasePath: '${directory.path}\\yixue.db',
    );
    addTearDown(bridge.dispose);

    for (final translation in const [
      CompletedTranslationData(
        id: 'quick-newest',
        sourceText: 'Needle from quick translation',
        translatedText: '快速翻译结果',
        providerId: 'local.test',
        createdAt: '2026-10-07T12:03:00+08:00',
      ),
      CompletedTranslationData(
        id: 'screenshot-newer',
        sourceText: 'Needle from screenshot',
        translatedText: '截屏词条 A',
        providerId: 'local.test',
        createdAt: '2026-10-07T12:02:00+08:00',
        origin: 'screenshot_translation',
      ),
      CompletedTranslationData(
        id: 'screenshot-older',
        sourceText: 'Different source',
        translatedText: '截屏词条 Needle B',
        providerId: 'local.test',
        createdAt: '2026-10-07T12:01:00+08:00',
        origin: 'screenshot_translation',
      ),
    ]) {
      bridge.recordCompletedTranslation(translation);
    }

    final secondFilteredPage = bridge.listTranslationHistoryPage(
      limit: 1,
      offset: 1,
      origin: 'screenshot_translation',
      query: 'Needle',
    );
    expect(secondFilteredPage, hasLength(1));
    expect(secondFilteredPage.single.id, 'screenshot-older');
  });
}
