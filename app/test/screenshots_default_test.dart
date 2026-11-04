// Screenshots are allowed by default, with a warning after one (owner 2026-11-04: a
// black screenshot looked broken, and Android said nothing); a Top secret vault still
// blocks them unless the person chose otherwise.

import 'dart:io';

import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/top_secret_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => Prefs.dir = Directory.systemTemp.createTempSync('prefs').path);
  tearDown(() => TopSecretMode.on = false);

  test('allowed by default; blocked by default in Top secret', () {
    expect(Settings.blockScreenshots, isFalse);
    TopSecretMode.on = true;
    expect(Settings.blockScreenshots, isTrue);
  });

  test("the person's choice wins either way", () {
    Prefs.write('block-screenshots', '1');
    expect(Settings.blockScreenshots, isTrue);
    Prefs.write('block-screenshots', '0');
    TopSecretMode.on = true;
    expect(Settings.blockScreenshots, isFalse);
  });
}
