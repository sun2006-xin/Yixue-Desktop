import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/features/home/home_planner_workspace.dart';
import 'package:yixue_app/features/home/home_greeting.dart';

typedef HomeSnapshotLoader = Future<HomeSnapshotData> Function();
typedef HomeWorkbenchSnapshotLoader = Future<HomeCoreSnapshotData?> Function();
typedef LatestTranslationLoader =
    Future<TranslationHistoryEntryData?> Function();
typedef HomeRecentActivityHandler = void Function(ActivityEventData activity);
typedef HomePlanLoader = Future<HomePlanData> Function();
typedef HomePlanSaver = Future<void> Function(HomePlanData plan);
typedef HomeDailyPlanRangeLoader = Future<List<HomeDailyPlanData>> Function(
  DateTime start,
  DateTime end,
);
typedef HomeDailyPlanOpener = void Function(DateTime date);
typedef HomeResumeTaskLoader = Future<HomeResumeTaskData?> Function();
typedef HomeUserProfileLoader = Future<HomeUserProfileData?> Function();
typedef HomeUserProfileSaver = Future<void> Function(
  HomeUserProfileData profile,
);

class HomeDashboardPage extends StatefulWidget {
  const HomeDashboardPage({
    required this.onContinueTranslation,
    required this.onStartTranslation,
    required this.onOpenScreenshot,
    required this.onOpenLearning,
    required this.onOpenLive,
    required this.loadSnapshot,
    this.loadWorkbenchSnapshot,
    this.onOpenRecent,
    this.onOpenHistory,
    this.onOpenTodaySummary,
    required this.loadLatestTranslation,
    required this.loadPlan,
    required this.savePlan,
    this.loadDailyPlan,
    this.loadDailyPlans,
    this.onOpenPlanner,
    this.onOpenPlannerDate,
    this.loadResumeTask,
    this.onOpenFocus,
    this.loadUserProfile,
    this.saveUserProfile,
    this.onEditProfile,
    this.clock = DateTime.now,
    super.key,
  });

  final ValueChanged<TranslationHistoryEntryData> onContinueTranslation;
  final ValueChanged<String> onStartTranslation;
  final VoidCallback onOpenScreenshot;
  final VoidCallback onOpenLearning;
  final VoidCallback onOpenLive;
  final HomeSnapshotLoader loadSnapshot;
  final HomeWorkbenchSnapshotLoader? loadWorkbenchSnapshot;
  final HomeRecentActivityHandler? onOpenRecent;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenTodaySummary;
  final LatestTranslationLoader loadLatestTranslation;
  final HomePlanLoader loadPlan;
  final HomePlanSaver savePlan;
  final HomeDailyPlanLoader? loadDailyPlan;
  final HomeDailyPlanRangeLoader? loadDailyPlans;
  final VoidCallback? onOpenPlanner;
  final HomeDailyPlanOpener? onOpenPlannerDate;
  final HomeResumeTaskLoader? loadResumeTask;
  final VoidCallback? onOpenFocus;
  final HomeUserProfileLoader? loadUserProfile;
  final HomeUserProfileSaver? saveUserProfile;
  final VoidCallback? onEditProfile;
  final DateTime Function() clock;

  @override
  State<HomeDashboardPage> createState() => _HomeDashboardPageState();
}

class _HomeDashboardPageState extends State<HomeDashboardPage> {
  final _quickStartController = TextEditingController();
  late Future<_HomeDashboardData> _dashboard;
  late Future<TranslationHistoryEntryData?> _latestTranslation;
  late Future<HomePlanData> _plan;
  late Future<HomeDailyPlanData?> _dailyPlan;
  late Future<List<HomeDailyPlanData>> _dailyPlans;
  late Future<HomeResumeTaskData?> _resumeTask;
  late Future<HomeUserProfileData?> _profile;

  @override
  void initState() {
    super.initState();
    _dashboard = _loadDashboard();
    _latestTranslation = widget.loadLatestTranslation();
    _plan = widget.loadPlan();
    final today = _dateOnly(widget.clock());
    _dailyPlan =
        widget.loadDailyPlan?.call(_dateKey(today)) ?? Future.value(null);
    final monthStart = DateTime(today.year, today.month);
    final monthEnd = DateTime(today.year, today.month + 1, 0);
    _dailyPlans =
        widget.loadDailyPlans?.call(monthStart, monthEnd) ??
        Future.value(const []);
    _resumeTask = widget.loadResumeTask?.call() ?? Future.value(null);
    _profile = widget.loadUserProfile?.call() ?? Future.value(null);
  }

