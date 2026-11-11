import 'package:flutter/material.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/learning_articles.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

typedef ContentLibraryDictionaryLoader =
    Future<List<DictionaryEntry>> Function();
typedef ContentLibrarySourceLoader = Future<List<ContentSourceData>> Function();
typedef ContentLibraryTextbookLoader =
    Future<List<LearningTextbookPackageData>> Function();

/// A transparent, read-only inventory for local learning content.
///
/// Importing and deleting content still goes through the existing dedicated
/// services. This page only gives users one place to understand what is
/// available, where it came from, and whether it is redistributable.
class ContentLibraryWorkspace extends StatefulWidget {
  const ContentLibraryWorkspace({
    required this.loadDictionary,
    required this.loadSources,
    required this.loadTextbooks,
    this.dictionaryPreferences = const DictionaryPreferences(),
    this.onImportDictionary,
    this.onOpenTextbooks,
    super.key,
  });

  final ContentLibraryDictionaryLoader loadDictionary;
  final ContentLibrarySourceLoader loadSources;
  final ContentLibraryTextbookLoader loadTextbooks;
  final DictionaryPreferences dictionaryPreferences;
  final VoidCallback? onImportDictionary;
  final VoidCallback? onOpenTextbooks;

  @override
  State<ContentLibraryWorkspace> createState() =>
      _ContentLibraryWorkspaceState();
}

class _ContentLibraryWorkspaceState extends State<ContentLibraryWorkspace> {
  var _loading = true;
  String? _error;
  List<DictionaryEntry> _dictionary = const [];
  List<ContentSourceData> _sources = const [];
  List<LearningTextbookPackageData> _textbooks = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dictionary = await widget.loadDictionary();
      final sources = await widget.loadSources();
      final textbooks = await widget.loadTextbooks();
      if (!mounted) return;
      setState(() {
        _dictionary = dictionary;
        _sources = sources;
        _textbooks = textbooks;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '内容库读取失败，请检查本地数据后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '内容库',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '词典、词库、文章和教材集中查看；内容默认留在你选择的本地目录。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('content-library-refresh'),
                  tooltip: '刷新内容库',
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: FilledButton.tonalIcon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新读取'),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
                    children: [
                      _summary(colors),
                      const SizedBox(height: 14),
                      _dictionaryCard(colors),
                      const SizedBox(height: 12),
                      _articleCard(colors),
                      const SizedBox(height: 12),
                      _textbookCard(colors),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _summary(ColorScheme colors) {
    final totalWords = _dictionary.length;
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        _InventoryMetric(label: '词典条目', value: '$totalWords'),
        _InventoryMetric(
          label: '内置文章',
          value: '${builtInLearningArticles.length}',
        ),
        _InventoryMetric(label: '本地文章', value: '${_sources.length}'),
        _InventoryMetric(label: '教材课程包', value: '${_textbooks.length}'),
      ],
    );
  }

  Widget _dictionaryCard(ColorScheme colors) {
    final sources = <String, int>{};
    for (final entry in _dictionary) {
      sources.update(entry.source, (count) => count + 1, ifAbsent: () => 1);
    }
    return _LibrarySection(
      key: const ValueKey('content-library-dictionary'),
      icon: Icons.menu_book_outlined,
      title: '词典与词库',
      subtitle: '用于快速翻译右侧释义、例句、收藏和四种学习方式。',
      trailing: widget.onImportDictionary == null
          ? null
          : OutlinedButton.icon(
              key: const ValueKey('content-library-import-dictionary'),
              onPressed: widget.onImportDictionary,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入合法词典包'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前共 ${_dictionary.length} 条；词典和翻译模型是两套不同资料。'),
          const SizedBox(height: 10),
          if (sources.isEmpty)
            const Text('暂无词典条目')
          else
            for (final source in sources.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _DictionarySourceRow(
                  rawSource: source.key,
                  count: source.value,
                  preferences: widget.dictionaryPreferences,
                ),
              ),
          if (sources.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '导入来源与许可信息按词包或导入者提供的声明显示，应用未核验其真实性。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          const Text('教材词表按版本、学段、年级和上下册管理；未授权的商业词典不会随软件发布。'),
        ],
      ),
    );
  }

  Widget _articleCard(ColorScheme colors) {
    return _LibrarySection(
      key: const ValueKey('content-library-articles'),
      icon: Icons.article_outlined,
      title: '文章与阅读资料',
      subtitle: '内置自写文章、阅读器导入和后续用户主动选择的公开参考资料。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final article in builtInLearningArticles)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.auto_stories_outlined),
              title: Text(article.title),
              subtitle: Text(
                '${article.level} · ${article.paragraphCount} 段 · 译学自写',
              ),
            ),
          if (_sources.isEmpty)
            const Text('还没有阅读器导入的文章。')
          else ...[
            for (final source in _sources)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(source.title),
                subtitle: Text(
                  '${source.kind} · ${source.localPath ?? '本地数据库'} · ${source.createdAt}',
                ),
              ),
          ],
          const SizedBox(height: 5),
          const Text('网上文章仅作为用户主动选择的学习来源，显示来源并要求用户自行确认使用权。'),
        ],
      ),
    );
  }

  Widget _textbookCard(ColorScheme colors) {
    return _LibrarySection(
      key: const ValueKey('content-library-textbooks'),
      icon: Icons.school_outlined,
      title: '教材课程包',
      subtitle: '只保存词表、课次元数据和用户有权使用的课程内容。',
      trailing: widget.onOpenTextbooks == null
          ? null
          : OutlinedButton.icon(
              key: const ValueKey('content-library-open-textbooks'),
              onPressed: widget.onOpenTextbooks,
              icon: const Icon(Icons.open_in_new_outlined),
              label: const Text('打开课程管理'),
            ),
      child: _textbooks.isEmpty
          ? const Text('暂无用户导入教材；内置自写文章不会伪装成官方教材。')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final package in _textbooks)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(package.title),
                    subtitle: Text(
                      '${package.ageBand} · ${package.level} · ${package.version}\n'
                      '${package.lessons.length} 课次 · ${package.licenseName} · ${package.rightsHolder}',
                    ),
                  ),
              ],
            ),
    );
  }
}

class _DictionarySourceRow extends StatelessWidget {
  const _DictionarySourceRow({
    required this.rawSource,
    required this.count,
    required this.preferences,
  });

  final String rawSource;
  final int count;
  final DictionaryPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final parts = rawSource.split(' · ');
    final id = dictionarySourceId(rawSource);
    DictionarySourcePreference? preference;
    for (final candidate in preferences.sources) {
      if (candidate.id == id) {
        preference = candidate;
        break;
      }
    }
    final displayName =
        preference?.displayName ?? (parts.length > 1 ? parts[1].trim() : id);
    final license =
        preference?.license ??
        (parts.length > 2 ? parts.skip(2).join(' · ').trim() : '');
    return Text(
      '• $displayName · $count 条 · 许可声明：${license.isEmpty ? '未提供' : license}',
    );
  }
}

class _InventoryMetric extends StatelessWidget {
  const _InventoryMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 142,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: .15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 3),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const Divider(height: 22),
            child,
          ],
        ),
      ),
    );
  }
}
