import 'package:flutter/material.dart';

/// The small, stable view model used by the learning entry page.
///
/// Keeping this view model independent from the repository makes the landing
/// page a real navigation surface instead of another data store. The parent
/// remains responsible for calculating the numbers and saving the session.
class LearningPlanViewData {
  const LearningPlanViewData({
    required this.focusTrackId,
    required this.title,
    required this.focus,
    required this.dueCount,
    required this.completedCount,
    required this.targetCount,
    required this.targetMinutes,
    required this.hasActiveSession,
    required this.paused,
    required this.sessionProgress,
    this.targetUnit = '项',
  });

  final String focusTrackId;
  final String title;
  final String focus;
  final int dueCount;
  final int completedCount;
  final int targetCount;
  final int targetMinutes;
  final bool hasActiveSession;
  final bool paused;
  final double sessionProgress;
  final String targetUnit;

  String get progressLabel => '$completedCount / $targetCount $targetUnit';
}

class LearningTrackViewData {
  const LearningTrackViewData({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.target,
    required this.progress,
    required this.status,
    this.enabled = true,
    this.showProgress = true,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;
  final String target;
  final double progress;
  final String status;
  final bool enabled;
  final bool showProgress;
}

/// Four-card learning entry point.
///
/// Textbook packages intentionally remain a content source under article
/// learning, so this surface never grows a fifth learning method card.
class LearningLandingWorkspace extends StatelessWidget {
  const LearningLandingWorkspace({
    required this.plan,
    required this.tracks,
    required this.onOpenTrack,
    required this.onStartPlan,
    required this.onRest,
    required this.onExit,
    this.onOpenContentLibrary,
    this.onOpenTextbooks,
    super.key,
  });

  final LearningPlanViewData plan;
  final List<LearningTrackViewData> tracks;
  final ValueChanged<String> onOpenTrack;
  final VoidCallback onStartPlan;
  final VoidCallback onRest;
  final VoidCallback onExit;
  final VoidCallback? onOpenContentLibrary;
  final VoidCallback? onOpenTextbooks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _LearningWelcome(),
        const SizedBox(height: 18),
        _PlanSummaryCard(
          plan: plan,
          onStartPlan: onStartPlan,
          onRest: onRest,
          onExit: onExit,
        ),
        const SizedBox(height: 24),
        _LearningPathHeader(
          onOpenContentLibrary: onOpenContentLibrary,
          onOpenTextbooks: onOpenTextbooks,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            // Desktop keeps the four independent methods in a calm 2 × 2
            // grid. A four-column strip makes the cards too narrow and hides
            // the distinction between the learning methods.
            // The page itself already has horizontal insets, so a normal
            // 800 px window arrives here at roughly 744 px.
            final columns = constraints.maxWidth >= 680 ? 2 : 1;
            final gap = 14.0;
            final width = columns == 1
                ? constraints.maxWidth
                : (constraints.maxWidth - (columns - 1) * gap) / columns;
            return KeyedSubtree(
              key: const ValueKey('learning-module-grid'),
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final track in tracks)
                    SizedBox(
                      width: width,
                      child: _TrackCard(
                        track: track,
                        isFocus: track.id == plan.focusTrackId,
                        onTap: () => onOpenTrack(track.id),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _LearningWelcome extends StatelessWidget {
  const _LearningWelcome();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '从查词到真正会用',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.25,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '把查到的词，练成会用的表达。',
            key: const ValueKey('learning-welcome-title'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '文章或截图中查词收藏，之后用词汇复习、发音和句子练习巩固。',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _LearningPathHeader extends StatelessWidget {
  const _LearningPathHeader({
    required this.onOpenContentLibrary,
    required this.onOpenTextbooks,
  });

  final VoidCallback? onOpenContentLibrary;
  final VoidCallback? onOpenTextbooks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final actions = Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (onOpenContentLibrary != null)
              TextButton.icon(
                key: const ValueKey('learning-open-content-library'),
                onPressed: onOpenContentLibrary,
                icon: const Icon(Icons.menu_book_outlined, size: 17),
                label: const Text('词典与资料'),
              ),
            if (onOpenTextbooks != null)
              TextButton.icon(
                key: const ValueKey('learning-open-textbooks'),
                onPressed: onOpenTextbooks,
                icon: const Icon(Icons.library_books_outlined, size: 17),
                label: const Text('教材词表'),
              ),
          ],
        );
        final title = Text(
          '学习路径',
          key: const ValueKey('learning-path-heading'),
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w800),
        );
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              if (onOpenContentLibrary != null || onOpenTextbooks != null)
                Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: title),
            actions,
          ],
        );
      },
    );
  }
}

class _PlanSummaryCard extends StatelessWidget {
  const _PlanSummaryCard({
    required this.plan,
    required this.onStartPlan,
    required this.onRest,
    required this.onExit,
  });

