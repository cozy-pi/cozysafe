// Touch ID on a Mac (docs/security.md, "Touch ID on a Mac"): the biometric key is kept
// only wrapped by the Secure Enclave, a cancelled prompt leaves everything as it was, and
// a key the enclave no longer accepts (fingers changed) turns biometric unlock off. The
// enclave and the Rust core are stand-ins.

import 'dart:convert';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/l10n/app_localizations_en.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake implements RustLibApi {
  Uint8List? unlockedWith;
  int forgets = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('UnlockWithBiometric')) {
      unlockedWith = call.namedArguments[#key] as Uint8List;
      return Future<VaultInfo?>.value(
          VaultInfo(id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: true, topSecret: false));
    }
    if (name.contains('ForgetBiometricUnlock')) {
      forgets++;
      return Future<void>.value();
    }
    return super.noSuchMethod(call);
  }
}

/// A stand-in enclave: XOR with a secret only it knows.
Uint8List _x(Uint8List b) => Uint8List.fromList([for (final v in b) v ^ 0xa5]);

late _Fake _fake;
var _enrolled = true;
var _fingersChanged = false;
var _cancel = false;
String? _reason;

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  setUp(() {
    _fake
      ..unlockedWith = null
      ..forgets = 0;
    _enrolled = true;
    _fingersChanged = false;
    _cancel = false;
    _reason = null;
    FlutterSecureStorage.setMockInitialValues({});
    MacBioKey.debug = (
      available: () async => _enrolled,
      wrap: (b) async => _x(b),
      unwrap: (blob, reason) async {
        _reason = reason;
        if (_cancel) throw PlatformException(code: 'cancelled');
        return _fingersChanged ? null : _x(blob);
      },
    );
  });
  tearDown(() => MacBioKey.debug = null);

  final store = BiometricUnlock(promptTitle: 'Unlock Cozy Safe', promptCancel: 'Cancel');
  final key = Uint8List.fromList(List.generate(32, (i) => i));

  test('offered as Touch ID only when a finger is enrolled', () async {
    expect(BiometricUnlock.platformSupported, isTrue);
    expect(await BiometricUnlock.available(), BiometricKind.fingerprint);
    _enrolled = false;
    expect(await BiometricUnlock.available(), isNull);
    final l = AppLocalizationsEn();
    expect(unlockWithLabel(l, BiometricKind.fingerprint), 'Unlock with Touch ID');
    expect(opensThisVaultLabel(l, BiometricKind.fingerprint), 'Touch ID opens this vault');
  });

  test('the key is kept only wrapped by the enclave', () async {
    await store.save(key);
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.containsKey('vault-unlock-key'), isFalse);
    expect(stored['vault-unlock-key-enclave'], base64Encode(_x(key)));
    expect(stored.values.any((v) => v == base64Encode(key)), isFalse);
  });

  test('Touch ID opens the vault with the unwrapped key', () async {
    await store.save(key);
    final vault = await store.unlock('lib');
    expect(vault?.id, 'v1');
    expect(_fake.unlockedWith, key);
    expect(_reason, 'Unlock Cozy Safe');
  });

  test('a cancelled prompt keeps biometric unlock on', () async {
    await store.save(key);
    _cancel = true;
    expect(await store.unlock('lib'), isNull);
    expect(_fake.forgets, 0);
    expect((await const FlutterSecureStorage().readAll()).containsKey('vault-unlock-key-enclave'), isTrue);
  });

  test('fingers changed: biometric unlock is turned off, the PIN or password is next', () async {
    await store.save(key);
    _fingersChanged = true;
    await expectLater(store.unlock('lib'), throwsA(isA<BiometricKeyGone>()));
    expect(_fake.forgets, 1);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });

  test('the enclave cannot make a key: turning on fails', () async {
    MacBioKey.debug = (
      available: () async => true,
      wrap: (_) async => null,
      unwrap: (_, _) async => null,
    );
    await expectLater(store.save(key), throwsStateError);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  });
}
