import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'l10n/app_localizations.dart';
import 'lock_guard.dart';
import 'platform.dart';
import 'privacy.dart';
import 'widgets/brand.dart';

import 'src/rust/api/vault.dart' as rust;
import 'top_secret_mode.dart';

/// What the device unlocks with, for the button label.
enum BiometricKind { face, fingerprint }

/// The biometric-gated half of biometric unlock (ADR 0001). Rust wraps a copy of the
/// vault's Master Key with a random key; that key lives here, in the Keychain
/// (`biometryCurrentSet`: a new fingerprint or face invalidates it), the Android
/// Keystore (strong biometrics, a fresh check for every read), or on a Mac wrapped by a
/// Touch ID key in the Secure Enclave ([MacBioKey]). Neither half opens the vault alone.
class BiometricUnlock {
  BiometricUnlock({required this.promptTitle, required this.promptCancel});

  final String promptTitle;
  final String promptCancel;

  static const _key = 'vault-unlock-key';
  static bool get platformSupported =>
      debugKind != null || Device.iOS || Device.android || MacBioKey.supported;

  /// For the mockup renders: act as a phone with this biometric (an iPhone: face).
  static BiometricKind? debugKind;

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
    if (debugKind != null) return debugKind;
    if (!platformSupported) return null;
    if (MacBioKey.supported) return await MacBioKey.available() ? BiometricKind.fingerprint : null;
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

  Future<void> save(Uint8List key) async {
    if (MacBioKey.supported) return MacBioKey.save(key);
    await _storage.write(key: _key, value: base64Encode(key));
  }

  /// Shows the system prompt. Null when the key is gone (biometrics changed, turned off).
  /// Throws when the user cancels or the check fails.
  Future<Uint8List?> read() async {
    if (MacBioKey.supported) return MacBioKey.read(promptTitle);
    final v = await PrivacyCover.whileAsking(() => _storage.read(key: _key));
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
    if (MacBioKey.supported) return MacBioKey.clear();
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Already gone or unreadable: either way nothing usable is left.
    }
  }
}

/// Touch ID on a Mac (docs/security.md, "Touch ID on a Mac"). The keychain items phones
/// use need the data-protection keychain on macOS, and with it a provisioning profile the
/// Developer ID build does not have. Instead the native side (`cozysafe/biokey`,
/// `macos/Runner/MainFlutterWindow.swift`) makes a Secure Enclave key that only Touch ID
/// can use (`biometryCurrentSet`) and wraps the biometric key with it; the wrapped blob is
/// useless off this Mac, so it lives in the legacy keychain like the Secret Key.
abstract final class MacBioKey {
  static const _channel = MethodChannel('cozysafe/biokey');
  static const _key = 'vault-unlock-key-enclave';
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(
      accountName: 'cozysafe.biometric',
      usesDataProtectionKeychain: false,
      synchronizable: false,
    ),
  );

  /// For tests: stands in for the Secure Enclave, and makes any platform act as a Mac.
  /// `unwrap` gives null when the key is gone, throws when the person cancels.
  @visibleForTesting
  static ({
    Future<bool> Function() available,
    Future<Uint8List?> Function(Uint8List) wrap,
    Future<Uint8List?> Function(Uint8List blob, String reason) unwrap,
  })? debug;

  /// Mockup renders and tests that act as a phone ([BiometricUnlock.debugKind],
  /// `Device.debugDesktop = false`) are not a Mac here either.
  static bool get supported =>
      debug != null || (Device.macOS && Device.debugDesktop != false && BiometricUnlock.debugKind == null);

  static Future<bool> available() async {
    if (debug case final d?) return d.available();
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Throws when the enclave cannot make the key: turning on is then rolled back.
  static Future<void> save(Uint8List key) async {
    final blob = debug != null
        ? await debug!.wrap(key)
        : await _channel.invokeMethod<Uint8List>('wrap', {'bytes': key});
    if (blob == null) throw StateError('No Touch ID key');
    await _storage.write(key: _key, value: base64Encode(blob));
  }

  /// Touch ID, then the key. Null when it is gone (fingers changed, nothing stored);
  /// throws when the person cancels or is not recognised.
  static Future<Uint8List?> read(String reason) async {
    final v = await _storage.read(key: _key);
    if (v == null) return null;
    final blob = base64Decode(v);
    if (debug case final d?) return d.unwrap(blob, reason);
    return PrivacyCover.whileAsking(
        () => _channel.invokeMethod<Uint8List>('unwrap', {'bytes': blob, 'reason': reason}));
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

/// The unlock button's text for [kind]: Touch ID on a Mac.
String unlockWithLabel(AppLocalizations l, BiometricKind kind) => kind == BiometricKind.face
    ? l.unlockWithFace
    : MacBioKey.supported
        ? l.unlockWithTouchId
        : l.unlockWithFingerprint;

/// The setting's title for [kind]: Touch ID on a Mac.
String opensThisVaultLabel(AppLocalizations l, BiometricKind kind) => kind == BiometricKind.face
    ? l.biometricThisVault
    : MacBioKey.supported
        ? l.touchIdThisVault
        : l.fingerprintThisVault;

/// Ask the phone's owner to confirm with Face ID, a fingerprint or the phone's
/// passcode (the system decides). Used before making another vault. True where the
/// device has no such check at all (some computers): there is nothing to ask.
/// For tests and mockup renders in debug builds only; see [confirmOwner].
bool debugOwnerConfirmed = false;

Future<bool> confirmOwner(String reason) async {
  // Mockup renders only: a debug build can act as if the owner confirmed. Release builds
  // compile this away (kDebugMode is a constant false there), so it is never a bypass.
  if (kDebugMode && debugOwnerConfirmed) return true;
  try {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) return true;
    return await PrivacyCover.whileAsking(() => auth.authenticate(localizedReason: reason));
  } catch (_) {
    return false;
  }
}

/// Every security setting asks who is holding the phone first (docs/security.md,
/// security settings): Face ID, fingerprint, or the phone's passcode. The vault stays
/// open while the system prompt is up.
Future<bool> confirmOwnerForSetting(String reason) async {
  LockGuard.allowAway();
  try {
    return await confirmOwner(reason);
  } finally {
    LockGuard.clear();
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

/// Ask once whether the open vault should open with Face ID / Touch ID / fingerprint
/// on this device, when it can and does not already (a vault restored or opened with the
/// password here). Replaces the PIN offered there before 2026-10-28.
Future<void> offerBiometric(BuildContext context) async {
  if (!BiometricUnlock.platformSupported || rust.biometricEnabled()) return;
  // One vault per device: never taken from another one by this question.
  if (rust.hasBiometricUnlock(dir: TopSecretMode.libraryDir)) return;
  final kind = await BiometricUnlock.available();
  if (kind == null || !context.mounted) return;
  final l = AppLocalizations.of(context);
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.biometricOfferTitle),
      content: Text(l.biometricOfferBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.biometricOfferNo)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.biometricOfferYes)),
      ],
    ),
  );
  if (yes == true) await turnOnBiometric(BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel));
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
