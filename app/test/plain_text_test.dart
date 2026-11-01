// Top Secret Mode reads plain text files (owner 2026-11-01). The Rust core decides; the
// screens only pick the page, from the same list of extensions.

import 'dart:io';

import 'package:cozysafe/screens/plain_text_view.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:flutter_test/flutter_test.dart';

ItemInfo _file(String name, int size, {String kind = 'file'}) => ItemInfo(
      id: 'x',
      kind: kind,
      name: name,
      mime: '',
      createdMs: 0,
      sizeBytes: BigInt.from(size),
      tagIds: const [],
      isFavorite: false,
      modifiedMs: 0,
    );

void main() {
  test('the screens list the same extensions as the core', () {
    final rust = File('rust/src/plain_text.rs').readAsStringSync();
    final block = RegExp(r'EXTENSIONS: &\[&str\] = &\[([^\]]*)\]').firstMatch(rust)!.group(1)!;
    final core = RegExp(r'"([a-z]+)"').allMatches(block).map((m) => m.group(1)!).toSet();
    expect(plainTextExtensions, core);
    expect(RegExp(r'pub\(crate\) const MAX: usize = 1 << 20;').hasMatch(rust), isTrue);
  });

  test('only small files with a listed extension open as text', () {
    expect(opensAsPlainText(_file('keys.PUB', 400)), isTrue);
    expect(opensAsPlainText(_file('notes.txt', plainTextMax)), isTrue);
    expect(opensAsPlainText(_file('notes.txt', plainTextMax + 1)), isFalse);
    expect(opensAsPlainText(_file('scan.pdf', 400)), isFalse);
    expect(opensAsPlainText(_file('page.html', 400)), isFalse);
    expect(opensAsPlainText(_file('IMG.txt', 400, kind: 'photo')), isFalse);
  });
}
