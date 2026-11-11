// Versioned contracts shared by the home dashboard and the local core.
//
// These objects deliberately distinguish an unavailable metric from a real
// zero. A module that has not connected its activity events must not make the
// dashboard look as if the user did nothing.

const homeWorkbenchSchemaVersion = 1;

class HomeFocusSessionData {
  const HomeFocusSessionData({
    required this.id,
    required this.title,
    required this.phase,
    required this.focusDurationSeconds,
    required this.restDurationSeconds,
    required this.targetCycles,
    required this.completedCycles,
    required this.elapsedSeconds,
    required this.startedAt,
    required this.running,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String phase;
  final int focusDurationSeconds;
  final int restDurationSeconds;
  final int targetCycles;
  final int completedCycles;
  final int elapsedSeconds;
  final String? startedAt;
  final bool running;
  final String updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'title': title,
    'phase': phase,
    'focus_duration_seconds': focusDurationSeconds,
    'rest_duration_seconds': restDurationSeconds,
    'target_cycles': targetCycles,
    'completed_cycles': completedCycles,
    'elapsed_seconds': elapsedSeconds,
    'started_at': startedAt,
    'running': running,
    'updated_at': updatedAt,
  };

  factory HomeFocusSessionData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final phase = json['phase'];
    final focus = json['focus_duration_seconds'];
    final rest = json['rest_duration_seconds'];
    final target = json['target_cycles'];
    final completed = json['completed_cycles'];
    final elapsed = json['elapsed_seconds'];
    final startedAt = json['started_at'];
    if (phase is! String ||
        !{'focus', 'rest'}.contains(phase) ||
        focus is! int ||
        focus < 1 ||
        focus > 86400 ||
        rest is! int ||
        rest < 0 ||
        rest > 86400 ||
        target is! int ||
        target < 1 ||
        target > 100 ||
        completed is! int ||
        completed < 0 ||
        completed > target ||
        elapsed is! int ||
        elapsed < 0 ||
        elapsed > 86400 ||
        (startedAt != null &&
            (startedAt is! String || DateTime.tryParse(startedAt) == null))) {
      throw const FormatException('专注会话参数无效');
    }
    return HomeFocusSessionData(
      id: _requireText(json['id'], '专注会话 ID', 120),
      title: _requireText(json['title'], '专注主题', 240),
      phase: phase,
      focusDurationSeconds: focus,
      restDurationSeconds: rest,
      targetCycles: target,
      completedCycles: completed,
      elapsedSeconds: elapsed,
      startedAt: startedAt as String?,
      running: _requireBool(json['running'], '专注状态'),
      updatedAt: _requireTimestamp(json['updated_at'], '专注更新时间'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeFocusSessionData &&
      other.id == id &&
      other.title == title &&
      other.phase == phase &&
      other.focusDurationSeconds == focusDurationSeconds &&
      other.restDurationSeconds == restDurationSeconds &&
      other.targetCycles == targetCycles &&
      other.completedCycles == completedCycles &&
      other.elapsedSeconds == elapsedSeconds &&
      other.startedAt == startedAt &&
      other.running == running &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    phase,
    focusDurationSeconds,
    restDurationSeconds,
    targetCycles,
    completedCycles,
    elapsedSeconds,
    startedAt,
    running,
    updatedAt,
  );
}

class HomeMetricData {
  const HomeMetricData({required this.available, required this.value});

  const HomeMetricData.available(this.value) : available = true;

  const HomeMetricData.unavailable() : available = false, value = 0;

  final bool available;
  final int value;

  Map<String, Object> toJson() => <String, Object>{
    'available': available,
    'value': value,
  };

  factory HomeMetricData.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('首页指标格式无效');
    final available = raw['available'];
    final value = raw['value'];
    if (available is! bool || value is! int || value < 0) {
      throw const FormatException('首页指标字段无效');
    }
    if (!available && value != 0) {
      throw const FormatException('未接入指标的值必须为零');
    }
    return HomeMetricData(available: available, value: value);
  }

  @override
  bool operator ==(Object other) =>
      other is HomeMetricData &&
      other.available == available &&
      other.value == value;

  @override
  int get hashCode => Object.hash(available, value);
}

class HomeSummaryData {
  const HomeSummaryData({
    required this.translationCount,
    required this.translationUnits,
    required this.learnedWords,
    required this.readingArticles,
    required this.readingUnits,
    required this.favoriteSentences,
    required this.favoriteWords,
    required this.speakingSeconds,
    required this.focusSeconds,
    required this.focusSessions,
  });

