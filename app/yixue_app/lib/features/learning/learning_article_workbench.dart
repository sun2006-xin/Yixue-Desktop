import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_articles.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/features/learning/open_example_attribution.dart';

typedef ArticleSpeakCallback = Future<void> Function(String value);

@visibleForTesting
String? learningArticleDictionaryTermFromSelection(
  String text,
  TextSelection selection,
) {
  if (!selection.isValid || selection.isCollapsed) return null;
  final start = selection.start;
  final end = selection.end;
  if (start < 0 || end > text.length || start >= end) return null;
  return dictionaryTermAtInput(text.substring(start, end).trim());
}

/// The reading surface used after an article source has been selected.
///
/// The widget deliberately keeps the source text and learning tools in two
/// stable columns. It does not fetch or redistribute web content by itself;
/// the parent owns source selection and persistence.
class LearningArticleWorkbench extends StatefulWidget {
  const LearningArticleWorkbench({
    required this.article,
    required this.articles,
    required this.selectedArticleId,
    required this.progress,
    required this.paragraphIndex,
    required this.translationVisible,
    required this.matchedVocabulary,
    required this.entriesByWord,
    required this.selectedWord,
    required this.isFavorite,
    required this.wordNote,
    required this.onSelectParagraph,
    required this.onSelectArticle,
    required this.onSelectWord,
    required this.onToggleWordFavorite,
    required this.onToggleTranslation,
    required this.onCompleteParagraph,
    required this.onToggleFavorite,
    required this.onAddVocabulary,
    required this.onSummarize,
    required this.onSaveWordNote,
    required this.onAnswerQuestion,
    this.onSpeak,
    this.summary,
    this.busy = false,
    this.onOpenImmersiveReader,
    this.immersiveMode = false,
    super.key,
  });

  final LearningArticle article;
  final List<LearningArticle> articles;
  final String selectedArticleId;
  final LearningArticleProgressData progress;
  final int paragraphIndex;
  final bool translationVisible;
  final List<String> matchedVocabulary;
  final Map<String, DictionaryEntry> entriesByWord;
  final String? selectedWord;
  final bool Function(String word) isFavorite;
  final String wordNote;
  final ValueChanged<int> onSelectParagraph;
  final ValueChanged<LearningArticle> onSelectArticle;
  final ValueChanged<String> onSelectWord;
  final Future<void> Function(String word) onToggleWordFavorite;
  final VoidCallback onToggleTranslation;
  final Future<void> Function() onCompleteParagraph;
  final Future<void> Function() onToggleFavorite;
  final Future<void> Function() onAddVocabulary;
  final Future<void> Function() onSummarize;
  final Future<void> Function(String word, String note) onSaveWordNote;
  final Future<void> Function(String questionId, int answerIndex)
  onAnswerQuestion;
  final ArticleSpeakCallback? onSpeak;
  final String? summary;
  final bool busy;
  final VoidCallback? onOpenImmersiveReader;

  /// Removes navigation chrome when this reader is embedded in focused mode.
  final bool immersiveMode;

  @override
  State<LearningArticleWorkbench> createState() =>
      _LearningArticleWorkbenchState();
}

