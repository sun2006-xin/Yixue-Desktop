import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/home/home_dashboard_page.dart';

void main() {
  testWidgets('shows local plan progress and saves edited goals', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const initial = HomePlanData(
      title: '考研核心词',
      dailyWordGoal: 40,
      dailyReadingPages: 6,
      dailyStudyMinutes: 45,
      scheduledWeekdays: [1, 3, 5],
    );
    const snapshot = HomeSnapshotData(
      learningMinutes: 22,
      readingPages: 3,
      masteredWords: 10,
      completedExercises: 2,
      recent: [],
    );
    HomePlanData? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => snapshot,
            loadLatestTranslation: () async => null,
            loadPlan: () async => initial,
            savePlan: (plan) async => saved = plan,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('考研核心词'), findsWidgets);
    expect(find.text(' / 40 词'), findsOneWidget);
    expect(find.text('今日：背词 40 个 · 阅读 6 页 · 学习 45 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-edit-plan')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('home-plan-word-goal')),
      '50',
    );
    await tester.enterText(
      find.byKey(const ValueKey('home-plan-reading-goal')),
      '8',
    );
    await tester.tap(find.byKey(const ValueKey('home-save-plan')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(saved?.dailyWordGoal, 50);
    expect(saved?.dailyReadingPages, 8);
  });

  testWidgets('renders versioned workbench metrics without inventing zeros', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const workbench = HomeCoreSnapshotData(
      localDate: '2026-09-15',
      summary: HomeSummaryData(
        translationCount: HomeMetricData.available(3),
        translationUnits: HomeMetricData.available(41),
        learnedWords: HomeMetricData.available(9),
        readingArticles: HomeMetricData.unavailable(),
        readingUnits: HomeMetricData.available(12),
        favoriteSentences: HomeMetricData.unavailable(),
        favoriteWords: HomeMetricData.unavailable(),
        speakingSeconds: HomeMetricData.available(90),
        focusSeconds: HomeMetricData.available(1500),
        focusSessions: HomeMetricData.available(1),
      ),
      recent: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => const HomeSnapshotData(
              learningMinutes: 999,
              readingPages: 999,
              masteredWords: 999,
              completedExercises: 999,
              recent: [],
            ),
            loadWorkbenchSnapshot: () async => workbench,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-summary-translation-count')),
          )
          .data,
      '3',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-summary-focus-minutes')),
          )
          .data,
      '25',
    );
    expect(find.text('文章 · 暂未接入'), findsOneWidget);
    expect(find.text('收藏词 · 暂未接入'), findsOneWidget);
    expect(find.text('999'), findsNothing);
  });

  testWidgets('weekly plan opens the calendar on the selected day', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DateTime? openedDate;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
            loadDailyPlan: (_) async => null,
            loadDailyPlans: (_, _) async => const [],
            onOpenPlanner: () {},
            onOpenPlannerDate: (date) => openedDate = date,
            clock: () => DateTime(2026, 9, 16),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tomorrow = find.byKey(const ValueKey('home-month-day-2026-9-17'));
    await tester.ensureVisible(tomorrow);
    await tester.tap(tomorrow);

    expect(openedDate, DateTime(2026, 9, 17));
  });

  testWidgets('homepage shows the complete current month plan calendar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DateTime? loadedStart;
    DateTime? loadedEnd;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
            loadDailyPlans: (start, end) async {
              loadedStart = start;
              loadedEnd = end;
              return const [
                HomeDailyPlanData(
                  id: 'plan-2026-09-18',
                  date: '2026-09-18',
                  title: '复习词汇',
                  tasks: [],
                  notes: '',
                  reflection: '',
                  keyPoints: '',
                  updatedAt: '2026-09-16T09:00:00+08:00',
                ),
              ];
            },
            onOpenPlanner: () {},
            onOpenPlannerDate: (_) {},
            clock: () => DateTime(2026, 9, 16),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026年9月'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-month-day-2026-9-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-month-day-2026-9-30')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-month-day-2026-9-18')),
      findsOneWidget,
    );
    expect(loadedStart, DateTime(2026, 9, 1));
    expect(loadedEnd, DateTime(2026, 9, 30));
  });

  testWidgets('recent content opens the complete history workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opened = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
            onOpenHistory: () => opened += 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('home-open-history'));
    expect(action, findsOneWidget);
    await tester.tap(action);

    expect(opened, 1);
  });

  testWidgets('recent workbench entries expose an actionable target', (
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
    String? openedId;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadWorkbenchSnapshot: () async => workbench,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
            onOpenRecent: (entry) => openedId = entry.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final target = find.byKey(
      const ValueKey('home-recent-translation:history-1'),
    );
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.tap(target);

    expect(openedId, activity.id);
  });

  testWidgets(
    'resume learning task takes priority over a translation history entry',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var continued = 0;
      const resume = HomeResumeTaskData(
        id: 'learning-resume:vocabulary-1',
        kind: 'learning',
        title: '六级核心词复习',
        route: 'learning',
        sourceId: 'vocabulary-1',
        position: 4,
        progressPercent: 38,
        lastTouchedAt: '2026-09-16T09:00:00+08:00',
        completed: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.vitality(),
          home: Scaffold(
            body: HomeDashboardPage(
              onContinueTranslation: (_) {},
              onStartTranslation: (_) {},
              onOpenScreenshot: () {},
              onOpenLearning: () => continued += 1,
              onOpenLive: () {},
              loadSnapshot: () async => _emptySnapshotForTest,
              loadLatestTranslation: () async =>
                  const TranslationHistoryEntryData(
                    id: 'translation-1',
                    sourceText: 'hello',
                    translatedText: '你好',
                    providerId: 'test-provider',
                    sourceLanguage: 'en',
                    targetLanguage: 'zh',
                    createdAt: '2026-09-16T09:01:00+08:00',
                  ),
              loadResumeTask: () async => resume,
              loadPlan: () async => const HomePlanData(),
              savePlan: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('六级核心词复习'), findsOneWidget);
      expect(find.text('学习记录 · 第 5 段 · 已完成 38%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-primary-continue')));
      expect(continued, 1);
    },
  );

  testWidgets('today summary exposes an independent details action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opened = 0;
    const workbench = HomeCoreSnapshotData(
      localDate: '2026-09-16',
      summary: HomeSummaryData.empty(),
      recent: [],
      details: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadWorkbenchSnapshot: () async => workbench,
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
            onOpenTodaySummary: () => opened += 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('home-open-today-summary'));
    expect(action, findsOneWidget);
    await tester.tap(action);

    expect(opened, 1);
  });

  testWidgets(
    'saving a personal greeting does not return a Future from setState',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      HomeUserProfileData? saved;
      final errors = <FlutterErrorDetails>[];
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details);
        previousErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousErrorHandler);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.vitality(),
          home: Scaffold(
            body: HomeDashboardPage(
              onContinueTranslation: (_) {},
              onStartTranslation: (_) {},
              onOpenScreenshot: () {},
              onOpenLearning: () {},
              onOpenLive: () {},
              loadSnapshot: () async => _emptySnapshotForTest,
              loadLatestTranslation: () async => null,
              loadPlan: () async => const HomePlanData(),
              savePlan: (_) async {},
              loadUserProfile: () async => null,
              saveUserProfile: (profile) async => saved = profile,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('home-edit-profile')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('home-profile-name')),
        '花鱼鱼',
      );
      await tester.tap(find.byKey(const ValueKey('home-save-profile')));
      await tester.pumpAndSettle();
      FlutterError.onError = previousErrorHandler;

      expect(saved?.displayName, '花鱼鱼');
      expect(find.textContaining('花鱼鱼'), findsOneWidget);
      expect(
        errors.where(
          (details) => details.exception.toString().contains(
            'setState() callback argument returned a Future',
          ),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('summary cards keep a shared height on wide home layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeDashboardPage(
            onContinueTranslation: (_) {},
            onStartTranslation: (_) {},
            onOpenScreenshot: () {},
            onOpenLearning: () {},
            onOpenLive: () {},
            loadSnapshot: () async => _emptySnapshotForTest,
            loadWorkbenchSnapshot: () async => const HomeCoreSnapshotData(
              localDate: '2026-09-16',
              summary: HomeSummaryData.empty(),
              recent: [],
            ),
            loadLatestTranslation: () async => null,
            loadPlan: () async => const HomePlanData(),
            savePlan: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final summaryHeight = tester
        .getSize(find.byKey(const ValueKey('home-card-today-summary')))
        .height;
    final weeklyHeight = tester
        .getSize(find.byKey(const ValueKey('home-card-weekly-plan')))
        .height;
    final recentHeight = tester
        .getSize(find.byKey(const ValueKey('home-card-recent-content')))
        .height;

    expect(summaryHeight, closeTo(weeklyHeight, 0.01));
    expect(summaryHeight, closeTo(recentHeight, 0.01));
  });
}

const _emptySnapshotForTest = HomeSnapshotData(
  learningMinutes: 0,
  readingPages: 0,
  masteredWords: 0,
  completedExercises: 0,
  recent: [],
);
