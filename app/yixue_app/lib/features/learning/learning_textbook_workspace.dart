import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';

/// The textbook surface is intentionally a separate widget from the review
/// engine. Imported course content can therefore grow without changing the
/// vocabulary scheduler or the translation page.
class LearningTextbookWorkspace extends StatelessWidget {
  const LearningTextbookWorkspace({
    required this.packages,
    required this.references,
    required this.selectedPackageId,
    required this.selectedLessonId,
    required this.onImport,
    required this.onShowFormat,
    required this.onSelectLesson,
    required this.onAddVocabulary,
    required this.onMarkLesson,
    this.onTranslateLesson,
    this.translationBusy = false,
    this.translationStatus,
    this.translationError,
    this.lookupDictionary,
    this.onSaveVocabularyWord,
    this.onSpeak,
    super.key,
  });

  final List<LearningTextbookPackageData> packages;
  final List<LearningTextbookReferenceData> references;
  final String? selectedPackageId;
  final String? selectedLessonId;
  final VoidCallback onImport;
  final VoidCallback onShowFormat;
  final void Function(
    LearningTextbookPackageData package,
    LearningTextbookLessonData lesson,
  )
  onSelectLesson;
  final VoidCallback onAddVocabulary;
  final VoidCallback onMarkLesson;
  final Future<void> Function(
    LearningTextbookPackageData package,
    LearningTextbookLessonData lesson,
  )?
  onTranslateLesson;
  final bool translationBusy;
  final String? translationStatus;
  final String? translationError;
  final Future<DictionaryEntry?> Function(String word)? lookupDictionary;
  final Future<void> Function(DictionaryEntry entry)? onSaveVocabularyWord;
  final Future<void> Function(String value)? onSpeak;

  LearningTextbookPackageData? get _selectedPackage {
    for (final package in packages) {
      if (package.id == selectedPackageId) return package;
    }
    return packages.isEmpty ? null : packages.first;
  }