class _LearningArticleWorkbenchState extends State<LearningArticleWorkbench> {
  late final TextEditingController _noteController;
  var _tool = _ArticleTool.translation;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.wordNote);
  }

  @override
  void didUpdateWidget(covariant LearningArticleWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedWord != widget.selectedWord) {
      _tool = widget.selectedWord == null
          ? _ArticleTool.translation
          : _ArticleTool.lookup;
    }
    if (oldWidget.wordNote != widget.wordNote &&
        widget.wordNote != _noteController.text) {
      _noteController.text = widget.wordNote;
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  LearningArticleParagraph get _paragraph =>
      widget.article.paragraphs[widget.paragraphIndex.clamp(
        0,
        widget.article.paragraphCount - 1,
      )];

  DictionaryEntry? get _entry => widget.selectedWord == null
      ? null
      : widget.entriesByWord[normalizeLearningWord(widget.selectedWord!)];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completed = widget.progress.completedParagraphs.length;
    final progressValue = widget.article.paragraphCount == 0
        ? 0.0
        : completed / widget.article.paragraphCount;

    return Card(
      key: const ValueKey('learning-article-workbench'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(widget.immersiveMode ? 14 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.immersiveMode)
              _ArticleWorkbenchHeader(
                article: widget.article,
                completed: completed,
                progress: progressValue,
                colors: colors,
                onSpeak: widget.onSpeak == null
                    ? null
                    : () => widget.onSpeak!(
                        widget.article.paragraphs
                            .map((paragraph) => paragraph.text)
                            .join('\n'),
                      ),
              ),
            if (!widget.immersiveMode && widget.articles.length > 1) ...[
              const SizedBox(height: 13),
              _ArticlePickerStrip(
                articles: widget.articles,
                selectedArticleId: widget.selectedArticleId,
                onSelect: widget.onSelectArticle,
              ),
            ],
            if (widget.onOpenImmersiveReader != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('learning-article-open-immersive'),
                  onPressed: widget.onOpenImmersiveReader,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('进入沉浸式阅读'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 840;
                if (!wide) {
                  return Column(
                    children: [
                      _buildOriginalPanel(context, colors),
                      const SizedBox(height: 14),
                      _buildToolPanel(context, colors),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: _buildOriginalPanel(context, colors),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 350,
                      child: _buildToolPanel(context, colors),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOriginalPanel(BuildContext context, ColorScheme colors) {
    final textTheme = Theme.of(context).textTheme;
    final selectedIndex = widget.paragraphIndex.clamp(
      0,
      widget.article.paragraphCount - 1,
    );
    return Container(
      key: const ValueKey('learning-article-original'),
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .34),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .66)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.subject_rounded, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '原文工作台',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '点击段落或词条',
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < widget.article.paragraphs.length; index++)
            Padding(
              padding: EdgeInsets.only(
                bottom: index == widget.article.paragraphs.length - 1 ? 0 : 10,
              ),
              child: _ArticleParagraphBlock(
                key: ValueKey('learning-article-paragraph-$index'),
                paragraph: widget.article.paragraphs[index],
                index: index,
                selected: index == selectedIndex,
                completed: widget.progress.completedParagraphs.contains(index),
                favorite: widget.progress.favoriteParagraphs.contains(index),
                vocabulary: _vocabularyForParagraph(
                  widget.article.paragraphs[index].text,
                ),
                selectedWord: widget.selectedWord,
                colors: colors,
                onSelect: () => widget.onSelectParagraph(index),
                onSelectWord: widget.onSelectWord,
                onSpeak: widget.onSpeak,
              ),
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withValues(alpha: .34),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.touch_app_outlined, color: colors.primary, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '选中一个词后，右侧会显示词义、例句和笔记；译文按段落对应。',
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.article.questions.isNotEmpty) ...[
            const SizedBox(height: 18),
            _ArticleComprehensionPanel(
              article: widget.article,
              progress: widget.progress,
              busy: widget.busy,
              onAnswerQuestion: widget.onAnswerQuestion,
              onSelectParagraph: widget.onSelectParagraph,
            ),
          ],
        ],
      ),
    );
  }

  List<String> _vocabularyForParagraph(String text) {
    final lower = text.toLowerCase();
    return widget.matchedVocabulary
        .where((word) => lower.contains(word.toLowerCase()))
        .toList(growable: false);
  }

  Widget _buildToolPanel(BuildContext context, ColorScheme colors) {
    return Container(
      key: const ValueKey('learning-article-tool-panel'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .76)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '学习工具',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ArticleToolTabs(
            value: _tool,
            hasWord: widget.selectedWord != null,
            onChanged: (value) => setState(() => _tool = value),
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _buildToolContent(context, colors),
          ),
        ],
      ),
    );
  }

  Widget _buildToolContent(BuildContext context, ColorScheme colors) {
    return switch (_tool) {
      _ArticleTool.translation => _buildTranslationTool(context, colors),
      _ArticleTool.lookup => _buildLookupTool(context, colors),
      _ArticleTool.examples => _buildExamplesTool(context, colors),
      _ArticleTool.notes => _buildNotesTool(context, colors),
      _ArticleTool.summary => _buildSummaryTool(context, colors),
    };
  }

  Widget _buildTranslationTool(BuildContext context, ColorScheme colors) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('learning-article-translation-tool'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '段落译文',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('learning-article-speak'),
              tooltip: '播放本段',
              onPressed: widget.onSpeak == null
                  ? null
                  : () => widget.onSpeak!(_paragraph.text),
              icon: const Icon(Icons.volume_up_outlined),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (widget.translationVisible)
          Text(
            _paragraph.translation,
            style: textTheme.bodyLarge?.copyWith(
              color: colors.onSurface,
              height: 1.55,
            ),
          )
        else
          _ArticleEmptyToolState(
            icon: Icons.visibility_outlined,
            title: '译文暂未展开',
            detail: '保持原文练习时，右侧不会自动填满。',
            action: OutlinedButton.icon(
              key: const ValueKey('learning-article-translation'),
              onPressed: widget.onToggleTranslation,
              icon: const Icon(Icons.translate_outlined),
              label: const Text('显示这一段译文'),
            ),
          ),
        const SizedBox(height: 14),
        _ArticleActionRow(
          busy: widget.busy,
          favorite: widget.progress.favoriteParagraphs.contains(
            widget.paragraphIndex,
          ),
          onToggleTranslation: widget.onToggleTranslation,
          onComplete: widget.onCompleteParagraph,
          onFavorite: widget.onToggleFavorite,
          onAddVocabulary: widget.onAddVocabulary,
          onSummarize: widget.onSummarize,
          translationVisible: widget.translationVisible,
        ),
      ],
    );
  }

  Widget _buildLookupTool(BuildContext context, ColorScheme colors) {
    final entry = _entry;
    if (entry == null) {
      return _ArticleEmptyToolState(
        key: const ValueKey('learning-article-lookup-empty'),
        icon: Icons.search_rounded,
        title: '选择左侧词条',
        detail: '点击段落下的词条标签，查看词义和变体。',
      );
    }
    return _ArticleDictionaryView(
      key: const ValueKey('learning-article-word-detail'),
      entry: entry,
      colors: colors,
      onSpeak: widget.onSpeak,
      onOpenExamples: () => setState(() => _tool = _ArticleTool.examples),
      isFavorite: widget.isFavorite(entry.word),
      onToggleFavorite: () => widget.onToggleWordFavorite(entry.word),
    );
  }

  Widget _buildExamplesTool(BuildContext context, ColorScheme colors) {
    final entry = _entry;
    if (entry == null) {
      return _ArticleEmptyToolState(
        key: const ValueKey('learning-article-examples-empty'),
        icon: Icons.forum_outlined,
        title: '选择词条查看例句',
        detail: '例句来自本地词典；后续可接入合法扩展词库。',
      );
    }
    return Column(
      key: const ValueKey('learning-article-examples-tool'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          entry.word,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(entry.partOfSpeech),
        const SizedBox(height: 8),
        _ArticleDictionaryQualityBadge(entry: entry),
        const SizedBox(height: 14),
        _ArticleExamplesSection(entry: entry, onSpeak: widget.onSpeak),
        if (entry.variants.isNotEmpty) ...[
          const SizedBox(height: 15),
          Text(
            '变体',
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final variant in entry.variants) Chip(label: Text(variant)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildNotesTool(BuildContext context, ColorScheme colors) {
    final word = widget.selectedWord;
    if (word == null) {
      return _ArticleEmptyToolState(
        key: const ValueKey('learning-article-notes-empty'),
        icon: Icons.edit_note_outlined,
        title: '选择词条记录笔记',
        detail: '批注会与这个词关联，便于后续学习模块继续复习。',
      );
    }
    return Column(
      key: const ValueKey('learning-article-notes-tool'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '「$word」的学习笔记',
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('learning-article-word-note-field'),
          controller: _noteController,
          minLines: 4,
          maxLines: 7,
          decoration: const InputDecoration(
            hintText: '写下语境、易错点或自己的理解…',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: widget.busy
              ? null
              : () => widget.onSaveWordNote(word, _noteController.text),
          icon: const Icon(Icons.save_outlined),
          label: const Text('保存这条笔记'),
        ),
      ],
    );
  }

  Widget _buildSummaryTool(BuildContext context, ColorScheme colors) {
    return Column(
      key: const ValueKey('learning-article-summary-tool'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ArticleEmptyToolState(
          icon: Icons.auto_awesome_outlined,
          title: widget.summary == null ? '生成文章总结' : '本篇文章总结',
          detail: widget.summary == null
              ? '总结模型是可选接口；没有配置时，原文、查词和进度仍可正常使用。'
              : widget.summary!,
          action: widget.summary == null
              ? FilledButton.icon(
                  key: const ValueKey('learning-article-summary'),
                  onPressed: widget.busy ? null : widget.onSummarize,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('生成总结'),
                )
              : null,
        ),
      ],
    );
  }
}

enum _ArticleTool { translation, lookup, examples, notes, summary }

class _ArticleWorkbenchHeader extends StatelessWidget {
  const _ArticleWorkbenchHeader({
    required this.article,
    required this.completed,
    required this.progress,
    required this.colors,
    required this.onSpeak,
  });

  final LearningArticle article;
  final int completed;
  final double progress;
  final ColorScheme colors;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                article.title,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                '${article.level} · $completed/${article.paragraphCount} 段已读',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 7,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ),
            ],
          ),
        ),
        if (onSpeak != null)
          IconButton(
            tooltip: '朗读全文',
            onPressed: onSpeak,
            icon: const Icon(Icons.volume_up_outlined),
          ),
      ],
    );
  }
}

