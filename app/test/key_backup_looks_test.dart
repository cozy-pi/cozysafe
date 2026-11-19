// The cloud copy of the 24 words names each vault by its code and, since 1.0.8, its icon
// and colour beside it, so a new phone shows the badge (vaults have no name). An older app
// must still read a copy written this way, and this app one written before.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) =>
      call.memberName.toString().contains('SecretKeyFingerprint') ? 'a1b2' : null;
}

void main() {
  final key = Uint8List.fromList(List.filled(32, 9));
  final cloud = <String, String>{};

  setUpAll(() => RustLib.initMock(api: _Fake()));

  setUp(() {
    cloud.clear();
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    KeyBackup.debugSupported = true;
    KeyBackup.debugStore = cloud;
  });

  test('keeps each vault\'s look beside its code, and the date it was kept', () async {
    expect(KeyBackup.savedAt(key), isNull);
    expect(await KeyBackup.save(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green'), isTrue);
    expect(await KeyBackup.save(key, vault: 'K8M2-4TXQ', icon: 'love', color: 'red'), isTrue);
    final copy = (await KeyBackup.findAll()).single;
    expect(copy.vaults, ['7F3A-9K2Q', 'K8M2-4TXQ']);
    expect(copy.looks['7F3A-9K2Q'], (icon: 'home', color: 'green'));
    expect(copy.looks['K8M2-4TXQ'], (icon: 'love', color: 'red'));
    expect(KeyBackup.savedAt(key), isNotNull);
    // An older app reads `vaults` as a list of strings: still one.
    final j = jsonDecode(cloud['secret-key.a1b2']!) as Map<String, dynamic>;
    expect((j['vaults'] as List).every((v) => v is String), isTrue);
  });

  test('a new look replaces the old one; no look keeps what was there', () async {
    await KeyBackup.save(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green');
    await KeyBackup.save(key, vault: '7F3A-9K2Q', icon: 'star', color: 'blue');
    await KeyBackup.save(key); // a new Recovery Key's copy names no vault
    final copy = (await KeyBackup.findAll()).single;
    expect(copy.vaults, ['7F3A-9K2Q']);
    expect(copy.looks['7F3A-9K2Q'], (icon: 'star', color: 'blue'));
  });

  test('a vault from before icons keeps no look; a copy from before 1.0.8 reads', () async {
    await KeyBackup.save(key, vault: '7F3A-9K2Q', icon: '', color: '');
    expect((await KeyBackup.findAll()).single.looks, isEmpty);
    cloud
      ..clear()
      ..['secret-key.a1b2'] = jsonEncode({'v': 1, 'key': base64Encode(key), 'vaults': ['7F3A-9K2Q']});
    final copy = (await KeyBackup.findAll()).single;
    expect(copy.vaults, ['7F3A-9K2Q']);
    expect(copy.looks, isEmpty);
  });

  test('opening a vault names it in a copy kept before 1.0.8, once', () async {
    cloud['secret-key.a1b2'] = jsonEncode({'v': 1, 'key': base64Encode(key), 'vaults': ['7F3A-9K2Q']});
    Prefs.write('key-backup.a1b2', '1');
    await KeyBackup.name(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green');
    expect((await KeyBackup.findAll()).single.looks['7F3A-9K2Q'], (icon: 'home', color: 'green'));
    // The next opening reads nothing: a copy changed elsewhere is left alone.
    cloud['secret-key.a1b2'] = jsonEncode({'v': 1, 'key': base64Encode(key), 'vaults': ['7F3A-9K2Q']});
    await KeyBackup.name(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green');
    expect((await KeyBackup.findAll()).single.looks, isEmpty);
    // A new look is written again.
    await KeyBackup.name(key, vault: '7F3A-9K2Q', icon: 'star', color: 'blue');
    expect((await KeyBackup.findAll()).single.looks['7F3A-9K2Q'], (icon: 'star', color: 'blue'));
  });

  test('no copy in the cloud, or the copy is off: opening keeps nothing', () async {
    await KeyBackup.name(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green');
    expect(cloud, isEmpty);
    Prefs.write('key-backup.a1b2', '1');
    await KeyBackup.name(key, vault: '7F3A-9K2Q', icon: 'home', color: 'green');
    expect(cloud, isEmpty);
  });
}
