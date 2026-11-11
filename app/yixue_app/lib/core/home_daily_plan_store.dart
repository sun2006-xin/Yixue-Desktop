import 'dart:convert';
import 'dart:io';

import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_workbench.dart';

/// Local persistence for the calendar-shaped homepage plan.
///
/// The legacy [FileHomePlanStore] remains available for compatibility. This
/// store keeps one validated plan per local calendar date, so changing
/// tomorrow's plan cannot overwrite today's notes or tasks.
class FileHomeDailyPlanStore {
  FileHomeDailyPlanStore(this.file);

  static const _maxFileBytes = 512 * 1024;

  final File file;

  Future<HomeDailyPlanData?> read(String date) async {
    if (!_isLocalDate(date)) return null;
    final plans = await _readPlans();
    return plans[date];
  }

  /// Returns all plans whose local calendar dates are within the inclusive
  /// range. The result is sorted by date so the same source can drive both
  /// the month calendar and the compact homepage week card.
  Future<List<HomeDailyPlanData>> readRange(
    DateTime start,
    DateTime end,
  ) async {
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    if (last.isBefore(first)) return const [];
    final plans = await _readPlans();
    final result = plans.values
        .where((plan) {
          final date = DateTime.tryParse(plan.date);
          if (date == null) return false;
          final local = DateTime(date.year, date.month, date.day);
          return !local.isBefore(first) && !local.isAfter(last);
        })
        .toList(growable: false);
    result.sort((left, right) => left.date.compareTo(right.date));
    return result;
  }

  Future<void> write(HomeDailyPlanData plan) async {
    final validated = HomeDailyPlanData.fromJson(plan.toJson());
    final plans = await _readPlans(allowMissing: true);
    plans[validated.date] = validated;
    await _writePlans(plans);
  }

  /// Creates a date-specific plan from the old global plan only when that
  /// date has no plan yet. Existing calendar edits always win.
  Future<bool> migrateLegacyIfMissing(
    HomePlanData legacy, {
    required String localDate,
    required String updatedAt,
  }) async {
    if (!_isLocalDate(localDate) || DateTime.tryParse(updatedAt) == null) {
      throw const FormatException('旧版计划迁移参数无效');
    }
    if (await read(localDate) != null) return false;

    final plan = HomeDailyPlanData(
      id: 'legacy-home-plan-$localDate',
      date: localDate,
      title: legacy.title,
      tasks: [
        HomePlanTaskData(
          id: 'legacy-vocabulary-$localDate',
          title: '复习 ${legacy.dailyWordGoal} 个单词',
          kind: 'vocabulary',
          targetCount: legacy.dailyWordGoal,
          estimatedMinutes: legacy.dailyStudyMinutes,
          scheduledAt: null,
          route: 'learning',
          completed: false,
        ),
        HomePlanTaskData(
          id: 'legacy-reading-$localDate',
          title: '阅读 ${legacy.dailyReadingPages} 页',
          kind: 'reading',
          targetCount: legacy.dailyReadingPages,
          estimatedMinutes: 0,
          scheduledAt: null,
          route: 'reader',
          completed: false,
        ),
      ],
      notes: '由旧版首页计划迁移，请在日历中确认今天的任务。',
      reflection: '',
      keyPoints: '',
      updatedAt: updatedAt,
    );
    await write(plan);
    return true;
  }

  Future<Map<String, HomeDailyPlanData>> _readPlans({
    bool allowMissing = false,
  }) async {
    try {
      if (!await file.exists()) {
        if (allowMissing) return <String, HomeDailyPlanData>{};
        return <String, HomeDailyPlanData>{};
      }
      if (await file.length() > _maxFileBytes) {
        if (allowMissing) {
          throw const FormatException('首页每日计划文件过大');
        }
        return <String, HomeDailyPlanData>{};
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['schema_version'] != homeWorkbenchSchemaVersion ||
          value['plans'] is! Map) {
        if (allowMissing) {
          throw const FormatException('首页每日计划文件格式无效');
        }
        return <String, HomeDailyPlanData>{};
      }
      final plans = <String, HomeDailyPlanData>{};
      final rawPlans = (value['plans'] as Map).cast<Object?, Object?>();
      for (final entry in rawPlans.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        try {
          final plan = HomeDailyPlanData.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          );
          if (plan.date == entry.key) plans[entry.key as String] = plan;
        } on FormatException {
          // Ignore one damaged date while keeping other local plans usable.
        }
      }
      return plans;
    } on FileSystemException {
      if (allowMissing) rethrow;
      return <String, HomeDailyPlanData>{};
    } on FormatException {
      if (allowMissing) rethrow;
      return <String, HomeDailyPlanData>{};
    } on JsonUnsupportedObjectError {
      if (allowMissing) rethrow;
      return <String, HomeDailyPlanData>{};
    }
  }

  Future<void> _writePlans(Map<String, HomeDailyPlanData> plans) async {
    await file.parent.create(recursive: true);
    final encoded = <String, Object?>{
      'schema_version': homeWorkbenchSchemaVersion,
      'plans': <String, Object?>{
        for (final entry in plans.entries) entry.key: entry.value.toJson(),
      },
    };
    await file.writeAsString(jsonEncode(encoded), flush: true);
  }

  static bool _isLocalDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null &&
        parsed.year.toString().padLeft(4, '0') == value.substring(0, 4) &&
        parsed.month.toString().padLeft(2, '0') == value.substring(5, 7) &&
        parsed.day.toString().padLeft(2, '0') == value.substring(8, 10);
  }
}
