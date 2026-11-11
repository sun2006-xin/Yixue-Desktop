import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/home/home_daily_stats_workspace.dart';

void main() {
  testWidgets(
    'daily stats workspace shows and filters local activity details',
    (tester) async {
      final snapshot = _snapshot([
        const ActivityEventData(
          id: 'reading-1',
          kind: ActivityKind.reading,
          title: 'Human-AI Collaboration.pdf',
          detail: '阅读器 · 第 3 段',
          sourceId: 'article-1',
          durationSeconds: 120,
          itemCount: 3,
          occurredAt: '2026-09-16T09:10:00+08:00',
        ),
        const ActivityEventData(
          id: 'translation-1',
          kind: ActivityKind.translation,
          title: 'Technology changes life.',
          detail: '快速翻译 · 英语 → 中文',
          durationSeconds: 12,
          itemCount: 4,
          occurredAt: '2026-09-16T09:00:00+08:00',
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeDailyStatsWorkspace(
              loadSnapshot: () async => snapshot,
              clock: () => DateTime(2026, 9, 16, 10),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-today-summary-details')),
        findsOneWidget,
      );
      expect(find.text('Human-AI Collaboration.pdf'), findsOneWidget);
      expect(find.text('Technology changes life.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('home-stats-filter-reading')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-stats-event-reading-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-stats-event-translation-1')),
        findsNothing,
      );
    },
  );

  testWidgets('daily stats workspace renders an explicit empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeDailyStatsWorkspace(
            loadSnapshot: () async => _snapshot(const []),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('home-today-summary-details')),
      findsOneWidget,
    );
    expect(find.text('今天还没有可展示的活动记录'), findsOneWidget);
  });
}

HomeCoreSnapshotData _snapshot(List<ActivityEventData> details) {
  return HomeCoreSnapshotData(
    localDate: '2026-09-16',
    summary: const HomeSummaryData.empty(),
    recent: details,
    details: details,
  );
}
