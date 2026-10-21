import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every page that has a back button can be swiped back too (docs/ui.md): on iOS
/// `canPop: false` switches the edge swipe off, so a page must not block its pop to
/// save or to hand back a result. Only a sheet that must not close mid-task may.
void main() {
  test('no page blocks the swipe back', () {
    const allowed = {
      // Encrypting an import: closing it mid-way would lose track of the files.
      'lib/screens/vault_home.dart': 1,
    };
    final found = <String, int>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final n = RegExp(r'canPop: false,').allMatches(f.readAsStringSync()).length;
      if (n > 0) found[f.path] = n;
    }
    expect(found, allowed);
  });
}
