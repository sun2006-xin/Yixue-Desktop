import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/features/home/home_planner_workspace.dart';

void main() {
  testWidgets('calendar selects a date and saves tasks and notes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final saved = <HomeDailyPlanData>[];
    final existing = HomeDailyPlanData(
      id: 'plan-2026-09-16',
      date: '2026-09-16',
      title: '今天的计划',
      tasks: const [],
      notes: '先完成阅读',
      reflection: '',
      keyPoints: '',
      updatedAt: '2026-09-16T08:00:00.000Z',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: HomePlannerWorkspace(
          initialDate: DateTime(2026, 9, 16),
          loadPlan: (date) async => date == '2026-09-16' ? existing : null,
          loadMonth: (_) async => [existing],
          savePlan: (plan) async => saved.add(plan),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026年9月'), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-today')), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-tomorrow')), findsOneWidget);
    expect(find.text('今天的计划'), findsOneWidget);
    expect(find.text('先完成阅读'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('planner-add-task')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('planner-task-title')),
      '完成一段精读',
    );
    await tester.tap(find.byKey(const ValueKey('planner-save-task')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('planner-save-day')));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.tasks.single.title, '完成一段精读');
    expect(saved.single.notes, '先完成阅读');
  });

  testWidgets('calendar can move across months and expose the selected date', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: HomePlannerWorkspace(
          initialDate: DateTime(2026, 12, 31),
          loadPlan: (_) async => null,
          loadMonth: (_) async => const [],
          savePlan: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026年12月'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('planner-next-month')));
    await tester.pumpAndSettle();
    expect(find.text('2027年1月'), findsOneWidget);
  });

  testWidgets('day detail scrolls inside a short desktop workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const existing = HomeDailyPlanData(
      id: 'plan-2026-09-16',
      date: '2026-09-16',
      title: '英语学习计划',
      tasks: [
        HomePlanTaskData(
          id: 'task-1',
          title: '复习 30 个单词',
          kind: '复习',
          targetCount: 30,
          estimatedMinutes: 30,
          scheduledAt: null,
          route: null,
          completed: false,
        ),
        HomePlanTaskData(
          id: 'task-2',
          title: '阅读 5 页',
          kind: '阅读',
          targetCount: 5,
          estimatedMinutes: 20,
          scheduledAt: null,
          route: null,
          completed: false,
        ),
      ],
      notes: '把今天的重点写下来',
      reflection: '',
      keyPoints: '',
      updatedAt: '2026-09-16T08:00:00.000Z',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: HomePlannerWorkspace(
          initialDate: DateTime(2026, 9, 16),
          loadPlan: (_) async => existing,
          loadMonth: (_) async => [existing],
          savePlan: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('planner-day-detail-scroll')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
