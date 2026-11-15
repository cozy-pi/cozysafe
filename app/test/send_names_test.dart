// Sending a selection: every decrypted copy gets its own file name, so two items with
// one name do not land on one file (lib/send_names.dart).

import 'package:cozysafe/send_names.dart';
import 'package:flutter_test/flutter_test.dart';

({String name, bool note}) _file(String name) => (name: name, note: false);
({String name, bool note}) _note(String name) => (name: name, note: true);

void main() {
  test('names that differ stay as they are', () {
    expect(sendNames([_file('IMG_1.jpg'), _file('Contract.pdf')]), ['IMG_1.jpg', 'Contract.pdf']);
  });

  test('a repeated name gets a number before its extension', () {
    expect(
      sendNames([_file('IMG_0001.jpg'), _file('IMG_0001.jpg'), _file('IMG_0001.jpg')]),
      ['IMG_0001.jpg', 'IMG_0001 (2).jpg', 'IMG_0001 (3).jpg'],
    );
  });

  test('the same name in another case is the same file on a phone', () {
    expect(sendNames([_file('Beach.MOV'), _file('beach.mov')]), ['Beach.MOV', 'beach (2).mov']);
  });

  test('a number that is taken already is skipped', () {
    expect(sendNames([_file('a.jpg'), _file('a (2).jpg'), _file('a.jpg')]), ['a.jpg', 'a (2).jpg', 'a (3).jpg']);
  });

  test('notes end in .txt, and two notes with one title both go', () {
    expect(sendNames([_note('Shopping'), _note('Shopping'), _note('list.txt')]), ['Shopping.txt', 'Shopping (2).txt', 'list.txt']);
  });

  test('no name, no extension, and characters a file name cannot hold', () {
    expect(sendNames([_file(''), _file('README'), _file('README'), _file('a/b:c.png')]), ['item-0', 'README', 'README (2)', 'a-b-c.png']);
    // A leading dot is not an extension.
    expect(sendNames([_file('.env'), _file('.env')]), ['.env', '.env (2)']);
  });

  test('every name is different, whatever comes in', () {
    final names = sendNames([for (var i = 0; i < 40; i++) _file(i.isEven ? 'x.jpg' : 'X.JPG')]);
    expect(names.map((n) => n.toLowerCase()).toSet().length, 40);
  });
}
