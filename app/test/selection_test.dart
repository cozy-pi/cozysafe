import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One way to select in every list (docs/ui.md): rows that can be long-pressed are
/// built on SelectableRow, so the circles and the tint are the same everywhere. A new
/// list with its own InkWell + onLongPress fails here.
void main() {
  test('long-pressable rows use SelectableRow', () {
    final own = RegExp(r'(InkWell|GestureDetector|ListTile)\((?:(?!\n  \S)[\s\S]){0,400}?onLongPress:');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('selectable_row.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in own.allMatches(src)) {
        // The photo grid draws its own circle on the picture (_MediaTile).
        final before = src.substring(0, m.start);
        if (before.substring(before.lastIndexOf('\nclass ')).startsWith('\nclass _MediaTile')) continue;
        // Holding the home tab locks the vault: a tab, not a list row.
        if (before.substring(before.lastIndexOf('\nclass ')).startsWith('\nclass _TabsState')) continue;
        offenders.add('${f.path}: ${m[0]!.split('\n').first.trim()}');
      }
    }
    expect(offenders, isEmpty);
  });
}