  @override
  void dispose() {
    _quickStartController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shell = YixueShellPalette.of(context);
    final today = widget.clock();
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(30, 24, 30, 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FutureBuilder<HomeUserProfileData?>(
                      future: _profile,
                      builder: (context, profileSnapshot) =>
                          FutureBuilder<_HomeDashboardData>(
                            future: _dashboard,
                            builder: (context, dashboardSnapshot) {
                              final workbench =
                                  dashboardSnapshot.data?.workbench;
                              final focusMinutes =
                                  workbench?.summary.focusSeconds.available ==
                                      true
                                  ? workbench!.summary.focusSeconds.value ~/ 60
                                  : 0;
                              return _GreetingHeader(
                                profile: profileSnapshot.data,
                                focusMinutes: focusMinutes,
                                now: today,
                              );
                            },
                          ),
                    ),
                  ),
                  if (widget.onEditProfile != null ||
                      widget.loadUserProfile != null)
                    IconButton(
                      key: const ValueKey('home-edit-profile'),
                      tooltip: '编辑个人问候',
                      onPressed:
                          widget.onEditProfile ??
                          () => unawaited(_editProfile()),
                      icon: const Icon(Icons.person_outline_rounded),
                    ),
                  const Icon(Icons.shield_outlined, size: 17),
                  const SizedBox(width: 7),
                  Text(
                    '内容默认在本地',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 820;
                  final continueCard =
                      FutureBuilder<TranslationHistoryEntryData?>(
                        future: _latestTranslation,
                        builder: (context, snapshot) =>
                            FutureBuilder<HomeResumeTaskData?>(
                              future: _resumeTask,
                              builder: (context, resumeSnapshot) =>
                                  _ContinueTaskCard(
                                    translation: snapshot.data,
                                    resumeTask: resumeSnapshot.data,
                                    loading:
                                        snapshot.connectionState !=
                                            ConnectionState.done ||
                                        resumeSnapshot.connectionState !=
                                            ConnectionState.done,
                                    onOpenLearning: widget.onOpenLearning,
                                    onContinueTranslation:
                                        widget.onContinueTranslation,
                                    vitality: shell.isVitality,
                                  ),
                            ),
                      );
                  final learningCard = FutureBuilder<_HomeDashboardData>(
                    future: _dashboard,
                    builder: (context, dashboardSnapshot) {
                      final data = dashboardSnapshot.data ?? _emptyDashboard;
                      return FutureBuilder<HomePlanData>(
                        future: _plan,
                        builder: (context, planSnapshot) =>
                            FutureBuilder<HomeDailyPlanData?>(
                              future: _dailyPlan,
                              builder: (context, dailyPlanSnapshot) =>
                                  _TodayLearningCard(
                                    snapshot: data.legacy,
                                    plan:
                                        planSnapshot.data ??
                                        const HomePlanData(),
                                    dailyPlan: dailyPlanSnapshot.data,
                                    loading:
                                        dashboardSnapshot.connectionState !=
                                            ConnectionState.done ||
                                        planSnapshot.connectionState !=
                                            ConnectionState.done ||
                                        dailyPlanSnapshot.connectionState !=
                                            ConnectionState.done,
                                    onContinue: widget.onOpenLearning,
                                    onOpenPlanner: widget.onOpenPlanner,
                                    onOpenFocus: widget.onOpenFocus,
                                  ),
                            ),
                      );
                    },
                  );
                  if (stacked) {
                    return Column(
                      children: [
                        continueCard,
                        const SizedBox(height: 14),
                        learningCard,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: continueCard),
                      const SizedBox(width: 14),
                      Expanded(flex: 4, child: learningCard),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              _QuickStartBar(
                controller: _quickStartController,
                onStart: () {
                  final text = _quickStartController.text.trim();
                  if (text.isNotEmpty) widget.onStartTranslation(text);
                },
                onScreenshot: widget.onOpenScreenshot,
                onLive: widget.onOpenLive,
              ),
              const SizedBox(height: 14),
              FutureBuilder<_HomeDashboardData>(
                future: _dashboard,
                builder: (context, dashboardSnapshot) {
                  final data = dashboardSnapshot.data ?? _emptyDashboard;
                  return FutureBuilder<HomePlanData>(
                    future: _plan,
                    builder: (context, planSnapshot) =>
                        FutureBuilder<HomeDailyPlanData?>(
                          future: _dailyPlan,
                          builder: (context, dailyPlanSnapshot) =>
                              FutureBuilder<List<HomeDailyPlanData>>(
                                future: _dailyPlans,
                                builder: (context, dailyPlansSnapshot) =>
                                    _DashboardSummaryRow(
                                      data: data,
                                      plan:
                                          planSnapshot.data ??
                                          const HomePlanData(),
                                      dailyPlan: dailyPlanSnapshot.data,
                                      dailyPlans:
                                          dailyPlansSnapshot.data ?? const [],
                                      today: today,
                                      loading:
                                          dashboardSnapshot.connectionState !=
                                          ConnectionState.done,
                                      planLoading:
                                          planSnapshot.connectionState !=
                                          ConnectionState.done,
                                      failed: dashboardSnapshot.hasError,
                                      onRefresh: () => setState(() {
                                        _dashboard = _loadDashboard();
                                        _dailyPlan = _loadDailyPlan();
                                        _dailyPlans = _loadDailyPlans();
                                        _resumeTask =
                                            widget.loadResumeTask?.call() ??
                                            Future.value(null);
                                        _profile =
                                            widget.loadUserProfile?.call() ??
                                            Future.value(null);
                                      }),
                                      onEditPlan: () => _editPlan(
                                        planSnapshot.data ??
                                            const HomePlanData(),
                                      ),
                                      onOpenPlanner: widget.onOpenPlanner,
                                      onOpenPlannerDate:
                                          widget.onOpenPlannerDate,
                                      onOpenRecent:
                                          widget.onOpenRecent ?? (_) {},
                                      onOpenHistory: widget.onOpenHistory,
                                      onOpenTodaySummary:
                                          widget.onOpenTodaySummary,
                                    ),
                              ),
                        ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<_HomeDashboardData> _loadDashboard() async {
    final workbench = await widget.loadWorkbenchSnapshot?.call();
    if (workbench != null) return _HomeDashboardData.fromWorkbench(workbench);
    return _HomeDashboardData.legacy(await widget.loadSnapshot());
  }

  Future<HomeDailyPlanData?> _loadDailyPlan() {
    return widget.loadDailyPlan?.call(_dateKey(_dateOnly(widget.clock()))) ??
        Future.value(null);
  }

  Future<List<HomeDailyPlanData>> _loadDailyPlans() {
    final today = _dateOnly(widget.clock());
    final monthStart = DateTime(today.year, today.month);
    final monthEnd = DateTime(today.year, today.month + 1, 0);
    return widget.loadDailyPlans?.call(monthStart, monthEnd) ??
        Future.value(const []);
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  Future<void> _editPlan(HomePlanData current) async {
    final updated = await showDialog<HomePlanData>(
      context: context,
      builder: (context) => _HomePlanEditorDialog(initial: current),
    );
    if (updated == null || !mounted) return;
    try {
      await widget.savePlan(updated);
      if (!mounted) return;
      setState(() => _plan = Future.value(updated));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('学习计划已保存在本机')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('学习计划保存失败：$error')));
    }
  }

  Future<void> _editProfile() async {
    final initial =
        await _profile ??
        HomeUserProfileData(
          displayName: '',
          encouragement: '',
          updatedAt: widget.clock().toIso8601String(),
        );
    if (!mounted) return;
    final updated = await showDialog<HomeUserProfileData>(
      context: context,
      builder: (context) => _HomeProfileEditorDialog(initial: initial),
    );
    if (updated == null || !mounted) return;
    try {
      await widget.saveUserProfile?.call(updated);
      if (!mounted) return;
      setState(() {
        _profile = Future.value(updated);
      });
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('个人问候已保存在本机')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('个人问候保存失败：$error')));
    }
  }
}

const _emptySnapshot = HomeSnapshotData(
  learningMinutes: 0,
  readingPages: 0,
  masteredWords: 0,
  completedExercises: 0,
  recent: [],
);

const _emptyDashboard = _HomeDashboardData(legacy: _emptySnapshot);

class _GreetingHeader extends StatelessWidget {
  const _GreetingHeader({
    required this.profile,
    required this.focusMinutes,
    required this.now,
  });

  final HomeUserProfileData? profile;
  final int focusMinutes;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          homeGreeting(now, profile: profile, focusMinutes: focusMinutes),
          key: const ValueKey('home-greeting'),
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          homeEncouragement(profile),
          key: const ValueKey('home-encouragement'),
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
        ),
      ],
    );
  }
}

class _HomeProfileEditorDialog extends StatefulWidget {
  const _HomeProfileEditorDialog({required this.initial});

