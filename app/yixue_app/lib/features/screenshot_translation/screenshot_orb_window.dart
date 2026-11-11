import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';

enum ScreenshotOrbMenuAction {
  capture,
  dictionaryLookup,
  openMain,
  shortcutSettings,
  disableOrb,
  quit,
  dismiss,
}

/// The orb's native window stays compact during hover and expands only for its
/// context menu, whose popup must fit within the native window bounds.
enum ScreenshotOrbWindowMode { orb, contextMenu }

Size screenshotOrbWindowSizeForMode(ScreenshotOrbWindowMode mode) =>
    switch (mode) {
      ScreenshotOrbWindowMode.orb => const Size(
        ScreenshotOrbWindow.diameter,
        ScreenshotOrbWindow.diameter,
      ),
      ScreenshotOrbWindowMode.contextMenu => const Size(240, 360),
    };

final class ScreenshotOrbDisplay {
  const ScreenshotOrbDisplay(this.workArea, this.scale);
  final Rect workArea;
  final double scale;
}

final class ScreenshotOrbWindowLayout {
  const ScreenshotOrbWindowLayout({
    required this.origin,
    required this.physicalSize,
    required this.contentOffset,
  });

  final Offset origin;
  final Size physicalSize;
  final Offset contentOffset;
}

/// Keeps the orb at the same physical point while its native window resizes.
ScreenshotOrbWindowLayout layoutScreenshotOrbWindow({
  required Offset anchor,
  required Rect workArea,
  required double scale,
  required Size logicalSize,
}) {
  final physicalSize = logicalSize * scale;
  final maxLeft = (workArea.right - physicalSize.width)
      .clamp(workArea.left, double.infinity)
      .toDouble();
  final maxTop = (workArea.bottom - physicalSize.height)
      .clamp(workArea.top, double.infinity)
      .toDouble();
  final origin = Offset(
    anchor.dx.clamp(workArea.left, maxLeft).toDouble(),
    anchor.dy.clamp(workArea.top, maxTop).toDouble(),
  );
  return ScreenshotOrbWindowLayout(
    origin: origin,
    physicalSize: physicalSize,
    contentOffset: (anchor - origin) / scale,
  );
}

/// Input and output are physical pixels; diameter/margin are logical pixels.
Offset snapScreenshotOrb(Offset position, List<ScreenshotOrbDisplay> displays) {
  if (displays.isEmpty) return position;
  double distance(Rect area) {
    final x = position.dx.clamp(area.left, area.right),
        y = position.dy.clamp(area.top, area.bottom);
    return (position - Offset(x.toDouble(), y.toDouble())).distanceSquared;
  }

  final display = displays.reduce(
    (a, b) => distance(a.workArea) <= distance(b.workArea) ? a : b,
  );
  final area = display.workArea, scale = display.scale;
  final margin = 12 * scale, diameter = ScreenshotOrbWindow.diameter * scale;
  final left = area.left + margin, top = area.top + margin;
  final right = (area.right - margin - diameter)
      .clamp(left, double.infinity)
      .toDouble();
  final bottom = (area.bottom - margin - diameter)
      .clamp(top, double.infinity)
      .toDouble();
  final clamped = Offset(
    position.dx.clamp(left, right).toDouble(),
    position.dy.clamp(top, bottom).toDouble(),
  );
  final edges = [
    Offset(left, clamped.dy),
    Offset(right, clamped.dy),
    Offset(clamped.dx, top),
    Offset(clamped.dx, bottom),
  ];
  return edges.reduce(
    (a, b) => (a - position).distanceSquared <= (b - position).distanceSquared
        ? a
        : b,
  );
}

/// Pure child UI: business commands, position persistence and exit remain main.
class ScreenshotOrbWindow extends StatefulWidget {
  static const double diameter = 56;
  const ScreenshotOrbWindow({
    required this.onCapture,
    required this.onMenu,
    required this.onDrag,
    this.beforeMenu,
    this.afterMenu,
    super.key,
  });
  final VoidCallback onCapture;
  final ValueChanged<ScreenshotOrbMenuAction> onMenu;
  final Future<void> Function() onDrag;
  final Future<void> Function()? beforeMenu, afterMenu;
  @override
  State<ScreenshotOrbWindow> createState() => _OrbState();
}

