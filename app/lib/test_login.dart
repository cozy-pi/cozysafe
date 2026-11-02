import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'l10n/app_localizations.dart';
import 'platform.dart';
import 'screens/common.dart';
import 'screens/vault_home.dart';
import 'secret_key_store.dart';
import 'src/rust/api/vault.dart' as rust;
import 'top_secret_mode.dart';
import 'widgets/readable.dart';
import 'widgets/toast.dart';

/// Builds for closed testing on Android are made with `--dart-define=TEST_LOGIN=true`
/// (release.yml, its `test_login` input): a build for everyone is made without it.
const testLoginBuild = bool.fromEnvironment('TEST_LOGIN');

/// "Test sign-in" (owner 2026-11-01), for testers of the Android builds: one tap opens a
/// vault. With none made this way yet, it makes one: the device's 24 words (new ones
/// when the device has none) and the fixed password "123456789"
/// ([rust.testVaultPassword]), which testers also type on their other devices. Made
/// already, it opens that same vault. Anyone can open that vault, so it is for trying the
/// app, never for real things (its note says so).
abstract final class TestLogin {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'cozysafe_test_login', resetOnError: false),
  );
  /// A made-up password of the first test builds (0.2.1 build 1129), still tried.
  static const _oldPassword = 'password';
  static const _vault = 'vault';

  /// Mockups: show the button on any platform; this vault is the test vault.
  static bool debugShown = false;
  static String? debugVaultId;

  /// Whether the button shows: Android test builds only.
  static bool get shown => debugShown || (testLoginBuild && Device.android);

  /// The passwords a test vault here opens with: the fixed one, and one kept by a first
  /// test build.
  static Future<List<String>> _passwords() async {
    String? old;
    try {
      old = await _storage.read(key: _oldPassword);
    } catch (_) {}
    return [rust.testVaultPassword(), ?old];
  }

  /// Open the test vault, made first when there is none.
  static Future<void> run(BuildContext context, String libraryDir) async {
    final l = AppLocalizations.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    try {
      rust.VaultInfo? vault;
      if (rust.hasVaults(dir: libraryDir)) {
        for (final password in await _passwords()) {
          vault = await rust.unlock(dir: libraryDir, password: password);
          if (vault != null) break;
        }
      }
      if (vault == null) {
        // None yet, or the one from before is gone: a new one, with the device's words
        // (new ones when it has none yet).
        if (await SecretKeyStore.read() == null) {
          final key = rust.newSecretKey();
          await SecretKeyStore.write(key);
          rust.setSecretKey(dir: libraryDir, key: key);
        }
        vault = await rust.createTestVault(dir: libraryDir);
      }
      await _storage.write(key: _vault, value: vault.id);
      TopSecretMode.opened(vault);
      final opened = vault;
      nav.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => Readable(child: VaultHomeScreen(libraryDir: libraryDir, vault: opened))),
        (_) => false,
      );
    } catch (e) {
      if (context.mounted) showToast(context, withCode(l, l.testLoginFailed, e), icon: Icons.error_outline_rounded);
    }
  }

  /// The test vault's id, when this is a test build and one was made (or opened) here.
  static Future<String?> vaultId() async {
    if (debugVaultId != null) return debugVaultId;
    if (!shown) return null;
    try {
      return await _storage.read(key: _vault);
    } catch (_) {
      return null;
    }
  }

  /// Whether the vault open now is this test build's test vault.
  static Future<bool> isOpen() async {
    final open = rust.openVaultInfo()?.id;
    return open != null && await vaultId() == open;
  }

  /// Delete the test vault (owner 2026-11-01: no password to type for it). False when
  /// [id] is not the test vault or it did not go.
  static Future<bool> delete(String libraryDir, String id) async {
    if (await vaultId() != id) return false;
    for (final password in await _passwords()) {
      final ok = rust.openVaultInfo()?.id == id
          ? await rust.deleteVault(dir: libraryDir, password: password)
          : await rust.deleteOtherVault(dir: libraryDir, vaultId: id, password: password);
      if (ok) {
        await _storage.delete(key: _vault);
        await _storage.delete(key: _oldPassword);
        // Its library's last vault: its 24 words go too, as for any vault.
        try {
          if (!rust.libraryHasVaults(dir: libraryDir) && await rust.resetEmptyLibrary(dir: libraryDir)) {
            await SecretKeyStore.delete();
          }
        } catch (_) {}
        return true;
      }
    }
    return false;
  }
}
