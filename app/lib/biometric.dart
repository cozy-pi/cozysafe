import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'widgets/brand.dart';

import 'src/rust/api/vault.dart' as rust;

/// What the device unlocks with, for the button label.
enum BiometricKind { face, fingerprint }

/// The biometric-gated half of biometric unlock (ADR 0001). Rust wraps a copy of the
/// vault's Master Key with a random key; that key lives here, in the Keychain
/// (`biometryCurrentSet`: a new fingerprint or face invalidates it) or the Android
/// Keystore (strong biometrics, a fresh check for every read). Neither half opens the
/// vault alone.
class BiometricUnlock {
  BiometricUnlock({required this.promptTitle, required this.promptCancel});

  final String promptTitle;
  final String promptCancel;

  static const _key = 'vault-unlock-key';
  static bool get platformSupported => Platform.isIOS || Platform.isAndroid;

  FlutterSecureStorage get _storage => FlutterSecureStorage(
        iOptions: const IOSOptions(
          accountName: 'cozysafe.biometric',
          accessibility: KeychainAccessibility.passcode,
          accessControlFlags: [AccessControlFlag.biometryCurrentSet],
          synchronizable: false,
        ),
        aOptions: AndroidOptions.biometric(
          storageNamespace: 'cozysafe_biometric',
          enforceBiometrics: true,
          requireBiometricsPerOperation: true,
          biometricType: AndroidBiometricType.strongBiometricOnly,
          // Never wipe silently on a failed or cancelled prompt.
          resetOnError: false,
          biometricPromptTitle: promptTitle,
          biometricPromptNegativeButton: promptCancel,
        ),
      );

  /// The kind of biometrics enrolled, or null when there is none to use.
  static Future<BiometricKind?> available() async {
    if (!platformSupported) return null;
    try {
      final auth = LocalAuthentication();
      if (!await auth.canCheckBiometrics) return null;
      final types = await auth.getAvailableBiometrics();
      if (types.isEmpty) return null;
      if (types.contains(BiometricType.face) && !types.contains(BiometricType.fingerprint)) {
        return BiometricKind.face;
      }
      return BiometricKind.fingerprint;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Uint8List key) => _storage.write(key: _key, value: base64Encode(key));

  /// Shows the system prompt. Null when the key is gone (biometrics changed, turned off).
  /// Throws when the user cancels or the check fails.
  Future<Uint8List?> read() async {
    final v = await _storage.read(key: _key);
    return v == null ? null : base64Decode(v);
  }

  /// Unlock with the system prompt. Null when the user cancels or isn't recognised;
  /// throws [BiometricKeyGone] when this device can no longer unlock biometrically.
  Future<rust.VaultInfo?> unlock(String dir) async {
    final Uint8List? key;
    try {
      key = await read();
    } catch (_) {
      return null;
    }
    if (key != null) {
      final vault = await rust.unlockWithBiometric(dir: dir, key: key);
      if (vault != null) return vault;
    }
    await rust.forgetBiometricUnlock(dir: dir);
    await clear();
    throw const BiometricKeyGone();
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Already gone or unreadable: either way nothing usable is left.
    }
  }
}

/// Turn biometric unlock on for the open vault: Rust makes the wrapped copy, the key goes
/// into the gated store (Android asks for a fingerprint here). Rolls back on failure.
Future<bool> turnOnBiometric(BiometricUnlock store) async {
  try {
    final key = await rust.enableBiometric();
    try {
      await store.save(key);
      return true;
    } catch (_) {
      await rust.disableBiometric();
      return false;
    }
  } catch (_) {
    return false;
  }
}

Future<void> turnOffBiometric(BiometricUnlock store) async {
  try {
    await rust.disableBiometric();
  } catch (_) {}
  await store.clear();
}

/// Biometrics changed (or the key was removed): unlock with the password and turn it on again.
class BiometricKeyGone implements Exception {
  const BiometricKeyGone();
}

/// The right symbol for the device: the Face ID glyph, or a fingerprint.
class BiometricGlyph extends StatelessWidget {
  const BiometricGlyph({super.key, required this.kind, this.size = 24, this.color});

  final BiometricKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => kind == BiometricKind.face
      ? FaceIdGlyph(size: size, color: color)
      : Icon(Icons.fingerprint, size: size, color: color);
}
