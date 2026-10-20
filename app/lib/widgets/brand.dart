import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';


/// The brand mark: one thick ring, a solid knob, the index (docs/ui.md). One ink; the
/// index is the same ink, lighter.
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
      Paint()..color = color.withValues(alpha: .55),
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// Lock-screen background: a fixed illustration of protected items (photos, an ID,
/// a receipt, a document) in greys, tilted and blurred, under a veil of the page colour.
/// Never the user's data: this screen runs while every vault is locked.
class VaultBackdrop extends StatelessWidget {
  const VaultBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(duration: const Duration(milliseconds: 350), color: tint),
        RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Opacity(opacity: 0.5, child: CustomPaint(painter: _CollagePainter())),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [tint.withValues(alpha: .72), tint.withValues(alpha: .9), tint],
              stops: const [0, .45, 1],
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
    [Color(0xFFDADADA), Color(0xFF8C8C8C)],
    [Color(0xFFE6E6E6)],
    [Color(0xFFEFEFEF)],
    [Color(0xFFDADADA), Color(0xFF6E6E6E)],
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

/// The moment a vault opens (or closes): an overlay in the page colour, the brand mark large in the
/// middle turns half a turn and scales out (opening) or in (closing). `onCovered` runs
/// while the overlay hides everything, which is when the caller switches screens.
Future<void> playVaultSpin(
  BuildContext context, {
  required bool opening,
  required VoidCallback onCovered,
}) async {
  // The page colour with the mark in ink: black and white, light or dark.
  final color = Theme.of(context).scaffoldBackgroundColor;
  final ink = Theme.of(context).colorScheme.onSurface;
  final overlay = Overlay.of(context, rootOverlay: true);
  final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final controller = AnimationController(
    vsync: overlay,
    duration: Duration(milliseconds: opening ? 1150 : 1050),
  );
  final entry = OverlayEntry(builder: (_) => _Spin(controller: controller, opening: opening, reduce: reduce, color: color, ink: ink));
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
  const _Spin({
    required AnimationController controller,
    required this.opening,
    required this.reduce,
    required this.color,
    required this.ink,
  }) : super(listenable: controller);

  final bool opening;
  final bool reduce;
  final Color color;
  final Color ink;

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
          color: color,
          child: Center(
            child: Opacity(
              opacity: alpha.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: turn * math.pi / 180,
                child: Transform.scale(scale: scale, child: BrandMark(size: 190, color: ink)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Face ID glyph as people know it from iPhone (four corner brackets, eyes, nose,
/// smile), drawn here because Flutter cannot use SF Symbols. Fingerprint devices use
/// [Icons.fingerprint] instead (see [BiometricGlyph]).
class FaceIdGlyph extends StatelessWidget {
  const FaceIdGlyph({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _FaceIdPainter(color ?? IconTheme.of(context).color ?? Colors.white),
      );
}

class _FaceIdPainter extends CustomPainter {
  _FaceIdPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path corner(double x, double y, double dx, double dy) => Path()
      ..moveTo(x, y + dy * 4 * s)
      ..lineTo(x, y + dy * 1.6 * s)
      ..quadraticBezierTo(x, y, x + dx * 1.6 * s, y)
      ..lineTo(x + dx * 4 * s, y);
    final a = 2.5 * s, b = 21.5 * s;
    for (final c in [corner(a, a, 1, 1), corner(b, a, -1, 1), corner(a, b, 1, -1), corner(b, b, -1, -1)]) {
      canvas.drawPath(c, p);
    }
    canvas.drawLine(Offset(8.5 * s, 8.6 * s), Offset(8.5 * s, 10.2 * s), p);
    canvas.drawLine(Offset(15.5 * s, 8.6 * s), Offset(15.5 * s, 10.2 * s), p);
    canvas.drawPath(
      Path()
        ..moveTo(12 * s, 8.6 * s)
        ..lineTo(12 * s, 12.8 * s)
        ..lineTo(11 * s, 12.8 * s),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(8.6 * s, 15.6 * s)
        ..quadraticBezierTo(12 * s, 18.2 * s, 15.4 * s, 15.6 * s),
      p,
    );
  }

  @override
  bool shouldRepaint(_FaceIdPainter old) => old.color != color;
}

/// The lock in the dock (option B, chosen 19.10.2026): a soft square body with a
/// keyhole cut through it, under a thick shackle. Drawn so it matches the dial.
class LockGlyph extends StatelessWidget {
  const LockGlyph({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _LockPainter(color ?? IconTheme.of(context).color ?? Colors.white),
      );
}

class _LockPainter extends CustomPainter {
  _LockPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final shackle = Path()
      ..moveTo(8 * s, 11 * s)
      ..lineTo(8 * s, 8.2 * s)
      ..arcToPoint(Offset(16 * s, 8.2 * s), radius: Radius.circular(4 * s))
      ..lineTo(16 * s, 11 * s);
    canvas.drawPath(
      shackle,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 * s
        ..strokeCap = StrokeCap.round,
    );
    final body = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(4 * s, 10.5 * s, 16 * s, 11 * s), Radius.circular(2.5 * s)));
    final hole = Path()
      ..addOval(Rect.fromCircle(center: Offset(12 * s, 15.1 * s), radius: 1.7 * s))
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(11 * s, 15.5 * s, 2 * s, 2.5 * s), Radius.circular(.5 * s)));
    canvas.drawPath(Path.combine(PathOperation.difference, body, hole), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LockPainter old) => old.color != color;
}
