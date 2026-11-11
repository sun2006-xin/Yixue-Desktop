import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/app/yixue_app.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/storage_policy.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/ui_preference_store.dart';

class _FakeCoreBridge implements AppCore {
  _FakeCoreBridge({this.snapshot = _previewSnapshot, this.profiles = const []});

  static const _previewSnapshot = HomeSnapshotData(
    learningMinutes: 36,
    readingPages: 8,
    masteredWords: 12,
    completedExercises: 6,
    recent: [],
  );

  final HomeSnapshotData snapshot;
  final List<ProviderProfileData> profiles;

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 2, coreVersion: '0.1.0');

  @override
  List<ProviderProfileData> listProviderProfiles() => profiles;

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      snapshot;

  @override
  void saveProviderProfile(ProviderProfileData profile) {}

  @override
  void deleteProviderProfile(String providerId) {}

  @override
  void dispose() {}
}

class _ThrowingFavoriteListDictionaryCore extends _FakeCoreBridge
    implements DictionaryCore {
  @override
  List<DictionaryEntryData> lookupDictionary(String word, {int limit = 10}) {
    if (word.toLowerCase() != 'apple') return const [];
    return const [
      DictionaryEntryData(
        id: 'seed.apple',
        word: 'apple',
        ipa: '/ˈæpəl/',
        partOfSpeech: 'n. 名词',
        meanings: ['苹果'],
        example: 'An apple a day keeps the doctor away.',
        exampleTranslation: '一天一苹果，医生远离我。',
        source: 'yixue-basic',
      ),
    ];
  }

  @override
  void saveDictionaryEntry(DictionaryEntryData entry) {}

  @override
  List<String> listFavoriteWords() =>
      throw StateError('favorite list is temporarily unavailable');

  @override
  void setFavoriteWord(String word, bool favorite) {}
}

class _WorkbenchFakeCoreBridge extends _FakeCoreBridge
    implements HomeWorkbenchCore {
  _WorkbenchFakeCoreBridge({required this.workbench});

  final HomeCoreSnapshotData workbench;

  @override
  HomeCoreSnapshotData homeWorkbenchSnapshot(
    String localDate, {
    int recentLimit = 10,
  }) => workbench;
}

class _DeletableHistoryFakeCore extends _FakeCoreBridge
    implements DeletableTranslationHistoryCore {
  final deletedIds = <String>[];

  @override
  void recordCompletedTranslation(CompletedTranslationData translation) {}

  @override
  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 500}) =>
      const <TranslationHistoryEntryData>[];

  @override
  void deleteTranslationHistory(List<String> ids) => deletedIds.addAll(ids);
}

