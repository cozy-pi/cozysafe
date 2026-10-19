// Design B paints the whole app in the vault's colour. Every colour, light and dark,
// must keep text readable (WCAG AA, 4.5:1) on what it sits on.

import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final b in Brightness.values) {
    for (final v in vaultColors) {
      test('${v.id} ${b.name}: text stays readable', () {
        final p = VaultPalette(v.color, b);
        expect(contrast(p.ink, p.bg), greaterThanOrEqualTo(4.5), reason: 'text on the background');
        expect(contrast(p.ink, p.surface), greaterThanOrEqualTo(4.5), reason: 'text on cards');
        expect(contrast(p.muted, p.surface), greaterThanOrEqualTo(4.5), reason: 'secondary text on cards');
        expect(contrast(p.muted, p.bg), greaterThanOrEqualTo(4.5), reason: 'secondary text on the background');
        expect(contrast(p.accent, p.surface), greaterThanOrEqualTo(4.5), reason: 'buttons and links on cards');
        expect(contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5), reason: 'text on filled buttons');
        expect(contrast(Colors.white, p.dock), greaterThanOrEqualTo(4.5), reason: 'dock labels');
      });
    }
  }
}