  final LearningPlanViewData plan;
  final VoidCallback onStartPlan;
  final VoidCallback onRest;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: const ValueKey('learning-plan-strip'),
      child: Card(
        key: const ValueKey('learning-plan-summary'),
        elevation: 0,
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .82)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 17),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final progress = plan.targetCount <= 0
                  ? 0.0
                  : (plan.completedCount / plan.targetCount).clamp(0.0, 1.0);
              final action = _PlanPrimaryAction(
                onStartPlan: onStartPlan,
                hasActiveSession: plan.hasActiveSession,
              );
              final due = KeyedSubtree(
                key: const ValueKey('learning-plan-due-count'),
                child: _PlanMetric(
                  label: '待复习',
                  value: '${plan.dueCount}',
                  detail: '优先巩固已学词汇',
                  valueKey: const ValueKey('learning-plan-due'),
                  colors: colors,
                ),
              );
              final today = KeyedSubtree(
                key: const ValueKey('learning-plan-today'),
                child: _PlanMetric(
                  label: '今日目标',
                  value:
                      '${plan.targetCount} ${plan.targetUnit} · ${plan.targetMinutes} 分钟',
                  detail: '完成后自动保存进度',
                  colors: colors,
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '今日学习安排',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              plan.title,
                              key: const ValueKey('learning-plan-title'),
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              plan.focus,
                              maxLines: compact ? 3 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.4,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (!compact) ...[const SizedBox(width: 20), action],
                    ],
                  ),
                  const SizedBox(height: 17),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: LinearProgressIndicator(
                      key: const ValueKey('learning-plan-progress'),
                      value: progress,
                      minHeight: 7,
                      backgroundColor: colors.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        '${plan.completedCount} / ${plan.targetCount} ${plan.targetUnit}已完成',
                        key: const ValueKey('learning-plan-progress-label'),
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      const Spacer(),
                      if (plan.hasActiveSession)
                        Wrap(
                          spacing: 2,
                          children: [
                            TextButton.icon(
                              key: const ValueKey('learning-plan-rest'),
                              onPressed: onRest,
                              icon: Icon(
                                plan.paused
                                    ? Icons.play_arrow_rounded
                                    : Icons.pause_rounded,
                                size: 18,
                              ),
                              label: Text(plan.paused ? '继续本轮' : '暂停本轮'),
                            ),
                            TextButton.icon(
                              key: const ValueKey('learning-plan-exit'),
                              onPressed: onExit,
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 18,
                              ),
                              label: const Text('结束本轮'),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if (compact) ...[const SizedBox(height: 9), action],
                  const SizedBox(height: 13),
                  if (compact)
                    Column(
                      children: [
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: due),
                            const SizedBox(width: 18),
                            Expanded(child: today),
                          ],
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        Expanded(child: due),
                        const SizedBox(width: 30),
                        Expanded(child: today),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlanMetric extends StatelessWidget {
  const _PlanMetric({
    required this.label,
    required this.value,
    required this.detail,
    required this.colors,
    this.valueKey,
  });

  final String label;
  final String value;
  final String detail;
  final ColorScheme colors;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        key: valueKey,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: colors.primary,
          fontWeight: FontWeight.w900,
          letterSpacing: -.3,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        detail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: colors.onSurfaceVariant),
      ),
    ],
  );
}

class _PlanPrimaryAction extends StatelessWidget {
  const _PlanPrimaryAction({
    required this.onStartPlan,
    required this.hasActiveSession,
  });

  final VoidCallback onStartPlan;
  final bool hasActiveSession;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton.icon(
      key: const ValueKey('learning-plan-continue'),
      onPressed: onStartPlan,
      icon: const Icon(Icons.arrow_forward_rounded),
      label: Text(hasActiveSession ? '继续学习' : '开始今日计划'),
    );
    return KeyedSubtree(
      key: const ValueKey('learning-start'),
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(width: 178, child: button),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.track,
    required this.isFocus,
    required this.onTap,
  });

  final LearningTrackViewData track;
  final bool isFocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = _trackAccent(track.id, colors);
    return KeyedSubtree(
      key: ValueKey('learning-track-${track.id}'),
      child: Card(
        key: ValueKey('learning-card-${track.id}'),
        elevation: 0,
        color: track.enabled
            ? colors.surface.withValues(alpha: .94)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(17),
          side: BorderSide(
            color: isFocus
                ? accent.withValues(alpha: .55)
                : colors.outlineVariant.withValues(alpha: .8),
            width: isFocus ? 1.3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 166,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(track.icon, color: accent, size: 28),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                track.title,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            if (isFocus)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: .1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    '今日主线',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: accent,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              )
                            else if (!track.enabled)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    '未接入',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: accent,
                              size: 24,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          track.target,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                track.status,
                                key: ValueKey(
                                  'learning-track-status-${track.id}',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colors.onSurfaceVariant,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                            if (track.showProgress) ...[
                              const SizedBox(width: 10),
                              SizedBox(
                                key: ValueKey(
                                  'learning-track-progress-${track.id}',
                                ),
                                width: 64,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: LinearProgressIndicator(
                                    value: track.enabled ? track.progress : 0,
                                    minHeight: 5,
                                    backgroundColor:
                                        colors.surfaceContainerHighest,
                                    color: accent,
                                  ),
                                ),
                              ),
                            ] else
                              Icon(
                                Icons.arrow_forward_rounded,
                                size: 16,
                                color: accent,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _trackAccent(String id, ColorScheme colors) => switch (id) {
  'vocabulary' => colors.primary,
  'pronunciation' => const Color(0xFF0CA58D),
  'sentence' => const Color(0xFF087D9A),
  'article' => const Color(0xFF0C9A96),
  _ => colors.primary,
};
