import 'package:flutter/material.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

typedef HomeDailyStatsSnapshotLoader = Future<HomeCoreSnapshotData?> Function();

class HomeDailyStatsWorkspace extends StatefulWidget {
  const HomeDailyStatsWorkspace({
    required this.loadSnapshot,
    this.clock = DateTime.now,
    this.onClose,
    super.key,
  });

  final HomeDailyStatsSnapshotLoader loadSnapshot;
  final DateTime Function() clock;
  final VoidCallback? onClose;

  @override
  State<HomeDailyStatsWorkspace> createState() =>
      _HomeDailyStatsWorkspaceState();
}

class _HomeDailyStatsWorkspaceState extends State<HomeDailyStatsWorkspace> {
  late Future<HomeCoreSnapshotData?> _snapshot;
  ActivityKind? _filter;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.loadSnapshot();
  }

  void _reload() {
    setState(() {
      _snapshot = widget.loadSnapshot();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HomeCoreSnapshotData?>(
      future: _snapshot,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _StatsMessage(
            title: '今日统计暂时读取失败',
            detail: '本地记录没有被删除，可以重新读取。',
            onClose: widget.onClose,
            action: TextButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新读取'),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return _StatsMessage(
            title: '今日统计',
            detail: '本地核心暂未提供统计数据。',
            onClose: widget.onClose,
            action: TextButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新读取'),
            ),
          );
        }
        return _StatsContent(
          snapshot: data,
          filter: _filter,
          onFilterChanged: (filter) => setState(() => _filter = filter),
          onReload: _reload,
          clock: widget.clock,
          onClose: widget.onClose,
        );
      },
    );
  }
}

class _StatsContent extends StatelessWidget {
  const _StatsContent({
    required this.snapshot,
    required this.filter,
    required this.onFilterChanged,
    required this.onReload,
    required this.clock,
    this.onClose,
  });

  final HomeCoreSnapshotData snapshot;
  final ActivityKind? filter;
  final ValueChanged<ActivityKind?> onFilterChanged;
  final VoidCallback onReload;
  final DateTime Function() clock;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activities = filter == null
        ? snapshot.details
        : snapshot.details.where((event) => event.kind == filter).toList();
    return ColoredBox(
      key: const ValueKey('home-today-summary-details'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '今日统计',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${snapshot.localDate} · 只统计保存在本机的活动',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('home-stats-reload'),
                      tooltip: '重新读取',
                      onPressed: onReload,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    if (onClose != null)
                      IconButton(
                        key: const ValueKey('home-close-today-summary'),
                        tooltip: '关闭',
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            _StatsMetricGrid(summary: snapshot.summary),
            const SizedBox(height: 22),
            Text(
              '活动明细',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            _StatsFilters(selected: filter, onChanged: onFilterChanged),
            const SizedBox(height: 12),
            if (activities.isEmpty)
              _EmptyActivities(
                filtered: filter != null,
                date: snapshot.localDate.isEmpty
                    ? _dateOnly(clock())
                    : snapshot.localDate,
              )
            else
              ...activities.map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ActivityDetailTile(event: event),
                ),
              ),
            const SizedBox(height: 12),
            _MethodologyCard(),
          ],
        ),
      ),
    );
  }
}

class _StatsMetricGrid extends StatelessWidget {
  const _StatsMetricGrid({required this.summary});

  final HomeSummaryData summary;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      (summary.translationCount, '翻译', '次', false),
      (summary.translationUnits, '处理', '词/字符', false),
      (summary.learnedWords, '学习', '词', false),
      (summary.readingArticles, '文章', '篇', false),
      (summary.readingUnits, '阅读', '页/段', false),
      (summary.favoriteSentences, '收藏句', '句', false),
      (summary.favoriteWords, '收藏词', '词', false),
      (summary.speakingSeconds, '同传/口语', '分钟', true),
      (summary.focusSeconds, '专注', '分钟', true),
      (summary.focusSessions, '专注次数', '次', false),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final metric in metrics)
          _StatsMetric(
            metric: metric.$1,
            label: metric.$2,
            unit: metric.$3,
            secondsToMinutes: metric.$4,
          ),
      ],
    );
  }
}

class _StatsMetric extends StatelessWidget {
  const _StatsMetric({
    required this.metric,
    required this.label,
    required this.unit,
    required this.secondsToMinutes,
  });

