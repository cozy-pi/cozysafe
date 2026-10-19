import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// This device's Secret Key in the platform keystore (ADR 0001): Keychain on Apple
/// devices (this device only, readable after the first unlock since boot), the Android
/// Keystore, the Windows credential store, libsecret on Linux. Not synced while Cozy Safe
/// has no sync; the Emergency Kit is the copy that leaves the device.
class SecretKeyStore {
  static const _name = 'secret-key';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'cozysafe.secret-key',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    // The legacy keychain needs no keychain-sharing entitlement, so Developer ID
    // builds run on any Mac.
    mOptions: MacOsOptions(
      accountName: 'cozysafe.secret-key',
      usesDataProtectionKeychain: false,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(storageNamespace: 'cozysafe_secret', resetOnError: false),
  );

  /// The stored key, or null when there is none or the store cannot read it (for
  /// example data restored onto a new phone without its keystore).
  static Future<Uint8List?> read() async {
    try {
      final v = await _storage.read(key: _name);
      return v == null ? null : base64Decode(v);
    } catch (_) {
      return null;
    }
  }

  /// Store the key and read it back: callers delete other copies only after this.
  static Future<void> write(Uint8List key) async {
    await _storage.write(key: _name, value: base64Encode(key));
    final back = await read();
    if (back == null || !listEquals(back, key)) {
      throw StateError('The keystore did not keep the Secret Key');
    }
  }
}

/// The PIN's device half (ADR 0001): a random key that never leaves this device's
/// keystore, plus the count of wrong PINs. 5 wrong in a row and the PIN is forgotten;
/// the password still opens the vault.
class PinStore {
  static const maxTries = 5;
  static const _key = 'pin-device-key';
  static const _fails = 'pin-fails';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'cozysafe.pin',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(accountName: 'cozysafe.pin', usesDataProtectionKeychain: false, synchronizable: false),
    aOptions: AndroidOptions(storageNamespace: 'cozysafe_pin', resetOnError: false),
  );

  static Future<Uint8List?> deviceKey() async {
    try {
      final v = await _storage.read(key: _key);
      return v == null ? null : base64Decode(v);
    } catch (_) {
      return null;
    }
  }

  /// A fresh device key each time a PIN is set (an old PIN file becomes useless).
  static Future<Uint8List> newDeviceKey(Uint8List random16) async {
    await _storage.write(key: _key, value: base64Encode(random16));
    await _storage.write(key: _fails, value: '0');
    final back = await deviceKey();
    if (back == null || !listEquals(back, random16)) {
      throw StateError('The keystore did not keep the PIN key');
    }
    return back;
  }

  static Future<int> fails() async {
    try {
      return int.tryParse(await _storage.read(key: _fails) ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> setFails(int n) async {
    try {
      await _storage.write(key: _fails, value: '$n');
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
      await _storage.delete(key: _fails);
    } catch (_) {}
  }
}
