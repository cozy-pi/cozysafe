// Design B paints the whole app in the vault's colour. Every colour, light and dark,
// must keep text readable (WCAG AA, 4.5:1) on what it sits on.

import 'dart:io';

import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no button style outside the theme sets a text style', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('theme.dart') || f.path.contains('src/rust')) continue;
      if (RegExp(r'\btextStyle:').hasMatch(f.readAsStringSync())) found.add(f.path);
    }
    // The size and weight go on the button's Text (docs/design-language.md, Buttons).
    expect(found, isEmpty);
  });

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
    // A button's text style set in a button style replaces the ambient one, font and
    // all: one without a font family draws boxes in the renders and falls off the theme's
    // font. Only the theme sets it, from its own type scale.
    test('${b.name}: themed buttons keep the theme font', () {
      final theme = buildTheme(b);
      for (final style in [theme.filledButtonTheme.style, theme.outlinedButtonTheme.style, theme.textButtonTheme.style]) {
        final text = style!.textStyle!.resolve(const {})!;
        expect(text.fontFamily, theme.textTheme.labelLarge!.fontFamily);
        expect(text.fontFamily, isNotNull);
      }
    });
    // An error is red, and its words still read on the page and on a card.
    test('${b.name}: an error is red and readable', () {
      final theme = buildTheme(b);
      final red = theme.colorScheme.error;
      expect(red.r, greaterThan(red.g + .5), reason: 'red, not the ink');
      expect(contrast(red, theme.scaffoldBackgroundColor), greaterThanOrEqualTo(4.5), reason: 'error text on the page');
      expect(contrast(red, theme.cardColor), greaterThanOrEqualTo(4.5), reason: 'error text on a card');
    });
  }
}
