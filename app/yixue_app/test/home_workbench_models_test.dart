import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_workbench.dart';

void main() {
  test('summary keeps unavailable modules distinct from a real zero', () {
    const summary = HomeSummaryData(
      translationCount: HomeMetricData.available(4),
      translationUnits: HomeMetricData.available(38),
      learnedWords: HomeMetricData.available(12),
      readingArticles: HomeMetricData.unavailable(),
      readingUnits: HomeMetricData.unavailable(),
      favoriteSentences: HomeMetricData.available(2),
      favoriteWords: HomeMetricData.available(5),
      speakingSeconds: HomeMetricData.unavailable(),
      focusSeconds: HomeMetricData.available(3000),
      focusSessions: HomeMetricData.available(1),
    );

    final restored = HomeSummaryData.fromJson(summary.toJson());

    expect(restored.translationCount, const HomeMetricData.available(4));
    expect(restored.readingArticles.available, isFalse);
    expect(restored.readingArticles.value, 0);
  });

  test('daily plan round-trips tasks, notes and local date', () {
    const plan = HomeDailyPlanData(
      id: 'plan-2026-09-15',
      date: '2026-09-15',
      title: '论文阅读与术语整理',
      tasks: [
        HomePlanTaskData(
          id: 'task-1',
          title: '阅读第三节',
          kind: 'reading',
          targetCount: 6,
          estimatedMinutes: 40,
          scheduledAt: '2026-09-15T19:00:00+08:00',
          route: 'reader',
          completed: false,
        ),
      ],
      notes: '先看方法部分',
      reflection: '待完成后记录',
      keyPoints: '保留术语上下文',
      updatedAt: '2026-09-15T18:00:00+08:00',
    );

    expect(HomeDailyPlanData.fromJson(plan.toJson()), plan);
  });

  test('invalid plan dates and resume progress are rejected', () {
    expect(
      () => HomeDailyPlanData.fromJson(<String, dynamic>{
        ...const HomeDailyPlanData(
          id: 'plan-1',
          date: '2026-09-15',
          title: '计划',
          tasks: [],
          notes: '',
          reflection: '',
          keyPoints: '',
          updatedAt: '2026-09-15T18:00:00+08:00',
        ).toJson(),
        'date': '2026-02-30',
      }),
      throwsFormatException,
    );

    expect(
      () => HomeResumeTaskData.fromJson(<String, dynamic>{
        'schema_version': 1,
        'id': 'resume-1',
        'kind': 'reader',
        'title': '论文',
        'route': 'reader',
        'progress_percent': 101,
        'last_touched_at': '2026-09-15T18:00:00+08:00',
        'completed': false,
      }),
      throwsFormatException,
    );
  });

  test('reminder and profile preserve explicit local choices', () {
    final reminder = HomeReminderData(
      id: 'reminder-1',
      title: '开始阅读',
      triggerAt: DateTime.parse('2026-09-15T19:00:00+08:00'),
      durationSeconds: 3000,
      restSeconds: 600,
      repeatRule: 'none',
      enabled: true,
    );
    const profile = HomeUserProfileData(
      displayName: '花鱼鱼',
      encouragement: '慢慢来，今天也会有收获',
      updatedAt: '2026-09-15T18:00:00+08:00',
    );

    expect(HomeReminderData.fromJson(reminder.toJson()), reminder);
    expect(HomeUserProfileData.fromJson(profile.toJson()), profile);
  });

  test('workbench snapshot supports empty state and recent content', () {
    const snapshot = HomeWorkbenchSnapshotData(
      localDate: '2026-09-15',
      summary: HomeSummaryData.empty(),
      dailyPlan: null,
      resumeTasks: [],
      recent: [
        HomeRecentContentData(
          id: 'history-1',
          kind: 'translation',
          title: 'Technology changes life',
          detail: '快速翻译',
          route: 'quick-translation',
          occurredAt: '2026-09-15T18:00:00+08:00',
          localSaved: true,
        ),
      ],
    );

    expect(HomeWorkbenchSnapshotData.fromJson(snapshot.toJson()), snapshot);
  });
}
