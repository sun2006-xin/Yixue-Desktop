import 'dart:convert';
import 'dart:io';

/// The user's small, local homepage plan.
///
/// Activity totals remain owned by the native core. This record only stores
/// the user's target, so editing a plan never changes historical activity.
class HomePlanData {
  const HomePlanData({
    this.title = '英语学习计划',
    this.dailyWordGoal = 30,
    this.dailyReadingPages = 5,
    this.dailyStudyMinutes = 30,
    this.scheduledWeekdays = const [1, 2, 3, 4, 5, 6, 7],
  });

  static const schemaVersion = 1;

  final String title;
  final int dailyWordGoal;
  final int dailyReadingPages;
  final int dailyStudyMinutes;
  final List<int> scheduledWeekdays;

  HomePlanData copyWith({
    String? title,
    int? dailyWordGoal,
    int? dailyReadingPages,
    int? dailyStudyMinutes,
    List<int>? scheduledWeekdays,
  }) => HomePlanData(
    title: title ?? this.title,
    dailyWordGoal: dailyWordGoal ?? this.dailyWordGoal,
    dailyReadingPages: dailyReadingPages ?? this.dailyReadingPages,
    dailyStudyMinutes: dailyStudyMinutes ?? this.dailyStudyMinutes,
    scheduledWeekdays: scheduledWeekdays ?? this.scheduledWeekdays,
  );

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'title': title,
    'dailyWordGoal': dailyWordGoal,
    'dailyReadingPages': dailyReadingPages,
    'dailyStudyMinutes': dailyStudyMinutes,
    'scheduledWeekdays': scheduledWeekdays,
  };

  factory HomePlanData.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException('unsupported home plan schema');
    }
    final title = json['title'];
    final dailyWordGoal = json['dailyWordGoal'];
    final dailyReadingPages = json['dailyReadingPages'];
    final dailyStudyMinutes = json['dailyStudyMinutes'];
    final scheduledWeekdays = json['scheduledWeekdays'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 120 ||
        dailyWordGoal is! int ||
        dailyReadingPages is! int ||
        dailyStudyMinutes is! int ||
        scheduledWeekdays is! List<dynamic>) {
      throw const FormatException('invalid home plan');
    }
    _validateGoal(dailyWordGoal, 'daily word goal');
    _validateGoal(dailyReadingPages, 'daily reading pages');
    _validateGoal(dailyStudyMinutes, 'daily study minutes');
    if (scheduledWeekdays.isEmpty || scheduledWeekdays.length > 7) {
      throw const FormatException('scheduled weekdays are invalid');
    }
    final weekdays = <int>[];
    for (final value in scheduledWeekdays) {
      if (value is! int || value < 1 || value > 7 || weekdays.contains(value)) {
        throw const FormatException('scheduled weekdays are invalid');
      }
      weekdays.add(value);
    }
    weekdays.sort();
    return HomePlanData(
      title: title.trim(),
      dailyWordGoal: dailyWordGoal,
      dailyReadingPages: dailyReadingPages,
      dailyStudyMinutes: dailyStudyMinutes,
      scheduledWeekdays: List.unmodifiable(weekdays),
    );
  }

  static void _validateGoal(int value, String name) {
    if (value < 1 || value > 10_000) {
      throw FormatException('$name is invalid');
    }
  }
}

abstract interface class HomePlanStore {
  Future<HomePlanData?> read();

  Future<void> write(HomePlanData plan);
}

class FileHomePlanStore implements HomePlanStore {
  FileHomePlanStore(this.file);

  static const _maxFileBytes = 64 * 1024;

  final File file;

  @override
  Future<HomePlanData?> read() async {
    try {
      if (!await file.exists() || await file.length() > _maxFileBytes) {
        return null;
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      return HomePlanData.fromJson(value);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  @override
  Future<void> write(HomePlanData plan) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(plan.toJson()), flush: true);
  }
}
