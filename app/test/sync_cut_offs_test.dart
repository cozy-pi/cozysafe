// Automatic sync cut off again and again shows a problem (owner 2026-10-29: every run hung
// for an afternoon and nothing on screen said so).

import 'package:cozysafe/sync/cut_offs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('three runs cut off in a row show the problem', () {
    final c = CutOffs();
    final shown = [for (var i = 0; i < 5; i++) (c..start()).cutOff()];
    expect(shown, [false, false, true, true, true]);
  });

  test('a sync that goes through starts the count again', () {
    final c = CutOffs();
    c
      ..start()
      ..cutOff()
      ..start()
      ..cutOff()
      ..ok();
    expect((c..start()).cutOff(), isFalse);
    expect((c..start()).cutOff(), isFalse);
    expect((c..start()).cutOff(), isTrue);
  });

  test('a run cut off after leaving the app is not counted', () {
    final c = CutOffs();
    for (var i = 0; i < 5; i++) {
      c
        ..start()
        ..away();
      expect(c.cutOff(), isFalse);
    }
    expect(c.count, 0);
  });
}
