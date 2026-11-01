import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'l10n/app_localizations.dart';
import 'platform.dart';
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
/// when the device has none) and a password made up here, kept in the Android Keystore.
/// Made already, it opens that same vault with the kept password. Anyone who can unlock
/// the phone can open that vault, so it is for trying the app, never for real things.
abstract final class TestLogin {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'cozysafe_test_login', resetOnError: false),
  );
  static const _password = 'password';

  /// Mockups: show the button on any platform.
  static bool debugShown = false;

  /// Whether the button shows: Android test builds only.
  static bool get shown => debugShown || (testLoginBuild && Device.android);

  /// Open the test vault, made first when there is none.
  static Future<void> run(BuildContext context, String libraryDir) async {
    final l = AppLocalizations.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    try {
      var password = await _storage.read(key: _password);
      rust.VaultInfo? vault;
      if (password != null && rust.hasVaults(dir: libraryDir)) {
        vault = await rust.unlock(dir: libraryDir, password: password);
      }
      if (vault == null) {
        // The device's words; new ones when it has none yet.
        if (await SecretKeyStore.read() == null) {
          final key = rust.newSecretKey();
          await SecretKeyStore.write(key);
          rust.setSecretKey(dir: libraryDir, key: key);
        }
        password = rust.suggestPassphrase();
        vault = await rust.createVaultWithPassword(
          dir: libraryDir,
          icon: 'bolt',
          color: 'orange',
          password: password,
          topSecret: false,
        );
        await _storage.write(key: _password, value: password);
      }
      TopSecretMode.opened(vault);
      final opened = vault;
      nav.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => Readable(child: VaultHomeScreen(libraryDir: libraryDir, vault: opened))),
        (_) => false,
      );
    } catch (_) {
      if (context.mounted) showToast(context, l.testLoginFailed, icon: Icons.error_outline_rounded);
    }
  }
}
