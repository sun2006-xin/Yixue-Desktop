import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/app/app_theme.dart';

enum _WorkspaceAppearanceChoice { inherit, focus, vitality }

class _ThemeToken {
  const _ThemeToken(this.key, this.label, this.hint);

  final String key;
  final String label;
  final String hint;
}

const _themeTokens = <_ThemeToken>[
  _ThemeToken('background', '页面背景', '主工作区底色'),
  _ThemeToken('surface', '卡片表面', '编辑器和设置卡片底色'),
  _ThemeToken('accent', '主标识色', '按钮、链接和焦点色'),
  _ThemeToken('outline', '分割线', '边框与分割线颜色'),
  _ThemeToken('sidebarTop', '侧栏上方', '侧边栏渐变起点'),
  _ThemeToken('sidebarBottom', '侧栏下方', '侧边栏渐变终点'),
  _ThemeToken('sidebarForeground', '侧栏文字', '侧边栏文字与图标'),
  _ThemeToken('sidebarGlow', '侧栏光晕', '选中项与侧栏光效'),
  _ThemeToken('selectedStart', '选中起点', '导航选中渐变起点'),
  _ThemeToken('selectedEnd', '选中终点', '导航选中渐变终点'),
  _ThemeToken('topStart', '顶部起点', '页面顶部渐变起点'),
  _ThemeToken('topEnd', '顶部终点', '页面顶部渐变终点'),
  _ThemeToken('topForeground', '顶部文字', '顶部标题与按钮文字'),
  _ThemeToken('topBorder', '顶部边缘', '顶部栏边缘高光'),
  _ThemeToken('statusBarColor', '状态栏颜色', '窗口最上方的标题栏底色'),
];

String _workspaceLabel(YixueWorkspace workspace) => switch (workspace) {
  YixueWorkspace.home => '首页',
  YixueWorkspace.quickTranslation => '快速翻译',
  YixueWorkspace.screenshotTranslation => '截屏翻译',
  YixueWorkspace.reader => '阅读器',
  YixueWorkspace.learning => '学习',
  YixueWorkspace.liveInterpretation => 'AI 同传',
  YixueWorkspace.models => '模型与服务',
  YixueWorkspace.settings => '设置',
};

class AppearanceSettingsCard extends StatefulWidget {
  const AppearanceSettingsCard({required this.controller, super.key});

  final AppearanceController controller;

  @override
  State<AppearanceSettingsCard> createState() => _AppearanceSettingsCardState();
}

class _AppearanceSettingsCardState extends State<AppearanceSettingsCard> {
  var _workspace = YixueWorkspace.home;