void main() {
  testWidgets('desktop shell exposes every primary workspace', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.pump();

    expect(find.text('译学'), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('快速翻译'), findsWidgets);
    expect(find.text('截屏翻译'), findsOneWidget);
    expect(find.text('阅读器'), findsOneWidget);
    expect(find.text('学习'), findsOneWidget);
    expect(find.text('AI 同传'), findsOneWidget);
    expect(find.text('模型与服务'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('本地优先 · 预览核心'), findsOneWidget);
    expect(find.text('版本 开发版'), findsNothing);
    expect(find.byKey(const ValueKey('window-drag-area')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
  });

  testWidgets('first workspace frame survives a local core startup failure', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        showLaunchAnimation: false,
        coreFactory: () => throw StateError('database temporarily unavailable'),
        translationHistoryLoader: () async => const [],
        translationHistoryPageLoader: (offset, limit) async => const [],
        favoriteWordPageLoader: ({query = '', limit = 40, offset = 0}) async =>
            const FavoriteWordPageData(records: [], hasMore: false),
      ),
    );

    expect(find.byKey(const ValueKey('window-drag-area')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('本地优先 · 状态暂不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick translation shows an explicitly selected provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [],
        coreFactory: () => _FakeCoreBridge(
          profiles: const [
            ProviderProfileData(
              id: 'api.openai-compatible',
              displayName: '我的翻译接口',
              kind: ProviderProfileKind.remoteApi,
              enabled: true,
              modelId: 'translation-model',
              endpoint: 'https://example.invalid/v1',
              assignedRoles: {ModelRole.translation},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('自定义接口 · 当前：我的翻译接口'), findsOneWidget);
    expect(find.text('本地处理'), findsNothing);
  });

  testWidgets('quick translation header adapts to a high-DPI laptop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1706, 1066);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(translationHistoryLoader: () async => const []),
    );
    await tester.pump();
    await tester.tap(find.text('快速翻译').first);
    await tester.pump(const Duration(milliseconds: 300));

    final header = find.byKey(const ValueKey('quick-translation-header'));
    expect(header, findsOneWidget);
    expect(
      tester.getRect(header).right,
      lessThanOrEqualTo(
        tester.view.physicalSize.width / tester.view.devicePixelRatio,
      ),
    );
    expect(
      find.byKey(const ValueKey('quick-translation-more-actions')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quick translation status follows the assigned translation role',
    (tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        YixueApp(
          translationHistoryLoader: () async => const [],
          coreFactory: () => _FakeCoreBridge(
            profiles: const [
              ProviderProfileData(
                id: 'local.understanding',
                displayName: '本地理解模型',
                kind: ProviderProfileKind.localModel,
                enabled: true,
                modelId: 'understanding-model',
                modelPath: r'D:\models\understanding',
                assignedRoles: {ModelRole.understanding},
              ),
              ProviderProfileData(
                id: 'api.translation',
                displayName: '我的翻译接口',
                kind: ProviderProfileKind.remoteApi,
                enabled: true,
                modelId: 'translation-model',
                endpoint: 'https://example.invalid/v1',
                assignedRoles: {ModelRole.translation},
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('自定义接口 · 当前：我的翻译接口'), findsOneWidget);
      expect(find.textContaining('本地理解模型'), findsNothing);
    },
  );

  testWidgets(
    'home dashboard exposes daily work without repeating navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const YixueApp());
      await tester.tap(find.text('首页'));
      await tester.pumpAndSettle();

      expect(find.text('译懂世界，学会表达。'), findsOneWidget);
      expect(find.text('继续任务'), findsOneWidget);
      expect(find.text('今日学习'), findsOneWidget);
      expect(find.text('今日总结'), findsOneWidget);
      expect(find.text('最近内容'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-primary-continue')),
        findsOneWidget,
      );
    },
  );

  testWidgets('home actions route into independent core workspaces', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-primary-continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('learning-home-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);

    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('home-quick-start-field')),
      'Technology changes us.',
    );
    await tester.tap(find.byKey(const ValueKey('home-start-translation')));
    await tester.pumpAndSettle();

    final source = tester.widget<TextField>(find.byType(TextField).first);
    expect(source.controller?.text, 'Technology changes us.');
  });

  testWidgets('home continue task reopens the latest translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [
          TranslationHistoryEntryData(
            id: 'translation-1',
            sourceText: 'A wider world.',
            translatedText: '更广阔的世界。',
            providerId: 'remote.example',
            createdAt: '2026-09-09T12:00:00+08:00',
          ),
        ],
      ),
    );
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    expect(find.text('A wider world.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-primary-continue')));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.any((field) => field.controller?.text == 'A wider world.'),
      isTrue,
    );
    expect(fields.any((field) => field.controller?.text == '更广阔的世界。'), isTrue);
  });

  testWidgets('home dashboard renders metrics from the injected local core', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const snapshot = HomeSnapshotData(
      learningMinutes: 23,
      readingPages: 5,
      masteredWords: 17,
      completedExercises: 9,
      recent: [],
    );

    await tester.pumpWidget(
      YixueApp(coreFactory: () => _FakeCoreBridge(snapshot: snapshot)),
    );
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-summary-learning-minutes')),
          )
          .data,
      '23',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-summary-mastered-words')),
          )
          .data,
      '17',
    );
    expect(find.text('完成一次阅读、学习或翻译后，记录会出现在这里。'), findsOneWidget);
  });

  testWidgets(
    'home shell uses the versioned workbench snapshot when available',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const workbench = HomeCoreSnapshotData(
        localDate: '2026-09-15',
        summary: HomeSummaryData(
          translationCount: HomeMetricData.available(4),
          translationUnits: HomeMetricData.available(57),
          learnedWords: HomeMetricData.available(11),
          readingArticles: HomeMetricData.unavailable(),
          readingUnits: HomeMetricData.available(6),
          favoriteSentences: HomeMetricData.unavailable(),
          favoriteWords: HomeMetricData.unavailable(),
          speakingSeconds: HomeMetricData.available(0),
          focusSeconds: HomeMetricData.available(3000),
          focusSessions: HomeMetricData.available(2),
        ),
        recent: [],
      );

      await tester.pumpWidget(
        YixueApp(
          coreFactory: () => _WorkbenchFakeCoreBridge(workbench: workbench),
        ),
      );
      await tester.tap(find.text('首页'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('home-summary-translation-count')),
            )
            .data,
        '4',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('home-summary-focus-minutes')),
            )
            .data,
        '50',
      );
      expect(find.text('文章 · 暂未接入'), findsOneWidget);
      expect(find.text('收藏句 · 暂未接入'), findsOneWidget);
      expect(find.text('36'), findsNothing);

      final detailsAction = find.byKey(
        const ValueKey('home-open-today-summary'),
      );
      expect(detailsAction, findsOneWidget);
      await tester.tap(detailsAction);
      await tester.pumpAndSettle();
      expect(find.text('今日统计'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-today-summary-details')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('home-close-today-summary')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('home recent translation reopens its saved history entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const activity = ActivityEventData(
      id: 'translation:history-1',
      kind: ActivityKind.translation,
      title: 'Technology changes life.',
      detail: '快速翻译 · 刚刚',
      durationSeconds: 0,
      itemCount: 1,
      occurredAt: '2026-09-15T09:00:00+08:00',
    );
    const workbench = HomeCoreSnapshotData(
      localDate: '2026-09-15',
      summary: HomeSummaryData(
        translationCount: HomeMetricData.available(1),
        translationUnits: HomeMetricData.available(23),
        learnedWords: HomeMetricData.available(0),
        readingArticles: HomeMetricData.unavailable(),
        readingUnits: HomeMetricData.unavailable(),
        favoriteSentences: HomeMetricData.unavailable(),
        favoriteWords: HomeMetricData.unavailable(),
        speakingSeconds: HomeMetricData.available(0),
        focusSeconds: HomeMetricData.available(0),
        focusSessions: HomeMetricData.available(0),
      ),
      recent: [activity],
    );
    const historyEntry = TranslationHistoryEntryData(
      id: 'history-1',
      sourceText: 'Technology changes life.',
      translatedText: '技术正在改变生活。',
      providerId: 'local.preview',
      createdAt: '2026-09-15T09:00:00+08:00',
    );

    await tester.pumpWidget(
      YixueApp(
        coreFactory: () => _WorkbenchFakeCoreBridge(workbench: workbench),
        translationHistoryLoader: () async => const [historyEntry],
      ),
    );
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    final target = find.byKey(
      const ValueKey('home-recent-translation:history-1'),
    );
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.any((field) => field.controller?.text == historyEntry.sourceText),
      isTrue,
    );
    expect(
      fields.any(
        (field) => field.controller?.text == historyEntry.translatedText,
      ),
      isTrue,
    );
  });

  testWidgets('navigation switches to the learning workspace', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('学习'));
    await tester.pump();

    expect(find.byKey(const ValueKey('page-skeleton')), findsOneWidget);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('page-skeleton')), findsNothing);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('learning-home-header')), findsOneWidget);
  });

  testWidgets(
    'switching back to a cached workspace skips the loading overlay',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const YixueApp());
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-skeleton')), findsNothing);

      await tester.tap(find.text('快速翻译'));
      await tester.pump();

      expect(find.byKey(const ValueKey('page-skeleton')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == '输入单词、句子或一段文字…',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('document reading stays unavailable in the translation app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);

    await tester.tap(find.text('阅读器'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-edge-reveal')), findsNothing);
    expect(find.text('暂未接入'), findsOneWidget);
    expect(find.text('暂未接入。阅读器正在独立开发，完成后再接入译学。'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-article-pane')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop sidebar gives the approved brand mark enough space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());

    final brandBox = tester.widget<SizedBox>(
      find.byKey(const ValueKey('sidebar-brand-mark')),
    );
    expect(brandBox.width, greaterThanOrEqualTo(52));
    expect(brandBox.height, greaterThanOrEqualTo(52));
  });

  testWidgets('desktop sidebar fully hides and can be revealed from the edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());

    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sidebar-collapse-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-edge-reveal')), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('sidebar-edge-reveal'))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('sidebar-temporary-overlay')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
  });

  testWidgets('temporary sidebar can be pinned open again', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = _MemorySidebarPreferenceStore(true);
    await tester.pumpWidget(YixueApp(sidebarPreferenceStore: preferences));
    await tester.tap(find.byKey(const ValueKey('sidebar-collapse-button')));
    await tester.pumpAndSettle();
    expect(preferences.expanded, isFalse);
    await tester.tap(find.byKey(const ValueKey('sidebar-edge-reveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-pin-button')));
    await tester.pumpAndSettle();

    expect(preferences.expanded, isTrue);
    expect(
      find.byKey(const ValueKey('sidebar-temporary-overlay')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
  });

  testWidgets('desktop restores the saved collapsed sidebar preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(sidebarPreferenceStore: _MemorySidebarPreferenceStore(false)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-edge-reveal')), findsOneWidget);
  });

  testWidgets('settings owns build and local privacy details', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('版本与构建'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('版本与构建'), findsOneWidget);
    expect(find.text('数据与隐私'), findsOneWidget);
    expect(find.text('开发版'), findsOneWidget);

    await tester.tap(find.text('数据与隐私'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-local-data')), findsOneWidget);
    expect(find.text('打开数据文件夹'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('settings lets users set a per-category local storage quota', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final policyStore = _MemoryStoragePolicyStore();

    await tester.pumpWidget(
      YixueApp(
        storagePolicyStore: policyStore,
        storageUsageLoader: () async =>
            StorageUsageData(usedBytes: {'favorite_words': 5 * 1024 * 1024}),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('数据与隐私'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('数据与隐私'));
    await tester.pumpAndSettle();

    expect(find.text('存储容量策略'), findsOneWidget);
    final editFavorite = find.byKey(
      const ValueKey('storage-quota-edit-favorite_words'),
    );
    await tester.scrollUntilVisible(
      editFavorite,
      220,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('占用估算：5.0 MB'), findsOneWidget);
    await tester.tap(editFavorite);
    await tester.pumpAndSettle();

    await tester.tap(find.text('自定义容量'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('storage-quota-custom-mb')),
      '128',
    );
    await tester.tap(find.byKey(const ValueKey('storage-quota-save')));
    await tester.pumpAndSettle();

    expect(
      policyStore.value?.quotaFor(StorageCategory.favoriteWords),
      128 * 1024 * 1024,
    );
    expect(find.text('收藏单词容量已设置为128.0 MB'), findsOneWidget);
  });

  testWidgets('settings switches among three official themes immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController();

    await tester.pumpWidget(YixueApp(appearanceController: appearance));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('外观与动效'), findsOneWidget);
    expect(find.text('生机'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('official-theme-light')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('motion-level-reduced')));
    await tester.pumpAndSettle();

    expect(appearance.value.officialTheme, YixueOfficialTheme.light);
    expect(appearance.value.motionLevel, YixueMotionLevel.reduced);
  });

  testWidgets('settings edits and applies a custom theme locally', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);

    await tester.pumpWidget(YixueApp(appearanceController: appearance));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-custom-theme')));
    await tester.pumpAndSettle();

    expect(find.text('自定义主题'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('custom-theme-name')),
      '我的晴空',
    );
    await tester.tap(find.byKey(const ValueKey('save-custom-theme')));
    await tester.pumpAndSettle();

    expect(appearance.value.customTheme?.name, '我的晴空');
    expect(find.text('编辑当前主题'), findsOneWidget);
  });

  testWidgets('settings opens local terminology management', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final terminology = TranslationTerminologyController();
    addTearDown(terminology.dispose);

    await tester.pumpWidget(
      YixueApp(translationTerminologyController: terminology),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('专业术语'), findsOneWidget);
    expect(find.text('0 条本地规则'), findsOneWidget);
    await tester.tap(find.text('专业术语'));
    await tester.pumpAndSettle();
    expect(find.text('新增规则'), findsOneWidget);
    expect(find.text('还没有规则。添加后，快速翻译会优先使用你的固定译法。'), findsOneWidget);
  });

  testWidgets('settings opens dictionary source management', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = DictionaryPreferencesController();
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      YixueApp(dictionaryPreferencesController: preferences),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('settings-scroll')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();

    expect(find.text('词典来源'), findsOneWidget);
    expect(find.text('1/1 个来源已启用'), findsOneWidget);
    await tester.tap(find.text('词典来源'));
    await tester.pumpAndSettle();
    expect(find.text('译学基础词典'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dictionary-source-yixue-basic')),
      findsOneWidget,
    );
  });

  testWidgets('translation preference controls use aligned shared padding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    final direction = tester
        .widget<DropdownButtonFormField<PreferredDirection>>(
          find.byKey(const ValueKey('translation-direction-preference')),
        );
    final tone = tester.widget<DropdownButtonFormField<TranslationTone>>(
      find.byKey(const ValueKey('translation-tone-preference')),
    );
    expect(
      direction.decoration.contentPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
    expect(
      tone.decoration.contentPadding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
    final lineBreaks = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('translation-line-breaks-preference')),
    );
    expect(
      lineBreaks.contentPadding,
      const EdgeInsets.symmetric(horizontal: 4),
    );
  });

  testWidgets('appearance changes preserve current translation input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController();

    await tester.pumpWidget(YixueApp(appearanceController: appearance));
    await tester.enterText(find.byType(TextField).first, 'Keep this text');

    appearance.setOfficialTheme(YixueOfficialTheme.light);
    await tester.pumpAndSettle();

    expect(find.text('Keep this text'), findsOneWidget);
  });

  testWidgets('navigation preserves the quick translation draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.enterText(find.byType(TextField).first, 'Keep my draft');
    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速翻译'));
    await tester.pumpAndSettle();

    expect(find.text('Keep my draft'), findsOneWidget);
  });

  testWidgets('editing the source clears the previous translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [
          TranslationHistoryEntryData(
            id: 'translation-stale-result',
            sourceText: 'hello',
            translatedText: '你好',
            providerId: 'local.dictionary',
            createdAt: '2026-09-13T12:00:00+08:00',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('hello').last);
    await tester.pump();
    final sourceField = find.byType(TextField).first;
    final translationField = tester
        .widgetList<TextField>(find.byType(TextField))
        .elementAt(1);
    expect(translationField.controller?.text, '你好');

    await tester.enterText(sourceField, 'world');
    expect(translationField.controller?.text, isEmpty);
  });

  testWidgets('navigation preserves the settings scroll position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    final settingsList = find.byKey(const ValueKey('settings-scroll'));
    await tester.drag(settingsList, const Offset(0, -280));
    await tester.pumpAndSettle();
    final before = tester
        .state<ScrollableState>(
          find.descendant(of: settingsList, matching: find.byType(Scrollable)),
        )
        .position
        .pixels;
    expect(before, greaterThan(0));

    await tester.tap(find.text('快速翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    final after = tester
        .state<ScrollableState>(
          find.descendant(of: settingsList, matching: find.byType(Scrollable)),
        )
        .position
        .pixels;
    expect(after, closeTo(before, 0.5));
  });

  testWidgets('settings exposes a per-page appearance override', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appearance = AppearanceController();
    await tester.pumpWidget(YixueApp(appearanceController: appearance));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('单页外观'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-appearance-menu')),
      findsOneWidget,
    );
    await tester.tap(find.text('专注'));
    await tester.pumpAndSettle();

    expect(
      appearance.value.workspaceStyles[YixueWorkspace.home],
      YixueVisualStyle.focus,
    );
  });

  testWidgets('vitality shell decoration is absent from plain themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = AppearanceController();

    await tester.pumpWidget(YixueApp(appearanceController: appearance));
    expect(find.byKey(const ValueKey('sidebar-vitality-glow')), findsOneWidget);

    appearance.setOfficialTheme(YixueOfficialTheme.light);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-vitality-glow')), findsNothing);

    appearance.setOfficialTheme(YixueOfficialTheme.dark);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar-vitality-glow')), findsNothing);
  });

  testWidgets('quick translation input updates count and can be cleared', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    final source = find.byType(TextField).first;
    await tester.enterText(source, 'Hello world');
    await tester.pump();

    expect(find.text('11 / 5000'), findsOneWidget);
    await tester.tap(find.text('清 空   Ctrl+L'));
    await tester.pump();
    expect(tester.widget<TextField>(source).controller?.text, isEmpty);
  });

  testWidgets('dictionary guide explains the package format before import', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    final toolsMenu = find.byKey(const ValueKey('dictionary-tools-menu'));
    await tester.ensureVisible(toolsMenu);
    await tester.tap(toolsMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('格式说明与模板'));
    await tester.pumpAndSettle();

    expect(find.text('词典包说明与导入方法'), findsOneWidget);
    expect(find.textContaining('只导入你拥有、公开许可或已经获准使用'), findsOneWidget);
    expect(find.textContaining('词典文件不是翻译模型'), findsOneWidget);
    expect(find.textContaining('内置基础词典'), findsOneWidget);
    expect(find.textContaining('基础词典'), findsWidgets);
    expect(find.textContaining('建设目标，尚未完成覆盖'), findsWidgets);
    expect(find.text('怎么导入'), findsOneWidget);
    expect(find.text('每条词条必须包含'), findsOneWidget);
    expect(find.text('保存可编辑模板'), findsOneWidget);
  });

  testWidgets('selecting an English word opens its dictionary explanation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    final source = find.byType(TextField).first;
    await tester.enterText(source, 'Hello teacher');
    await tester.pump();

    final sourceField = tester.widget<TextField>(source);
    final controller = sourceField.controller!;
    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 6, extentOffset: 13),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('dictionary-query')))
          .controller
          ?.text,
      'teacher',
    );
    expect(find.textContaining('/ˈtiːtʃə(r)/'), findsOneWidget);
    expect(find.textContaining('教师；老师'), findsOneWidget);

    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 0, extentOffset: 13),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('dictionary-query')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.textContaining('/ˈtiːtʃə(r)/'), findsNothing);
  });

  testWidgets('a stale dictionary response cannot replace the latest word', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = <String, Completer<DictionaryEntry?>>{};

    Future<DictionaryEntry?> lookup(String word) {
      final key = word.trim().toLowerCase();
      final request = Completer<DictionaryEntry?>();
      pending[key] = request;
      return request.future;
    }

    await tester.pumpWidget(YixueApp(dictionaryLookupLoader: lookup));
    final source = find.byType(TextField).first;
    await tester.enterText(source, 'hello teacher');
    await tester.pump();
    final controller = tester.widget<TextField>(source).controller!;

    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(pending.containsKey('hello'), isTrue);

    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 6, extentOffset: 13),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(pending.containsKey('teacher'), isTrue);

    pending['teacher']!.complete(
      const LocalDictionaryService().lookup('teacher'),
    );
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('dictionary-query')))
          .controller
          ?.text,
      'teacher',
    );

    pending['hello']!.complete(const LocalDictionaryService().lookup('hello'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('dictionary-query')))
          .controller
          ?.text,
      'teacher',
    );
    expect(find.textContaining('/ˈtiːtʃə(r)/'), findsOneWidget);
  });

  testWidgets('dictionary explanation saves a local note and learning flag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    WordAnnotationData? saved;
    var saveAttempts = 0;
    final learningStore = MemoryLearningStore();

    await tester.pumpWidget(
      YixueApp(
        learningStore: learningStore,
        wordAnnotationLoader: (_) async => null,
        wordAnnotationSaver: (annotation) async {
          saveAttempts++;
          if (saveAttempts == 1) {
            throw StateError('synthetic local storage failure');
          }
          saved = annotation;
        },
      ),
    );
    final source = find.byType(TextField).first;
    await tester.enterText(source, 'Hello teacher');
    await tester.pump();
    final controller = tester.widget<TextField>(source).controller!;
    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 6, extentOffset: 13),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '我的笔记',
      ),
      '我的工作例句。',
    );
    await tester.tap(find.text('保存笔记'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请检查本地存储后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(saved?.word, 'teacher');
    expect(saved?.note, '我的工作例句。');

    await tester.tap(find.text('加入学习'));
    await tester.pumpAndSettle();
    expect(saved?.addedToLearning, isTrue);
    final learningState = await learningStore.read();
    expect(learningState?.items.any((item) => item.word == 'teacher'), isTrue);
  });

  testWidgets('Ctrl+L clears focused quick translation input', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    final source = find.byType(TextField).first;
    await tester.tap(source);
    await tester.enterText(source, 'clear me');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(tester.widget<TextField>(source).controller?.text, isEmpty);
  });

  testWidgets('paste reads text clipboard and enables translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(YixueApp(clipboardReader: () async => 'Paste me'));
    final translateButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '翻 译   Enter'),
    );
    expect(translateButton.onPressed, isNull);

    await tester.tap(find.text('粘 贴   Ctrl+V'));
    await tester.pump();

    expect(find.text('8 / 5000'), findsOneWidget);
    final enabledButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '翻 译   Enter'),
    );
    expect(enabledButton.onPressed, isNotNull);
  });

  testWidgets('quick translation displays the returned Chinese text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var called = false;
    await tester.pumpWidget(
      YixueApp(
        quickTranslationRunner: (_, _) async {
          called = true;
          return '技术改变生活。';
        },
      ),
    );

    await tester.enterText(
      find.byType(TextField).first,
      'Technology changes life.',
    );
    await tester.pump();
    await tester.tap(find.text('翻 译   Enter'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.any((field) => field.controller?.text == '技术改变生活。'), isTrue);
  });

  testWidgets('moving the source selection preserves a completed translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(quickTranslationRunner: (_, _) async => '你好，老师。'),
    );
    final source = find.byType(TextField).first;
    await tester.enterText(source, 'Hello teacher');
    await tester.pump();
    await tester.tap(find.text('翻 译   Enter'));
    await tester.pumpAndSettle();

    final translation = tester
        .widgetList<TextField>(find.byType(TextField))
        .elementAt(1);
    expect(translation.controller?.text, '你好，老师。');

    final controller = tester.widget<TextField>(source).controller!;
    controller.value = controller.value.copyWith(
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await tester.pump();

    expect(translation.controller?.text, '你好，老师。');
  });

  testWidgets('quick translation explains rejected formatting damage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      YixueApp(
        quickTranslationRunner: (_, _) async =>
            throw const QuickTranslationException('format_integrity_failed'),
      ),
    );

    await tester.enterText(find.byType(TextField).first, 'Open v2.1.');
    await tester.pump();
    await tester.tap(find.text('翻 译   Enter'));
    await tester.pumpAndSettle();

    expect(find.text('模型改坏了原文中的格式内容，本次结果未保存，请重试或更换模型'), findsOneWidget);
  });

  testWidgets('failed retry clears the previous translation result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    await tester.pumpWidget(
      YixueApp(
        quickTranslationRunner: (_, _) async {
          attempts += 1;
          if (attempts == 1) return '第一次译文';
          throw const QuickTranslationException('suspicious_model_output');
        },
      ),
    );

    await tester.enterText(find.byType(TextField).first, 'Retry this text.');
    await tester.pump();
    await tester.tap(find.text('翻 译   Enter'));
    await tester.pumpAndSettle();
    expect(find.text('第一次译文'), findsOneWidget);

    await tester.tap(find.text('翻 译   Enter'));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.elementAt(1).controller?.text, isEmpty);
    expect(find.text('模型输出疑似重复或退化，本次结果未保存，请更换翻译模型'), findsOneWidget);
  });

  testWidgets('active translation can be cancelled without showing a result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<String>();
    var cancelled = false;
    await tester.pumpWidget(
      YixueApp(
        quickTranslationRunner: (_, _) => pending.future,
        quickTranslationCanceller: () async {
          cancelled = true;
          return true;
        },
      ),
    );

    await tester.enterText(find.byType(TextField).first, 'Keep this input.');
    await tester.pump();
    await tester.tap(find.text('翻 译   Enter'));
    await tester.pump();
    expect(find.text('取消翻译'), findsOneWidget);

    await tester.tap(find.text('取消翻译'));
    await tester.pump();
    pending.complete('Result that must be ignored');
    await tester.pumpAndSettle();

    expect(cancelled, isTrue);
    expect(find.text('取消翻译'), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.any((field) => field.controller?.text == 'Keep this input.'),
      isTrue,
    );
    expect(
      fields.any(
        (field) => field.controller?.text == 'Result that must be ignored',
      ),
      isFalse,
    );
  });

  testWidgets(
    'quick translation switches between English and Chinese directions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const YixueApp());

      expect(find.text('英语（自动检测）'), findsOneWidget);
      expect(find.text('中文（简体）'), findsOneWidget);
      expect(find.text('英译中'), findsOneWidget);

      await tester.tap(find.text('英译中'));
      await tester.pumpAndSettle();

      expect(find.text('中文（简体）'), findsOneWidget);
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('中译英'), findsOneWidget);
    },
  );

  testWidgets('translation history can restore source and result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [
          TranslationHistoryEntryData(
            id: 'translation-1',
            sourceText: 'Technology changes life.',
            translatedText: '技术改变生活。',
            providerId: 'remote.example',
            createdAt: '2026-09-09T12:00:00+08:00',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Technology changes life.').last);
    await tester.pump();

    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.any(
        (field) => field.controller?.text == 'Technology changes life.',
      ),
      isTrue,
    );
    expect(fields.any((field) => field.controller?.text == '技术改变生活。'), isTrue);
  });

  testWidgets(
    'translation history opens a detail workspace and saves annotations',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TranslationAnnotationData? saved;
      await tester.pumpWidget(
        YixueApp(
          translationHistoryLoader: () async => const [
            TranslationHistoryEntryData(
              id: 'translation-1',
              sourceText: 'Technology changes life.',
              translatedText: '技术改变生活。',
              providerId: 'local.opus-en-zh',
              createdAt: '2026-09-13T12:00:00+08:00',
            ),
          ],
          translationAnnotationLoader: () async => const [],
          translationAnnotationSaver: (annotation) async => saved = annotation,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, '历史'));
      await tester.pumpAndSettle();

      expect(find.text('翻译历史'), findsWidgets);
      expect(find.text('模型：local.opus-en-zh'), findsOneWidget);
      expect(find.text('继续翻译'), findsOneWidget);

      await tester.tap(find.text('收藏这次翻译'));
      await tester.pumpAndSettle();
      expect(saved?.translationId, 'translation-1');
      expect(saved?.favorite, isTrue);

      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '这次翻译的笔记',
        ),
        '保留这个句型。',
      );
      await tester.tap(find.text('保存标注'));
      await tester.pumpAndSettle();
      expect(saved?.note, '保留这个句型。');

      await tester.tap(find.text('继续翻译'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .any(
              (field) => field.controller?.text == 'Technology changes life.',
            ),
        isTrue,
      );
    },
  );

  testWidgets('translation history pages and exports stay bounded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstPage = List.generate(
      50,
      (index) => TranslationHistoryEntryData(
        id: 'page-$index',
        sourceText: 'Sentence $index.',
        translatedText: '句子 $index。',
        providerId: 'local.test',
        createdAt: '2026-09-14T12:00:00+08:00',
      ),
    );
    final secondPage = [
      const TranslationHistoryEntryData(
        id: 'page-50',
        sourceText: 'Sentence 50.',
        translatedText: '句子 50。',
        providerId: 'local.test',
        createdAt: '2026-09-14T11:00:00+08:00',
      ),
    ];
    List<TranslationHistoryEntryData>? exported;
    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [],
        translationHistoryPageLoader: (offset, _) async =>
            offset == 0 ? firstPage : secondPage,
        translationHistoryExporter: (history, _) async {
          exported = history;
          return r'D:\译学\exports\history.json';
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '历史'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('history-load-more')),
      500,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('history-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const ValueKey('history-load-more')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-load-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-export')));
    await tester.pumpAndSettle();

    expect(exported, isNotNull);
    expect(exported, hasLength(51));
    expect(find.textContaining('翻译历史已导出'), findsOneWidget);
  });

  testWidgets('translation history can select and delete every paged result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstPage = List.generate(
      50,
      (index) => TranslationHistoryEntryData(
        id: 'bulk-$index',
        sourceText: 'Source sentence $index.',
        translatedText: '原文 $index。',
        providerId: 'local.test',
        createdAt: '2026-09-14T12:00:00+08:00',
      ),
    );
    const finalEntry = TranslationHistoryEntryData(
      id: 'bulk-50',
      sourceText: 'Source sentence 50.',
      translatedText: '原文 50。',
      providerId: 'local.test',
      createdAt: '2026-09-14T11:00:00+08:00',
    );
    final core = _DeletableHistoryFakeCore();
    await tester.pumpWidget(
      YixueApp(
        coreFactory: () => core,
        translationHistoryPageLoader: (offset, _) async =>
            offset == 0 ? firstPage : const [finalEntry],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '历史'));
    await tester.pumpAndSettle();

    expect(find.text('全选筛选结果'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-select-all-visible')));
    await tester.pumpAndSettle();
    expect(find.text('51 条已选'), findsOneWidget);
    expect(find.text('清空已选'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    expect(core.deletedIds, hasLength(51));
    expect(core.deletedIds, contains('bulk-50'));
    expect(find.text('51 条已选'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel all history selection clears selections across filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [
          TranslationHistoryEntryData(
            id: 'filter-0',
            sourceText: 'Source sentence 0.',
            translatedText: '原文 0',
            providerId: 'local.test',
            createdAt: '2026-09-14T12:00:00+08:00',
          ),
          TranslationHistoryEntryData(
            id: 'filter-1',
            sourceText: 'Source sentence 1.',
            translatedText: '原文 1',
            providerId: 'local.test',
            createdAt: '2026-09-14T11:00:00+08:00',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '历史'));
    await tester.pumpAndSettle();

    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '搜索原文、译文、模型或笔记',
    );
    await tester.enterText(searchField, 'Source sentence 0.');
    await tester.tap(find.byKey(const ValueKey('history-select-all-visible')));
    await tester.pumpAndSettle();
    expect(find.text('1 条已选'), findsOneWidget);

    await tester.enterText(searchField, 'Source sentence 1.');
    await tester.tap(find.byKey(const ValueKey('history-select-all-visible')));
    await tester.pumpAndSettle();
    expect(find.text('2 条已选'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-select-all-visible')));
    await tester.pumpAndSettle();
    expect(find.text('2 条已选'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact shell uses bottom navigation without layout errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('快速翻译'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact quick translation keeps source and result visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      YixueApp(quickTranslationRunner: (_, _) async => '你好'),
    );

    expect(find.text('英语（自动检测）'), findsOneWidget);
    expect(find.text('中文（简体）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact quick translation can open its learning panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
    await tester.pumpAndSettle();

    expect(find.text('词语解释'), findsOneWidget);
    expect(find.text('例句'), findsOneWidget);
    expect(find.text('已收藏单词'), findsOneWidget);
    expect(find.text('翻译历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact quick translation carries selected Chinese terms into learning lookup',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lookupCalls = <String>[];

      await tester.pumpWidget(
        YixueApp(
          dictionaryLookupLoader: (term) async {
            lookupCalls.add(term);
            const local = LocalDictionaryService();
            return local.lookup(term) ?? local.lookupChinese(term);
          },
        ),
      );
      await tester.pumpAndSettle();

      final source = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '输入单词、句子或一段文字…',
      );
      await tester.enterText(source, '我正在学习语言');
      final sourceController = tester.widget<TextField>(source).controller!;
      sourceController.selection = const TextSelection(
        baseOffset: 3,
        extentOffset: 5,
      );
      await tester.pump();
      expect(find.text('已选中“学习”，可打开查词。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(lookupCalls, contains('学习'));
      final query = tester.widget<TextField>(
        find.byKey(const ValueKey('dictionary-query')),
      );
      expect(query.controller?.text, '学习');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact quick translation carries selected English words into learning lookup',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lookupCalls = <String>[];

      await tester.pumpWidget(
        YixueApp(
          dictionaryLookupLoader: (term) async {
            lookupCalls.add(term);
            const local = LocalDictionaryService();
            return local.lookup(term) ?? local.lookupChinese(term);
          },
        ),
      );
      await tester.pumpAndSettle();

      final source = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '输入单词、句子或一段文字…',
      );
      await tester.enterText(source, 'I like apple pie');
      final sourceController = tester.widget<TextField>(source).controller!;
      sourceController.selection = const TextSelection(
        baseOffset: 7,
        extentOffset: 12,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(lookupCalls, <String>['apple']);
      final query = tester.widget<TextField>(
        find.byKey(const ValueKey('dictionary-query')),
      );
      expect(query.controller?.text, 'apple');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quick dictionary looks up English and Chinese while typing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lookupCalls = <String>[];
    await tester.pumpWidget(
      YixueApp(
        dictionaryLookupLoader: (word) async {
          lookupCalls.add(word);
          const local = LocalDictionaryService();
          return local.lookup(word) ?? local.lookupChinese(word);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
    await tester.pumpAndSettle();

    final query = find.byKey(const ValueKey('dictionary-query'));
    await tester.ensureVisible(query);
    await tester.enterText(query, 'apple');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(lookupCalls.last, 'apple');
    expect(find.textContaining('apple'), findsWidgets);
    expect(find.textContaining('苹果'), findsWidgets);

    await tester.enterText(query, '苹果');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(lookupCalls.last, '苹果');
    expect(find.textContaining('apple'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual dictionary search stays tappable and reuses the pending auto lookup',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lookup = Completer<DictionaryEntry?>();
      final lookupCalls = <String>[];
      await tester.pumpWidget(
        YixueApp(
          dictionaryLookupLoader: (word) {
            lookupCalls.add(word);
            return lookup.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('dictionary-query'));
      final submit = find.byKey(const ValueKey('dictionary-query-submit'));
      await tester.ensureVisible(query);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.enterText(query, 'apple');
      await tester.pump(const Duration(milliseconds: 300));
      expect(lookupCalls, <String>['apple']);
      expect(find.text('查询中'), findsOneWidget);

      await tester.tap(submit);
      await tester.pump();
      expect(lookupCalls, <String>['apple']);

      lookup.complete(const LocalDictionaryService().lookup('apple'));
      await tester.pumpAndSettle();
      expect(find.text('释义'), findsOneWidget);
      expect(find.textContaining('苹果'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quick dictionary tools stay in one menu on a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('dictionary-tools-menu')),
    );

    expect(find.byKey(const ValueKey('dictionary-tools-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('dictionary-guide')), findsNothing);
    expect(find.byKey(const ValueKey('dictionary-import')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('dictionary-tools-menu')));
    await tester.pumpAndSettle();
    expect(find.text('格式说明与模板'), findsOneWidget);
    expect(find.text('导入授权词典包'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quick dictionary reaches the bundled Chinese fallback in core mode',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        YixueApp(coreFactory: _ThrowingFavoriteListDictionaryCore.new),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('dictionary-query'));
      final submit = find.byKey(const ValueKey('dictionary-query-submit'));
      await tester.ensureVisible(query);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.enterText(query, '苹果');
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.textContaining('apple'), findsWidgets);
      expect(find.textContaining('苹果'), findsWidgets);
      expect(find.text('本地词典暂未收录“苹果”。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quick dictionary keeps a result when favorite loading fails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(coreFactory: _ThrowingFavoriteListDictionaryCore.new),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
    await tester.pumpAndSettle();

    final query = find.byKey(const ValueKey('dictionary-query'));
    final submit = find.byKey(const ValueKey('dictionary-query-submit'));
    await tester.ensureVisible(query);
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'apple');
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('释义'), findsOneWidget);
    expect(find.textContaining('苹果'), findsWidgets);
    expect(find.text('查词失败；请检查本地词典配置后重试。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quick dictionary offers model translation when local lookup fails',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <(String, TranslationDirection)>[];
      await tester.pumpWidget(
        YixueApp(
          dictionaryLookupLoader: (_) async => throw StateError('offline'),
          quickTranslationRunnerWithOptions: (text, direction, _) async {
            calls.add((text, direction));
            return '模型试译';
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('dictionary-query'));
      final submit = find.byKey(const ValueKey('dictionary-query-submit'));
      await tester.ensureVisible(query);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.enterText(query, '苹果');
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.text('查词失败；请检查本地词典配置后重试。'), findsOneWidget);
      final translate = find.byKey(const ValueKey('dictionary-translate-term'));
      expect(translate, findsOneWidget);
      await tester.tap(translate);
      await tester.pumpAndSettle();
      expect(calls, <(String, TranslationDirection)>[
        ('苹果', TranslationDirection.chineseToEnglish),
      ]);
      expect(
        find.byKey(const ValueKey('dictionary-translation-result')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing the dictionary query hides the previous entry until debounce completes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lookupCalls = <String>[];
      await tester.pumpWidget(
        YixueApp(
          dictionaryLookupLoader: (word) async {
            lookupCalls.add(word);
            const local = LocalDictionaryService();
            return local.lookup(word) ?? local.lookupChinese(word);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('dictionary-query'));
      final submit = find.byKey(const ValueKey('dictionary-query-submit'));
      await tester.ensureVisible(query);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.enterText(query, 'apple');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('释义'), findsOneWidget);
      expect(lookupCalls, <String>['apple']);

      await tester.enterText(query, '苹果');
      await tester.pump();
      expect(find.text('释义'), findsNothing);
      expect(find.text('本地词典暂未收录“苹果”。'), findsNothing);
      expect(find.text('停顿后会自动查询，也可按 Enter 或点击搜索。'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('释义'), findsOneWidget);
      expect(lookupCalls, <String>['apple', '苹果']);
      expect(find.text('停顿后会自动查询，也可按 Enter 或点击搜索。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('quick dictionary can explicitly translate an unknown headword', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <(String, TranslationDirection)>[];
    await tester.pumpWidget(
      YixueApp(
        dictionaryLookupLoader: (_) async => null,
        quickTranslationRunnerWithOptions: (text, direction, _) async {
          calls.add((text, direction));
          return '示例译文';
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-learning-panel')));
    await tester.pumpAndSettle();

    final query = find.byKey(const ValueKey('dictionary-query'));
    final initialSubmit = find.byKey(const ValueKey('dictionary-query-submit'));
    await tester.ensureVisible(query);
    await tester.ensureVisible(initialSubmit);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'ephemeral');
    await tester.tap(initialSubmit);
    await tester.pumpAndSettle();
    final translate = find.byKey(const ValueKey('dictionary-translate-term'));
    await tester.ensureVisible(translate);
    await tester.tap(translate);
    await tester.pumpAndSettle();

    expect(calls, <(String, TranslationDirection)>[
      ('ephemeral', TranslationDirection.englishToChinese),
    ]);
    expect(find.textContaining('示例译文'), findsOneWidget);

    final searchButton = find.byKey(const ValueKey('dictionary-query-submit'));
    await tester.ensureVisible(searchButton);
    await tester.pumpAndSettle();
    await tester.enterText(query, '实验');
    await tester.pump();
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    await tester.tap(translate);
    await tester.pumpAndSettle();
    expect(calls, <(String, TranslationDirection)>[
      ('ephemeral', TranslationDirection.englishToChinese),
      ('实验', TranslationDirection.chineseToEnglish),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dictionary entry prioritizes senses and folds candidate details',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const entry = DictionaryEntry(
        word: 'apple',
        ipa: '/ˈæpəl/',
        partOfSpeech: 'n. 名词',
        meanings: ['苹果', '苹果公司（Apple）'],
        example: 'An apple a day keeps the doctor away.',
        exampleTranslation: '一天一苹果，医生远离我。',
        variants: ['apples'],
      );
      await tester.pumpWidget(
        YixueApp(dictionaryLookupLoader: (_) async => entry),
      );
      await tester.pumpAndSettle();

      final query = find.byKey(const ValueKey('dictionary-query'));
      await tester.ensureVisible(query);
      await tester.enterText(query, 'apple');
      await tester.tap(find.byKey(const ValueKey('dictionary-query-submit')));
      await tester.pumpAndSettle();

      expect(find.text('释义'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('quick-learning-sidebar')),
        const Offset(0, -420),
      );
      await tester.pumpAndSettle();
      expect(find.text('例句'), findsOneWidget);
      expect(find.text('词形候选（待审校）：apples'), findsNothing);

      final details = find.byKey(
        const ValueKey('dictionary-entry-usage-details'),
      );
      await tester.ensureVisible(details);
      final detailsTitle = find.text('用法、词形与来源');
      await tester.ensureVisible(detailsTitle);
      await tester.tap(detailsTitle);
      await tester.pumpAndSettle();

      expect(find.text('词形候选（待审校）：apples'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide quick translation keeps the learning rail visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [
          TranslationHistoryEntryData(
            id: 'learning-rail-history',
            sourceText: 'Technology changes life.',
            translatedText: '技术改变生活。',
            providerId: 'preview',
            createdAt: '2026-09-14T12:00:00+08:00',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('quick-learning-sidebar')),
      findsOneWidget,
    );
    expect(find.text('词语解释'), findsOneWidget);
    expect(find.text('例句'), findsOneWidget);
    expect(find.text('已收藏单词'), findsOneWidget);
    expect(find.text('翻译历史'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quick-history-open-all')),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey('quick-learning-sidebar')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-history-open-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quick translation history card opens the standalone history workspace',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        YixueApp(
          translationHistoryLoader: () async => const [
            TranslationHistoryEntryData(
              id: 'history-header-entry',
              sourceText: 'Technology changes life.',
              translatedText: '技术改变生活。',
              providerId: 'preview',
              createdAt: '2026-09-14T12:00:00+08:00',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('quick-history-header')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quick translation opens the standalone favorite workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const page = FavoriteWordPageData(
      hasMore: false,
      records: [
        FavoriteWordRecordData(
          word: 'consistency',
          favoritedAt: '2026-09-14 12:00:00',
          languagePair: 'en-zh',
          dictionaryEntries: [
            DictionaryEntryData(
              id: 'seed.consistency',
              word: 'consistency',
              ipa: '/kənˈsɪstənsi/',
              partOfSpeech: 'n.',
              meanings: ['一致性；连贯性'],
              example: 'Consistency is the key to success.',
              exampleTranslation: '一致性是成功的关键。',
              source: 'yixue-basic',
            ),
          ],
          annotation: null,
        ),
      ],
    );

    await tester.pumpWidget(
      YixueApp(
        favoriteWordPageLoader: ({query = '', limit = 40, offset = 0}) async =>
            page,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('quick-favorites-header')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('favorite-words-workspace')),
      findsOneWidget,
    );
    expect(find.text('收藏词库'), findsOneWidget);
    expect(find.text('Consistency is the key to success.'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-word-note')), findsOneWidget);
  });

  testWidgets(
    'quick translation network mode is a model option, not a browser search',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? webSearchEnabled;

      await tester.pumpWidget(
        YixueApp(
          quickTranslationRunnerWithOptions: (_, _, options) async {
            webSearchEnabled = options.webSearchEnabled;
            return '你好';
          },
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'hello');
      await tester.tap(find.byKey(const ValueKey('network-search-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('联网检索已开启'), findsOneWidget);
      expect(find.text('打开浏览器搜索'), findsNothing);
      expect(find.text('搜索单词、短语或已确认的片段'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '翻 译   Enter'));
      await tester.pumpAndSettle();

      expect(webSearchEnabled, isTrue);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller?.text == '你好',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact home dashboard stacks without layout errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const YixueApp());
    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();

    expect(find.text('译懂世界，学会表达。'), findsOneWidget);
    expect(find.text('继续任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings reports health from the injected core', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(YixueApp(coreFactory: _FakeCoreBridge.new));
    await tester.tap(find.text('模型与服务'));
    await tester.pumpAndSettle();

    expect(find.text('本地核心已连接'), findsOneWidget);
    expect(find.text('核心 0.1.0  ·  协议 v2'), findsOneWidget);
  });

  testWidgets('settings shows the currently selected model', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [],
        coreFactory: () => _FakeCoreBridge(
          profiles: const [
            ProviderProfileData(
              id: 'local.opus',
              displayName: '英中本地模型',
              kind: ProviderProfileKind.localModel,
              enabled: true,
              modelId: 'yixue.opus-en-zh.int8',
              modelPath: r'D:\models\yixue.opus-en-zh.int8',
              assignedRoles: {ModelRole.translation},
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined).last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('模型与处理'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('本地模型 · 当前：英中本地模型'), findsOneWidget);
    expect(find.text('本地优先 · 模型尚未启用'), findsNothing);
  });

  testWidgets('roleless Qwen is not displayed as the active translator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      YixueApp(
        translationHistoryLoader: () async => const [],
        coreFactory: () => _FakeCoreBridge(
          profiles: const [
            ProviderProfileData(
              id: 'qwen.local',
              displayName: '千问本机接口',
              kind: ProviderProfileKind.remoteApi,
              enabled: true,
              modelId: 'qwen3.5:4b',
              endpoint: 'http://127.0.0.1:11434/v1',
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('本地优先 · 内置英汉模型'), findsOneWidget);
    expect(find.text('自定义接口 · 当前：千问本机接口'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _MemorySidebarPreferenceStore implements SidebarPreferenceStore {
  _MemorySidebarPreferenceStore(this.expanded);

  bool? expanded;

  @override
  Future<bool?> readSidebarExpanded() async => expanded;

  @override
  Future<void> writeSidebarExpanded(bool value) async {
    expanded = value;
  }
}

class _MemoryStoragePolicyStore implements StoragePolicyStore {
  StoragePolicy? value;

  @override
  Future<StoragePolicy?> read() async => value;

  @override
  Future<void> write(StoragePolicy policy) async {
    value = policy;
  }
}
