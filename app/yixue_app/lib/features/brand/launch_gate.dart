import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';

enum YixueLaunchVariant { full, compact }

@immutable
class YixueLaunchPresentation {
  const YixueLaunchPresentation({
    this.motionLevel = YixueMotionLevel.full,
    this.variant = YixueLaunchVariant.full,
  });

  final YixueMotionLevel motionLevel;
  final YixueLaunchVariant variant;
}

class LaunchGate extends StatefulWidget {
  const LaunchGate({
    required this.motionLevel,
    required this.child,
    this.variant = YixueLaunchVariant.full,
    super.key,
  });

  final YixueMotionLevel motionLevel;
  final YixueLaunchVariant variant;
  final Widget child;

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Stopwatch? _elapsed;
  var _showOverlay = false;
  var _assetPrecacheRequested = false;

  @override
  void initState() {
    super.initState();
    if (widget.motionLevel != YixueMotionLevel.off) _startAnimation();
  }

  @override
  void didUpdateWidget(covariant LaunchGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.motionLevel == YixueMotionLevel.off) {
      _controller?.stop();
      _elapsed?.stop();
      _showOverlay = false;
      return;
    }
    if (oldWidget.motionLevel == YixueMotionLevel.off) {
      _startAnimation();
      return;
    }
    if (_targetDuration(oldWidget) != _targetDuration(widget)) {
      _retimeAnimation();
    }
  }

  Duration _targetDuration(LaunchGate config) => switch (config.motionLevel) {
    YixueMotionLevel.reduced => const Duration(milliseconds: 250),
    YixueMotionLevel.full =>
      config.variant == YixueLaunchVariant.full
          ? const Duration(milliseconds: 5600)
          : const Duration(milliseconds: 3600),
    YixueMotionLevel.off => Duration.zero,
  };

  void _startAnimation() {
    _controller?.dispose();
    _showOverlay = true;
    _elapsed = Stopwatch()..start();
    _controller =
        AnimationController(vsync: this, duration: _targetDuration(widget))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              _elapsed?.stop();
              setState(() => _showOverlay = false);
            }
          })
          ..forward();
  }

  void _retimeAnimation() {
    final controller = _controller;
    if (controller == null || !_showOverlay) return;
    final remaining =
        _targetDuration(widget) - (_elapsed?.elapsed ?? Duration.zero);
    if (remaining <= Duration.zero) {
      controller.stop();
      _elapsed?.stop();
      _showOverlay = false;
      return;
    }
    final progress = controller.value.clamp(0.0, 0.999999).toDouble();
    final remainingProgress = 1 - progress;
    final newDuration = Duration(
      milliseconds: (remaining.inMilliseconds / remainingProgress).round(),
    );
    controller
      ..stop()
      ..duration = newDuration
      ..forward(from: progress);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null || _assetPrecacheRequested) return;
    _assetPrecacheRequested = true;
    precacheImage(const AssetImage(YixueBrandMark.assetPath), context);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_showOverlay)
            AnimatedBuilder(
              animation: _controller!,
              builder: (context, _) => LaunchBrandSurface(
                progress: _controller!.value,
                reduced: widget.motionLevel == YixueMotionLevel.reduced,
              ),
            ),
        ],
      ),
    );
  }
}

class LaunchBrandSurface extends StatelessWidget {
  const LaunchBrandSurface({
    required this.progress,
    required this.reduced,
    super.key,
  });

  final double progress;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final markProgress = reduced ? 1.0 : _interval(progress, 0.04, 0.42);
    final titleOpacity = reduced
        ? progress
        : Curves.easeOut.transform(_interval(progress, 0.38, 0.52));
    final sloganOpacity = reduced
        ? progress
        : Curves.easeOut.transform(_interval(progress, 0.47, 0.62));
    final overlayOpacity = reduced ? 1.0 : 1 - _interval(progress, 0.93, 1);
    return Opacity(
      opacity: overlayOpacity,
      child: DecoratedBox(
        key: const ValueKey('launch-overlay'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF031D31), Color(0xFF03475A), Color(0xFF087866)],
            stops: [0, 0.58, 1],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _LaunchAtmosphere(),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    key: const ValueKey('launch-brand-mark'),
                    width: 284,
                    height: 284,
                    child: RepaintBoundary(
                      child: YixueBrandMark(progress: markProgress),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Opacity(
                    opacity: titleOpacity,
                    child: const Text(
                      '译学',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 42,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        height: 1.1,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Opacity(
                    opacity: sloganOpacity,
                    child: const Text(
                      '让世界，可以理解',
                      style: TextStyle(
                        color: Color(0xFFD7E8E7),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 6,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _interval(double value, double begin, double end) =>
      ((value - begin) / (end - begin)).clamp(0.0, 1.0);
}

class _LaunchAtmosphere extends StatelessWidget {
  const _LaunchAtmosphere();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.18, -0.16),
            radius: 0.72,
            colors: [Color(0x2438DFAE), Color(0x00031D31)],
          ),
        ),
      ),
    );
  }
}