  LearningTextbookLessonData? get _selectedLesson {
    final package = _selectedPackage;
    if (package == null) return null;
    for (final lesson in package.lessons) {
      if (lesson.id == selectedLessonId) return lesson;
    }
    return package.lessons.first;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedPackage = _selectedPackage;
    final selectedLesson = _selectedLesson;
    return Column(
      key: const ValueKey('learning-textbook-workspace'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIntro(context, colors),
        const SizedBox(height: 16),
        _buildReferences(context, colors),
        const SizedBox(height: 16),
        if (packages.isEmpty)
          _SectionCard(
            child: Text(
              '还没有可用教材。你可以先使用内置自写课程，或导入自己拥有合法使用权的教材资料。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 980) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 300,
                      child: _SectionCard(
                        child: _buildPackageList(context, colors),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildLessonDetail(
                        context,
                        colors,
                        selectedPackage,
                        selectedLesson,
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  _SectionCard(child: _buildPackageList(context, colors)),
                  const SizedBox(height: 16),
                  _buildLessonDetail(
                    context,
                    colors,
                    selectedPackage,
                    selectedLesson,
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildIntro(BuildContext context, ColorScheme colors) {
    return _SectionCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.school_outlined, color: colors.primary, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '教材与课程',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '按年龄、学段、考试目标或职业场景学习；课程资料与进度保存在本地。',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('learning-textbook-import'),
                onPressed: onImport,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('导入教材'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-textbook-format'),
                onPressed: onShowFormat,
                icon: const Icon(Icons.help_outline),
                label: const Text('导入说明'),
              ),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (constraints.maxWidth >= 700)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: title),
                    actions,
                  ],
                )
              else ...[
                title,
                const SizedBox(height: 12),
                actions,
              ],
              const SizedBox(height: 14),
              Text(
                LearningTextbookPackageService.importGuidance,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReferences(BuildContext context, ColorScheme colors) {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.category_outlined, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                '适用范围',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900 ? 3 : 1;
              final width = columns == 1
                  ? double.infinity
                  : (constraints.maxWidth - 24) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final reference in references)
                    SizedBox(
                      width: width,
                      child: Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: .35,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: .6),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              reference.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${reference.ageBand} · ${reference.level}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.primary),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              reference.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              reference.status,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPackageList(BuildContext context, ColorScheme colors) {
    final builtIn = packages
        .where(
          (package) => package.origin == LearningTextbookOrigin.selfAuthored,
        )
        .toList(growable: false);
    final imported = packages
        .where(
          (package) => package.origin != LearningTextbookOrigin.selfAuthored,
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '可用课程',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          '${packages.length} 个课程包 · 点击课次开始学习',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (builtIn.isNotEmpty) ...[
          _GroupLabel(label: '译学自写', color: colors.primary),
          const SizedBox(height: 7),
          for (final package in builtIn) ...[
            _PackageTile(
              package: package,
              selected: package.id == _selectedPackage?.id,
              onSelect: () => onSelectLesson(package, package.lessons.first),
            ),
            const SizedBox(height: 8),
          ],
        ],
        if (imported.isNotEmpty) ...[
          _GroupLabel(label: '已导入', color: const Color(0xFF0A8F78)),
          const SizedBox(height: 7),
          for (final package in imported) ...[
            _PackageTile(
              package: package,
              selected: package.id == _selectedPackage?.id,
              onSelect: () => onSelectLesson(package, package.lessons.first),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  Widget _buildLessonDetail(
    BuildContext context,
    ColorScheme colors,
    LearningTextbookPackageData? package,
    LearningTextbookLessonData? lesson,
  ) {
    if (package == null || lesson == null) {
      return const _SectionCard(child: Text('请选择一个课程。'));
    }
    return _SectionCard(
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
                      package.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${package.ageBand} · ${package.level} · ${package.version}',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (onSpeak != null)
                IconButton(
                  key: const ValueKey('learning-textbook-speak'),
                  tooltip: '播放课次',
                  onPressed: () => onSpeak!(lesson.sourceText),
                  icon: const Icon(Icons.volume_up_outlined),
                ),
            ],
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _MetaChip(label: '来源：${package.origin.label}'),
              _MetaChip(label: '许可证：${package.licenseName}'),
              _MetaChip(label: '权利人：${package.rightsHolder}'),
            ],
          ),
          const Divider(height: 28),
          Text(
            '课程目录',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          if (package.lessons.length <= 8)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in package.lessons)
                  ChoiceChip(
                    key: ValueKey('learning-textbook-lesson-${item.id}'),
                    label: Text(item.title),
                    selected: item.id == lesson.id,
                    onSelected: (_) => onSelectLesson(package, item),
                  ),
              ],
            )
          else
            DropdownButtonFormField<String>(
              key: ValueKey(
                'learning-textbook-lesson-select-${package.id}-${lesson.id}',
              ),
              initialValue: lesson.id,
              decoration: InputDecoration(
                labelText: '当前课次',
                helperText: '共 ${package.lessons.length} 节；下拉选择课次',
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final item in package.lessons)
                  DropdownMenuItem(
                    value: item.id,
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (lessonId) {
                if (lessonId == null) return;
                for (final item in package.lessons) {
                  if (item.id != lessonId) continue;
                  onSelectLesson(package, item);
                  break;
                }
              },
            ),
          const Divider(height: 28),
          Text(
            lesson.title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 13),
          if (onTranslateLesson != null &&
              package.origin != LearningTextbookOrigin.selfAuthored) ...[
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('learning-textbook-translate-lesson'),
                  onPressed: translationBusy
                      ? null
                      : () => onTranslateLesson!(package, lesson),
                  icon: translationBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.translate_rounded),
                  label: Text(
                    translationBusy
                        ? '正在翻译'
                        : lesson.translation.trim().isEmpty
                        ? '翻译本课'
                        : '重新翻译本课',
                  ),
                ),
                if (translationStatus != null)
                  Text(
                    translationStatus!,
                    key: const ValueKey('learning-textbook-translate-status'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
              ],
            ),
            if (translationError != null) ...[
              const SizedBox(height: 7),
              Text(
                translationError!,
                key: const ValueKey('learning-textbook-translate-error'),
                style: TextStyle(color: colors.error),
              ),
            ],
            const SizedBox(height: 13),
          ],
          _TextbookTextBlock(
            key: ValueKey('textbook-original-${package.id}-${lesson.id}'),
            title: '原文',
            text: lesson.sourceText,
            color: colors.onSurface,
            lookupDictionary: lookupDictionary,
            onSaveVocabularyWord: onSaveVocabularyWord,
          ),
          const SizedBox(height: 13),
          _TextbookTextBlock(
            title: '参考译文',
            text: lesson.translation.trim().isEmpty
                ? '本课还没有译文。可以先阅读原文并选词查释义，或使用上方“翻译本课”。'
                : lesson.translation,
            color: colors.onSurfaceVariant,
          ),
          if (lesson.vocabulary.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              '本课词汇 · ${lesson.vocabulary.length}',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final word in lesson.vocabulary)
                  InputChip(
                    label: Text(word),
                    onPressed: onSpeak == null ? null : () => onSpeak!(word),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                key: const ValueKey('learning-textbook-add-vocabulary'),
                onPressed: onAddVocabulary,
                icon: const Icon(Icons.playlist_add_outlined),
                label: Text('加入学习词书（${lesson.vocabulary.length}）'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('learning-textbook-mark-lesson'),
                onPressed: onMarkLesson,
                icon: const Icon(Icons.done_rounded),
                label: const Text('标记本课已学'),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            '教材进度会写入本地学习库，关闭软件后可以从这里继续。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .75)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .035),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({
    required this.package,
    required this.selected,
    required this.onSelect,
  });

  final LearningTextbookPackageData package;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: .55)
          : colors.surfaceContainerHighest.withValues(alpha: .35),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                package.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${package.ageBand} · ${package.level}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.primary),
              ),
              const SizedBox(height: 4),
              Text(
                '${package.lessons.length} 课次 · ${package.origin.label}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextbookTextBlock extends StatefulWidget {
  const _TextbookTextBlock({
    super.key,
    required this.title,
    required this.text,
    required this.color,
    this.lookupDictionary,
    this.onSaveVocabularyWord,
  });

  final String title;
  final String text;
  final Color color;
  final Future<DictionaryEntry?> Function(String word)? lookupDictionary;
  final Future<void> Function(DictionaryEntry entry)? onSaveVocabularyWord;

  @override
  State<_TextbookTextBlock> createState() => _TextbookTextBlockState();
}

class _TextbookTextBlockState extends State<_TextbookTextBlock> {
  DictionaryEntry? _entry;
  String? _query;
  String? _lookupMessage;
  var _lookupRequest = 0;
  var _lookupBusy = false;
  var _savingWord = false;
  var _wordSaved = false;

  Future<void> _lookupSelection(TextSelection selection) async {
    final lookup = widget.lookupDictionary;
    if (lookup == null || selection.isCollapsed) return;
    final start = selection.start.clamp(0, widget.text.length).toInt();
    final end = selection.end.clamp(0, widget.text.length).toInt();
    if (end <= start) return;
    final word = dictionaryTermAtInput(widget.text.substring(start, end));
    if (word == null) {
      _lookupRequest++;
      setState(() {
        _query = null;
        _entry = null;
        _lookupBusy = false;
        _wordSaved = false;
        _lookupMessage = '请选择一个英文单词或简短中文词条。';
      });
      return;
    }
    if (_query == word && (_lookupBusy || _entry != null)) return;

    final request = ++_lookupRequest;
    setState(() {
      _query = word;
      _entry = null;
      _lookupBusy = true;
      _wordSaved = false;
      _lookupMessage = '正在查询本地词典…';
    });
    try {
      final entry = await lookup(word);
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = entry;
        _lookupBusy = false;
        _lookupMessage = entry == null ? '本地词典暂未收录“$word”。' : null;
      });
    } on Object {
      if (!mounted || request != _lookupRequest) return;
      setState(() {
        _entry = null;
        _lookupBusy = false;
        _lookupMessage = '查词暂不可用；原文仍可继续阅读。';
      });
    }
  }

  Future<void> _saveVocabularyWord(DictionaryEntry entry) async {
    final save = widget.onSaveVocabularyWord;
    if (save == null || _savingWord || _wordSaved) return;
    setState(() => _savingWord = true);
    try {
      await save(entry);
      if (!mounted) return;
      setState(() {
        _wordSaved = true;
        _lookupMessage = '已加入学习词书';
      });
    } on Object {
      if (!mounted) return;
      setState(() => _lookupMessage = '加入学习词书失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _savingWord = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final entry = _entry;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .28),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          SelectableText(
            widget.text,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: widget.color, height: 1.55),
            onSelectionChanged: widget.lookupDictionary == null
                ? null
                : (selection, _) => unawaited(_lookupSelection(selection)),
          ),
          if (widget.lookupDictionary != null) ...[
            const SizedBox(height: 7),
            Text(
              '选中一个英文单词或简短中文词条，可查看释义和例句。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (_lookupBusy || _lookupMessage != null || entry != null) ...[
            const Divider(height: 22),
            if (_lookupBusy)
              const LinearProgressIndicator(minHeight: 2)
            else if (_lookupMessage != null && entry == null)
              Text(
                _query == null ? _lookupMessage! : '$_query：$_lookupMessage',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            if (entry != null) ...[
              if (_query != null)
                Text(
                  '查词：$_query',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              const SizedBox(height: 5),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.word,
                          key: const ValueKey(
                            'learning-textbook-dictionary-word',
                          ),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        if (entry.ipa.isNotEmpty ||
                            entry.partOfSpeech.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            [
                              entry.ipa,
                              entry.partOfSpeech,
                            ].where((value) => value.isNotEmpty).join(' · '),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.onSaveVocabularyWord != null)
                    TextButton.icon(
                      key: const ValueKey(
                        'learning-textbook-dictionary-save-word',
                      ),
                      onPressed: _savingWord || _wordSaved
                          ? null
                          : () => _saveVocabularyWord(entry),
                      icon: Icon(
                        _wordSaved
                            ? Icons.check_rounded
                            : Icons.bookmark_add_outlined,
                      ),
                      label: Text(
                        _savingWord
                            ? '保存中'
                            : _wordSaved
                            ? '已加入'
                            : '加入词书',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              for (var index = 0; index < entry.meanings.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${index + 1}. ${entry.meanings[index]}'),
                ),
              if (entry.example.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  entry.example,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
                if (entry.exampleTranslation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      entry.exampleTranslation,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
              ],
              if (entry.variants.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text('词形：${entry.variants.join(' · ')}'),
                ),
            ],
            if (_lookupMessage != null && entry != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  _lookupMessage!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.primary),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: color, fontWeight: FontWeight.w800),
  );
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) =>
      Chip(label: Text(label), visualDensity: VisualDensity.compact);
}
