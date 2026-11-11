import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yixue_app/app/app_theme.dart';

abstract interface class WindowActions {
  Future<void> minimize();

  Future<void> toggleMaximize();

  Future<void> close();
}

class NativeWindowActions implements WindowActions {
  const NativeWindowActions();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> close() => windowManager.close();
}

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    this.actions = const NativeWindowActions(),
    this.onBack,
  });

  static const height = 36.0;

  final WindowActions actions;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final shell = YixueShellPalette.of(context);
    return SizedBox(
      height: height,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color: shell.isCustomTheme ? shell.statusBarColor : null,
          gradient: shell.isCustomTheme
              ? null
              : LinearGradient(colors: [shell.topStart, shell.topEnd]),
        ),
        child: Row(
          children: [
            if (onBack != null)
              Tooltip(
                message: '返回译学工作台',
                child: IconButton(
                  key: const ValueKey('reader-shell-return'),
                  onPressed: onBack,
                  style: ButtonStyle(
                    minimumSize: const WidgetStatePropertyAll(Size(46, 36)),
                    maximumSize: const WidgetStatePropertyAll(Size(46, 36)),
                    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                    foregroundColor: WidgetStatePropertyAll(
                      shell.topForeground,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_back_rounded, size: 17),
                ),
              ),
            Expanded(
              child: DragToMoveArea(
                key: const ValueKey('window-drag-area'),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: shell.topBorder)),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            _WindowControlButton(
              key: const ValueKey('window-minimize'),
              tooltip: '最小化',
              icon: Icons.remove_rounded,
              foreground: shell.topForeground,
              onPressed: actions.minimize,
            ),
            _WindowControlButton(
              key: const ValueKey('window-maximize'),
              tooltip: '最大化或还原',
              icon: Icons.crop_square_rounded,
              foreground: shell.topForeground,
              onPressed: actions.toggleMaximize,
            ),
            _WindowControlButton(
              key: const ValueKey('window-close'),
              tooltip: '关闭',
              icon: Icons.close_rounded,
              foreground: shell.topForeground,
              isClose: true,
              onPressed: actions.close,
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatelessWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.foreground,
    required this.onPressed,
    this.isClose = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final Color foreground;
  final Future<void> Function() onPressed;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(46, 36)),
          maximumSize: const WidgetStatePropertyAll(Size(46, 36)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return Colors.white;
            }
            return foreground;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (isClose && states.contains(WidgetState.hovered)) {
              return const Color(0xFFC42B1C);
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.primary.withValues(alpha: 0.08);
            }
            if (states.contains(WidgetState.pressed)) {
              return colors.primary.withValues(alpha: 0.12);
            }
            return Colors.transparent;
          }),
        ),
        icon: Icon(icon, size: 16),
      ),
    );
  }
}
