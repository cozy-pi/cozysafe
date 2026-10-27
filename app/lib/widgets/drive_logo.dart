import 'package:flutter/material.dart';

/// Google Drive's own logo (owner 2026-10-27: the standard icon, not a cloud), drawn from
/// its six coloured parts so no image or SVG library is needed. Unaltered, as Google's
/// brand rules ask; it stands for Drive only.
class DriveLogo extends StatelessWidget {
  const DriveLogo({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size * 78 / 87.3), painter: const _DrivePainter());
}

class _DrivePainter extends CustomPainter {
  const _DrivePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 87.3, size.height / 78);
    void part(Color color, void Function(Path p) draw) {
      final p = Path();
      draw(p);
      canvas.drawPath(p..close(), Paint()..color = color);
    }

    part(const Color(0xFF0066DA), (p) => p
      ..moveTo(6.6, 66.85)
      ..lineTo(10.45, 73.5)
      ..cubicTo(11.25, 74.9, 12.4, 76.0, 13.75, 76.8)
      ..lineTo(27.5, 53)
      ..lineTo(0, 53)
      ..cubicTo(0, 54.55, 0.4, 56.1, 1.2, 57.5));
    part(const Color(0xFF00AC47), (p) => p
      ..moveTo(43.65, 25)
      ..lineTo(29.9, 1.2)
      ..cubicTo(28.55, 2.0, 27.4, 3.1, 26.6, 4.5)
      ..lineTo(1.2, 48.5)
      ..cubicTo(0.4, 49.9, 0, 51.45, 0, 53)
      ..lineTo(27.5, 53));
    part(const Color(0xFFEA4335), (p) => p
      ..moveTo(73.55, 76.8)
      ..cubicTo(74.9, 76.0, 76.05, 74.9, 76.85, 73.5)
      ..lineTo(78.45, 70.75)
      ..lineTo(86.1, 57.5)
      ..cubicTo(86.9, 56.1, 87.3, 54.55, 87.3, 53)
      ..lineTo(59.798, 53)
      ..lineTo(65.65, 64.5));
    part(const Color(0xFF00832D), (p) => p
      ..moveTo(43.65, 25)
      ..lineTo(57.4, 1.2)
      ..cubicTo(56.05, 0.4, 54.5, 0, 52.9, 0)
      ..lineTo(34.4, 0)
      ..cubicTo(32.8, 0, 31.25, 0.45, 29.9, 1.2));
    part(const Color(0xFF2684FC), (p) => p
      ..moveTo(59.8, 53)
      ..lineTo(27.5, 53)
      ..lineTo(13.75, 76.8)
      ..cubicTo(15.1, 77.6, 16.65, 78, 18.25, 78)
      ..lineTo(69.05, 78)
      ..cubicTo(70.65, 78, 72.2, 77.55, 73.55, 76.8));
    part(const Color(0xFFFFBA00), (p) => p
      ..moveTo(73.4, 26.5)
      ..lineTo(60.7, 4.5)
      ..cubicTo(59.9, 3.1, 58.75, 2.0, 57.4, 1.2)
      ..lineTo(43.65, 25)
      ..lineTo(59.8, 53)
      ..lineTo(87.25, 53)
      ..cubicTo(87.25, 51.45, 86.85, 49.9, 86.05, 48.5));
  }

  @override
  bool shouldRepaint(_DrivePainter old) => false;
}
