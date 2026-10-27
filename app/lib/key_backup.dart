import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform.dart';
import 'prefs.dart';

/// The 24 words kept in the person's iCloud Keychain too (owner 2026-10-26, option 2):
/// off unless turned on in Settings. Apple encrypts the iCloud Keychain end to end; a new
/// iPhone signed in to the same Apple account then finds the words and asks only for the
/// vault password. The trade: whoever takes over the Apple account has the words, and
/// still needs the password. Android (Google Block Store) comes later. Never the PIN's
/// device key: that one stays in this phone's chip.
abstract final class KeyBackup {
  static const _pref = 'key-backup-icloud';
  static const _name = 'secret-key';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'cozysafe.secret-key.icloud',
      accessibility: KeychainAccessibility.first_unlock,
      synchronizable: true,
    ),
  );

  /// For tests and mockups.
  @visibleForTesting
  static bool? debugSupported;

  static bool get supported => debugSupported ?? Device.iOS;

  static bool get on => Prefs.read(_pref) == '1';

  /// Keep [key] in the iCloud Keychain; true once it reads back.
  static Future<bool> turnOn(Uint8List key) async {
    try {
      await _storage.write(key: _name, value: base64Encode(key));
      final back = await _storage.read(key: _name);
      if (back != base64Encode(key)) return false;
      Prefs.write(_pref, '1');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Take the words out of the iCloud Keychain (every device signed in loses them).
  static Future<void> turnOff() async {
    Prefs.write(_pref, '0');
    try {
      await _storage.delete(key: _name);
    } catch (_) {}
  }

  /// On a new phone: the words from the iCloud Keychain, if they are there.
  static Future<Uint8List?> find() async {
    if (!supported) return null;
    try {
      final v = await _storage.read(key: _name);
      return v == null ? null : base64Decode(v);
    } catch (_) {
      return null;
    }
  }
}
