import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The brand mark: one thick ring, a solid knob, the gold index (docs/ui.md).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100;
    final c = Offset(50 * s, 50 * s);
    canvas.drawCircle(
      c,
      34 * s,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12 * s,
    );
    canvas.drawCircle(c, 12 * s, Paint()..color = color);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(46 * s, 4 * s, 8 * s, 18 * s), Radius.circular(4 * s)),
      Paint()..color = Brand.gold,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// Lock-screen background: a fixed illustration of protected items (photos, an ID,
/// a receipt, a document), tilted and blurred, under a vault-green veil. Never the
/// user's data: this screen runs while every vault is locked.
class VaultBackdrop extends StatelessWidget {
  const VaultBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Brand.deep),
        RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Opacity(opacity: 0.5, child: CustomPaint(painter: _CollagePainter())),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB80F3D33), Color(0xE60F3D33), Brand.deep],
              stops: [0, .45, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _CollagePainter extends CustomPainter {
  static const _fills = [
    [Color(0xFFFFFFFF)],
    [Color(0xFFCFE0EA), Color(0xFF7FA79A)],
    [Color(0xFFDCE6F2)],
    [Color(0xFFF1E6D6)],
    [Color(0xFFCFE0EA), Color(0xFF4E7F70)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-8 * math.pi / 180);
    const w = 120.0, h = 130.0, gap = 12.0;
    final cols = (size.width / (w + gap)).ceil() + 3;
    final rows = (size.height / (h + gap)).ceil() + 3;
    var n = 0;
    for (var r = -rows ~/ 2; r <= rows ~/ 2; r++) {
      for (var c = -cols ~/ 2; c <= cols ~/ 2; c++) {
        final rect = Rect.fromLTWH(c * (w + gap), r * (h + gap), w, h);
        final f = _fills[n++ % _fills.length];
        final paint = Paint();
        if (f.length == 1) {
          paint.color = f[0];
        } else {
          paint.shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [f[0], f[0], f[1]],
            stops: const [0, .55, .55],
          ).createShader(rect);
        }
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(14)), paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CollagePainter old) => false;
}

/// The moment a vault opens (or closes): a green overlay, the brand mark large in the
/// middle turns half a turn and scales out (opening) or in (closing). `onCovered` runs
/// while the overlay hides everything, which is when the caller switches screens.
Future<void> playVaultSpin(BuildContext context, {required bool opening, required VoidCallback onCovered}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final controller = AnimationController(
    vsync: overlay,
    duration: Duration(milliseconds: opening ? 1150 : 1050),
  );
  final entry = OverlayEntry(builder: (_) => _Spin(controller: controller, opening: opening, reduce: reduce));
  overlay.insert(entry);
  var covered = false;
  void check() {
    if (!covered && controller.value >= (opening ? .62 : .25)) {
      covered = true;
      onCovered();
    }
  }

  controller.addListener(check);
  await controller.forward();
  if (!covered) onCovered();
  entry.remove();
  controller.dispose();
}

class _Spin extends AnimatedWidget {
  const _Spin({required AnimationController controller, required this.opening, required this.reduce})
      : super(listenable: controller);

  final bool opening;
  final bool reduce;

  double get t => (listenable as AnimationController).value;

  static double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final ease = Curves.easeInOutCubic;
    double bg, scale, turn, alpha;
    if (opening) {
      bg = t < .14 ? _seg(t, 0, .14) : (t < .78 ? 1 : 1 - _seg(t, .78, 1));
      scale = t < .16 ? .55 + .45 * ease.transform(_seg(t, 0, .16)) : (t < .78 ? 1 : 1 + 1.6 * ease.transform(_seg(t, .78, 1)));
      turn = t < .16 ? 0 : (t < .62 ? 192 * ease.transform(_seg(t, .16, .62)) : 192 - 12 * _seg(t, .62, .70));
      alpha = t < .78 ? 1 : 1 - _seg(t, .78, 1);
    } else {
      bg = t < .18 ? _seg(t, 0, .18) : (t < .80 ? 1 : 1 - _seg(t, .80, 1));
      scale = t < .20 ? 2.6 - 1.6 * ease.transform(_seg(t, 0, .20)) : (t < .82 ? 1 : 1 - .45 * _seg(t, .82, 1));
      turn = t < .20 ? 180 : (t < .62 ? 180 - 192 * ease.transform(_seg(t, .20, .62)) : -12 + 12 * _seg(t, .62, .70));
      alpha = t < .20 ? _seg(t, 0, .20) : (t < .82 ? 1 : 1 - _seg(t, .82, 1));
    }
    if (reduce) {
      scale = 1;
      turn = opening ? 180 : 0;
    }
    return IgnorePointer(
      child: Opacity(
        opacity: bg.clamp(0.0, 1.0),
        child: ColoredBox(
          color: Brand.deep,
          child: Center(
            child: Opacity(
              opacity: alpha.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: turn * math.pi / 180,
                child: Transform.scale(scale: scale, child: const BrandMark(size: 190, color: Colors.white)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
