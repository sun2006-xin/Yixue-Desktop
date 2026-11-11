import 'package:flutter/material.dart';
import 'package:yixue_app/core/home_workbench.dart';

typedef HomeDailyPlanLoader = Future<HomeDailyPlanData?> Function(String date);
typedef HomeMonthPlanLoader = Future<List<HomeDailyPlanData>> Function(
  DateTime month,
);
typedef HomeDailyPlanSaver = Future<void> Function(HomeDailyPlanData plan);

/// The date-scoped planner used by both the homepage and the future learning
/// workspace. It deliberately owns no database implementation: the shell
/// injects the local repository, while tests and previews can use memory.
class HomePlannerWorkspace extends StatefulWidget {
  const HomePlannerWorkspace({
    required this.loadPlan,
    required this.loadMonth,
    required this.savePlan,
    this.initialDate,
    this.onClose,
    this.clock = DateTime.now,
    super.key,
  });

  final HomeDailyPlanLoader loadPlan;
  final HomeMonthPlanLoader loadMonth;
  final HomeDailyPlanSaver savePlan;
  final DateTime? initialDate;
  final VoidCallback? onClose;
  final DateTime Function() clock;

  @override
  State<HomePlannerWorkspace> createState() => _HomePlannerWorkspaceState();
}

class _HomePlannerWorkspaceState extends State<HomePlannerWorkspace> {
  late DateTime _selectedDate;
  late DateTime _displayedMonth;
  late Future<List<HomeDailyPlanData>> _monthPlans;
  HomeDailyPlanData? _selectedPlan;
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _reflection = TextEditingController();
  final _keyPoints = TextEditingController();
  var _loadingDay = true;
  var _saving = false;
  var _dirty = false;
  List<HomePlanTaskData> _tasks = const [];

