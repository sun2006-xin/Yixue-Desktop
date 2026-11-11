import 'package:flutter/material.dart';

class YixueBrandMark extends StatelessWidget {
  const YixueBrandMark({super.key, this.progress = 1});

  static const assetPath = 'assets/brand/yixue-logo-master-v3.png';

  final double progress;

  @override
  Widget build(BuildContext context) {
    final reveal = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0));
    return Semantics(
      label: '译学标志',
      image: true,
      child: Stack(
        key: const ValueKey('yixue-brand-mark'),
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0.16 * reveal,
            child: Transform.scale(
              scale: 0.84 + (0.12 * reveal),
              child: Image.asset(
                assetPath,
                excludeFromSemantics: true,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
          ClipRect(
            clipper: _BrandRevealClipper(reveal),
            child: Image.asset(
              assetPath,
              key: const ValueKey('yixue-brand-master-image'),
              excludeFromSemantics: true,
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
            ),
          ),
          if (reveal > 0 && reveal < 1)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _WritingGlintPainter(progress: reveal),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BrandRevealClipper extends CustomClipper<Rect> {
  const _BrandRevealClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) {
    final eased = Curves.easeInOutCubic.transform(progress);
    final width = size.width * eased;
    final height = size.height * (0.48 + (0.52 * eased));
    return Rect.fromLTWH(0, size.height - height, width, height);
  }

  @override
  bool shouldReclip(covariant _BrandRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

class _WritingGlintPainter extends CustomPainter {
  const _WritingGlintPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final travel = Curves.easeInOut.transform(progress);
    final x = size.width * (0.14 + (travel * 0.72));
    final y = size.height * (0.66 - (travel * 0.34));
    final glow = Paint()
      ..shader =
          const RadialGradient(colors: [Color(0xD9FFFFFF), Color(0x0015CFE0)])
              .createShader(
                Rect.fromCircle(center: Offset(x, y), radius: size.width * 0.1),
              );
    canvas.drawCircle(Offset(x, y), size.width * 0.1, glow);
  }

  @override
  bool shouldRepaint(covariant _WritingGlintPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
