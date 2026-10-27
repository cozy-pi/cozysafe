// The PIN's device key goes into the phone's secure hardware (owner 2026-10-26, B1):
// the keystore then holds only the wrapped key, and phones without such hardware keep
// working as before.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cozysafe/hw_key.dart';
import 'package:cozysafe/secret_key_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in chip: XOR with a secret only it knows.
Uint8List _x(Uint8List b) => Uint8List.fromList([for (final v in b) v ^ 0x5a]);

void main() {
  tearDown(() => HwKey.debug = null);

  test('a new device key is kept only wrapped', () async {
    FlutterSecureStorage.setMockInitialValues({});
    HwKey.debug = (wrap: (b) async => _x(b), unwrap: (b) async => _x(b));
    final key = await PinStore.deviceKeyOrCreate(() => Uint8List.fromList(List.generate(32, (i) => i)));
    final stored = await const FlutterSecureStorage().readAll(
        aOptions: AndroidOptions(storageNamespace: 'cozysafe_pin', resetOnError: false));
    expect(stored.containsKey('pin-device-key'), isFalse);
    expect(stored['pin-device-key-hw'], base64Encode(_x(key)));
    expect(await PinStore.deviceKey(), key);
  });

  test('a clear key from before moves into the hardware on first use', () async {
    final old = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    FlutterSecureStorage.setMockInitialValues({'pin-device-key': base64Encode(old)});
    HwKey.debug = (wrap: (b) async => _x(b), unwrap: (b) async => _x(b));
    expect(await PinStore.deviceKey(), old);
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.containsKey('pin-device-key'), isFalse);
    expect(await PinStore.deviceKey(), old);
  });

  test('without the hardware the key stays as it was', () async {
    FlutterSecureStorage.setMockInitialValues({});
    HwKey.debug = (wrap: (_) async => null, unwrap: (_) async => null);
    final key = await PinStore.deviceKeyOrCreate(() => Uint8List.fromList(List.filled(32, 7)));
    expect(await PinStore.deviceKey(), key);
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.containsKey('pin-device-key'), isTrue);
  });

  test('a wrap that does not read back keeps the clear key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    HwKey.debug = (wrap: (b) async => _x(b), unwrap: (_) async => Uint8List(32));
    final key = await PinStore.deviceKeyOrCreate(() => Uint8List.fromList(List.filled(32, 9)));
    final stored = await const FlutterSecureStorage().readAll();
    expect(stored.containsKey('pin-device-key-hw'), isFalse);
    expect(stored['pin-device-key'], base64Encode(key));
  });
}
