import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One way for every kind of item (docs/ui.md, owner 2026-10-22): a long press opens the
/// item's menu (lib/widgets/item_menu.dart), as in the iPhone's Files app; selecting many
/// goes through the Select button. A new long press that selects, or does something of
/// its own, fails here.
void main() {
  test('every long press opens a menu', () {
    final press = RegExp(r'onLongPress:\s*([^\n]*)');
    // What a long press may lead to: a menu, a callback that is one, or the home tab's
    // hold-to-lock (lib/widgets/vault_bar.dart).
    final ok = RegExp(r'[Mm]enu|onLongPress\b|hold\b|null');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in press.allMatches(f.readAsStringSync())) {
        if (!ok.hasMatch(m[1]!)) offenders.add('${f.path}: ${m[0]!.trim()}');
      }
    }
    expect(offenders, isEmpty);
  });
}