  @override
  void initState() {
    super.initState();
    final initial = _dateOnly(widget.initialDate ?? widget.clock());
    _selectedDate = initial;
    _displayedMonth = DateTime(initial.year, initial.month);
    _monthPlans = _readMonth();
    _loadSelectedDate();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _reflection.dispose();
    _keyPoints.dispose();
    super.dispose();
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  Future<List<HomeDailyPlanData>> _readMonth() =>
      widget.loadMonth(_displayedMonth);

  Future<void> _loadSelectedDate() async {
    setState(() => _loadingDay = true);
    try {
      final plan = await widget.loadPlan(_dateKey(_selectedDate));
      if (!mounted) return;
      _selectedPlan = plan;
      _title.text = plan?.title ?? '今日学习计划';
      _notes.text = plan?.notes ?? '';
      _reflection.text = plan?.reflection ?? '';
      _keyPoints.text = plan?.keyPoints ?? '';
      _tasks = List<HomePlanTaskData>.of(plan?.tasks ?? const []);
      _dirty = false;
      setState(() => _loadingDay = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingDay = false);
      _showMessage('这一天的计划读取失败，请稍后重试');
    }
  }

  void _selectDate(DateTime value) {
    final date = _dateOnly(value);
    if (date.month != _displayedMonth.month ||
        date.year != _displayedMonth.year) {
      _displayedMonth = DateTime(date.year, date.month);
      _monthPlans = _readMonth();
    }
    _selectedDate = date;
    _loadSelectedDate();
  }

  void _moveMonth(int amount) {
    final next = DateTime(_displayedMonth.year, _displayedMonth.month + amount);
    setState(() {
      _displayedMonth = next;
      _monthPlans = _readMonth();
    });
  }

  Future<void> _saveDay() async {
    if (_saving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      _showMessage('请先填写当天计划标题');
      return;
    }
    setState(() => _saving = true);
    final now = widget.clock().toIso8601String();
    final plan = HomeDailyPlanData(
      id: _selectedPlan?.id ?? 'home-plan-${_dateKey(_selectedDate)}',
      date: _dateKey(_selectedDate),
      title: title,
      tasks: List<HomePlanTaskData>.unmodifiable(_tasks),
      notes: _notes.text.trim(),
      reflection: _reflection.text.trim(),
      keyPoints: _keyPoints.text.trim(),
      updatedAt: now,
    );
    try {
      await widget.savePlan(plan);
      if (!mounted) return;
      _selectedPlan = plan;
      _dirty = false;
      _monthPlans = _readMonth();
      setState(() => _saving = false);
      _showMessage('已保存 ${plan.date} 的计划');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showMessage('计划保存失败，请检查本地资料库');
    }
  }

  Future<void> _addTask([HomePlanTaskData? existing]) async {
    final task = await showDialog<HomePlanTaskData>(
      context: context,
      builder: (context) => _PlannerTaskDialog(initial: existing),
    );
    if (task == null || !mounted) return;
    setState(() {
      final index = _tasks.indexWhere((item) => item.id == task.id);
      if (index < 0) {
        _tasks = [..._tasks, task];
      } else {
        final updated = List<HomePlanTaskData>.of(_tasks)..[index] = task;
        _tasks = updated;
      }
      _dirty = true;
    });
  }

  void _toggleTask(HomePlanTaskData task, bool value) {
    final index = _tasks.indexOf(task);
    if (index < 0) return;
    final updated = List<HomePlanTaskData>.of(_tasks)
      ..[index] = HomePlanTaskData(
        id: task.id,
        title: task.title,
        kind: task.kind,
        targetCount: task.targetCount,
        estimatedMinutes: task.estimatedMinutes,
        scheduledAt: task.scheduledAt,
        route: task.route,
        completed: value,
        sourceId: task.sourceId,
      );
    setState(() {
      _tasks = updated;
      _dirty = true;
    });
  }

  void _removeTask(HomePlanTaskData task) {
    setState(() {
      _tasks = _tasks.where((item) => item.id != task.id).toList();
      _dirty = true;
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    try {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } on AssertionError {
      // A standalone preview may not have a Scaffold yet; the save itself
      // has already completed and must remain usable in that context.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.calendar_month_outlined, color: colors.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '学习计划',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text('把今天、明天和每一个想完成的目标留在本地'),
                    ],
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    key: const ValueKey('planner-close'),
                    tooltip: '关闭',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 780;
                  final calendar = _CalendarPanel(
                    displayedMonth: _displayedMonth,
                    selectedDate: _selectedDate,
                    monthPlans: _monthPlans,
                    onPreviousMonth: () => _moveMonth(-1),
                    onNextMonth: () => _moveMonth(1),
                    onToday: () => _selectDate(_dateOnly(widget.clock())),
                    onTomorrow: () => _selectDate(
                      _dateOnly(widget.clock()).add(const Duration(days: 1)),
                    ),
                    onSelectDate: _selectDate,
                  );
                  final detail = _DayDetailPanel(
                    selectedDate: _selectedDate,
                    loading: _loadingDay,
                    saving: _saving,
                    dirty: _dirty,
                    title: _title,
                    notes: _notes,
                    reflection: _reflection,
                    keyPoints: _keyPoints,
                    tasks: _tasks,
                    onChanged: () => setState(() => _dirty = true),
                    onAddTask: _addTask,
                    onEditTask: _addTask,
                    onToggleTask: _toggleTask,
                    onRemoveTask: _removeTask,
                    onSave: _saveDay,
                  );
                  if (stacked) {
                    return ListView(
                      children: [
                        SizedBox(height: 480, child: calendar),
                        const SizedBox(height: 16),
                        detail,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 360, child: calendar),
                      const SizedBox(width: 16),
                      Expanded(child: detail),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarPanel extends StatelessWidget {
  const _CalendarPanel({
    required this.displayedMonth,
    required this.selectedDate,
    required this.monthPlans,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onToday,
    required this.onTomorrow,
    required this.onSelectDate,
  });

  final DateTime displayedMonth;
  final DateTime selectedDate;
  final Future<List<HomeDailyPlanData>> monthPlans;
  final VoidCallback onPreviousMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onToday;
  final VoidCallback onTomorrow;
  final ValueChanged<DateTime> onSelectDate;

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('planner-previous-month'),
                tooltip: '上个月',
                onPressed: onPreviousMonth,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  '${displayedMonth.year}年${displayedMonth.month}月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('planner-next-month'),
                tooltip: '下个月',
                onPressed: onNextMonth,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  key: const ValueKey('planner-today'),
                  onPressed: onToday,
                  child: const Text('今天'),
                ),
                TextButton(
                  key: const ValueKey('planner-tomorrow'),
                  onPressed: onTomorrow,
                  child: const Text('明天'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final label in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: FutureBuilder<List<HomeDailyPlanData>>(
              future: monthPlans,
              builder: (context, snapshot) {
                final planned = <String>{
                  for (final item in snapshot.data ?? const []) item.date,
                };
                final first = DateTime(
                  displayedMonth.year,
                  displayedMonth.month,
                  1,
                );
                final start = first.subtract(Duration(days: first.weekday - 1));
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 42,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 5,
                  ),
                  itemBuilder: (context, index) {
                    final date = start.add(Duration(days: index));
                    final key = _dateKey(date);
                    final inMonth = date.month == displayedMonth.month;
                    final selected = DateUtils.isSameDay(date, selectedDate);
                    final today = DateUtils.isSameDay(date, DateTime.now());
                    return InkWell(
                      key: ValueKey('planner-day-$key'),
                      borderRadius: BorderRadius.circular(9),
                      onTap: () => onSelectDate(date),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.primary
                              : planned.contains(key)
                              ? colors.primary.withAlpha(22)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: today
                                ? colors.primary
                                : selected
                                ? colors.primary
                                : colors.outline.withAlpha(100),
                            width: today || selected ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${date.day}',
                              style: TextStyle(
                                color: selected
                                    ? colors.onPrimary
                                    : inMonth
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant.withAlpha(110),
                                fontWeight: selected || today
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                              ),
                            ),
                            if (planned.contains(key))
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.circle,
                                  size: 4,
                                  color: selected
                                      ? colors.onPrimary
                                      : colors.primary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '有小圆点表示当天已有计划',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayDetailPanel extends StatelessWidget {
  const _DayDetailPanel({
    required this.selectedDate,
    required this.loading,
    required this.saving,
    required this.dirty,
    required this.title,
    required this.notes,
    required this.reflection,
    required this.keyPoints,
    required this.tasks,
    required this.onChanged,
    required this.onAddTask,
    required this.onEditTask,
    required this.onToggleTask,
    required this.onRemoveTask,
    required this.onSave,
  });

  final DateTime selectedDate;
  final bool loading;
  final bool saving;
  final bool dirty;
  final TextEditingController title;
  final TextEditingController notes;
  final TextEditingController reflection;
  final TextEditingController keyPoints;
  final List<HomePlanTaskData> tasks;
  final VoidCallback onChanged;
  final Future<void> Function() onAddTask;
  final Future<void> Function(HomePlanTaskData task) onEditTask;
  final ValueChanged2<HomePlanTaskData, bool> onToggleTask;
  final ValueChanged<HomePlanTaskData> onRemoveTask;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outline),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (loading) return const Center(child: CircularProgressIndicator());
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selectedDate.year}年${selectedDate.month}月${selectedDate.day}日',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (dirty)
                    Text(
                      '未保存',
                      style: TextStyle(color: colors.error, fontSize: 12),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('planner-day-title'),
                controller: title,
                maxLength: 120,
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(
                  labelText: '当天计划标题',
                  prefixIcon: Icon(Icons.flag_outlined),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text(
                    '当天任务',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('planner-add-task'),
                    onPressed: () => onAddTask(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加任务'),
                  ),
                ],
              ),
              if (tasks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('还没有任务，可以先写下今天最重要的一件事。'),
                )
              else
                ...tasks.map(
                  (task) => _PlannerTaskRow(
                    task: task,
                    onToggle: (value) => onToggleTask(task, value),
                    onEdit: () => onEditTask(task),
                    onRemove: () => onRemoveTask(task),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('planner-day-notes'),
                controller: notes,
                maxLines: 3,
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(
                  labelText: '自由笔记',
                  hintText: '今天想做什么、资料放在哪里……',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('planner-day-reflection'),
                controller: reflection,
                maxLines: 2,
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(labelText: '心得体会'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('planner-day-key-points'),
                controller: keyPoints,
                maxLines: 2,
                onChanged: (_) => onChanged(),
                decoration: const InputDecoration(labelText: '注意点'),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(
                    dirty ? '保存后会同步首页本周计划' : '已与首页计划同步',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    key: const ValueKey('planner-save-day'),
                    onPressed: saving ? null : onSave,
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(saving ? '保存中' : '保存当天计划'),
                  ),
                ],
              ),
            ],
          );
          if (!constraints.hasBoundedHeight) return content;
          return SingleChildScrollView(
            key: const ValueKey('planner-day-detail-scroll'),
            child: content,
          );
        },
      ),
    );
  }
}

typedef ValueChanged2<A, B> = void Function(A first, B second);

class _PlannerTaskRow extends StatelessWidget {
  const _PlannerTaskRow({
    required this.task,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
  });

  final HomePlanTaskData task;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withAlpha(90),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Checkbox(
            value: task.completed,
            onChanged: (value) => onToggle(value ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: TextStyle(
                    decoration: task.completed
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                Text(
                  '${task.kind} · ${task.estimatedMinutes} 分钟${task.targetCount == null ? '' : ' · 目标 ${task.targetCount}'}',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('planner-edit-task-${task.id}'),
            tooltip: '编辑任务',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 17),
          ),
          IconButton(
            key: ValueKey('planner-remove-task-${task.id}'),
            tooltip: '删除任务',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded, size: 17),
          ),
        ],
      ),
    );
  }
}

class _PlannerTaskDialog extends StatefulWidget {
  const _PlannerTaskDialog({this.initial});

  final HomePlanTaskData? initial;

  @override
  State<_PlannerTaskDialog> createState() => _PlannerTaskDialogState();
}

class _PlannerTaskDialogState extends State<_PlannerTaskDialog> {
  late final TextEditingController _title;
  late final TextEditingController _target;
  late final TextEditingController _minutes;
  late String _kind;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _target = TextEditingController(
      text: initial?.targetCount?.toString() ?? '',
    );
    _minutes = TextEditingController(
      text: initial?.estimatedMinutes.toString() ?? '25',
    );
    _kind = initial?.kind ?? '学习';
  }

  @override
  void dispose() {
    _title.dispose();
    _target.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final minutes = int.tryParse(_minutes.text.trim());
    final target = _target.text.trim().isEmpty
        ? null
        : int.tryParse(_target.text.trim());
    if (title.isEmpty ||
        minutes == null ||
        minutes < 0 ||
        target != null && target < 0) {
      setState(() => _error = '请填写任务名称，并输入有效的时长或目标数量');
      return;
    }
    Navigator.of(context).pop(
      HomePlanTaskData(
        id:
            widget.initial?.id ??
            'task-${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        kind: _kind,
        targetCount: target,
        estimatedMinutes: minutes,
        scheduledAt: widget.initial?.scheduledAt,
        route: widget.initial?.route,
        completed: widget.initial?.completed ?? false,
        sourceId: widget.initial?.sourceId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '添加当天任务' : '编辑当天任务'),
    content: SizedBox(
      width: 390,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('planner-task-title'),
              controller: _title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: '任务名称'),
            ),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '任务类型'),
              items: const [
                DropdownMenuItem(value: '学习', child: Text('学习')),
                DropdownMenuItem(value: '阅读', child: Text('阅读')),
                DropdownMenuItem(value: '翻译', child: Text('翻译')),
                DropdownMenuItem(value: '复习', child: Text('复习')),
                DropdownMenuItem(value: '其他', child: Text('其他')),
              ],
              onChanged: (value) => setState(() => _kind = value ?? '学习'),
            ),
            TextField(
              controller: _target,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '目标数量（可选）'),
            ),
            TextField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '预计分钟'),
            ),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('planner-save-task'),
        onPressed: _save,
        child: const Text('保存任务'),
      ),
    ],
  );
}
