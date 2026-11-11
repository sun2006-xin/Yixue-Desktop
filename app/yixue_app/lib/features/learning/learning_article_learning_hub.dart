import 'package:flutter/material.dart';

/// Entry surface for article learning.
///
/// Article learning starts with a calm choice page and keeps its tools local.
class LearningArticleLearningHub extends StatelessWidget {
  const LearningArticleLearningHub({
    required this.onOpenPlan,
    required this.onOpenProgress,
    required this.onOpenVocabulary,
    required this.onOpenSummary,
    this.onOpenSourceSettings,
    super.key,
  });

  final VoidCallback onOpenPlan;
  final VoidCallback onOpenProgress;
  final VoidCallback onOpenVocabulary;
  final VoidCallback onOpenSummary;
  final VoidCallback? onOpenSourceSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('learning-article-learning-hub'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .82)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .11),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.article_outlined,
                    color: colors.primary,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '文章学习',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '在真实语境中阅读，积累词汇与表达。',
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (onOpenSourceSettings != null)
                  IconButton(
                    key: const ValueKey('learning-article-source-settings'),
                    tooltip: '选择文章来源',
                    onPressed: onOpenSourceSettings,
                    icon: const Icon(Icons.tune_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 15),
            Container(
              height: 158,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                gradient: LinearGradient(
                  colors: [
                    colors.primaryContainer.withValues(alpha: .92),
                    colors.secondaryContainer.withValues(alpha: .72),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned(
                    right: -20,
                    bottom: -35,
                    child: Icon(
                      Icons.menu_book_rounded,
                      size: 210,
                      color: colors.primary.withValues(alpha: .13),
                    ),
                  ),
                  Positioned(
                    left: 19,
                    top: 18,
                    right: 160,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '精读学习',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '围绕文章语境积累词汇、整理表达并查看学习进度。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.35,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            KeyedSubtree(
              key: const ValueKey('learning-article-shortcuts'),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 640 ? 4 : 2;
                  final gap = 9.0;
                  final width =
                      (constraints.maxWidth - (columns - 1) * gap) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      _ArticleHubShortcut(
                        width: width,
                        icon: Icons.calendar_month_outlined,
                        label: '学习计划',
                        onTap: onOpenPlan,
                      ),
                      _ArticleHubShortcut(
                        width: width,
                        icon: Icons.bar_chart_outlined,
                        label: '阅读进度',
                        onTap: onOpenProgress,
                      ),
                      _ArticleHubShortcut(
                        width: width,
                        icon: Icons.star_border_rounded,
                        label: '收藏词汇',
                        onTap: onOpenVocabulary,
                      ),
                      _ArticleHubShortcut(
                        width: width,
                        icon: Icons.article_outlined,
                        label: '文章总结',
                        onTap: onOpenSummary,
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '文章来源和阅读记录由你决定；联网文章需确认来源与使用权。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleHubShortcut extends StatelessWidget {
  const _ArticleHubShortcut({
    required this.width,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double width;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: colors.surfaceContainerHighest.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
            child: Column(
              children: [
                Icon(icon, color: colors.primary, size: 23),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