  final HomeUserProfileData initial;

  @override
  State<_HomeProfileEditorDialog> createState() =>
      _HomeProfileEditorDialogState();
}

class _HomeProfileEditorDialogState extends State<_HomeProfileEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _encouragement;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.displayName);
    _encouragement = TextEditingController(text: widget.initial.encouragement);
  }

  @override
  void dispose() {
    _name.dispose();
    _encouragement.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(
      HomeUserProfileData(
        displayName: _name.text.trim(),
        encouragement: _encouragement.text.trim(),
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('个人问候'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('home-profile-name'),
            controller: _name,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: '昵称（可选）',
              hintText: '例如：花鱼鱼',
            ),
          ),
          TextField(
            key: const ValueKey('home-profile-encouragement'),
            controller: _encouragement,
            maxLength: 240,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '专属鼓励语（可选）',
              hintText: '例如：慢慢来，今天也会有收获',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('home-save-profile'),
        onPressed: _save,
        child: const Text('保存'),
      ),
    ],
  );
}

class _HomeDashboardData {
  const _HomeDashboardData({required this.legacy, this.workbench});

  const _HomeDashboardData.legacy(HomeSnapshotData snapshot)
    : this(legacy: snapshot);

  factory _HomeDashboardData.fromWorkbench(HomeCoreSnapshotData snapshot) =>
      _HomeDashboardData(
        legacy: _legacySnapshotFromWorkbench(snapshot),
        workbench: snapshot,
      );

