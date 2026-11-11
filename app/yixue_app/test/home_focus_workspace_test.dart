import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/home/home_focus_workspace.dart';

void main() {
  testWidgets('focus session can start, pause, and resume locally', (
    tester,
  ) async {
    HomeFocusSessionData? stored;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeFocusWorkspace(
            loadSession: () async => stored,
            saveSession: (session) async => stored = session,
            clearSession: () async => stored = null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('50 分钟'), findsOneWidget);
    expect(find.text('10 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-pause')), findsOneWidget);
    expect(stored?.running, isTrue);

    await tester.tap(find.byKey(const ValueKey('focus-pause')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-resume')), findsOneWidget);
    expect(stored?.running, isFalse);

    await tester.tap(find.byKey(const ValueKey('focus-resume')));
    await tester.pumpAndSettle();
    expect(stored?.running, isTrue);
  });

  testWidgets('ending a focus session records one activity and clears it', (
    tester,
  ) async {
    HomeFocusSessionData? stored;
    final activities = <ActivityEventData>[];
    var now = DateTime(2026, 9, 16, 9);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.vitality(),
        home: Scaffold(
          body: HomeFocusWorkspace(
            loadSession: () async => stored,
            saveSession: (session) async => stored = session,
            clearSession: () async => stored = null,
            recordActivity: (activity) async => activities.add(activity),
            clock: () => now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pumpAndSettle();
    now = now.add(const Duration(seconds: 20));
    await tester.tap(find.byKey(const ValueKey('focus-end')));
    await tester.pumpAndSettle();

    expect(stored, isNull);
    expect(activities, hasLength(1));
    expect(activities.single.kind, ActivityKind.focus);
    expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);
  });
}
