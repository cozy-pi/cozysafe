import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform.dart';
import 'prefs.dart';
import 'src/rust/api/vault.dart' as rust;

/// One set of 24 words kept in the cloud: the key, and the codes of the vaults that use it
/// (ADR 0008), so a new phone knows which set opens which vault.
class KeyCopy {
  const KeyCopy(this.key, this.vaults);
  final Uint8List key;
  final List<String> vaults;
}

/// The 24 words kept in the person's iCloud Keychain too, as a synchronizable keychain
/// item that Apple encrypts end to end; on Android in Google Block Store (BlockStore.kt),
/// only when Google encrypts it end to end (the phone has a screen lock). A new phone
/// signed in to the same account finds the words and asks only for the vault password.
/// The trade: whoever takes over the account has the words, and still needs the password.
///
/// Offered when a vault is made, on by default for an everyday vault (owner 2026-11-05:
/// security first, not to the extreme); never for a Top secret one, and never for a set
/// a Top secret vault also uses. Each set is its own item, named by the key's public
/// fingerprint (`secret-key.<4 hex>`), holding the key and the codes of its vaults: a
/// device with several vaults or sets keeps one copy per set, none overwriting another.
/// Never the PIN's device key: that one stays in this phone's chip.
abstract final class KeyBackup {
  static const _prefix = 'secret-key.';
  /// Before ADR 0008 one copy, named only `secret-key`: still read on a new phone.
  static const _legacy = 'secret-key';
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

  /// iPhone (iCloud Keychain) and Android (Block Store). Not on computers: no system
  /// store there that syncs end to end for a sandboxed or unsigned app.
  static bool get supported => debugSupported ?? (Device.iOS || Device.android);

  /// For tests and mockups: the Google wording on any platform.
  @visibleForTesting
  static bool? debugGoogle;

  /// Google Block Store (Android) rather than the iCloud Keychain.
  static bool get google => debugGoogle ?? Device.android;

  /// For tests: what the cloud holds, instead of the real store.
  @visibleForTesting
  static Map<String, String>? debugStore;

  static String _pref(String fp) => 'key-backup.$fp';

  /// This device put a copy of the set with this key there (and has not taken it out).
  static bool isOn(Uint8List key) => Prefs.read(_pref(rust.secretKeyFingerprint(key: key))) == '1';

  static Future<bool> _write(String name, String value) async {
    if (debugStore case final s?) {
      s[name] = value;
      return true;
    }
    if (Device.android) {
      return await _android.invokeMethod<bool>('store', {'key': name, 'bytes': Uint8List.fromList(utf8.encode(value))}) ?? false;
    }
    await _storage.write(key: name, value: value);
    return await _storage.read(key: name) == value;
  }

  static Future<String?> _read(String name) async {
    if (debugStore case final s?) return s[name];
    if (Device.android) {
      final b = await _android.invokeMethod<Uint8List>('find', {'key': name});
      return b == null ? null : utf8.decode(b, allowMalformed: true);
    }
    return _storage.read(key: name);
  }

  static Future<void> _delete(String name) async {
    if (debugStore case final s?) {
      s.remove(name);
      return;
    }
    if (Device.android) {
      await _android.invokeMethod<bool>('delete', {'key': name});
      return;
    }
    await _storage.delete(key: name);
  }

  static Future<List<String>> _names() async {
    if (debugStore case final s?) return s.keys.toList();
    if (Device.android) return (await _android.invokeListMethod<String>('keys')) ?? const [];
    return (await _storage.readAll()).keys.toList();
  }

  static KeyCopy? _parse(String? value) {
    if (value == null) return null;
    try {
      final j = jsonDecode(value) as Map<String, dynamic>;
      return KeyCopy(base64Decode(j['key'] as String), [for (final v in j['vaults'] as List) v as String]);
    } catch (_) {
      // Before ADR 0008 the value was the bare key in base 64.
      try {
        return KeyCopy(base64Decode(value), const []);
      } catch (_) {
        return null;
      }
    }
  }

  /// Keep the set with [key] there, adding [vault] (its code) to the vaults it names;
  /// true once it reads back. False when the store keeps nothing (no screen lock on
  /// Android, signed out of iCloud).
  static Future<bool> save(Uint8List key, {String? vault}) async {
    if (!supported) return false;
    final fp = rust.secretKeyFingerprint(key: key);
    if (fp.isEmpty) return false;
    try {
      final name = '$_prefix$fp';
      final had = _parse(await _read(name));
      // The same fingerprint for another key (one set in 65 536): keep both, the newer
      // under the same name would overwrite the other, so it is refused instead.
      if (had != null && !listEquals(had.key, key)) return false;
      final vaults = {...?had?.vaults, ?vault}.toList();
      final ok = await _write(name, jsonEncode({'v': 1, 'key': base64Encode(key), 'vaults': vaults}));
      if (ok) Prefs.write(_pref(fp), '1');
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Take the set with [key] out (from every device signed in to the account).
  static Future<void> remove(Uint8List key) async {
    final fp = rust.secretKeyFingerprint(key: key);
    Prefs.write(_pref(fp), '0');
    try {
      await _delete('$_prefix$fp');
    } catch (_) {}
  }

  /// On a new phone: every set kept there, the one-copy form of before ADR 0008 too.
  static Future<List<KeyCopy>> findAll() async {
    if (!supported) return const [];
    try {
      final out = <KeyCopy>[];
      for (final name in await _names()) {
        if (name != _legacy && !name.startsWith(_prefix)) continue;
        final copy = _parse(await _read(name));
        if (copy != null && !out.any((c) => listEquals(c.key, copy.key))) out.add(copy);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