class _ArticlePickerStrip extends StatelessWidget {
  const _ArticlePickerStrip({
    required this.articles,
    required this.selectedArticleId,
    required this.onSelect,
  });

  final List<LearningArticle> articles;
  final String selectedArticleId;
  final ValueChanged<LearningArticle> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('learning-article-library-picker'),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(Icons.library_books_outlined, color: colors.primary, size: 19),
          const SizedBox(width: 8),
          Text(
            '文章库',
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final article in articles)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(article.title),
                        selected: article.id == selectedArticleId,
                        onSelected: (_) => onSelect(article),
                        selectedColor: colors.primaryContainer,
                        labelStyle: TextStyle(
                          color: article.id == selectedArticleId
                              ? colors.primary
                              : colors.onSurface,
                          fontWeight: article.id == selectedArticleId
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArticleComprehensionPanel extends StatelessWidget {
  const _ArticleComprehensionPanel({
    required this.article,
    required this.progress,
    required this.busy,
    required this.onAnswerQuestion,
    required this.onSelectParagraph,
  });

  final LearningArticle article;
  final LearningArticleProgressData progress;
  final bool busy;
  final Future<void> Function(String questionId, int answerIndex)
  onAnswerQuestion;
  final ValueChanged<int> onSelectParagraph;

  @override
  Widget build(BuildContext context) =>
      _buildComprehensionPanel(context, Theme.of(context).colorScheme);
  Widget _buildComprehensionPanel(BuildContext context, ColorScheme colors) {
    final questions = article.questions;
    final correctCount = questions
        .where(
          (question) =>
              progress.questionAnswers[question.id] ==
              question.correctChoiceIndex,
        )
        .length;
    return Container(
      key: const ValueKey('learning-article-comprehension'),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .76)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.quiz_outlined, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '理解检查',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                '$correctCount / ${questions.length} 答对',
                key: const ValueKey('learning-article-comprehension-progress'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '先根据原文作答；答错时回到对应段落找线索。进度会保存在本机。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 13),
          for (var index = 0; index < questions.length; index++) ...[
            if (index > 0) const Divider(height: 22),
            _buildComprehensionQuestion(context, colors, questions[index]),
          ],
        ],
      ),
    );
  }

