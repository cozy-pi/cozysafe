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

/// The hand-over from the system's launch screen (the page colour and the dial in the
/// middle, 120 pt: ios/Runner LaunchScreen, android launch_background / splash_icon) to
/// the first screen: the first frame looks exactly like the launch screen, then the dial
/// shrinks and fades while the page under it shows through (owner 2026-10-21: the jump
/// from the plain splash to the detailed lock screen felt abrupt). Cold start only.
class LaunchHandoff extends StatefulWidget {
  const LaunchHandoff({super.key, required this.child});
  final Widget child;

  static bool _played = false;
  @visibleForTesting
  static void debugReset() {
    _played = false;
    _running = false;
  }

  /// Mockups: hold the first frame until [debugGo], so a shot can freeze a moment.
  @visibleForTesting
  static bool debugHold = false;
  static final _go = ChangeNotifier();
  @visibleForTesting
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  static void debugGo() => _go.notifyListeners();

  /// Where the system launch screen's dial sits, in logical pixels.
  static const dial = 120.0;

  /// The first screen's own dial, if it has one (the lock screen): the splash dial flies
  /// onto it and becomes it; otherwise it shrinks away.
  static final target = GlobalKey(debugLabel: 'launch-target');

  /// True only while the hand-over plays: screens put [target] on their dial then, never
  /// later, so two screens can never hold the one key.
  static bool get running => _running;
  static bool _running = false;

  @override
  State<LaunchHandoff> createState() => _LaunchHandoffState();
}

