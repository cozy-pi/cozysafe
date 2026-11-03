// The lock-screen backdrop stays inside its page (owner 2026-11-03): its tilted collage
// is drawn well past the page's edges, and during the iPhone back swipe the sliding
// page's collage covered the first screen, logo and buttons included.

import 'dart:ui' as ui;

import 'package:cozysafe/widgets/brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the backdrop paints nothing outside its page', (t) async {
    final key = GlobalKey();
    await t.binding.setSurfaceSize(const Size(400, 400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: RepaintBoundary(
        key: key,
        child: const ColoredBox(
          color: Colors.white,
          child: Center(child: SizedBox(width: 100, height: 100, child: VaultBackdrop())),
        ),
      ),
    ));
    await t.pumpAndSettle();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await t.runAsync(() async {
      final image = await boundary.toImage();
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    var outside = 0;
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 400; x++) {
        if (x >= 150 && x < 250 && y >= 150 && y < 250) continue;
        final i = (y * 400 + x) * 4;
        if (bytes!.getUint8(i) != 255 || bytes.getUint8(i + 1) != 255 || bytes.getUint8(i + 2) != 255) outside++;
      }
    }
    expect(outside, 0);
  });
}
