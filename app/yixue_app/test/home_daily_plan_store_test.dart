import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_daily_plan_store.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_workbench.dart';

void main() {
  test(
    'stores multiple daily plans without overwriting another date',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-daily-plan-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileHomeDailyPlanStore(
        File('${directory.path}${Platform.pathSeparator}home-daily-plans.json'),
      );
      final today = HomeDailyPlanData(
        id: 'plan-2026-09-15',
        date: '2026-09-15',
        title: '今天的学习',
        tasks: [
          const HomePlanTaskData(
            id: 'task-1',
            title: '复习单词',
            kind: 'vocabulary',
            targetCount: 30,
            estimatedMinutes: 25,
            scheduledAt: '2026-09-15T08:30:00.000Z',
            route: 'learning',
            completed: false,
          ),
        ],
        notes: '',
        reflection: '',
        keyPoints: '',
        updatedAt: '2026-09-15T08:00:00.000Z',
      );
      final tomorrow = HomeDailyPlanData(
        id: 'plan-2026-09-16',
        date: '2026-09-16',
        title: '明天的学习',
        tasks: [
          const HomePlanTaskData(
            id: 'task-2',
            title: '阅读文章',
            kind: 'reading',
            targetCount: 3,
            estimatedMinutes: 40,
            scheduledAt: null,
            route: 'reader',
            completed: false,
          ),
        ],
        notes: '',
        reflection: '',
        keyPoints: '',
        updatedAt: '2026-09-15T08:01:00.000Z',
      );

      await store.write(today);
      await store.write(tomorrow);

      expect((await store.read('2026-09-15'))?.title, '今天的学习');
      expect((await store.read('2026-09-16'))?.title, '明天的学习');
      expect(await store.read('2026-09-17'), isNull);
    },
  );

  test('reads an inclusive date range in calendar order', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-daily-plan-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileHomeDailyPlanStore(
      File('${directory.path}${Platform.pathSeparator}home-daily-plans.json'),
    );

    HomeDailyPlanData plan(String date) => HomeDailyPlanData(
      id: 'plan-$date',
      date: date,
      title: '计划 $date',
      tasks: const [],
      notes: '',
      reflection: '',
      keyPoints: '',
      updatedAt: '${date}T08:00:00.000Z',
    );

    await store.write(plan('2026-09-30'));
    await store.write(plan('2026-10-01'));
    await store.write(plan('2026-10-08'));

    final range = await store.readRange(
      DateTime(2026, 9, 29),
      DateTime(2026, 10, 7),
    );
    expect(range.map((item) => item.date), ['2026-09-30', '2026-10-01']);
  });

  test('returns null for missing, invalid, or oversized data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yixue-daily-plan-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}home-daily-plans.json',
    );
    final store = FileHomeDailyPlanStore(file);

    expect(await store.read('2026-09-15'), isNull);
    await file.writeAsString('{"schemaVersion":1,"plans":[]');
    expect(await store.read('2026-09-15'), isNull);
    await file.writeAsString(List.filled(600 * 1024, 'x').join());
    expect(await store.read('2026-09-15'), isNull);
  });

  test(
    'migrates the legacy plan once and preserves an existing daily plan',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-daily-plan-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileHomeDailyPlanStore(
        File('${directory.path}${Platform.pathSeparator}home-daily-plans.json'),
      );
      const legacy = HomePlanData(
        title: '考研核心词',
        dailyWordGoal: 40,
        dailyReadingPages: 8,
        dailyStudyMinutes: 45,
        scheduledWeekdays: [1, 3, 5],
      );

      final migrated = await store.migrateLegacyIfMissing(
        legacy,
        localDate: '2026-09-15',
        updatedAt: '2026-09-15T08:00:00.000Z',
      );
      final preserved = await store.migrateLegacyIfMissing(
        legacy,
        localDate: '2026-09-15',
        updatedAt: '2026-09-15T09:00:00.000Z',
      );

      expect(migrated, isTrue);
      expect(preserved, isFalse);
      final loaded = await store.read('2026-09-15');
      expect(loaded?.title, '考研核心词');
      expect(loaded?.tasks.map((task) => task.targetCount), [40, 8]);
      expect(loaded?.tasks.map((task) => task.kind), ['vocabulary', 'reading']);

      final raw =
          jsonDecode(await store.file.readAsString()) as Map<String, dynamic>;
      expect(raw['schema_version'], homeWorkbenchSchemaVersion);
    },
  );
}
