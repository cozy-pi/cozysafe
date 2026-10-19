import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';
import 'screens/create_vault.dart';
import 'screens/restore.dart';
import 'screens/unlock.dart';
import 'secret_key_store.dart';
import 'src/rust/api/vault.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final support = await getApplicationSupportDirectory();
  final libraryDir = '${support.path}${Platform.pathSeparator}library';
  final hasKey = await loadSecretKey(libraryDir);
  runApp(CozySafeApp(libraryDir: libraryDir, hasSecretKey: hasKey));
}

/// Hand this device's Secret Key to Rust. First-preview installs kept it in a file:
/// move it into the keystore, and wipe the file only once the keystore has it.
Future<bool> loadSecretKey(String libraryDir) async {
  var key = await SecretKeyStore.read();
  if (key == null) {
    try {
      final legacy = await rust.legacySecretKey(dir: libraryDir);
      if (legacy != null) {
        await SecretKeyStore.write(legacy);
        await rust.forgetLegacySecretKey(dir: libraryDir);
        key = legacy;
      }
    } catch (_) {
      // Keep the file; the move is tried again next start.
    }
  }
  return key != null && rust.setSecretKey(key: key);
}

class CozySafeApp extends StatelessWidget {
  const CozySafeApp({super.key, required this.libraryDir, required this.hasSecretKey});

  final String libraryDir;
  final bool hasSecretKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      // Follow the system language; English when the device language is unsupported.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: !rust.hasVaults(dir: libraryDir)
          ? CreateVaultScreen(libraryDir: libraryDir, first: true)
          : hasSecretKey
              ? UnlockScreen(libraryDir: libraryDir)
              // Vaults are here but this device has no Secret Key (reinstall,
              // restored phone): ask for the Emergency Kit.
              : RestoreScreen(libraryDir: libraryDir, needFile: false),
    );
  }
}
