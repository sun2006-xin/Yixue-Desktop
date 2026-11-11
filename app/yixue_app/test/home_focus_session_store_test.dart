import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_focus_session_store.dart';
import 'package:yixue_app/core/home_workbench.dart';

void main() {
  test('persists and clears a resumable focus session', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-focus-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileHomeFocusSessionStore(
      File('${directory.path}${Platform.pathSeparator}focus.json'),
    );
    const session = HomeFocusSessionData(
      id: 'focus-1',
      title: '精读一小时',
      phase: 'focus',
      focusDurationSeconds: 1500,
      restDurationSeconds: 300,
      targetCycles: 4,
      completedCycles: 0,
      elapsedSeconds: 120,
      startedAt: '2026-09-16T09:00:00+08:00',
      running: true,
      updatedAt: '2026-09-16T09:02:00+08:00',
    );

    await store.write(session);
    expect(await store.read(), session);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test(
    'rejects an invalid phase and never trusts malformed local data',
    () async {
      final directory = await Directory.systemTemp.createTemp('yixue-focus-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}focus.json');
      final store = FileHomeFocusSessionStore(file);
      await file.writeAsString('{"schema_version":1,"phase":"unknown"}');
      expect(await store.read(), isNull);
    },
  );
}