  final HomeSnapshotData legacy;
  final HomeCoreSnapshotData? workbench;

  List<ActivityEventData> get recent => workbench?.recent ?? legacy.recent;
}

HomeSnapshotData _legacySnapshotFromWorkbench(HomeCoreSnapshotData snapshot) {
  final summary = snapshot.summary;
  final minutes = summary.focusSeconds.available
      ? summary.focusSeconds.value ~/ 60
      : 0;
  final readingUnits = summary.readingUnits.available
      ? summary.readingUnits.value
      : 0;
  final learnedWords = summary.learnedWords.available
      ? summary.learnedWords.value
      : 0;
  return HomeSnapshotData(
    learningMinutes: minutes,
    readingPages: readingUnits,
    masteredWords: learnedWords,
    completedExercises: 0,
    recent: snapshot.recent,
  );
}

class _DashboardSummaryRow extends StatelessWidget {
  const _DashboardSummaryRow({
    required this.data,
    required this.plan,
    required this.dailyPlan,
    required this.dailyPlans,
    required this.today,
    required this.loading,
    required this.planLoading,
    required this.failed,
    required this.onRefresh,
    required this.onEditPlan,
    required this.onOpenPlanner,
    this.onOpenPlannerDate,
    required this.onOpenRecent,
    this.onOpenHistory,
    this.onOpenTodaySummary,
  });

  final _HomeDashboardData data;
  final HomePlanData plan;
  final HomeDailyPlanData? dailyPlan;
  final List<HomeDailyPlanData> dailyPlans;
  final DateTime today;
  final bool loading;
  final bool planLoading;
  final bool failed;
  final VoidCallback onRefresh;
  final VoidCallback onEditPlan;
  final VoidCallback? onOpenPlanner;
  final HomeDailyPlanOpener? onOpenPlannerDate;
  final HomeRecentActivityHandler onOpenRecent;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenTodaySummary;

  @override
  Widget build(BuildContext context) {
    final summary = KeyedSubtree(
      key: const ValueKey('home-card-today-summary'),
      child: _TodaySummaryCard(
        data: data,
        loading: loading,
        onOpenDetails: onOpenTodaySummary,
      ),
    );
    final weeklyPlan = KeyedSubtree(
      key: const ValueKey('home-card-weekly-plan'),
      child: _WeeklyPlanCard(
        plan: plan,
        dailyPlan: dailyPlan,
        dailyPlans: dailyPlans,
        today: today,
        loading: planLoading,
        onEdit: onEditPlan,
        onOpenPlanner: onOpenPlanner,
        onOpenPlannerDate: onOpenPlannerDate,
      ),
    );
    final recent = KeyedSubtree(
      key: const ValueKey('home-card-recent-content'),
      child: _RecentContentCard(
        activities: data.recent,
        failed: failed,
        onRefresh: onRefresh,
        onOpenRecent: onOpenRecent,
        onOpenHistory: onOpenHistory,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              summary,
              const SizedBox(height: 14),
              weeklyPlan,
              const SizedBox(height: 14),
              recent,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 4, child: summary),
              const SizedBox(width: 14),
              Expanded(flex: 4, child: weeklyPlan),
              const SizedBox(width: 14),
              Expanded(flex: 5, child: recent),
            ],
          ),
        );
      },
    );
  }
}

class _ContinueTaskCard extends StatelessWidget {
  const _ContinueTaskCard({
    required this.translation,
    required this.resumeTask,
    required this.loading,
    required this.onOpenLearning,
    required this.onContinueTranslation,
    required this.vitality,
  });

