import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/home_plan.dart';

void main() {
  test('round trips a local plan and normalizes weekday order', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-plan-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileHomePlanStore(
      File('${directory.path}${Platform.pathSeparator}home-plan.json'),
    );
    const plan = HomePlanData(
      title: '考研核心词',
      dailyWordGoal: 40,
      dailyReadingPages: 8,
      dailyStudyMinutes: 45,
      scheduledWeekdays: [5, 1, 3],
    );

    await store.write(plan);
    final loaded = await store.read();

    expect(loaded?.title, '考研核心词');
    expect(loaded?.dailyWordGoal, 40);
    expect(loaded?.scheduledWeekdays, [1, 3, 5]);
  });

  test('ignores an invalid or oversized plan file', () async {
    final directory = await Directory.systemTemp.createTemp('yixue-plan-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}home-plan.json',
    );
    final store = FileHomePlanStore(file);

    await file.writeAsString(
      '{"schemaVersion":1,"title":"","dailyWordGoal":0}',
    );
    expect(await store.read(), isNull);
    await file.writeAsString(List.filled(70 * 1024, 'x').join());
    expect(await store.read(), isNull);
  });
}