  final HomeMetricData metric;
  final String label;
  final String unit;
  final bool secondsToMinutes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = !metric.available
        ? '—'
        : secondsToMinutes
        ? '${metric.value ~/ 60}'
        : '${metric.value}';
    return Container(
      width: 126,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (metric.available) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    unit,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            metric.available ? label : '$label · 暂未接入',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StatsFilters extends StatelessWidget {
  const _StatsFilters({required this.selected, required this.onChanged});

  final ActivityKind? selected;
  final ValueChanged<ActivityKind?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _filterChip(context, null, '全部', 'home-stats-filter-all'),
        _filterChip(
          context,
          ActivityKind.translation,
          '翻译',
          'home-stats-filter-translation',
        ),
        _filterChip(
          context,
          ActivityKind.reading,
          '阅读',
          'home-stats-filter-reading',
        ),
        _filterChip(
          context,
          ActivityKind.vocabulary,
          '词汇',
          'home-stats-filter-vocabulary',
        ),
        _filterChip(
          context,
          ActivityKind.exercise,
          '练习',
          'home-stats-filter-exercise',
        ),
        _filterChip(
          context,
          ActivityKind.speaking,
          '同传/口语',
          'home-stats-filter-speaking',
        ),
        _filterChip(
          context,
          ActivityKind.focus,
          '专注',
          'home-stats-filter-focus',
        ),
      ],
    );
  }

  Widget _filterChip(
    BuildContext context,
    ActivityKind? kind,
    String label,
    String key,
  ) {
    return FilterChip(
      key: ValueKey(key),
      selected: selected == kind,
      label: Text(label),
      onSelected: (_) => onChanged(kind),
    );
  }
}

class _ActivityDetailTile extends StatelessWidget {
  const _ActivityDetailTile({required this.event});

  final ActivityEventData event;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = event.durationSeconds > 0
        ? ' · ${_formatDuration(event.durationSeconds)}'
        : '';
    final items = event.itemCount > 0 ? ' · ${event.itemCount} 项' : '';
    final source = event.sourceId == null ? '' : ' · 来源 ${event.sourceId}';
    return Container(
      key: ValueKey('home-stats-event-${event.id}'),
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _activityIcon(event.kind),
              size: 19,
              color: colors.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  event.detail ?? _activityLabel(event.kind),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${_activityLabel(event.kind)} · ${_displayTime(event.occurredAt)}$duration$items$source',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodologyCard extends StatelessWidget {
  const _MethodologyCard();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '统计口径：翻译按完成记录计次，处理量按事件中的词/字符数，阅读按已关联的本地文章去重，收藏句和收藏词分别读取对应本地表，时长按活动事件累计。未接入模块显示“—”，不会伪装成 0。',
              style: TextStyle(
                color: colors.onSecondaryContainer,
                height: 1.45,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyActivities extends StatelessWidget {
  const _EmptyActivities({required this.filtered, required this.date});

  final bool filtered;
  final String date;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 18),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        children: [
          Icon(Icons.event_note_outlined, size: 32, color: colors.primary),
          const SizedBox(height: 10),
          Text(
            filtered ? '这个模块今天还没有记录' : '今天还没有可展示的活动记录',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            filtered ? '切换“全部”查看其他模块。' : '$date 的活动会在完成后自动出现在这里。',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StatsMessage extends StatelessWidget {
  const _StatsMessage({
    required this.title,
    required this.detail,
    required this.action,
    this.onClose,
  });

  final String title;
  final String detail;
  final Widget action;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(detail),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                action,
                if (onClose != null)
                  IconButton(
                    key: const ValueKey('home-close-today-summary'),
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _activityIcon(ActivityKind kind) => switch (kind) {
  ActivityKind.translation => Icons.translate_rounded,
  ActivityKind.reading => Icons.menu_book_outlined,
  ActivityKind.vocabulary => Icons.bookmark_border_rounded,
  ActivityKind.exercise => Icons.edit_note_rounded,
  ActivityKind.speaking => Icons.graphic_eq_rounded,
  ActivityKind.focus => Icons.timer_outlined,
};

String _activityLabel(ActivityKind kind) => switch (kind) {
  ActivityKind.translation => '翻译',
  ActivityKind.reading => '阅读',
  ActivityKind.vocabulary => '词汇',
  ActivityKind.exercise => '练习',
  ActivityKind.speaking => '同传/口语',
  ActivityKind.focus => '专注',
};

String _formatDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
}

String _displayTime(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  return '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
}

String _dateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