  final TranslationHistoryEntryData? translation;
  final HomeResumeTaskData? resumeTask;
  final bool loading;
  final VoidCallback onOpenLearning;
  final ValueChanged<TranslationHistoryEntryData> onContinueTranslation;
  final bool vitality;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resume = resumeTask;
    final hasResume = resume != null;
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.surface,
        gradient: vitality
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF8FCFF), Color(0xFFEAF9F4)],
              )
            : null,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12023A52),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories_outlined, color: colors.primary),
              const SizedBox(width: 9),
              const Text('继续任务', style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                loading
                    ? '读取本地记录…'
                    : hasResume
                    ? '最近活动'
                    : translation == null
                    ? '尚无任务'
                    : '最近翻译',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            resume?.title ?? translation?.sourceText ?? '从一次翻译或学习开始',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800, height: 1.25),
          ),
          const SizedBox(height: 8),
          Text(
            resume == null
                ? translation?.translatedText ?? '完成后的内容会安全保存在本机，方便继续查看'
                : '学习记录 · 第 ${(resume.position ?? 0) + 1} 段 · 已完成 ${resume.progressPercent}%',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: loading
                        ? null
                        : hasResume
                        ? resume.progressPercent / 100
                        : translation == null
                        ? 0
                        : 1,
                    minHeight: 6,
                    backgroundColor: colors.surfaceContainerHighest,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF20BE8C)),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              FilledButton.icon(
                key: const ValueKey('home-primary-continue'),
                onPressed: loading
                    ? null
                    : hasResume
                    ? onOpenLearning
                    : translation == null
                    ? onOpenLearning
                    : () => onContinueTranslation(translation!),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: Text(
                  hasResume
                      ? '继续学习'
                      : translation == null
                      ? '开始学习'
                      : '再次查看',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TodayLearningCard extends StatelessWidget {
  const _TodayLearningCard({
    required this.snapshot,
    required this.plan,
    required this.dailyPlan,
    required this.loading,
    required this.onContinue,
    this.onOpenPlanner,
    this.onOpenFocus,
  });

  final HomeSnapshotData snapshot;
  final HomePlanData plan;
  final HomeDailyPlanData? dailyPlan;
  final bool loading;
  final VoidCallback onContinue;
  final VoidCallback? onOpenPlanner;
  final VoidCallback? onOpenFocus;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (onOpenPlanner != null) {
      final current = dailyPlan;
      final total = current?.tasks.length ?? 0;
      final completed =
          current?.tasks.where((task) => task.completed).length ?? 0;
      final progress = total == 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
      return Container(
        constraints: const BoxConstraints(minHeight: 240),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '今日学习',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Icon(
                  Icons.edit_calendar_outlined,
                  size: 18,
                  color: colors.primary,
                ),
              ],
            ),
            const SizedBox(height: 17),
            Text(
              current?.title ?? '今天还没有计划',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 9),
            Text(
              total == 0
                  ? '把想做的事写下来，今天从一项任务开始。'
                  : '已完成 $completed / $total 项任务',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: loading ? null : progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: colors.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(colors.primary),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('home-open-planner-today'),
                  onPressed: onOpenPlanner,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: const Text('打开今日计划'),
                ),
                if (onOpenFocus != null) ...[
                  TextButton.icon(
                    key: const ValueKey('home-open-focus'),
                    onPressed: onOpenFocus,
                    icon: const Icon(Icons.timer_outlined, size: 18),
                    label: const Text('开始专注'),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }
    final progress = (snapshot.masteredWords / plan.dailyWordGoal)
        .clamp(0.0, 1.0)
        .toDouble();
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '今日学习',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 17),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${snapshot.masteredWords}',
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 36,
                  height: 1,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                ' / ${plan.dailyWordGoal} 词',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            '${plan.title} · 阅读 ${plan.dailyReadingPages} 页 · 学习 ${plan.dailyStudyMinutes} 分钟',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: loading ? null : progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
            backgroundColor: colors.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(colors.primary),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onContinue,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('继续背词'),
          ),
        ],
      ),
    );
  }
}

class _QuickStartBar extends StatelessWidget {
  const _QuickStartBar({
    required this.controller,
    required this.onStart,
    required this.onScreenshot,
    required this.onLive,
  });

  final TextEditingController controller;
  final VoidCallback onStart;
  final VoidCallback onScreenshot;
  final VoidCallback onLive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.translate_rounded, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const ValueKey('home-quick-start-field'),
              controller: controller,
              onSubmitted: (_) => onStart(),
              decoration: const InputDecoration(
                hintText: '输入或粘贴文字，直接开始翻译',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          FilledButton(
            key: const ValueKey('home-start-translation'),
            onPressed: onStart,
            child: const Text('开始翻译'),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '截屏翻译',
            onPressed: onScreenshot,
            icon: const Icon(Icons.center_focus_weak_rounded),
          ),
          IconButton(
            tooltip: 'AI 同传',
            onPressed: onLive,
            icon: const Icon(Icons.graphic_eq_rounded),
          ),
        ],
      ),
    );
  }
}

class _TodaySummaryCard extends StatelessWidget {
  const _TodaySummaryCard({
    required this.data,
    required this.loading,
    this.onOpenDetails,
  });

