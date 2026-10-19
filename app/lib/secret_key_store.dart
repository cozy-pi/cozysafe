import 'dart:convert';
import 'dart:typed_data';

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