  const HomeSummaryData.empty()
    : translationCount = const HomeMetricData.unavailable(),
      translationUnits = const HomeMetricData.unavailable(),
      learnedWords = const HomeMetricData.unavailable(),
      readingArticles = const HomeMetricData.unavailable(),
      readingUnits = const HomeMetricData.unavailable(),
      favoriteSentences = const HomeMetricData.unavailable(),
      favoriteWords = const HomeMetricData.unavailable(),
      speakingSeconds = const HomeMetricData.unavailable(),
      focusSeconds = const HomeMetricData.unavailable(),
      focusSessions = const HomeMetricData.unavailable();

  final HomeMetricData translationCount;
  final HomeMetricData translationUnits;
  final HomeMetricData learnedWords;
  final HomeMetricData readingArticles;
  final HomeMetricData readingUnits;
  final HomeMetricData favoriteSentences;
  final HomeMetricData favoriteWords;
  final HomeMetricData speakingSeconds;
  final HomeMetricData focusSeconds;
  final HomeMetricData focusSessions;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': homeWorkbenchSchemaVersion,
    'translation_count': translationCount.toJson(),
    'translation_units': translationUnits.toJson(),
    'learned_words': learnedWords.toJson(),
    'reading_articles': readingArticles.toJson(),
    'reading_units': readingUnits.toJson(),
    'favorite_sentences': favoriteSentences.toJson(),
    'favorite_words': favoriteWords.toJson(),
    'speaking_seconds': speakingSeconds.toJson(),
    'focus_seconds': focusSeconds.toJson(),
    'focus_sessions': focusSessions.toJson(),
  };

  factory HomeSummaryData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    return HomeSummaryData(
      translationCount: HomeMetricData.fromJson(json['translation_count']),
      translationUnits: HomeMetricData.fromJson(json['translation_units']),
      learnedWords: HomeMetricData.fromJson(json['learned_words']),
      readingArticles: HomeMetricData.fromJson(json['reading_articles']),
      readingUnits: HomeMetricData.fromJson(json['reading_units']),
      favoriteSentences: HomeMetricData.fromJson(json['favorite_sentences']),
      favoriteWords: HomeMetricData.fromJson(json['favorite_words']),
      speakingSeconds: HomeMetricData.fromJson(json['speaking_seconds']),
      focusSeconds: HomeMetricData.fromJson(json['focus_seconds']),
      focusSessions: HomeMetricData.fromJson(json['focus_sessions']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeSummaryData &&
      other.translationCount == translationCount &&
      other.translationUnits == translationUnits &&
      other.learnedWords == learnedWords &&
      other.readingArticles == readingArticles &&
      other.readingUnits == readingUnits &&
      other.favoriteSentences == favoriteSentences &&
      other.favoriteWords == favoriteWords &&
      other.speakingSeconds == speakingSeconds &&
      other.focusSeconds == focusSeconds &&
      other.focusSessions == focusSessions;

  @override
  int get hashCode => Object.hash(
    translationCount,
    translationUnits,
    learnedWords,
    readingArticles,
    readingUnits,
    favoriteSentences,
    favoriteWords,
    speakingSeconds,
    focusSeconds,
    focusSessions,
  );
}

class HomePlanTaskData {
  const HomePlanTaskData({
    required this.id,
    required this.title,
    required this.kind,
    required this.targetCount,
    required this.estimatedMinutes,
    required this.scheduledAt,
    required this.route,
    required this.completed,
    this.sourceId,
  });

  final String id;
  final String title;
  final String kind;
  final int? targetCount;
  final int estimatedMinutes;
  final String? scheduledAt;
  final String? route;
  final bool completed;
  final String? sourceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'title': title,
    'kind': kind,
    'target_count': targetCount,
    'estimated_minutes': estimatedMinutes,
    'scheduled_at': scheduledAt,
    'route': route,
    'completed': completed,
    'source_id': sourceId,
  };

  factory HomePlanTaskData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final targetCount = json['target_count'];
    final estimatedMinutes = json['estimated_minutes'];
    final scheduledAt = json['scheduled_at'];
    final route = json['route'];
    final sourceId = json['source_id'];
    if (targetCount != null && (targetCount is! int || targetCount < 0)) {
      throw const FormatException('计划目标数量无效');
    }
    if (estimatedMinutes is! int ||
        estimatedMinutes < 0 ||
        estimatedMinutes > 1440) {
      throw const FormatException('计划预计时长无效');
    }
    if (scheduledAt != null) _requireTimestamp(scheduledAt, '计划时间');
    if (route != null && (route is! String || route.length > 120)) {
      throw const FormatException('计划页面无效');
    }
    if (sourceId != null && (sourceId is! String || sourceId.length > 256)) {
      throw const FormatException('计划来源无效');
    }
    return HomePlanTaskData(
      id: _requireText(json['id'], '任务 ID', 120),
      title: _requireText(json['title'], '任务标题', 240),
      kind: _requireText(json['kind'], '任务类型', 64),
      targetCount: targetCount as int?,
      estimatedMinutes: estimatedMinutes,
      scheduledAt: scheduledAt as String?,
      route: route as String?,
      completed: _requireBool(json['completed'], '任务状态'),
      sourceId: sourceId as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomePlanTaskData &&
      other.id == id &&
      other.title == title &&
      other.kind == kind &&
      other.targetCount == targetCount &&
      other.estimatedMinutes == estimatedMinutes &&
      other.scheduledAt == scheduledAt &&
      other.route == route &&
      other.completed == completed &&
      other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    kind,
    targetCount,
    estimatedMinutes,
    scheduledAt,
    route,
    completed,
    sourceId,
  );
}

class HomeDailyPlanData {
  const HomeDailyPlanData({
    required this.id,
    required this.date,
    required this.title,
    required this.tasks,
    required this.notes,
    required this.reflection,
    required this.keyPoints,
    required this.updatedAt,
  });

