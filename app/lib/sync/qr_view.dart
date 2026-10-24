import 'package:flutter/material.dart';

import '../src/rust/api/sync.dart' as sync;

/// A QR code drawn from the Rust encoder's modules: dark on white with a quiet zone,
/// whatever the theme (scanners need the contrast).
class QrView extends StatelessWidget {
  const QrView({super.key, required this.text, this.size = 220});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = sync.qrMatrix(text: text);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .06),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
      child: m == null ? null : CustomPaint(painter: _Modules(m)),
    );
  }
}

class _Modules extends CustomPainter {
  _Modules(this.m);
  final sync.QrMatrix m;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / m.size;
    final ink = Paint()..color = Colors.black;
    for (var y = 0; y < m.size; y++) {
      for (var x = 0; x < m.size; x++) {
        if (m.dark[y * m.size + x]) {
          // A hair larger so neighbours join without seams.
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + .5, cell + .5), ink);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Modules old) => old.m != m;
}
