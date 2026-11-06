// The Material Symbols font is a subset (assets/fonts/README.md): every glyph `Sym`
// names must be in it, or it would draw as an empty box.

import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/widgets/symbols.dart';
import 'package:flutter_test/flutter_test.dart';

/// The code points a TrueType font maps (its cmap, format 4 subtables).
Set<int> _mapped(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  final tables = b.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final at = 12 + 16 * i;
    if (String.fromCharCodes(bytes.sublist(at, at + 4)) == 'cmap') cmap = b.getUint32(at + 8);
  }
  expect(cmap, greaterThan(0), reason: 'no cmap');
  final out = <int>{};
  for (var i = 0; i < b.getUint16(cmap + 2); i++) {
    final sub = cmap + b.getUint32(cmap + 4 + 8 * i + 4);
    if (b.getUint16(sub) != 4) continue;
    final segs = b.getUint16(sub + 6) ~/ 2;
    final ends = sub + 14, starts = ends + 2 * segs + 2, deltas = starts + 2 * segs, offsets = deltas + 2 * segs;
    for (var s = 0; s < segs; s++) {
      final end = b.getUint16(ends + 2 * s), start = b.getUint16(starts + 2 * s);
      final delta = b.getInt16(deltas + 2 * s), offset = b.getUint16(offsets + 2 * s);
      for (var c = start; c <= end && c != 0xffff; c++) {
        final glyph = offset == 0
            ? (c + delta) & 0xffff
            : b.getUint16(offsets + 2 * s + offset + 2 * (c - start));
        if (glyph != 0) out.add(c);
      }
    }
  }
  return out;
}

void main() {
  test('every Sym glyph is in the bundled font, in its family', () {
    final mapped = _mapped(File('assets/fonts/MaterialSymbolsRounded.ttf').readAsBytesSync());
    for (final icon in Sym.all) {
      expect(icon.fontFamily, 'MaterialSymbolsRounded');
      expect(mapped, contains(icon.codePoint), reason: 'U+${icon.codePoint.toRadixString(16)}');
    }
  });
}