  final String id;
  final String date;
  final String title;
  final List<HomePlanTaskData> tasks;
  final String notes;
  final String reflection;
  final String keyPoints;
  final String updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'date': date,
    'title': title,
    'tasks': tasks.map((task) => task.toJson()).toList(growable: false),
    'notes': notes,
    'reflection': reflection,
    'key_points': keyPoints,
    'updated_at': updatedAt,
  };

  factory HomeDailyPlanData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final rawTasks = json['tasks'];
    if (rawTasks is! List || rawTasks.length > 100) {
      throw const FormatException('每日计划任务列表无效');
    }
    return HomeDailyPlanData(
      id: _requireText(json['id'], '计划 ID', 120),
      date: _requireLocalDate(json['date']),
      title: _requireText(json['title'], '计划标题', 240),
      tasks: rawTasks
          .map((item) {
            if (item is! Map) throw const FormatException('计划任务格式无效');
            return HomePlanTaskData.fromJson(item.cast<String, dynamic>());
          })
          .toList(growable: false),
      notes: _requireText(json['notes'], '计划笔记', 10000, allowEmpty: true),
      reflection: _requireText(
        json['reflection'],
        '学习心得',
        10000,
        allowEmpty: true,
      ),
      keyPoints: _requireText(
        json['key_points'],
        '注意点',
        10000,
        allowEmpty: true,
      ),
      updatedAt: _requireTimestamp(json['updated_at'], '计划更新时间'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeDailyPlanData &&
      other.id == id &&
      other.date == date &&
      other.title == title &&
      _listEquals(other.tasks, tasks) &&
      other.notes == notes &&
      other.reflection == reflection &&
      other.keyPoints == keyPoints &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    date,
    title,
    Object.hashAll(tasks),
    notes,
    reflection,
    keyPoints,
    updatedAt,
  );
}

class HomeResumeTaskData {
  const HomeResumeTaskData({
    required this.id,
    required this.kind,
    required this.title,
    required this.route,
    required this.progressPercent,
    required this.lastTouchedAt,
    required this.completed,
    this.sourceId,
    this.position,
  });

  final String id;
  final String kind;
  final String title;
  final String route;
  final String? sourceId;
  final int? position;
  final int progressPercent;
  final String lastTouchedAt;
  final bool completed;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'kind': kind,
    'title': title,
    'route': route,
    'source_id': sourceId,
    'position': position,
    'progress_percent': progressPercent,
    'last_touched_at': lastTouchedAt,
    'completed': completed,
  };

