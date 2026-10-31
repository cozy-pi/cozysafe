import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform.dart';
import 'prefs.dart';
import 'words_export.dart';

/// The 24 words kept in the person's iCloud Keychain too (owner 2026-10-26, option 2):
/// off unless turned on in Settings. Apple encrypts the iCloud Keychain end to end; a new
/// iPhone signed in to the same Apple account then finds the words and asks only for the
/// vault password. The trade: whoever takes over the Apple account has the words, and
/// still needs the password. On Android the same through Google Block Store
/// (BlockStore.kt), kept only when Google encrypts it end to end. Never the PIN's device
/// key: that one stays in this phone's chip.
abstract final class KeyBackup {
  static const _pref = 'key-backup-icloud';
  static const _name = 'secret-key';
  static const _android = MethodChannel('cozysafe/blockstore');

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

  /// Only in a build where the words may leave the app ([wordsExport]): the iCloud
  /// Keychain and Block Store keep them on Apple's or Google's servers (owner
  /// 2026-10-30: the words are never written anywhere but on paper).
  static bool get supported => debugSupported ?? (wordsExport && (Device.iOS || Device.android));

  /// For tests and mockups: the Google wording on any platform.
  @visibleForTesting
  static bool? debugGoogle;

  /// Google Block Store (Android) rather than the iCloud Keychain.
  static bool get google => debugGoogle ?? Device.android;

  static bool get on => Prefs.read(_pref) == '1';

  /// Keep [key] in the iCloud Keychain (Block Store on Android); true once it reads back.
  static Future<bool> turnOn(Uint8List key) async {
    if (!supported) return false;
    try {
      if (Device.android) {
        final ok = await _android.invokeMethod<bool>('store', {'bytes': key}) ?? false;
        if (ok) Prefs.write(_pref, '1');
        return ok;
      }
      await _storage.write(key: _name, value: base64Encode(key));
      final back = await _storage.read(key: _name);
      if (back != base64Encode(key)) return false;
      Prefs.write(_pref, '1');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Take the words out of the iCloud Keychain or Block Store (every device signed in loses them).
  static Future<void> turnOff() async {
    Prefs.write(_pref, '0');
    try {
      if (Device.android) {
        await _android.invokeMethod<bool>('delete');
        return;
      }
      await _storage.delete(key: _name);
    } catch (_) {}
  }

  /// At start: a copy kept before this build forbade it is taken out (from every device
  /// signed in to the account), so no build of this kind leaves one behind.
  static Future<void> sweep() async {
    if (wordsExport || !on || !(Device.iOS || Device.android)) return;
    await turnOff();
  }

  /// On a new phone: the words from the iCloud Keychain or Block Store, if they are there.
  static Future<Uint8List?> find() async {
    if (!supported) return null;
    try {
      if (Device.android) return await _android.invokeMethod<Uint8List>('find');
      final v = await _storage.read(key: _name);
      return v == null ? null : base64Decode(v);
    } catch (_) {
      return null;
    }
  }
}