  Future<void> _importTheme() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '译学主题包', extensions: ['json']),
      ],
    );
    if (picked == null || !mounted) return;
    try {
      final file = File(picked.path);
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('主题包超过 1 MB');
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('主题包必须是 JSON 对象');
      }
      final spec = CustomThemeSpec.fromJson(decoded);
      widget.controller.setCustomTheme(spec);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已应用主题：${spec.name}')));
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('主题包无效：${error.message}')));
      }
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('主题包读取失败，请检查文件权限')));
      }
    }
  }

  Future<void> _exportTheme(CustomThemeSpec? spec) async {
    if (spec == null) return;
    final location = await getSaveLocation(
      suggestedName: 'yixue-theme-${spec.name}.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: '译学主题包', extensions: ['json']),
      ],
    );
    if (location == null || !mounted) return;
    try {
      await File(location.path).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(spec.toJson())}\n',
        flush: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('主题包已导出到：${location.path}')));
      }
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('主题包导出失败，请检查文件权限')));
      }
    }
  }

  Future<void> _editTheme(AppearanceState appearance) async {
    final theme = Theme.of(context);
    final shell = YixueShellPalette.of(context);
    final current =
        appearance.customTheme ??
        CustomThemeSpec(
          name: '译学自定义',
          background: theme.scaffoldBackgroundColor,
          surface: theme.colorScheme.surface,
          accent: theme.colorScheme.primary,
          outline: theme.colorScheme.outline,
          sidebarTop: shell.sidebarTop,
          sidebarBottom: shell.sidebarBottom,
          sidebarForeground: shell.sidebarForeground,
          sidebarGlow: shell.sidebarGlow,
          selectedStart: shell.selectedStart,
          selectedEnd: shell.selectedEnd,
          topStart: shell.topStart,
          topEnd: shell.topEnd,
          topForeground: shell.topForeground,
          topBorder: shell.topBorder,
          statusBarColor: shell.statusBarColor,
        );
    final updated = await showDialog<CustomThemeSpec>(
      context: context,
      builder: (context) => _ThemeEditorDialog(initial: current),
    );
    if (updated == null || !mounted) return;
    widget.controller.setCustomTheme(updated);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已应用自定义主题：${updated.name}')));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final appearance = widget.controller.value;
        final workspaceStyle = switch (appearance.workspaceStyles[_workspace]) {
          YixueVisualStyle.focus => _WorkspaceAppearanceChoice.focus,
          YixueVisualStyle.vitality => _WorkspaceAppearanceChoice.vitality,
          null => _WorkspaceAppearanceChoice.inherit,
        };
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 14),
                  const Text(
                    '外观与动效',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('import-custom-theme'),
                    onPressed: _importTheme,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('导入自定义主题'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('edit-custom-theme'),
                    onPressed: () => _editTheme(appearance),
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(
                      appearance.customTheme == null ? '创建自定义主题' : '编辑当前主题',
                    ),
                  ),
                  if (appearance.customTheme != null)
                    TextButton.icon(
                      key: const ValueKey('clear-custom-theme'),
                      onPressed: widget.controller.clearCustomTheme,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: Text('恢复官方主题（${appearance.customTheme!.name}）'),
                    ),
                  if (appearance.customTheme != null)
                    TextButton.icon(
                      key: const ValueKey('export-custom-theme'),
                      onPressed: () => _exportTheme(appearance.customTheme),
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('导出当前主题包'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (appearance.customTheme?.backgroundImagePath != null) ...[
                Row(
                  children: [
                    Icon(
                      appearance.customTheme!.usableBackgroundImagePath == null
                          ? Icons.image_not_supported_outlined
                          : Icons.image_outlined,
                      size: 18,
                      color:
                          appearance.customTheme!.usableBackgroundImagePath ==
                              null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        appearance.customTheme!.usableBackgroundImagePath ==
                                null
                            ? '自定义背景图未找到，当前已回退为纯色；可重新编辑主题选择本地图片。'
                            : '自定义背景图已启用，仅以低透明度显示，确保文字和阅读内容清晰。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              _OptionGroup<YixueOfficialTheme>(
                title: '官方主题',
                selected: appearance.officialTheme,
                segments: const [
                  ButtonSegment(
                    value: YixueOfficialTheme.vitality,
                    label: Text('生机'),
                  ),
                  ButtonSegment(
                    value: YixueOfficialTheme.light,
                    label: Text('浅色', key: ValueKey('official-theme-light')),
                  ),
                  ButtonSegment(
                    value: YixueOfficialTheme.dark,
                    label: Text('深色'),
                  ),
                ],
                onSelected: widget.controller.setOfficialTheme,
              ),
              const SizedBox(height: 16),
              _OptionGroup<YixueMotionLevel>(
                title: '动效等级',
                selected: appearance.motionLevel,
                segments: const [
                  ButtonSegment(
                    value: YixueMotionLevel.full,
                    label: Text('完整'),
                  ),
                  ButtonSegment(
                    value: YixueMotionLevel.reduced,
                    label: Text('减少', key: ValueKey('motion-level-reduced')),
                  ),
                  ButtonSegment(value: YixueMotionLevel.off, label: Text('关闭')),
                ],
                onSelected: widget.controller.setMotionLevel,
              ),
              const SizedBox(height: 16),
              Text(
                '单页外观',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<YixueWorkspace>(
                    key: const ValueKey('workspace-appearance-menu'),
                    value: _workspace,
                    items: YixueWorkspace.values
                        .where((workspace) => workspace != YixueWorkspace.reader)
                        .map(
                          (workspace) => DropdownMenuItem(
                            value: workspace,
                            child: Text(_workspaceLabel(workspace)),
                          ),
                        )
                        .toList(),
                    onChanged: (workspace) {
                      if (workspace != null) {
                        setState(() => _workspace = workspace);
                      }
                    },
                  ),
                  SegmentedButton<_WorkspaceAppearanceChoice>(
                    key: const ValueKey('workspace-appearance-options'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _WorkspaceAppearanceChoice.inherit,
                        label: Text('跟随主题'),
                      ),
                      ButtonSegment(
                        value: _WorkspaceAppearanceChoice.focus,
                        label: Text('专注'),
                      ),
                      ButtonSegment(
                        value: _WorkspaceAppearanceChoice.vitality,
                        label: Text('本页生机'),
                      ),
                    ],
                    selected: {workspaceStyle},
                    onSelectionChanged: (selection) {
                      final style = switch (selection.single) {
                        _WorkspaceAppearanceChoice.inherit => null,
                        _WorkspaceAppearanceChoice.focus =>
                          YixueVisualStyle.focus,
                        _WorkspaceAppearanceChoice.vitality =>
                          YixueVisualStyle.vitality,
                      };
                      widget.controller.setWorkspaceStyle(_workspace, style);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                switch (appearance.officialTheme) {
                  YixueOfficialTheme.vitality => '生机：蓝天与新绿的品牌主题，适合首页和日常学习。',
                  YixueOfficialTheme.light => '浅色：减少装饰与高光，适合论文和长时间阅读。',
                  YixueOfficialTheme.dark => '深色：克制的深灰界面，适合夜间和低光环境。',
                },
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThemeEditorDialog extends StatefulWidget {
  const _ThemeEditorDialog({required this.initial});

  final CustomThemeSpec initial;

  @override
  State<_ThemeEditorDialog> createState() => _ThemeEditorDialogState();
}

class _ThemeEditorDialogState extends State<_ThemeEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _fontFamilyController;
  late final TextEditingController _backgroundPathController;
  late final Map<String, TextEditingController> _colorControllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial.name);
    _fontFamilyController = TextEditingController(
      text: widget.initial.fontFamily,
    );
    _backgroundPathController = TextEditingController(
      text: widget.initial.backgroundImagePath ?? '',
    );
    final colors = Map<String, dynamic>.from(
      widget.initial.toJson()['colors']! as Map,
    );
    _colorControllers = {
      for (final token in _themeTokens)
        token.key: TextEditingController(text: colors[token.key] as String),
    };
  }

  @override
  void dispose() {
    _nameController.dispose();
    _fontFamilyController.dispose();
    _backgroundPathController.dispose();
    for (final controller in _colorControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickBackgroundImage() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '本地背景图',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        ),
      ],
    );
    if (picked == null || !mounted) return;
    try {
      final file = File(picked.path);
      if (!await file.exists()) {
        throw const FormatException('背景图文件不存在');
      }
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('背景图超过 8 MB，请选择更轻量的图片');
      }
      _backgroundPathController.text = file.path;
      setState(() => _error = null);
    } on FileSystemException {
      setState(() => _error = '背景图读取失败，请检查文件权限');
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Color? _parseColor(String raw) {
    final normalized = raw.trim().replaceFirst('#', '');
    final hex = normalized.length == 6 ? 'FF$normalized' : normalized;
    if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(hex)) return null;
    return Color(int.parse(hex, radix: 16));
  }

  void _save() {
    final colors = <String, String>{};
    for (final token in _themeTokens) {
      final raw = _colorControllers[token.key]!.text;
      if (_parseColor(raw) == null) {
        setState(() => _error = '${token.label}不是有效颜色，请填写 #RRGGBB 或 #AARRGGBB');
        return;
      }
      colors[token.key] = raw.trim();
    }
    final fontFamily = _fontFamilyController.text.trim();
    final backgroundPath = _backgroundPathController.text.trim();
    try {
      final spec = CustomThemeSpec.fromJson({
        'schemaVersion': 1,
        'name': _nameController.text.trim(),
        'fontFamily': fontFamily,
        if (backgroundPath.isNotEmpty) 'backgroundImagePath': backgroundPath,
        'colors': colors,
      });
      Navigator.of(context).pop(spec);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义主题'),
      content: SizedBox(
        width: 640,
        height: 700,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('可编辑名称、字体、颜色和本地背景图；不会读取脚本、网络资源或用户数据。'),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('custom-theme-name'),
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '主题名称',
                hintText: '例如：晴空纸页',
                border: OutlineInputBorder(),
              ),
              maxLength: 64,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('custom-theme-font-family'),
                    controller: _fontFamilyController,
                    decoration: const InputDecoration(
                      labelText: '界面字体',
                      hintText: '例如：Microsoft YaHei UI',
                      helperText: '需是系统已安装字体；未安装时由系统回退。',
                      border: OutlineInputBorder(),
                    ),
                    maxLength: 120,
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey('custom-theme-background-path'),
                    controller: _backgroundPathController,
                    decoration: InputDecoration(
                      labelText: '本地背景图（可选）',
                      hintText: '选择一张本地图片',
                      helperText: '缺失或损坏时自动回退为纯色，最大 8 MB。',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: '选择背景图',
                        onPressed: _pickBackgroundImage,
                        icon: const Icon(Icons.folder_open_rounded),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedBuilder(
              animation: Listenable.merge([
                ..._colorControllers.values,
                _fontFamilyController,
                _backgroundPathController,
              ]),
              builder: (context, _) {
                Color color(String key, Color fallback) =>
                    _parseColor(_colorControllers[key]!.text) ?? fallback;
                final outline = Theme.of(context).colorScheme.outline;
                final sidebarTop = color('sidebarTop', Colors.blueGrey);
                final sidebarBottom = color('sidebarBottom', Colors.teal);
                final topStart = color('topStart', sidebarTop);
                final topEnd = color('topEnd', sidebarBottom);
                final surface = color('surface', Colors.white);
                final statusBar = color('statusBarColor', topStart);
                final backgroundPath = _backgroundPathController.text.trim();
                final hasBackground =
                    backgroundPath.isNotEmpty &&
                    File(backgroundPath).existsSync();
                return Container(
                  key: const ValueKey('custom-theme-preview'),
                  height: 78,
                  decoration: BoxDecoration(
                    color: surface,
                    border: Border.all(color: outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    children: [
                      Container(
                        width: 108,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [sidebarTop, sidebarBottom],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.menu_book_rounded,
                          color: color('sidebarForeground', Colors.white),
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            if (hasBackground)
                              Positioned.fill(
                                child: Opacity(
                                  opacity: 0.12,
                                  child: Image.file(
                                    File(backgroundPath),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            Column(
                              children: [
                                Container(height: 10, color: statusBar),
                                Container(
                                  height: 20,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [topStart, topEnd],
                                    ),
                                  ),
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                  ),
                                  child: Text(
                                    '译学 · 主题预览',
                                    style: TextStyle(
                                      color: color(
                                        'topForeground',
                                        Colors.white,
                                      ),
                                      fontWeight: FontWeight.w700,
                                      fontFamily: _fontFamilyController.text
                                          .trim(),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      width: 180,
                                      height: 24,
                                      margin: const EdgeInsets.only(left: 14),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            color('selectedStart', Colors.blue),
                                            color('selectedEnd', Colors.green),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.separated(
                key: const ValueKey('custom-theme-color-list'),
                itemCount: _themeTokens.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final token = _themeTokens[index];
                  final controller = _colorControllers[token.key]!;
                  return Row(
                    children: [
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, _, _) => Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: _parseColor(controller.text),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 106,
                        child: Text(
                          token.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          key: ValueKey('custom-theme-${token.key}'),
                          controller: controller,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '#RRGGBB',
                            helperText: token.hint,
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() => _error = null),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-custom-theme'),
          onPressed: _save,
          child: const Text('应用主题'),
        ),
      ],
    );
  }
}

class _OptionGroup<T> extends StatelessWidget {
  const _OptionGroup({
    required this.title,
    required this.selected,
    required this.segments,
    required this.onSelected,
  });

  final String title;
  final T selected;
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 10,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: segments,
          selected: {selected},
          onSelectionChanged: (selection) => onSelected(selection.single),
        ),
      ],
    );
  }
}