  factory HomeResumeTaskData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final position = json['position'];
    final progress = json['progress_percent'];
    final sourceId = json['source_id'];
    if (position != null && (position is! int || position < 0)) {
      throw const FormatException('继续任务位置无效');
    }
    if (progress is! int || progress < 0 || progress > 100) {
      throw const FormatException('继续任务进度无效');
    }
    if (sourceId != null && (sourceId is! String || sourceId.length > 256)) {
      throw const FormatException('继续任务来源无效');
    }
    return HomeResumeTaskData(
      id: _requireText(json['id'], '继续任务 ID', 120),
      kind: _requireText(json['kind'], '继续任务类型', 64),
      title: _requireText(json['title'], '继续任务标题', 240),
      route: _requireText(json['route'], '继续任务页面', 120),
      sourceId: sourceId as String?,
      position: position as int?,
      progressPercent: progress,
      lastTouchedAt: _requireTimestamp(json['last_touched_at'], '任务更新时间'),
      completed: _requireBool(json['completed'], '任务完成状态'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeResumeTaskData &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.route == route &&
      other.sourceId == sourceId &&
      other.position == position &&
      other.progressPercent == progressPercent &&
      other.lastTouchedAt == lastTouchedAt &&
      other.completed == completed;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    title,
    route,
    sourceId,
    position,
    progressPercent,
    lastTouchedAt,
    completed,
  );
}

class HomeReminderData {
  const HomeReminderData({
    required this.id,
    required this.title,
    required this.triggerAt,
    required this.durationSeconds,
    required this.restSeconds,
    required this.repeatRule,
    required this.enabled,
  });

  final String id;
  final String title;
  final DateTime triggerAt;
  final int durationSeconds;
  final int restSeconds;
  final String repeatRule;
  final bool enabled;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'title': title,
    'trigger_at': triggerAt.toIso8601String(),
    'duration_seconds': durationSeconds,
    'rest_seconds': restSeconds,
    'repeat_rule': repeatRule,
    'enabled': enabled,
  };

  factory HomeReminderData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final rawTriggerAt = json['trigger_at'];
    final triggerAt = rawTriggerAt is String
        ? DateTime.tryParse(rawTriggerAt)
        : null;
    final durationSeconds = json['duration_seconds'];
    final restSeconds = json['rest_seconds'];
    if (triggerAt == null ||
        durationSeconds is! int ||
        durationSeconds < 0 ||
        durationSeconds > 604800 ||
        restSeconds is! int ||
        restSeconds < 0 ||
        restSeconds > 86400) {
      throw const FormatException('本地提醒参数无效');
    }
    return HomeReminderData(
      id: _requireText(json['id'], '提醒 ID', 120),
      title: _requireText(json['title'], '提醒标题', 240),
      triggerAt: triggerAt,
      durationSeconds: durationSeconds,
      restSeconds: restSeconds,
      repeatRule: _requireText(json['repeat_rule'], '提醒规则', 120),
      enabled: _requireBool(json['enabled'], '提醒状态'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeReminderData &&
      other.id == id &&
      other.title == title &&
      other.triggerAt == triggerAt &&
      other.durationSeconds == durationSeconds &&
      other.restSeconds == restSeconds &&
      other.repeatRule == repeatRule &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    triggerAt,
    durationSeconds,
    restSeconds,
    repeatRule,
    enabled,
  );
}

class HomeUserProfileData {
  const HomeUserProfileData({
    required this.displayName,
    required this.encouragement,
    required this.updatedAt,
  });

  final String displayName;
  final String encouragement;
  final String updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'schema_version': homeWorkbenchSchemaVersion,
    'display_name': displayName,
    'encouragement': encouragement,
    'updated_at': updatedAt,
  };