class _OrbState extends State<ScreenshotOrbWindow>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final _ripple =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _captureFeedback = false);
        }
      });
  Timer? _feedbackTimer;
  Offset? _down;
  bool _dragged = false, _dragging = false, _pressed = false;
  bool _secondaryClickPending = false;
  bool _hover = false, _focused = false, _menuOpen = false;
  bool _captureFeedback = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion != _reduceMotion) {
      _reduceMotion = reduceMotion;
      _ripple.stop();
      _feedbackTimer?.cancel();
      _captureFeedback = false;
    }
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _ripple.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _capture() {
    _feedbackTimer?.cancel();
    setState(() => _captureFeedback = true);
    if (_reduceMotion) {
      // Keep a visible confirmation without spatial or opacity animation.
      _feedbackTimer = Timer(const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _captureFeedback = false);
      });
    } else {
      _ripple.forward(from: 0);
    }
    widget.onCapture();
  }

  void _cancelPointer() {
    _down = null;
    _secondaryClickPending = false;
    setState(() {
      _pressed = false;
      _dragging = false;
    });
  }

  Future<void> _drag() async {
    try {
      await widget.onDrag();
    } finally {
      if (mounted) setState(() => _dragging = false);
    }
  }

  Future<void> _menu() async {
    if (_menuOpen) return;
    final colors = Theme.of(context).colorScheme;
    _menuOpen = true;
    _cancelPointer();
    ScreenshotOrbMenuAction? action;
    try {
      await widget.beforeMenu?.call();
      if (!mounted) return;
      // Resizing the child window is asynchronous from Flutter's layout
      // pipeline. Wait for that layout to publish the expanded overlay before
      // computing the popup anchor and viewport bounds.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final box = context.findRenderObject()! as RenderBox;
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final anchor = Rect.fromLTWH(
        box.localToGlobal(Offset.zero, ancestor: overlay).dx,
        box.localToGlobal(Offset.zero, ancestor: overlay).dy,
        ScreenshotOrbWindow.diameter,
        ScreenshotOrbWindow.diameter,
      );
      action = await showMenu<ScreenshotOrbMenuAction>(
        context: context,
        position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
        popUpAnimationStyle: _reduceMotion ? AnimationStyle.noAnimation : null,
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: colors.outlineVariant),
        ),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 240),
        clipBehavior: Clip.antiAlias,
        items: [
          _menuItem(
            action: ScreenshotOrbMenuAction.capture,
            label: '截屏翻译',
            icon: Icons.crop_free_rounded,
            emphasis: true,
          ),
          _menuItem(
            action: ScreenshotOrbMenuAction.dictionaryLookup,
            label: '划词查词',
            icon: Icons.menu_book_outlined,
          ),
          _menuItem(
            action: ScreenshotOrbMenuAction.openMain,
            label: '打开译学工作台',
            icon: Icons.dashboard_outlined,
          ),
          const PopupMenuDivider(height: 8),
          _menuItem(
            action: ScreenshotOrbMenuAction.shortcutSettings,
            label: '快捷键设置',
            icon: Icons.keyboard_alt_outlined,
            brandAccent: true,
          ),
          const PopupMenuDivider(height: 8),
          _menuItem(
            action: ScreenshotOrbMenuAction.disableOrb,
            label: '关闭悬浮球',
            icon: Icons.visibility_off_outlined,
            subdued: true,
          ),
          _menuItem(
            action: ScreenshotOrbMenuAction.quit,
            label: '退出译学',
            icon: Icons.power_settings_new_rounded,
            destructive: true,
          ),
          const PopupMenuDivider(height: 8),
          _menuItem(
            action: ScreenshotOrbMenuAction.dismiss,
            label: '收起菜单',
            icon: Icons.close_rounded,
            subdued: true,
          ),
        ],
      );
    } finally {
      try {
        await widget.afterMenu?.call();
      } catch (_) {
        // Viewport cleanup cannot veto an already selected business command.
      } finally {
        _menuOpen = false;
        if (mounted) {
          _cancelPointer();
        }
      }
    }
    if (mounted &&
        action != null &&
        action != ScreenshotOrbMenuAction.dismiss) {
      widget.onMenu(action);
    }
  }

  PopupMenuItem<ScreenshotOrbMenuAction> _menuItem({
    required ScreenshotOrbMenuAction action,
    required String label,
    required IconData icon,
    bool emphasis = false,
    bool brandAccent = false,
    bool subdued = false,
    bool destructive = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final palette = YixueShellPalette.of(context);
    final green = palette.isCustomTheme
        ? palette.selectedEnd
        : YixueShellPalette.vitality.selectedEnd;
    final tileColor = destructive
        ? colors.errorContainer.withValues(alpha: 0.58)
        : emphasis
        ? colors.primaryContainer
        : brandAccent
        ? Color.alphaBlend(green.withValues(alpha: 0.15), colors.surface)
        : colors.surfaceContainerHighest.withValues(alpha: 0.72);
    final foreground = destructive
        ? colors.error
        : subdued
        ? colors.onSurfaceVariant
        : emphasis || !brandAccent
        ? colors.primary
        : colors.onSurface;
    final textColor = destructive
        ? colors.error
        : emphasis
        ? colors.primary
        : colors.onSurface;

    return PopupMenuItem<ScreenshotOrbMenuAction>(
      key: ValueKey('screenshot-orb-menu-${action.name}'),
      value: action,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: foreground),
          ),
          const SizedBox(width: 11),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: emphasis ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = YixueShellPalette.of(context);
    final accent = palette.isCustomTheme
        ? palette.selectedEnd
        : YixueShellPalette.vitality.selectedEnd;
    final hoverDuration = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final pressDuration = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 90);
    return Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
      },
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent && !_menuOpen) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _cancelPointer();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            _capture();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        key: const ValueKey('orb-pointer-region'),
        opaque: false,
        cursor: _dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Semantics(
          key: const ValueKey('orb-capture-semantics'),
          label: '截屏翻译',
          button: true,
          onTap: _capture,
          child: Listener(
            behavior: HitTestBehavior.deferToChild,
            onPointerDown: (event) {
              if ((event.buttons & kSecondaryMouseButton) != 0) {
                _down = null;
                _secondaryClickPending = true;
                return;
              }
              if (event.buttons == kPrimaryMouseButton) {
                if (_menuOpen) return;
                _focus.requestFocus();
                _down = event.position;
                _dragged = false;
                setState(() => _pressed = true);
              }
            },
            onPointerMove: (event) {
              if (_down != null &&
                  !_dragged &&
                  (event.position - _down!).distance >= 5) {
                _dragged = true;
                setState(() {
                  _dragging = true;
                  _pressed = false;
                });
                unawaited(_drag());
              }
            },
            onPointerUp: (event) {
              if (_secondaryClickPending) {
                _secondaryClickPending = false;
                unawaited(_menu());
                return;
              }
              final capture = _down != null && !_dragged;
              _cancelPointer();
              if (capture) _capture();
            },
            onPointerCancel: (_) {
              _cancelPointer();
            },
            child: Container(
              key: const ValueKey('screenshot-orb'),
              width: ScreenshotOrbWindow.diameter,
              height: ScreenshotOrbWindow.diameter,
              decoration: const BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(2),
                    child: AnimatedScale(
                      key: const ValueKey('orb-hover-scale'),
                      scale: _hover && !_dragging ? 1.07 : 1,
                      duration: hoverDuration,
                      curve: Curves.easeOutCubic,
                      child: AnimatedScale(
                        key: const ValueKey('orb-press-scale'),
                        scale: _pressed ? 0.91 : 1,
                        duration: pressDuration,
                        curve: Curves.easeOutCubic,
                        child: AnimatedContainer(
                          key: const ValueKey('orb-surface'),
                          duration: hoverDuration,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [colors.primary, accent],
                            ),
                            border: Border.all(
                              color: _focused
                                  ? colors.surface
                                  : (_hover || _pressed || _dragging)
                                  ? Colors.white
                                  : colors.onPrimary.withValues(alpha: 0.65),
                              width: _focused || _pressed || _dragging
                                  ? 2.5
                                  : _hover
                                  ? 2.25
                                  : 1.5,
                            ),
                            // Keep all feedback inside the orb window. A
                            // blurred BoxShadow expands into the desktop and
                            // reads as a dark patch after keyboard focus.
                            boxShadow: const [],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              IgnorePointer(
                                child: AnimatedOpacity(
                                  key: const ValueKey('orb-hover-highlight'),
                                  opacity: _hover && !_dragging ? 1 : 0,
                                  duration: hoverDuration,
                                  curve: Curves.easeOutCubic,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: RadialGradient(
                                        center: const Alignment(-0.45, -0.55),
                                        radius: 1.15,
                                        colors: [
                                          Colors.white.withValues(alpha: 0.32),
                                          Colors.white.withValues(alpha: 0.05),
                                          Colors.transparent,
                                        ],
                                        stops: const [0, 0.52, 1],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                child: AnimatedOpacity(
                                  key: const ValueKey('orb-press-highlight'),
                                  opacity: _pressed ? 0.18 : 0,
                                  duration: pressDuration,
                                  curve: Curves.easeOutCubic,
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              Center(
                                child: Image.asset(
                                  YixueBrandMark.assetPath,
                                  key: const ValueKey('orb-brand'),
                                  width: 36,
                                  height: 36,
                                  excludeFromSemantics: true,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_captureFeedback)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _ripple,
                          builder: (_, _) {
                            final progress = _reduceMotion
                                ? 0.42
                                : _ripple.value;
                            return ClipOval(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Opacity(
                                    key: const ValueKey('orb-capture-flash'),
                                    opacity: _reduceMotion
                                        ? 0.2
                                        : 0.22 * (1 - progress),
                                    child: const ColoredBox(
                                      color: Colors.white,
                                    ),
                                  ),
                                  Center(
                                    child: Opacity(
                                      key: const ValueKey('orb-capture-ripple'),
                                      opacity: _reduceMotion ? 1 : 1 - progress,
                                      child: Transform.scale(
                                        key: const ValueKey(
                                          'orb-capture-ring-scale',
                                        ),
                                        scale: 0.4 + 0.6 * progress,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2.2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
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
