import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/shell/window_title_bar.dart';

/// The business runtime has been released. Only host exit can be retried.
class ScreenshotTranslationExitRecovery extends StatelessWidget {
  const ScreenshotTranslationExitRecovery({
    required this.controller,
    super.key,
  });
  final ScreenshotTranslationDesktopController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      body: Column(
        children: [
          const WindowTitleBar(),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.exit_to_app_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '退出未完成',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      controller.lifecycleError ?? '请重试退出。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: controller.exitInProgress
                          ? null
                          : controller.quit,
                      child: Text(controller.exitInProgress ? '正在退出…' : '重试退出'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class ScreenshotTranslationSettingsCard extends StatefulWidget {
  const ScreenshotTranslationSettingsCard({
    required this.controller,
    super.key,
  });
  final ScreenshotTranslationDesktopController controller;
  @override
  State<ScreenshotTranslationSettingsCard> createState() => _SettingsState();
}

class _SettingsState extends State<ScreenshotTranslationSettingsCard> {
  final _focus = FocusNode();
  bool _recording = false, _saving = false;
  @override
  void dispose() {
    if (widget.controller.hotKeyRecording) {
      unawaited(widget.controller.endHotKeyRecording());
    }
    _focus.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    if (_recording) {
      setState(() => _recording = false);
      await widget.controller.endHotKeyRecording();
      return;
    }
    if (await widget.controller.beginHotKeyRecording() && mounted) {
      setState(() => _recording = true);
      _focus.requestFocus();
    }
  }

  Future<void> _save(ScreenshotTranslationPreferences next) async {
    setState(() => _saving = true);
    try {
      await widget.controller.update(next);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_recording || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      unawaited(widget.controller.endHotKeyRecording());
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
      setState(() => _recording = false);
      unawaited(_saveRecordedKey(hotKey));
    } on FormatException {
      /* Keep listening until a full modified chord. */
    }
    return KeyEventResult.handled;
  }

  Future<void> _saveRecordedKey(ScreenshotHotKey hotKey) async {
    await widget.controller.endHotKeyRecording();
    if (!mounted) return;
    await _save(widget.controller.preferences.copyWith(hotKey: hotKey));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller,
          colors = Theme.of(context).colorScheme;
      if (_recording && !controller.hotKeyRecording) _recording = false;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            onFocusChange: (focused) {
              if (!focused && _recording) {
                setState(() => _recording = false);
                unawaited(controller.endHotKeyRecording());
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.center_focus_weak_rounded,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '截屏翻译',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用悬浮圆球'),
                  subtitle: const Text('开启后关闭主窗口会保留圆球；关闭圆球后主窗口正常退出。'),
                  value: controller.preferences.orbEnabled,
                  onChanged: _saving
                      ? null
                      : (value) => _save(
                          controller.preferences.copyWith(orbEnabled: value),
                        ),
                ),
                const SizedBox(height: 8),
                Text('系统全局快捷键', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _recording
                          ? '请按组合键 · Esc 取消'
                          : controller.preferences.hotKey.label,
                    ),
                    OutlinedButton(
                      onPressed: _saving ? null : _record,
                      child: Text(_recording ? '取消录制' : '修改快捷键'),
                    ),
                    if (controller.hotKeyError != null &&
                        !controller.hotKeyRecording)
                      TextButton(
                        onPressed: _saving ? null : controller.retryHotKey,
                        child: const Text('重试注册'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  controller.hotKeyError ??
                      (controller.hotKeyRecording
                          ? '录制中 · 当前快捷键暂时停用'
                          : controller.hotKeyRegistered
                          ? '已注册 · 在其他应用中也可使用'
                          : '正在注册系统快捷键…'),
                  style: TextStyle(
                    color: controller.hotKeyError == null
                        ? colors.onSurfaceVariant
                        : colors.error,
                  ),
                ),
                if (controller.orbError != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.orbError!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                      TextButton(
                        onPressed: controller.retryOrb,
                        child: const Text('重试圆球'),
                      ),
                    ],
                  ),
                if (controller.saveError != null)
                  Text(
                    controller.saveError!,
                    style: TextStyle(color: colors.error),
                  ),
                if (controller.lifecycleError != null)
                  Text(
                    controller.lifecycleError!,
                    style: TextStyle(color: colors.error),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