  factory HomeUserProfileData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    return HomeUserProfileData(
      displayName: _requireText(
        json['display_name'],
        '昵称',
        40,
        allowEmpty: true,
      ),
      encouragement: _requireText(
        json['encouragement'],
        '鼓励语',
        240,
        allowEmpty: true,
      ),
      updatedAt: _requireTimestamp(json['updated_at'], '资料更新时间'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeUserProfileData &&
      other.displayName == displayName &&
      other.encouragement == encouragement &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(displayName, encouragement, updatedAt);
}

class HomeRecentContentData {
  const HomeRecentContentData({
    required this.id,
    required this.kind,
    required this.title,
    required this.detail,
    required this.route,
    required this.occurredAt,
    required this.localSaved,
  });

  final String id;
  final String kind;
  final String title;
  final String? detail;
  final String route;
  final String occurredAt;
  final bool localSaved;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'id': id,
    'kind': kind,
    'title': title,
    'detail': detail,
    'route': route,
    'occurred_at': occurredAt,
    'local_saved': localSaved,
  };

  factory HomeRecentContentData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final detail = json['detail'];
    if (detail != null && (detail is! String || detail.length > 1000)) {
      throw const FormatException('最近内容详情无效');
    }
    return HomeRecentContentData(
      id: _requireText(json['id'], '最近内容 ID', 120),
      kind: _requireText(json['kind'], '最近内容类型', 64),
      title: _requireText(json['title'], '最近内容标题', 240),
      detail: detail as String?,
      route: _requireText(json['route'], '最近内容页面', 120),
      occurredAt: _requireTimestamp(json['occurred_at'], '最近内容时间'),
      localSaved: _requireBool(json['local_saved'], '本地保存状态'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeRecentContentData &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.detail == detail &&
      other.route == route &&
      other.occurredAt == occurredAt &&
      other.localSaved == localSaved;

  @override
  int get hashCode =>
      Object.hash(id, kind, title, detail, route, occurredAt, localSaved);
}

class HomeWorkbenchSnapshotData {
  const HomeWorkbenchSnapshotData({
    required this.localDate,
    required this.summary,
    required this.dailyPlan,
    required this.resumeTasks,
    required this.recent,
  });

  final String localDate;
  final HomeSummaryData summary;
  final HomeDailyPlanData? dailyPlan;
  final List<HomeResumeTaskData> resumeTasks;
  final List<HomeRecentContentData> recent;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': homeWorkbenchSchemaVersion,
    'local_date': localDate,
    'summary': summary.toJson(),
    'daily_plan': dailyPlan?.toJson(),
    'resume_tasks': resumeTasks
        .map((task) => task.toJson())
        .toList(growable: false),
    'recent': recent.map((item) => item.toJson()).toList(growable: false),
  };

  factory HomeWorkbenchSnapshotData.fromJson(Map<String, dynamic> json) {
    _requireSchema(json);
    final rawPlan = json['daily_plan'];
    final rawResumeTasks = json['resume_tasks'];
    final rawRecent = json['recent'];
    if (rawPlan != null && rawPlan is! Map ||
        rawResumeTasks is! List ||
        rawResumeTasks.length > 100 ||
        rawRecent is! List ||
        rawRecent.length > 100) {
      throw const FormatException('首页快照列表格式无效');
    }
    return HomeWorkbenchSnapshotData(
      localDate: _requireLocalDate(json['local_date']),
      summary: _mapValue(json['summary'], HomeSummaryData.fromJson),
      dailyPlan: rawPlan == null
          ? null
          : HomeDailyPlanData.fromJson(rawPlan.cast<String, dynamic>()),
      resumeTasks: rawResumeTasks
          .map((item) => _mapValue(item, HomeResumeTaskData.fromJson))
          .toList(growable: false),
      recent: rawRecent
          .map((item) => _mapValue(item, HomeRecentContentData.fromJson))
          .toList(growable: false),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeWorkbenchSnapshotData &&
      other.localDate == localDate &&
      other.summary == summary &&
      other.dailyPlan == dailyPlan &&
      _listEquals(other.resumeTasks, resumeTasks) &&
      _listEquals(other.recent, recent);

  @override
  int get hashCode => Object.hash(
    localDate,
    summary,
    dailyPlan,
    Object.hashAll(resumeTasks),
    Object.hashAll(recent),
  );
}

T _mapValue<T>(Object? raw, T Function(Map<String, dynamic>) parser) {
  if (raw is! Map) throw const FormatException('首页对象格式无效');
  return parser(raw.cast<String, dynamic>());
}

void _requireSchema(Map<String, dynamic> json) {
  if (json['schema_version'] != homeWorkbenchSchemaVersion) {
    throw const FormatException('首页数据版本不受支持');
  }
}

String _requireText(
  Object? value,
  String label,
  int maxLength, {
  bool allowEmpty = false,
}) {
  if (value is! String) throw FormatException('$label格式无效');
  final trimmed = value.trim();
  if ((!allowEmpty && trimmed.isEmpty) || trimmed.length > maxLength) {
    throw FormatException('$label长度无效');
  }
  return trimmed;
}

bool _requireBool(Object? value, String label) {
  if (value is! bool) throw FormatException('$label格式无效');
  return value;
}

String _requireLocalDate(Object? value) {
  final date = _requireText(value, '本地日期', 10);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    throw const FormatException('本地日期格式无效');
  }
  final parsed = DateTime.tryParse(date);
  if (parsed == null ||
      parsed.year.toString().padLeft(4, '0') != date.substring(0, 4) ||
      parsed.month.toString().padLeft(2, '0') != date.substring(5, 7) ||
      parsed.day.toString().padLeft(2, '0') != date.substring(8, 10)) {
    throw const FormatException('本地日期不存在');
  }
  return date;
}

String _requireTimestamp(Object? value, String label) {
  final timestamp = _requireText(value, label, 80);
  if (DateTime.tryParse(timestamp) == null) {
    throw FormatException('$label格式无效');
  }
  return timestamp;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