class _LaunchHandoffState extends State<LaunchHandoff> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  void _start() => _c?.forward();

  @override
  void initState() {
    super.initState();
    // Decide before marking it played: only the very first screen gets the hand-over.
    if (!LaunchHandoff._played) {
      _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
      LaunchHandoff._running = true;
    }
    LaunchHandoff._played = true;
    if (LaunchHandoff.debugHold) {
      LaunchHandoff._go.addListener(_start);
    } else {
      _start();
    }
    _c?.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        LaunchHandoff._running = false;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    LaunchHandoff._go.removeListener(_start);
    if (_c != null) LaunchHandoff._running = false;
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || c.isCompleted) return widget.child;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    final veil = CurvedAnimation(parent: c, curve: const Interval(.15, .85, curve: Curves.easeOut));
    final fly = CurvedAnimation(parent: c, curve: const Interval(0, .85, curve: Curves.easeInOutCubic));
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, box) => AnimatedBuilder(
                animation: c,
                builder: (context, _) {
                  final start = Rect.fromCenter(center: box.biggest.center(Offset.zero), width: LaunchHandoff.dial, height: LaunchHandoff.dial);
                  // The target's place, in this overlay's coordinates.
                  final here = context.findRenderObject() as RenderBox?;
                  final t = LaunchHandoff.target.currentContext?.findRenderObject() as RenderBox?;
                  final end = (t != null && here != null && t.attached && here.attached)
                      ? here.globalToLocal(t.localToGlobal(Offset.zero)) & t.size
                      : null;
                  final at = end == null ? start : Rect.lerp(start, end, fly.value)!;
                  // With a target the dial lands and hands over; without, it fades.
                  final markOpacity = end == null ? 1 - fly.value : (c.value < .85 ? 1.0 : (1 - (c.value - .85) / .15));
                  return Stack(children: [
                    Positioned.fill(child: ColoredBox(color: page.withValues(alpha: 1 - veil.value))),
                    Positioned.fromRect(
                      rect: at,
                      child: Opacity(
                        opacity: markOpacity.clamp(0, 1),
                        child: BrandMark(size: at.width, color: ink),
                      ),
                    ),
                  ]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
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

/// Lock-screen background: a fixed illustration of the things a vault keeps (photos, an
/// ID card, a receipt, notes, a PDF, a passport), tilted and softly blurred under a veil
/// of the page colour. Drawn in the theme's own greys (2026-10-21: light shapes on the
/// dark theme showed as bright patches). Never the user's data: this screen runs while
/// every vault is locked.
class VaultBackdrop extends StatelessWidget {
  const VaultBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).scaffoldBackgroundColor;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(duration: const Duration(milliseconds: 350), color: tint),
        RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5),
            child: Opacity(opacity: dark ? .85 : .6, child: CustomPaint(painter: _CollagePainter(dark: dark))),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Deeper down the page, fully covering its lower half (owner 2026-10-28,
              // was an even veil): the picture shows on top, the keys sit on plain colour.
              colors: [tint.withValues(alpha: .55), tint.withValues(alpha: .8), tint, tint],
              stops: const [0, .3, .5, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Columns of cards of different kinds and heights, like a pinboard.
class _CollagePainter extends CustomPainter {
  _CollagePainter({required this.dark});
  final bool dark;

  // The theme's greys: card, line, accent, deep.
  Color get _card => dark ? const Color(0xFF2B2D31) : const Color(0xFFFFFFFF);
  Color get _line => dark ? const Color(0xFF4A4D54) : const Color(0xFFC9CDD3);
  Color get _soft => dark ? const Color(0xFF383B41) : const Color(0xFFE6E8EC);
  Color get _deep => dark ? const Color(0xFF55585F) : const Color(0xFF8E939B);

  // Everything a vault keeps (owner 2026-10-24: not only landscapes): photos of several
  // kinds, videos, passwords, keys and codes, notes, documents, cards, voice.
  static const _kinds = [
    'portrait', 'password', 'pdf', 'video', 'key', 'note', 'sunset', 'id', 'voice', 'grid',
    'qr', 'receipt', 'video', 'password', 'portrait', 'note', 'passport', 'key', 'pdf', 'sunset',
  ];
  static const _heights = {
    'portrait': 132.0, 'sunset': 96.0, 'grid': 118.0, 'video': 92.0, 'password': 70.0, 'key': 88.0,
    'qr': 118.0, 'voice': 66.0, 'id': 78.0, 'receipt': 168.0, 'note': 128.0, 'pdf': 150.0, 'passport': 140.0,
  };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-8 * math.pi / 180);
    const w = 118.0, gap = 12.0;
    final half = math.max(size.width, size.height) * .8;
    final cols = (half * 2 / (w + gap)).ceil();
    var n = 0;
    for (var c = 0; c < cols; c++) {
      final x = -half + c * (w + gap);
      // Each column starts at its own height, so rows do not line up.
      var y = -half - (c * 47 % 130);
      while (y < half) {
        final kind = _kinds[(n++ * 7 + c) % _kinds.length];
        final h = _heights[kind]!;
        _draw(canvas, kind, Rect.fromLTWH(x, y, w, h));
        y += h + gap;
      }
    }
    canvas.restore();
  }

  void _draw(Canvas canvas, String kind, Rect r) {
    final fill = Paint()..color = _card;
    final line = Paint()..color = _line;
    final soft = Paint()..color = _soft;
    final deep = Paint()..color = _deep;
    RRect round(Rect x, double rad) => RRect.fromRectAndRadius(x, Radius.circular(rad));
    void bar(double dx, double dy, double len, {Paint? p, double t = 6}) =>
        canvas.drawRRect(round(Rect.fromLTWH(r.left + dx, r.top + dy, len, t), t / 2), p ?? line);

    switch (kind) {
      case 'portrait':
        // A photo of someone: head and shoulders.
        canvas.drawRRect(round(r, 12), soft);
        canvas.save();
        canvas.clipRRect(round(r, 12));
        canvas.drawCircle(Offset(r.center.dx, r.top + r.height * .40), 20, deep);
        canvas.drawOval(Rect.fromCenter(center: Offset(r.center.dx, r.bottom + 8), width: 92, height: 76), deep);
        canvas.restore();
      case 'sunset':
        // A sun sitting on the sea.
        canvas.drawRRect(round(r, 12), soft);
        canvas.save();
        canvas.clipRRect(round(r, 12));
        canvas.drawCircle(Offset(r.center.dx, r.top + r.height * .62), 22, fill);
        canvas.drawRect(Rect.fromLTRB(r.left, r.top + r.height * .62, r.right, r.bottom), deep);
        for (var i = 0; i < 3; i++) {
          bar(26.0 + i * 8, r.height * .72 + i * 8, 66 - i * 16.0, p: soft, t: 4);
        }
        canvas.restore();
      case 'grid':
        // An album: four small pictures.
        canvas.drawRRect(round(r, 12), fill);
        const pad = 8.0, gap = 6.0;
        final cw = (r.width - pad * 2 - gap) / 2, ch = (r.height - pad * 2 - gap) / 2;
        for (var i = 0; i < 4; i++) {
          final cell = Rect.fromLTWH(r.left + pad + (i % 2) * (cw + gap), r.top + pad + (i ~/ 2) * (ch + gap), cw, ch);
          canvas.drawRRect(round(cell, 7), i == 1 || i == 2 ? deep : soft);
        }
      case 'video':
        // A frame with a play button and a progress bar.
        canvas.drawRRect(round(r, 12), deep);
        final c = Offset(r.center.dx, r.top + r.height * .44);
        canvas.drawCircle(c, 18, soft);
        canvas.drawPath(
            Path()
              ..moveTo(c.dx - 5, c.dy - 9)
              ..lineTo(c.dx + 10, c.dy)
              ..lineTo(c.dx - 5, c.dy + 9)
              ..close(),
            deep);
        bar(12, r.height - 16, r.width - 24, p: soft, t: 4);
        bar(12, r.height - 16, (r.width - 24) * .4, p: fill, t: 4);
      case 'password':
        // A password field: dots, and the key beside them.
        canvas.drawRRect(round(r, 12), fill);
        bar(12, 12, 52, p: deep, t: 7);
        canvas.drawRRect(round(Rect.fromLTWH(r.left + 10, r.top + 30, r.width - 20, 28), 8), soft);
        for (var i = 0; i < 7; i++) {
          canvas.drawCircle(Offset(r.left + 22 + i * 11.0, r.top + 44), 3.2, deep);
        }
      case 'key':
        // A key, and a recovery code in groups.
        canvas.drawRRect(round(r, 12), fill);
        final k = Offset(r.left + 26, r.top + 28);
        canvas.drawCircle(k, 12, deep);
        canvas.drawCircle(k, 5, fill);
        bar(36, 25, 52, p: deep, t: 6);
        bar(74, 29, 6, p: deep, t: 12);
        bar(62, 29, 6, p: deep, t: 9);
        for (var i = 0; i < 4; i++) {
          bar(12.0 + i * 25, 56, 20, p: soft, t: 6);
          bar(12.0 + i * 25, 68, 20, p: soft, t: 6);
        }
      case 'qr':
        // A code to scan.
        canvas.drawRRect(round(r, 12), fill);
        final q = Rect.fromLTWH(r.left + 14, r.top + 14, r.width - 28, r.width - 28);
        final cell = q.width / 9;
        for (var y = 0; y < 9; y++) {
          for (var x = 0; x < 9; x++) {
            final corner = (x < 3 && y < 3) || (x > 5 && y < 3) || (x < 3 && y > 5);
            final on = corner ? (x % 6 != 1 || y % 6 != 1) && !(x % 6 == 1 && y % 6 == 1) : ((x * 7 + y * 3) % 5 < 2);
            if (on) canvas.drawRect(Rect.fromLTWH(q.left + x * cell, q.top + y * cell, cell * .9, cell * .9), deep);
          }
        }
      case 'voice':
        // A recording: a wave.
        canvas.drawRRect(round(r, 12), fill);
        canvas.drawCircle(Offset(r.left + 20, r.center.dy), 10, deep);
        for (var i = 0; i < 12; i++) {
          final h = 8.0 + ((i * 37) % 23);
          canvas.drawRRect(
              round(Rect.fromCenter(center: Offset(r.left + 40 + i * 6.0, r.center.dy), width: 3.5, height: h), 2), soft);
        }
      case 'id':
        canvas.drawRRect(round(r, 10), fill);
        canvas.drawRRect(round(Rect.fromLTWH(r.left + 10, r.top + 12, 34, 44), 6), soft);
        canvas.drawCircle(Offset(r.left + 27, r.top + 28), 8, deep);
        canvas.drawRRect(round(Rect.fromLTWH(r.left + 15, r.top + 40, 24, 14), 7), deep);
        bar(52, 16, 54);
        bar(52, 30, 40, p: soft);
        bar(52, 44, 48, p: soft);
        bar(10, 64, 98, p: soft, t: 5);
      case 'receipt':
        final body = Path()..moveTo(r.left, r.top);
        body.lineTo(r.right, r.top);
        body.lineTo(r.right, r.bottom - 6);
        for (var x = r.right; x > r.left; x -= 12) {
          body.lineTo(x - 6, r.bottom);
          body.lineTo(x - 12, r.bottom - 6);
        }
        body.close();
        canvas.drawPath(body, fill);
        bar(30, 14, 58, p: deep, t: 7);
        for (var i = 0; i < 6; i++) {
          bar(12, 36.0 + i * 16, 50, p: soft, t: 5);
          bar(84, 36.0 + i * 16, 22, t: 5);
        }
        bar(12, 138, 94, p: deep, t: 7);
      case 'note':
        canvas.drawRRect(round(r, 12), fill);
        bar(12, 14, 70, p: deep, t: 8);
        for (var i = 0; i < 6; i++) {
          bar(12, 36.0 + i * 14, i == 5 ? 46 : 94, p: soft, t: 5);
        }
      case 'pdf':
        final fold = Path()
          ..moveTo(r.left + 12, r.top)
          ..lineTo(r.right - 26, r.top)
          ..lineTo(r.right, r.top + 26)
          ..lineTo(r.right, r.bottom - 12)
          ..arcToPoint(Offset(r.right - 12, r.bottom), radius: const Radius.circular(12))
          ..lineTo(r.left + 12, r.bottom)
          ..arcToPoint(Offset(r.left, r.bottom - 12), radius: const Radius.circular(12))
          ..lineTo(r.left, r.top + 12)
          ..arcToPoint(Offset(r.left + 12, r.top), radius: const Radius.circular(12))
          ..close();
        canvas.drawPath(fold, fill);
        canvas.drawPath(
            Path()
              ..moveTo(r.right - 26, r.top)
              ..lineTo(r.right - 26, r.top + 26)
              ..lineTo(r.right, r.top + 26)
              ..close(),
            soft);
        canvas.drawRRect(round(Rect.fromLTWH(r.left + 12, r.top + 14, 34, 16), 4), deep);
        for (var i = 0; i < 6; i++) {
          bar(12, 42.0 + i * 15, i.isOdd ? 80 : 94, p: soft, t: 5);
        }
      case 'passport':
        canvas.drawRRect(round(r, 10), deep);
        canvas.drawCircle(Offset(r.center.dx, r.top + 54), 22, Paint()
          ..color = _soft
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4);
        canvas.drawCircle(Offset(r.center.dx, r.top + 54), 9, soft);
        bar(28, 94, 62, p: soft, t: 6);
        bar(38, 108, 42, p: soft, t: 5);
    }
  }

  @override
  bool shouldRepaint(_CollagePainter old) => old.dark != dark;
}

/// The moment a vault opens (or closes): an overlay in the page colour, the brand mark large in the
/// middle turns half a turn and scales out (opening) or in (closing). `onCovered` runs
/// while the overlay hides everything, which is when the caller switches screens.
Future<void> playVaultSpin(
  BuildContext context, {
  required bool opening,
  required VoidCallback onCovered,
  Widget? behind,
  Color? glow,
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
  final entry = OverlayEntry(
      builder: (_) => _Spin(
          controller: controller, opening: opening, reduce: reduce, color: color, ink: ink, behind: behind, glow: glow));
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
    this.behind,
    this.glow,
  }) : super(listenable: controller);

  /// The vault's colour, glowing around the dial's edge while it turns.
  final Color? glow;

  /// Opening: the vault's icon behind the dial, blurred and faint as the dial starts to
  /// turn, sharper as it opens, sharp once the dial has gone (owner 2026-10-21). The vault
  /// screen then shows the same icon in the same place, so the two meet without a jump.
  final Widget? behind;

  final bool opening;
  final bool reduce;
  final Color color;
  final Color ink;

  double get t => (listenable as AnimationController).value;

  static double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  /// From the dial's first turn (.16) to fully open (.78): faint and very blurred, then
  /// clearer with the turn, sharp as the dial scales away.
  Widget _behind(Widget icon) {
    final open = Curves.easeInOut.transform(_seg(t, .16, .80));
    // While the solid dial turns, the vault's colour glows around its edge; as
    // the dial swings away the icon behind comes forward from small and soft to sharp.
    final reveal = Curves.easeOutCubic.transform(_seg(t, .74, 1));
    final blur = reduce ? 0.0 : 16 * (1 - reveal);
    final g = glow;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (g != null)
          Opacity(
            opacity: (.75 * open * (1 - reveal)).clamp(0.0, 1.0),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26, tileMode: TileMode.decal),
              child: Container(width: 250, height: 250, decoration: BoxDecoration(color: g, shape: BoxShape.circle)),
            ),
          ),
        Opacity(
          opacity: reveal,
          child: Transform.scale(
            scale: .7 + .3 * reveal,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal),
              child: icon,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ease = Curves.easeInOutCubic;
    double bg, scale, turn, alpha;
    if (opening) {
      bg = t < .14 ? _seg(t, 0, .14) : (t < .78 ? 1 : 1 - _seg(t, .78, 1));
      scale = t < .16 ? .55 + .45 * ease.transform(_seg(t, 0, .16)) : (t < .78 ? 1 : 1 + 1.6 * ease.transform(_seg(t, .78, 1)));
      turn = t < .16 ? 0 : (t < .62 ? 192 * ease.transform(_seg(t, .16, .62)) : 192 - 12 * _seg(t, .62, .70));
      // With the vault's icon behind, the dial thins as it turns so the icon shows
      // through, then goes as it scales away.
      alpha = t < .78 ? 1 : 1 - _seg(t, .78, 1);
      // With the vault's icon behind: the dial stays solid and swings open past the eye,
      // like a safe's door (owner chose this over a dial thinning over the icon).
      if (behind != null && t >= .78) {
        scale = 1 + 3.2 * Curves.easeIn.transform(_seg(t, .78, 1));
        alpha = 1 - Curves.easeIn.transform(_seg(t, .84, 1));
      }
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
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (opening && behind != null) _behind(behind!),
                Opacity(
                  opacity: alpha.clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: turn * math.pi / 180,
                    child: Transform.scale(scale: scale, child: BrandMark(size: 190, color: ink)),
                  ),
                ),
              ],
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