  final _HomeDashboardData data;
  final bool loading;
  final VoidCallback? onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final workbench = data.workbench;
    if (workbench != null) {
      final summary = workbench.summary;
      final metrics = [
        summary.translationCount,
        summary.translationUnits,
        summary.learnedWords,
        summary.readingArticles,
        summary.readingUnits,
        summary.favoriteSentences,
        summary.favoriteWords,
        summary.speakingSeconds,
        summary.focusSeconds,
        summary.focusSessions,
      ];
      return _DashboardCard(
        title: '今日总结',
        trailing: loading
            ? '读取本地记录…'
            : metrics.any((metric) => !metric.available)
            ? '部分指标暂未接入'
            : '仅统计本机活动',
        trailingWidget: onOpenDetails == null
            ? null
            : TextButton(
                key: const ValueKey('home-open-today-summary'),
                onPressed: onOpenDetails,
                child: const Text('查看详情'),
              ),
        child: Wrap(
          spacing: 14,
          runSpacing: 16,
          children: [
            _workbenchMetric(
              key: const ValueKey('home-summary-translation-count'),
              metric: summary.translationCount,
              unit: '次',
              label: '翻译',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-translation-units'),
              metric: summary.translationUnits,
              unit: '词/字符',
              label: '处理',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-learned-words'),
              metric: summary.learnedWords,
              unit: '词',
              label: '学习',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-reading-articles'),
              metric: summary.readingArticles,
              unit: '篇',
              label: '文章',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-reading-units'),
              metric: summary.readingUnits,
              unit: '页/段',
              label: '阅读',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-favorite-sentences'),
              metric: summary.favoriteSentences,
              unit: '句',
              label: '收藏句',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-favorite-words'),
              metric: summary.favoriteWords,
              unit: '词',
              label: '收藏词',
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-speaking-minutes'),
              metric: summary.speakingSeconds,
              unit: '分钟',
              label: '同传/口语',
              convertSecondsToMinutes: true,
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-focus-minutes'),
              metric: summary.focusSeconds,
              unit: '分钟',
              label: '专注',
              convertSecondsToMinutes: true,
            ),
            _workbenchMetric(
              key: const ValueKey('home-summary-focus-sessions'),
              metric: summary.focusSessions,
              unit: '次',
              label: '专注次数',
            ),
          ],
        ),
      );
    }

