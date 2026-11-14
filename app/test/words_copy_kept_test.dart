// Deleting a vault from this device forgets its 24 words here. Their copy in iCloud
// Keychain or Google Block Store goes only when the vault's copy in Google Drive goes
// too: a copy of the vault left elsewhere opens with those words and nothing else, and
// someone who never wrote them down must still be able to restore it (review 2026-11-14).

import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/secret_key_store.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  setUp(() async {
    cloud.clear();
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    KeyBackup.debugSupported = true;
    KeyBackup.debugGoogle = false;
    KeyBackup.debugStore = cloud;
    FlutterSecureStorage.setMockInitialValues({});
    await SecretKeyStore.write(key);
    expect(await KeyBackup.save(key, vault: '7F3A-9K2Q'), isTrue);
    expect(cloud, hasLength(1));
  });

  tearDown(() {
    KeyBackup.debugSupported = null;
    KeyBackup.debugGoogle = null;
    KeyBackup.debugStore = null;
  });

  test('kept: the words leave this device, their cloud copy stays', () async {
    await SecretKeyStore.delete(null, true);
    expect(await SecretKeyStore.read(), isNull);
    expect(cloud, hasLength(1));
    expect((await KeyBackup.findAll()).single.key, key);
  });

  test('not kept (the copy in Google Drive went too): the cloud copy goes', () async {
    await SecretKeyStore.delete();
    expect(await SecretKeyStore.read(), isNull);
    expect(cloud, isEmpty);
  });
}
