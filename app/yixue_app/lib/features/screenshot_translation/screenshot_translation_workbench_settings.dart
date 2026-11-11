import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

/// Screenshot-only preference controls, kept inside the screenshot workspace.
/// Provider credentials remain in the shared model settings.
final class ScreenshotTranslationWorkbenchSettings extends StatefulWidget {
  const ScreenshotTranslationWorkbenchSettings({
    required this.controller,
    required this.archiveController,
    required this.runtime,
    super.key,
  });

  final ScreenshotTranslationDesktopController controller;
  final ScreenshotTranslationArchiveController? archiveController;
  final ScreenshotTranslationRuntime runtime;

  @override
  State<ScreenshotTranslationWorkbenchSettings> createState() =>
      _ScreenshotTranslationWorkbenchSettingsState();
}

final class _ScreenshotTranslationWorkbenchSettingsState
    extends State<ScreenshotTranslationWorkbenchSettings> {
  final FocusNode _recordFocus = FocusNode();
  bool _recording = false;
  bool _startingRecording = false;
  bool _finishingRecording = false;
  bool _savingPreferences = false;
  bool _clearingImages = false;
  final Set<String> _retryingIds = {};
  late Future<ScreenshotTranslationOcrCapabilities> _ocrCapabilities;

  @override
  void initState() {
    super.initState();
    _ocrCapabilities = widget.runtime.inspectOcrCapabilities();
  }

  @override
  void didUpdateWidget(
    covariant ScreenshotTranslationWorkbenchSettings oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runtime, widget.runtime)) {
      _ocrCapabilities = widget.runtime.inspectOcrCapabilities();
    }
  }

  void _refreshOcrCapabilities() {
    setState(() {
      _ocrCapabilities = widget.runtime.inspectOcrCapabilities(refresh: true);
    });
  }

  @override
  void dispose() {
    if (_startingRecording || widget.controller.hotKeyRecording) {
      unawaited(widget.controller.endHotKeyRecording());
    }
    _recordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      widget.controller,
      widget.runtime,
      ?widget.archiveController,
    ];
    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        final controller = widget.controller;
        final archive = widget.archiveController;
        final runtime = widget.runtime;
        final orbFailed =
            controller.orbRuntimeState == ScreenshotOrbRuntimeState.failed;
        final orbStatus =
            controller.orbError ??
            switch (controller.orbRuntimeState) {
              ScreenshotOrbRuntimeState.initializing => '状态：正在初始化…',
              ScreenshotOrbRuntimeState.starting => '状态：正在启动悬浮球…',
              ScreenshotOrbRuntimeState.visible => '状态：悬浮球已显示',
              ScreenshotOrbRuntimeState.closing => '状态：正在关闭悬浮球…',
              ScreenshotOrbRuntimeState.disabled => '状态：悬浮球已关闭',
              ScreenshotOrbRuntimeState.failed =>
                controller.preferences.orbEnabled
                    ? '悬浮球启动失败，请重试。'
                    : '悬浮球关闭失败，请重试。',
            };
        if (_recording && !controller.hotKeyRecording) _recording = false;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsCard(
              title: '桌面操作',
              icon: Icons.display_settings_outlined,
              child: Focus(
                focusNode: _recordFocus,
                onKeyEvent: _onHotKeyEvent,
                onFocusChange: (focused) {
                  if (!focused && _recording) _cancelRecording();
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('screenshot-workbench-orb-toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用译学悬浮球'),
                      subtitle: const Text('左键开始框选；右键打开快捷操作。关闭主窗口时按悬浮球状态继续运行。'),
                      value: controller.preferences.orbEnabled,
                      onChanged: _savingPreferences
                          ? null
                          : (value) => _save(
                              controller.preferences.copyWith(
                                orbEnabled: value,
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _StateLine(
                        icon: switch (controller.orbRuntimeState) {
                          ScreenshotOrbRuntimeState.initializing ||
                          ScreenshotOrbRuntimeState.starting ||
                          ScreenshotOrbRuntimeState.closing =>
                            Icons.hourglass_top_rounded,
                          ScreenshotOrbRuntimeState.visible =>
                            Icons.radio_button_checked_rounded,
                          ScreenshotOrbRuntimeState.disabled =>
                            Icons.radio_button_unchecked_rounded,
                          ScreenshotOrbRuntimeState.failed =>
                            Icons.error_outline_rounded,
                        },
                        text: orbStatus,
                        warning: orbFailed,
                        action: !orbFailed
                            ? null
                            : TextButton(
                                key: const ValueKey(
                                  'screenshot-workbench-retry-orb',
                                ),
                                onPressed: controller.retryOrb,
                                child: Text(
                                  controller.preferences.orbEnabled
                                      ? '重试显示'
                                      : '重试关闭',
                                ),
                              ),
                      ),
                    ),
                    const Divider(height: 20),
                    Text(
                      '系统全局快捷键',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _KeyCap(
                          label: _startingRecording
                              ? '正在暂停快捷键…'
                              : _finishingRecording
                              ? '正在应用新快捷键…'
                              : _recording
                              ? '请按组合键 · Esc 取消'
                              : controller.preferences.hotKey.label,
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey(
                            'screenshot-workbench-record-hotkey',
                          ),
                          onPressed:
                              _savingPreferences ||
                                  _startingRecording ||
                                  _finishingRecording
                              ? null
                              : _toggleRecording,
                          icon: _startingRecording || _finishingRecording
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _recording
                                      ? Icons.close_rounded
                                      : Icons.keyboard_alt_outlined,
                                ),
                          label: Text(
                            _startingRecording
                                ? '正在准备录制…'
                                : _finishingRecording
                                ? '正在保存快捷键…'
                                : _recording
                                ? '取消录制'
                                : '录制新快捷键',
                          ),
                        ),
                        if (controller.hotKeyError != null &&
                            !controller.hotKeyRecording)
                          TextButton(
                            onPressed: _savingPreferences
                                ? null
                                : controller.retryHotKey,
                            child: const Text('重试注册'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      controller.hotKeyError ??
                          (controller.hotKeyRecording
                              ? '录制期间暂停当前快捷键。'
                              : controller.hotKeyRegistered
                              ? '已注册，可在其他应用中触发。'
                              : '正在注册系统快捷键。'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: controller.hotKeyError == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const Divider(height: 20),
                    Row(
                      children: [
                        Icon(
                          Icons.push_pin_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '固定截图区域',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                switch (controller.preferences.pinnedRegion) {
                                  final region? =>
                                    '${region.width} × ${region.height} 像素 · 可在结果窗按需刷新',
                                  null => '在截图结果中固定一个区域，之后可一键刷新',
                                },
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (controller.preferences.pinnedRegion != null)
                          IconButton(
                            key: const ValueKey(
                              'screenshot-workbench-clear-pinned-region',
                            ),
                            tooltip: '清除固定区域',
                            visualDensity: VisualDensity.compact,
                            onPressed: _savingPreferences
                                ? null
                                : _clearPinnedRegion,
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                      ],
                    ),
                    if (controller.saveError != null) ...[
                      const SizedBox(height: 7),
                      _StateLine(
                        icon: Icons.save_outlined,
                        text: controller.saveError!,
                        warning: true,
                      ),
                    ],
                    if (controller.lifecycleError != null) ...[
                      const SizedBox(height: 7),
                      _StateLine(
                        icon: Icons.info_outline_rounded,
                        text: controller.lifecycleError!,
                        warning: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildOcrCard(),
            const SizedBox(height: 12),
            _SettingsCard(
              title: '原图留存',
              icon: Icons.image_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile.adaptive(
                    key: const ValueKey(
                      'screenshot-workbench-save-images-toggle',
                    ),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动保存截图原图'),
                    subtitle: const Text('原图仅保存在本机。关闭后只影响新截图，已有原图不会被删除。'),
                    value: controller.preferences.saveScreenshotImages,
                    onChanged: _savingPreferences
                        ? null
                        : (value) => _save(
                            controller.preferences.copyWith(
                              saveScreenshotImages: value,
                            ),
                          ),
                  ),
                  const SizedBox(height: 4),
                  _ArchiveStorageSummary(archive: archive),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('screenshot-workbench-clear-images'),
                      onPressed:
                          archive == null ||
                              _clearingImages ||
                              archive.imageStats.imageCount == 0
                          ? null
                          : () => _confirmClearImages(archive),
                      icon: _clearingImages
                          ? const SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_sweep_outlined),
                      label: Text(_clearingImages ? '正在清理…' : '清理所有已保存原图'),
                    ),
                  ),
                  Text(
                    '清理会删除本地图片文件、保留 OCR 原文和译文历史。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _RetryableImagesCard(
              runtime: runtime,
              archive: archive,
              retryingIds: _retryingIds,
              onRetry: _retryImage,
            ),
            const SizedBox(height: 12),
            _SettingsCard(
              title: '本地与隐私',
              icon: Icons.shield_outlined,
              child: Text(
                '截图原图只保存在本地应用数据目录。网络 Provider 会收到 OCR 文字用于翻译，不会收到截图图片。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildOcrCard() => _SettingsCard(
    title: '本机 OCR 语言与状态',
    icon: Icons.document_scanner_outlined,
    child: FutureBuilder<ScreenshotTranslationOcrCapabilities>(
      future: _ocrCapabilities,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final capabilities = snapshot.data;
        final ready = capabilities?.isReady == true && !snapshot.hasError;
        final colors = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StateLine(
              icon: loading
                  ? Icons.hourglass_top_rounded
                  : ready
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded,
              text: loading
                  ? '正在检查 OCR 引擎与语言包…'
                  : snapshot.hasError || capabilities == null
                  ? 'OCR 状态检查失败'
                  : capabilities.statusMessage,
              warning: !loading && !ready,
              action: TextButton(
                key: const ValueKey('screenshot-workbench-refresh-ocr-status'),
                onPressed: loading ? null : _refreshOcrCapabilities,
                child: Text(loading ? '检查中…' : '重新检查'),
              ),
            ),
            if (!loading) ...[
              const SizedBox(height: 6),
              Text(
                snapshot.hasError || capabilities == null
                    ? '请检查本机 Tesseract 安装和语言数据目录。'
                    : capabilities.guidance,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
              ),
            ],
          ],
        );
      },
    ),
  );

  KeyEventResult _onHotKeyEvent(FocusNode node, KeyEvent event) {
    if (!_recording || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelRecording();
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers = <String>[
      if (keyboard.isControlPressed) 'control',
      if (keyboard.isAltPressed) 'alt',
      if (keyboard.isShiftPressed) 'shift',
      if (keyboard.isMetaPressed) 'meta',
    ];
    try {
      final hotKey = ScreenshotHotKey.fromJson({
        'keyCode': event.physicalKey.usbHidUsage,
        'modifiers': modifiers,
      });
      setState(() {
        _recording = false;
        _finishingRecording = true;
      });
      unawaited(_saveRecordedKey(hotKey));
    } on FormatException {
      // Keep recording when the user presses only a modifier.
    }
    return KeyEventResult.handled;
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      _cancelRecording();
      return;
    }
    if (_startingRecording || _finishingRecording || _savingPreferences) return;
    setState(() => _startingRecording = true);
    late final bool started;
    try {
      started = await widget.controller.beginHotKeyRecording();
    } finally {
      if (mounted) setState(() => _startingRecording = false);
    }
    if (started && mounted) {
      setState(() => _recording = true);
      _recordFocus.requestFocus();
    }
  }

  void _cancelRecording() {
    if (!mounted) return;
    setState(() {
      _recording = false;
      _finishingRecording = true;
    });
    unawaited(_cancelRecordingAndRestoreHotKey());
  }

  Future<void> _cancelRecordingAndRestoreHotKey() async {
    try {
      await widget.controller.endHotKeyRecording();
    } finally {
      if (mounted) setState(() => _finishingRecording = false);
    }
  }

  Future<void> _saveRecordedKey(ScreenshotHotKey hotKey) async {
    try {
      await widget.controller.endHotKeyRecording();
      final next = widget.controller.preferences.copyWith(hotKey: hotKey);
      if (mounted) {
        await _save(next);
      } else {
        await widget.controller.update(next);
      }
    } finally {
      if (mounted) setState(() => _finishingRecording = false);
    }
  }

  Future<void> _save(ScreenshotTranslationPreferences next) async {
    setState(() => _savingPreferences = true);
    try {
      await widget.controller.update(next);
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  Future<void> _clearPinnedRegion() async {
    setState(() => _savingPreferences = true);
    try {
      await widget.runtime.updatePinnedRegionPreference(null);
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  Future<void> _confirmClearImages(
    ScreenshotTranslationArchiveController archive,
  ) async {
    final before = archive.imageStats;
    if (before.imageCount == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清理已保存的全部原图？'),
        content: Text(
          '将删除 ${before.imageCount} 张截图原图（${_formatBytes(before.totalBytes)}）。\n\nOCR 原文和译文历史会保留；已关闭自动保存的设置不会改变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理图片'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearingImages = true);
    try {
      await archive.clearAllImages();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('已清理 ${before.imageCount} 张原图；OCR 原文和译文历史仍保留。'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('清理失败，部分原图可能仍在本机。请重试。')));
      }
    } finally {
      if (mounted) setState(() => _clearingImages = false);
    }
  }

  Future<void> _retryImage(String historyId) async {
    setState(() => _retryingIds.add(historyId));
    try {
      final saved = await widget.runtime.retryImageSave(captureId: historyId);
      if (saved) _refreshArchiveImageStats();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(saved ? '原图保存重试已完成。' : '原图未能保存，重试权限可能已失效；请查看本机原图状态。'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('原图保存仍未成功，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _retryingIds.remove(historyId));
    }
  }

  void _refreshArchiveImageStats() {
    final archive = widget.archiveController;
    if (archive == null) return;
    unawaited(() async {
      try {
        await archive.inspectImages();
      } on Object {
        // The retry result is already known. A storage scan must not delay it.
      }
    }());
  }
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 9),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

final class _ArchiveStorageSummary extends StatelessWidget {
  const _ArchiveStorageSummary({required this.archive});
  final ScreenshotTranslationArchiveController? archive;

  @override
  Widget build(BuildContext context) {
    final stats = archive?.imageStats;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.storage_outlined, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              stats == null
                  ? '图片存储尚未连接'
                  : '本机原图 ${stats.imageCount} 张 · ${_formatBytes(stats.totalBytes)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

final class _RetryableImagesCard extends StatelessWidget {
  const _RetryableImagesCard({
    required this.runtime,
    required this.archive,
    required this.retryingIds,
    required this.onRetry,
  });
  final ScreenshotTranslationRuntime runtime;
  final ScreenshotTranslationArchiveController? archive;
  final Set<String> retryingIds;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    final retryable = runtime.retryableImageSaves;
    final colors = Theme.of(context).colorScheme;
    return _SettingsCard(
      title: '原图保存重试',
      icon: Icons.sync_rounded,
      child: retryable.isEmpty
          ? Text(
              '没有待重试的图片。保存失败时，译文历史仍会保留。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            )
          : Column(
              children: [
                for (final item in retryable)
                  _RetryableImageRow(
                    historyId: item.captureId,
                    entry: _entryFor(archive, item.captureId),
                    retrying: retryingIds.contains(item.captureId),
                    onRetry: () => onRetry(item.captureId),
                  ),
              ],
            ),
    );
  }

  TranslationHistoryEntryData? _entryFor(
    ScreenshotTranslationArchiveController? archive,
    String id,
  ) {
    for (final entry
        in archive?.entries ?? const <TranslationHistoryEntryData>[]) {
      if (entry.captureId == id) return entry;
    }
    return null;
  }
}

final class _RetryableImageRow extends StatelessWidget {
  const _RetryableImageRow({
    required this.historyId,
    required this.entry,
    required this.retrying,
    required this.onRetry,
  });
  final String historyId;
  final TranslationHistoryEntryData? entry;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.image_not_supported_outlined),
    title: Text(
      entry == null
          ? '截屏记录 ${_shortId(historyId)}'
          : entry!.sourceText.replaceAll(RegExp(r'\s+'), ' '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: const Text('图片仍在本次运行内存中，可重试写入本机。'),
    trailing: TextButton(
      onPressed: retrying ? null : onRetry,
      child: retrying
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('重试'),
    ),
  );
}

final class _StateLine extends StatelessWidget {
  const _StateLine({
    required this.icon,
    required this.text,
    this.warning = false,
    this.action,
  });
  final IconData icon;
  final String text;
  final bool warning;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: warning ? colors.error : colors.primary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: warning ? colors.error : colors.onSurfaceVariant,
            ),
          ),
        ),
        ?action,
      ],
    );
  }
}

final class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w700),
    ),
  );
}

String _shortId(String value) =>
    value.length <= 14 ? value : '${value.substring(0, 14)}…';

String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