    final snapshot = data.legacy;
    return _DashboardCard(
      title: '今日总结',
      trailing: loading ? '读取本地记录…' : '仅统计本机活动',
      child: Wrap(
        spacing: 18,
        runSpacing: 16,
        children: [
          _Metric(
            valueKey: const ValueKey('home-summary-learning-minutes'),
            value: '${snapshot.learningMinutes}',
            unit: '分钟',
            label: '学习',
          ),
          _Metric(
            valueKey: const ValueKey('home-summary-reading-pages'),
            value: '${snapshot.readingPages}',
            unit: '页',
            label: '阅读',
          ),
          _Metric(
            valueKey: const ValueKey('home-summary-mastered-words'),
            value: '${snapshot.masteredWords}',
            unit: '词',
            label: '掌握',
          ),
          _Metric(
            valueKey: const ValueKey('home-summary-completed-exercises'),
            value: '${snapshot.completedExercises}',
            unit: '题',
            label: '练习',
          ),
        ],
      ),
    );
  }

  _Metric _workbenchMetric({
    required Key key,
    required HomeMetricData metric,
    required String unit,
    required String label,
    bool convertSecondsToMinutes = false,
  }) {
    final value = metric.available
        ? convertSecondsToMinutes
              ? '${metric.value ~/ 60}'
              : '${metric.value}'
        : '—';
    return _Metric(
      valueKey: key,
      value: value,
      unit: metric.available ? unit : '',
      label: metric.available ? label : '$label · 暂未接入',
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.valueKey,
    required this.value,
    required this.unit,
    required this.label,
  });

  final Key valueKey;
  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: 80,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  key: valueKey,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 4),
                  child: Text(
                    unit,
                    style: TextStyle(
                      color: muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(label, style: TextStyle(color: muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _WeeklyPlanCard extends StatelessWidget {
  const _WeeklyPlanCard({
    required this.plan,
    required this.dailyPlan,
    required this.dailyPlans,
    required this.today,
    required this.loading,
    required this.onEdit,
    this.onOpenPlanner,
    this.onOpenPlannerDate,
  });

  final HomePlanData plan;
  final HomeDailyPlanData? dailyPlan;
  final List<HomeDailyPlanData> dailyPlans;
  final DateTime today;
  final bool loading;
  final VoidCallback onEdit;
  final VoidCallback? onOpenPlanner;
  final HomeDailyPlanOpener? onOpenPlannerDate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (onOpenPlanner != null) {
      final plans = <String, HomeDailyPlanData>{
        for (final item in dailyPlans) item.date: item,
      };
      final todayPlan = dailyPlan;
      final taskCount = todayPlan?.tasks.length ?? 0;
      return _DashboardCard(
        title: '计划日历',
        trailing: loading ? '读取中…' : '${plans.length} 天已安排',
        child: Column(
          children: [
            _HomeMonthCalendar(
              month: DateTime(today.year, today.month),
              today: today,
              plannedDates: plans.keys.toSet(),
              onSelectDate: (date) {
                final openForDate = onOpenPlannerDate;
                if (openForDate != null) {
                  openForDate(date);
                } else {
                  onOpenPlanner!();
                }
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.flag_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    todayPlan == null
                        ? '今天还没有计划，点击日历安排任务'
                        : '今日：${todayPlan.title} · $taskCount 项任务',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('home-open-planner'),
                  tooltip: '打开月历',
                  onPressed: onOpenPlanner,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final monday = today.subtract(Duration(days: today.weekday - 1));
    const dayLabels = ['一', '二', '三', '四', '五', '六', '日'];
    return _DashboardCard(
      title: '本周计划',
      trailing: loading ? '读取中…' : '${plan.scheduledWeekdays.length} 天/周',
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < dayLabels.length; index++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: index == 6 ? 0 : 5),
                    child: _PlanDayChip(
                      label: dayLabels[index],
                      date: monday.add(Duration(days: index)),
                      today: today,
                      scheduled: plan.scheduledWeekdays.contains(index + 1),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.flag_outlined, size: 18, color: colors.primary),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '今日：背词 ${plan.dailyWordGoal} 个 · 阅读 ${plan.dailyReadingPages} 页 · 学习 ${plan.dailyStudyMinutes} 分钟',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const ValueKey('home-edit-plan'),
                tooltip: '编辑学习计划',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeMonthCalendar extends StatelessWidget {
  const _HomeMonthCalendar({
    required this.month,
    required this.today,
    required this.plannedDates,
    required this.onSelectDate,
  });

  final DateTime month;
  final DateTime today;
  final Set<String> plannedDates;
  final ValueChanged<DateTime> onSelectDate;

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Widget _dayCell(BuildContext context, DateTime date, ColorScheme colors) {
    final key = _dateKey(date);
    final inMonth = date.month == month.month;
    final isToday = DateUtils.isSameDay(date, today);
    final planned = plannedDates.contains(key);
    return InkWell(
      key: ValueKey('home-month-day-${date.year}-${date.month}-${date.day}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onSelectDate(date),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isToday
              ? colors.primary
              : planned
              ? colors.primary.withAlpha(22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isToday ? colors.primary : colors.outline.withAlpha(100),
            width: isToday ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                color: isToday
                    ? colors.onPrimary
                    : inMonth
                    ? colors.onSurface
                    : colors.onSurfaceVariant.withAlpha(110),
                fontSize: 12,
                fontWeight: isToday || planned
                    ? FontWeight.w800
                    : FontWeight.w500,
              ),
            ),
            if (planned)
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: isToday ? colors.onPrimary : colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    final gridStart = first.subtract(Duration(days: first.weekday - 1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.calendar_month_outlined,
              size: 17,
              color: colors.primary,
            ),
            const SizedBox(width: 7),
            Text(
              '${month.year}年${month.month}月',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            Text(
              '点击日期打开详细计划',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final label in ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Column(
          key: const ValueKey('home-month-calendar'),
          children: [
            for (var row = 0; row < 6; row++) ...[
              if (row > 0) const SizedBox(height: 4),
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: column == 6 ? 0 : 4),
                          child: _dayCell(
                            context,
                            gridStart.add(Duration(days: row * 7 + column)),
                            colors,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: colors.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '小圆点表示当天已有计划',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlanDayChip extends StatelessWidget {
  const _PlanDayChip({
    required this.label,
    required this.date,
    required this.today,
    required this.scheduled,
  });

  final String label;
  final DateTime date;
  final DateTime today;
  final bool scheduled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isToday = DateUtils.isSameDay(date, today);
    final background = isToday
        ? colors.primary
        : scheduled
        ? colors.primary.withAlpha(24)
        : Colors.transparent;
    final foreground = isToday ? colors.onPrimary : colors.onSurface;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isToday ? colors.primary : colors.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: TextStyle(color: foreground, fontSize: 11)),
          Text(
            '${date.day}',
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentContentCard extends StatelessWidget {
  const _RecentContentCard({
    required this.activities,
    required this.failed,
    required this.onRefresh,
    required this.onOpenRecent,
    this.onOpenHistory,
  });

  final List<ActivityEventData> activities;
  final bool failed;
  final VoidCallback onRefresh;
  final HomeRecentActivityHandler onOpenRecent;
  final VoidCallback? onOpenHistory;

  @override
  Widget build(BuildContext context) {
    return _DashboardCard(
      title: '最近内容',
      trailing: failed ? '读取失败' : '本地记录',
      trailingWidget: onOpenHistory == null
          ? null
          : TextButton(
              key: const ValueKey('home-open-history'),
              onPressed: onOpenHistory,
              child: const Text('查看全部历史'),
            ),
      child: failed
          ? TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新读取'),
            )
          : activities.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('完成一次阅读、学习或翻译后，记录会出现在这里。'),
                if (onOpenHistory != null) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    key: const ValueKey('home-empty-history-open'),
                    onPressed: onOpenHistory,
                    icon: const Icon(Icons.history_rounded, size: 17),
                    label: const Text('打开历史记录'),
                  ),
                ],
              ],
            )
          : Column(
              children: [
                for (var index = 0; index < activities.length; index++) ...[
                  if (index > 0) const Divider(height: 20),
                  _RecentRow(
                    activity: activities[index],
                    icon: _activityIcon(activities[index].kind),
                    title: activities[index].title,
                    detail: activities[index].detail ?? '已保存在本地',
                    onOpen: onOpenRecent,
                  ),
                ],
              ],
            ),
    );
  }

  IconData _activityIcon(ActivityKind kind) => switch (kind) {
    ActivityKind.translation => Icons.translate_rounded,
    ActivityKind.reading => Icons.description_outlined,
    ActivityKind.vocabulary => Icons.bookmark_border_rounded,
    ActivityKind.exercise => Icons.edit_note_rounded,
    ActivityKind.speaking => Icons.mic_none_rounded,
    ActivityKind.focus => Icons.timer_outlined,
  };
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.activity,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onOpen,
  });

  final ActivityEventData activity;
  final IconData icon;
  final String title;
  final String detail;
  final HomeRecentActivityHandler onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('home-recent-${activity.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => onOpen(activity),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: Row(
            children: [
              Icon(icon, size: 19, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      detail,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomePlanEditorDialog extends StatefulWidget {
  const _HomePlanEditorDialog({required this.initial});

  final HomePlanData initial;

  @override
  State<_HomePlanEditorDialog> createState() => _HomePlanEditorDialogState();
}

class _HomePlanEditorDialogState extends State<_HomePlanEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _words;
  late final TextEditingController _pages;
  late final TextEditingController _minutes;
  late Set<int> _selectedWeekdays;
  String? _scheduleError;

  @override
  void initState() {
    super.initState();
    final plan = widget.initial;
    _title = TextEditingController(text: plan.title);
    _words = TextEditingController(text: '${plan.dailyWordGoal}');
    _pages = TextEditingController(text: '${plan.dailyReadingPages}');
    _minutes = TextEditingController(text: '${plan.dailyStudyMinutes}');
    _selectedWeekdays = plan.scheduledWeekdays.toSet();
  }

  @override
  void dispose() {
    _title.dispose();
    _words.dispose();
    _pages.dispose();
    _minutes.dispose();
    super.dispose();
  }

  String? _positiveInteger(String? raw) {
    final value = int.tryParse(raw?.trim() ?? '');
    return value == null || value < 1 || value > 10_000
        ? '请输入 1–10000 的整数'
        : null;
  }

  void _submit() {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid || _selectedWeekdays.isEmpty) {
      setState(() {
        _scheduleError = _selectedWeekdays.isEmpty ? '至少安排一天学习' : null;
      });
      return;
    }
    final weekdays = _selectedWeekdays.toList()..sort();
    Navigator.of(context).pop(
      widget.initial.copyWith(
        title: _title.text.trim(),
        dailyWordGoal: int.parse(_words.text.trim()),
        dailyReadingPages: int.parse(_pages.text.trim()),
        dailyStudyMinutes: int.parse(_minutes.text.trim()),
        scheduledWeekdays: weekdays,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return AlertDialog(
      title: const Text('编辑学习计划'),
      content: SizedBox(
        width: 430,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const ValueKey('home-plan-title'),
                  controller: _title,
                  maxLength: 120,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请填写计划名称' : null,
                  decoration: const InputDecoration(labelText: '计划名称'),
                ),
                TextFormField(
                  key: const ValueKey('home-plan-word-goal'),
                  controller: _words,
                  keyboardType: TextInputType.number,
                  validator: _positiveInteger,
                  decoration: const InputDecoration(labelText: '每日背词数'),
                ),
                TextFormField(
                  key: const ValueKey('home-plan-reading-goal'),
                  controller: _pages,
                  keyboardType: TextInputType.number,
                  validator: _positiveInteger,
                  decoration: const InputDecoration(labelText: '每日阅读页数'),
                ),
                TextFormField(
                  key: const ValueKey('home-plan-minutes-goal'),
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  validator: _positiveInteger,
                  decoration: const InputDecoration(labelText: '每日学习分钟'),
                ),
                const SizedBox(height: 16),
                const Text(
                  '安排学习日',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var index = 0; index < labels.length; index++)
                      FilterChip(
                        key: ValueKey('home-plan-weekday-${index + 1}'),
                        label: Text(labels[index]),
                        selected: _selectedWeekdays.contains(index + 1),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _selectedWeekdays.add(index + 1);
                          } else {
                            _selectedWeekdays.remove(index + 1);
                          }
                          _scheduleError = null;
                        }),
                      ),
                  ],
                ),
                if (_scheduleError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _scheduleError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('home-save-plan'),
          onPressed: _submit,
          child: const Text('保存计划'),
        ),
      ],
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.trailing,
    required this.child,
    this.trailingWidget,
  });

  final String title;
  final String trailing;
  final Widget child;
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              trailingWidget ??
                  Text(
                    trailing,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}
