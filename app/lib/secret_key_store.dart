import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'hw_key.dart';
import 'key_backup.dart';

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
    // A new Recovery Key replaces the iCloud Keychain copy, when that is on.
    if (KeyBackup.on) await KeyBackup.turnOn(key);
  }

  /// Forget the key (the last vault on this device was deleted): a new vault starts
  /// with new words, and backups of the old one cannot be opened with this device's copy.
  static Future<void> delete() async {
    await _storage.delete(key: _name);
    if (await read() != null) throw StateError('The keystore still holds the Secret Key');
    await KeyBackup.turnOff();
  }
}

/// The PIN's device half (ADR 0001): one random key, shared by every vault's PIN here,
/// kept wrapped by a key inside the phone's secure hardware ([HwKey]: Secure Enclave,
/// Android Keystore) so a copy of the keystore cannot be tried offline, plus the count
/// of wrong PINs. Wrong PINs make you wait longer and longer (1, 5, 15, 60 minutes); at
/// [wipeAt] the PIN goes when the vault has a password to fall back on.
class PinStore {
  /// The device key in the clear (before 0.1.76, or where there is no secure hardware).
  static const _key = 'pin-device-key';
  /// The device key wrapped by [HwKey].
  static const _wrapped = 'pin-device-key-hw';
  static const _fails = 'pin-fails';
  static const _until = 'pin-wait-until';

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
      final wrapped = await _storage.read(key: _wrapped);
      if (wrapped != null) return await HwKey.unwrap(base64Decode(wrapped));
      final v = await _storage.read(key: _key);
      if (v == null) return null;
      final key = base64Decode(v);
      await _seal(key); // a key from before: into the hardware now
      return key;
    } catch (_) {
      return null;
    }
  }

  /// Keep [key] wrapped by the secure hardware and drop the clear copy, once the wrapped
  /// one reads back the same. False (the clear copy stays) where there is no hardware.
  static Future<bool> _seal(Uint8List key) async {
    final blob = await HwKey.wrap(key);
    if (blob == null) return false;
    final back = await HwKey.unwrap(blob);
    if (back == null || !listEquals(back, key)) return false;
    await _storage.write(key: _wrapped, value: base64Encode(blob));
    if (await _storage.read(key: _wrapped) != base64Encode(blob)) return false;
    await _storage.delete(key: _key);
    return true;
  }

  /// The device key, made once (from `random16`) the first time a PIN is set.
  static Future<Uint8List> deviceKeyOrCreate(Uint8List Function() random16) async {
    final existing = await deviceKey();
    if (existing != null) return existing;
    final key = random16();
    if (!await _seal(key)) await _storage.write(key: _key, value: base64Encode(key));
    final back = await deviceKey();
    if (back == null || !listEquals(back, key)) {
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

  /// When the pad opens again, or null when there is no wait.
  static Future<DateTime?> waitUntil() => TryWait.until(_storage, _until);

  /// Wrong PINs in a row after which the PIN copies are removed (owner 2026-10-26): the
  /// vault then opens with its password only, and a PIN can be set again.
  static const wipeAt = 10;

  /// Wait after this many wrong PINs in a row (4 free tries).
  static Duration waitFor(int fails) => switch (fails) {
        < 5 => Duration.zero,
        5 => const Duration(minutes: 1),
        6 => const Duration(minutes: 5),
        7 => const Duration(minutes: 15),
        _ => const Duration(hours: 1),
      };

  /// Record a wrong PIN; returns the wait it caused. At [wipeAt] in a row the caller
  /// removes the PIN ([wipe]).
  static Future<Duration> addFail() async {
    final n = (await fails()) + 1;
    final wait = waitFor(n);
    try {
      await _storage.write(key: _fails, value: '$n');
      if (wait > Duration.zero) await TryWait.start(_storage, _until, wait);
    } catch (_) {}
    return wait;
  }

  /// Too many wrong PINs: every PIN copy on this device goes (the vault keeps opening
  /// with its password), and the count starts again.
  static Future<void> wipe(String libraryDir, Future<void> Function({required String dir}) forgetPin) async {
    try {
      await forgetPin(dir: libraryDir);
    } catch (_) {}
    await resetFails();
  }

  // Wrong vault passwords (owner 2026-10-23: weak passwords are allowed, so guessing on
  // this phone must be slow). Only tries of a possible password (8 characters or more)
  // count; tries happen while typing, so the first 10 are free.
  static const _pwFails = 'password-fails';
  static const _pwUntil = 'password-wait-until';

  static Duration passwordWaitFor(int fails) => fails < 10 ? Duration.zero : waitFor(fails - 5);

  static Future<DateTime?> passwordWaitUntil() => TryWait.until(_storage, _pwUntil);

  static Future<Duration> addPasswordFail() async {
    var n = 0;
    try {
      n = (int.tryParse(await _storage.read(key: _pwFails) ?? '') ?? 0) + 1;
    } catch (_) {}
    final wait = passwordWaitFor(n);
    try {
      await _storage.write(key: _pwFails, value: '$n');
      if (wait > Duration.zero) await TryWait.start(_storage, _pwUntil, wait);
    } catch (_) {}
    return wait;
  }

  static Future<void> resetPasswordFails() async {
    try {
      await _storage.write(key: _pwFails, value: '0');
      await TryWait.clear(_storage, _pwUntil);
    } catch (_) {}
  }

  static Future<void> resetFails() async {
    try {
      await _storage.write(key: _fails, value: '0');
      await TryWait.clear(_storage, _until);
    } catch (_) {}
  }

  /// The app no longer offers a PIN (decisions 2026-10-28): drop the PIN of every vault
  /// that opens with a password, then the device key once no PIN is left. A PIN-only
  /// vault (made before, never given a password) keeps its PIN and the key.
  static Future<void> retire(String libraryDir, {
    required int Function({required String dir}) forgetWithPassword,
    required List<int> Function({required String dir}) lengths,
  }) async {
    try {
      forgetWithPassword(dir: libraryDir);
      if (lengths(dir: libraryDir).isNotEmpty) return;
      await _storage.delete(key: _wrapped);
      await _storage.delete(key: _key);
      await resetFails();
    } catch (_) {} // tried again at the next lock screen
  }
}

/// A wait after wrong tries that changing the phone's date and time cannot shorten
/// (owner 2026-10-26). What is kept is the time left, not an end time: it goes down only
/// while the app runs, by the smaller of the wall clock and a monotonic clock, so moving
/// the date forward gains nothing and moving it back costs nothing. Time with the app
/// closed does not count.
abstract final class TryWait {
  static final _mono = Stopwatch()..start();
  /// Per wait, the monotonic reading at the last update in this run of the app.
  static final _seen = <String, Duration>{};

  @visibleForTesting
  static Duration Function() monotonic = () => _mono.elapsed;
  @visibleForTesting
  static DateTime Function() wall = DateTime.now;

  static Future<void> start(FlutterSecureStorage storage, String name, Duration wait) async {
    _seen[name] = monotonic();
    await storage.write(key: name, value: '${wait.inMilliseconds}|${wall().millisecondsSinceEpoch}');
  }

  static Future<void> clear(FlutterSecureStorage storage, String name) async {
    _seen.remove(name);
    await storage.delete(key: name);
  }

  /// The end of the wait as the screen shows it (now plus what is left), or null.
  static Future<DateTime?> until(FlutterSecureStorage storage, String name) async {
    try {
      final parts = (await storage.read(key: name) ?? '').split('|');
      if (parts.length != 2) return null; // none, or an end time from before 0.1.76
      var left = Duration(milliseconds: int.tryParse(parts[0]) ?? 0);
      final stamp = DateTime.fromMillisecondsSinceEpoch(int.tryParse(parts[1]) ?? 0);
      final mono = monotonic();
      final before = _seen[name];
      if (before != null) {
        var gone = wall().difference(stamp);
        final monoGone = mono - before;
        if (monoGone < gone) gone = monoGone;
        if (gone > Duration.zero) left -= gone;
      }
      _seen[name] = mono;
      if (left <= Duration.zero) {
        await clear(storage, name);
        return null;
      }
      await storage.write(key: name, value: '${left.inMilliseconds}|${wall().millisecondsSinceEpoch}');
      return wall().add(left);
    } catch (_) {
      return null;
    }
  }
}