  Widget _buildComprehensionQuestion(
    BuildContext context,
    ColorScheme colors,
    LearningArticleQuestion question,
  ) {
    final selected = progress.questionAnswers[question.id];
    final isCorrect = selected == question.correctChoiceIndex;
    final evidenceParagraph = question.evidenceParagraphIndex + 1;
    return Column(
      key: ValueKey('learning-article-question-${question.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.prompt,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(fontWeight: FontWeight.w700, height: 1.4),
        ),
        const SizedBox(height: 9),
        for (var index = 0; index < question.choices.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: ValueKey('learning-article-answer-${question.id}-$index'),
                onPressed: busy || isCorrect
                    ? null
                    : () => onAnswerQuestion(question.id, index),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
                  backgroundColor: selected == index
                      ? isCorrect
                            ? colors.primaryContainer.withValues(alpha: .5)
                            : colors.errorContainer.withValues(alpha: .52)
                      : null,
                  side: BorderSide(
                    color: selected == index
                        ? isCorrect
                              ? colors.primary
                              : colors.error
                        : colors.outlineVariant,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      selected == index
                          ? isCorrect
                                ? Icons.check_circle_outline_rounded
                                : Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 19,
                      color: selected == index && !isCorrect
                          ? colors.error
                          : colors.primary,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        question.choices[index],
                        textAlign: TextAlign.left,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (selected != null)
          Container(
            key: ValueKey('learning-article-answer-feedback-${question.id}'),
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: isCorrect
                  ? colors.primaryContainer.withValues(alpha: .45)
                  : colors.errorContainer.withValues(alpha: .48),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCorrect
                      ? '答对了。${question.explanation}'
                      : '再回到第 $evidenceParagraph 段找线索，然后重试。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isCorrect
                        ? colors.onSurface
                        : colors.onErrorContainer,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isCorrect)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: ValueKey(
                        'learning-article-answer-evidence-${question.id}',
                      ),
                      onPressed: busy
                          ? null
                          : () => onSelectParagraph(
                              question.evidenceParagraphIndex,
                            ),
                      icon: const Icon(Icons.my_location_outlined, size: 17),
                      label: Text('定位到第 $evidenceParagraph 段'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ArticleParagraphBlock extends StatelessWidget {
  const _ArticleParagraphBlock({
    super.key,
    required this.paragraph,
    required this.index,
    required this.selected,
    required this.completed,
    required this.favorite,
    required this.vocabulary,
    required this.selectedWord,
    required this.colors,
    required this.onSelect,
    required this.onSelectWord,
    required this.onSpeak,
  });

  final LearningArticleParagraph paragraph;
  final int index;
  final bool selected;
  final bool completed;
  final bool favorite;
  final List<String> vocabulary;
  final String? selectedWord;
  final ColorScheme colors;
  final VoidCallback onSelect;
  final ValueChanged<String> onSelectWord;
  final ArticleSpeakCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final border = selected
        ? colors.primary.withValues(alpha: .72)
        : colors.outlineVariant.withValues(alpha: .55);
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: .27)
          : colors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 12, 10, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border, width: selected ? 1.4 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '段落 ${index + 1}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  if (completed)
                    Icon(Icons.check_circle, color: colors.primary, size: 17),
                  if (favorite) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.bookmark, color: colors.tertiary, size: 17),
                  ],
                  if (onSpeak != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '朗读本段',
                      onPressed: () => onSpeak!(paragraph.text),
                      icon: const Icon(Icons.volume_up_outlined, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              SelectableText(
                paragraph.text,
                key: const ValueKey('learning-article-selectable-original'),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.55,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
                onSelectionChanged: (selection, _) {
                  final term = learningArticleDictionaryTermFromSelection(
                    paragraph.text,
                    selection,
                  );
                  if (term == null ||
                      normalizeLearningWord(term) ==
                          normalizeLearningWord(selectedWord ?? '')) {
                    return;
                  }
                  onSelectWord(term);
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  '选中单个词语可查词；也可以使用下方词汇标签。',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              if (vocabulary.isNotEmpty) ...[
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final word in vocabulary)
                      ActionChip(
                        key: ValueKey('learning-article-word-$word'),
                        avatar: Icon(
                          word == selectedWord
                              ? Icons.radio_button_checked
                              : Icons.search,
                          size: 15,
                        ),
                        label: Text(word),
                        onPressed: () => onSelectWord(word),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ArticleToolTabs extends StatelessWidget {
  const _ArticleToolTabs({
    required this.value,
    required this.hasWord,
    required this.onChanged,
  });

  final _ArticleTool value;
  final bool hasWord;
  final ValueChanged<_ArticleTool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tool in _ArticleTool.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(tool.label),
                selected: value == tool,
                onSelected: (_) => onChanged(tool),
                selectedColor: colors.primaryContainer,
                labelStyle: TextStyle(
                  color: value == tool ? colors.primary : colors.onSurface,
                  fontWeight: value == tool ? FontWeight.w700 : FontWeight.w500,
                ),
                avatar: tool == _ArticleTool.lookup && hasWord
                    ? Icon(Icons.check, size: 15, color: colors.primary)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

extension on _ArticleTool {
  String get label => switch (this) {
    _ArticleTool.translation => '译文',
    _ArticleTool.lookup => '查词',
    _ArticleTool.examples => '例句',
    _ArticleTool.notes => '批注',
    _ArticleTool.summary => '总结',
  };
}

class _ArticleEmptyToolState extends StatelessWidget {
  const _ArticleEmptyToolState({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 19),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        children: [
          Icon(icon, color: colors.primary, size: 28),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

class _ArticleActionRow extends StatelessWidget {
  const _ArticleActionRow({
    required this.busy,
    required this.favorite,
    required this.onToggleTranslation,
    required this.onComplete,
    required this.onFavorite,
    required this.onAddVocabulary,
    required this.onSummarize,
    required this.translationVisible,
  });

  final bool busy;
  final bool favorite;
  final VoidCallback onToggleTranslation;
  final Future<void> Function() onComplete;
  final Future<void> Function() onFavorite;
  final Future<void> Function() onAddVocabulary;
  final Future<void> Function() onSummarize;
  final bool translationVisible;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        OutlinedButton.icon(
          onPressed: onToggleTranslation,
          icon: const Icon(Icons.translate_outlined, size: 18),
          label: Text(translationVisible ? '隐藏译文' : '显示译文'),
        ),
        FilledButton.icon(
          key: const ValueKey('learning-article-complete'),
          onPressed: busy ? null : () => onComplete(),
          icon: const Icon(Icons.done_rounded, size: 18),
          label: const Text('标记已读'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('learning-article-favorite'),
          onPressed: busy ? null : () => onFavorite(),
          icon: Icon(
            favorite ? Icons.bookmark : Icons.bookmark_border,
            size: 18,
          ),
          label: Text(favorite ? '取消收藏' : '收藏段落'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('learning-article-vocabulary'),
          onPressed: busy ? null : () => onAddVocabulary(),
          icon: const Icon(Icons.playlist_add_outlined, size: 18),
          label: const Text('加入词书'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('learning-article-summary'),
          onPressed: busy ? null : () => onSummarize(),
          icon: const Icon(Icons.auto_awesome_outlined, size: 18),
          label: const Text('AI 总结'),
        ),
      ],
    );
  }
}

class _ArticleDictionaryView extends StatelessWidget {
  const _ArticleDictionaryView({
    super.key,
    required this.entry,
    required this.colors,
    required this.onSpeak,
    required this.onOpenExamples,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final DictionaryEntry entry;
  final ColorScheme colors;
  final ArticleSpeakCallback? onSpeak;
  final VoidCallback onOpenExamples;
  final bool isFavorite;
  final Future<void> Function() onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('learning-article-dictionary-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                entry.word,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (onSpeak != null)
              IconButton(
                tooltip: '播放发音',
                onPressed: () => onSpeak!(entry.word),
                icon: const Icon(Icons.volume_up_outlined),
              ),
          ],
        ),
        Text(
          '${entry.ipa}  ·  ${entry.partOfSpeech}',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _ArticleDictionaryQualityBadge(entry: entry),
        const SizedBox(height: 12),
        for (var index = 0; index < entry.meanings.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text('${index + 1}. ${entry.meanings[index]}'),
          ),
        const SizedBox(height: 11),
        _ArticleExamplesSection(entry: entry, onSpeak: onSpeak),
        if (entry.variants.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '变体：${entry.variants.join(' · ')}',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: onOpenExamples,
              icon: const Icon(Icons.forum_outlined, size: 18),
              label: const Text('查看例句'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => onToggleFavorite(),
              icon: Icon(
                isFavorite ? Icons.bookmark : Icons.bookmark_add_outlined,
                size: 18,
              ),
              label: Text(isFavorite ? '取消收藏' : '收藏词条'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ArticleDictionaryQualityBadge extends StatelessWidget {
  const _ArticleDictionaryQualityBadge({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (entry.qualityStatus) {
      'published' => '译学已审校',
      'assistant_verified' => 'AI 来源已核对',
      'assistant_verified_with_gaps' => 'AI 来源已核对 · 有字段待补',
      'published_with_assistant_enrichment' => '基础已审校 · AI 来源已核对',
      'published_with_candidate_enrichment' => '基础已审校 · 候选待核对',
      _ => '来源内容待核对',
    };
    final reviewed =
        entry.qualityStatus == 'published' ||
        entry.qualityStatus == 'published_with_assistant_enrichment' ||
        entry.qualityStatus == 'published_with_candidate_enrichment';
    final assistantChecked =
        entry.qualityStatus.startsWith('assistant_verified') ||
        entry.qualityStatus == 'published_with_assistant_enrichment';
    final background = reviewed
        ? colors.primaryContainer
        : assistantChecked
        ? colors.tertiaryContainer
        : colors.surfaceContainerHighest;
    final foreground = reviewed
        ? colors.onPrimaryContainer
        : assistantChecked
        ? colors.onTertiaryContainer
        : colors.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('learning-article-quality-status'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _ArticleExamplesSection extends StatefulWidget {
  const _ArticleExamplesSection({required this.entry, required this.onSpeak});

  final DictionaryEntry entry;
  final ArticleSpeakCallback? onSpeak;

  @override
  State<_ArticleExamplesSection> createState() =>
      _ArticleExamplesSectionState();
}

class _ArticleExamplesSectionState extends State<_ArticleExamplesSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final onSpeak = widget.onSpeak;
    final colors = Theme.of(context).colorScheme;
    if (entry.exampleIsOpenCandidate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: colors.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: const ValueKey('learning-article-candidate-examples'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('开放来源例句候选 · 待核对'),
                          const SizedBox(height: 3),
                          Text(
                            '${entry.exampleCandidates.length} 条来源候选',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            for (final candidate in entry.exampleCandidates.take(6))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(candidate.englishText),
                          if (candidate.chineseText.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              candidate.chineseText,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                          OpenExampleAttribution(candidate: candidate),
                        ],
                      ),
                    ),
                    if (onSpeak != null)
                      IconButton(
                        tooltip: '播放来源例句',
                        onPressed: () => onSpeak(candidate.englishText),
                        icon: const Icon(Icons.volume_up_outlined),
                      ),
                  ],
                ),
              ),
        ],
      );
    }
    if (entry.hasExample) {
      return _ExamplePair(
        english: entry.example,
        chinese: entry.exampleTranslation,
        onSpeak: onSpeak == null ? null : () => onSpeak(entry.example),
      );
    }
    return Text(
      '暂无已审校例句',
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

class _ExamplePair extends StatelessWidget {
  const _ExamplePair({
    required this.english,
    required this.chinese,
    required this.onSpeak,
  });

  final String english;
  final String chinese;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 10, 7, 10),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(english, style: const TextStyle(height: 1.45)),
                const SizedBox(height: 4),
                Text(
                  chinese,
                  style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
          if (onSpeak != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '播放例句',
              onPressed: onSpeak,
              icon: const Icon(Icons.volume_up_outlined, size: 19),
            ),
        ],
      ),
    );
  }
}
