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

/// The PIN's device half (ADR 0001): one random key that never leaves this device's
/// keystore, shared by every vault's PIN here, plus the count of wrong PINs. Wrong
/// PINs make you wait longer and longer (1, 5, 15, 60 minutes) and never wipe
/// anything: a vault may have no password to fall back on.
class PinStore {
  static const _key = 'pin-device-key';
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
      final v = await _storage.read(key: _key);
      return v == null ? null : base64Decode(v);
    } catch (_) {
      return null;
    }
  }

  /// The device key, made once (from `random16`) the first time a PIN is set.
  static Future<Uint8List> deviceKeyOrCreate(Uint8List Function() random16) async {
    final existing = await deviceKey();
    if (existing != null) return existing;
    final key = random16();
    await _storage.write(key: _key, value: base64Encode(key));
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
  static Future<DateTime?> waitUntil() async {
    try {
      final ms = int.tryParse(await _storage.read(key: _until) ?? '');
      if (ms == null) return null;
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      return t.isAfter(DateTime.now()) ? t : null;
    } catch (_) {
      return null;
    }
  }

  /// Wait after this many wrong PINs in a row (4 free tries).
  static Duration waitFor(int fails) => switch (fails) {
        < 5 => Duration.zero,
        5 => const Duration(minutes: 1),
        6 => const Duration(minutes: 5),
        7 => const Duration(minutes: 15),
        _ => const Duration(hours: 1),
      };

  /// Record a wrong PIN; returns the wait it caused.
  static Future<Duration> addFail() async {
    final n = (await fails()) + 1;
    final wait = waitFor(n);
    try {
      await _storage.write(key: _fails, value: '$n');
      if (wait > Duration.zero) {
        await _storage.write(key: _until, value: '${DateTime.now().add(wait).millisecondsSinceEpoch}');
      }
    } catch (_) {}
    return wait;
  }

  // Wrong vault passwords (owner 2026-10-23: weak passwords are allowed, so guessing on
  // this phone must be slow). Only tries of a possible password (8 characters or more)
  // count; tries happen while typing, so the first 10 are free.
  static const _pwFails = 'password-fails';
  static const _pwUntil = 'password-wait-until';

  static Duration passwordWaitFor(int fails) => fails < 10 ? Duration.zero : waitFor(fails - 5);

  static Future<DateTime?> passwordWaitUntil() async {
    try {
      final ms = int.tryParse(await _storage.read(key: _pwUntil) ?? '');
      if (ms == null) return null;
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      return t.isAfter(DateTime.now()) ? t : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Duration> addPasswordFail() async {
    var n = 0;
    try {
      n = (int.tryParse(await _storage.read(key: _pwFails) ?? '') ?? 0) + 1;
    } catch (_) {}
    final wait = passwordWaitFor(n);
    try {
      await _storage.write(key: _pwFails, value: '$n');
      if (wait > Duration.zero) {
        await _storage.write(key: _pwUntil, value: '${DateTime.now().add(wait).millisecondsSinceEpoch}');
      }
    } catch (_) {}
    return wait;
  }

  static Future<void> resetPasswordFails() async {
    try {
      await _storage.write(key: _pwFails, value: '0');
      await _storage.delete(key: _pwUntil);
    } catch (_) {}
  }

  static Future<void> resetFails() async {
    try {
      await _storage.write(key: _fails, value: '0');
      await _storage.delete(key: _until);
    } catch (_) {}
  }
}
