import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'appearance.dart';
import 'debug_log.dart';
import 'l10n/app_localizations.dart';
import 'language.dart';
import 'offline.dart';
import 'screens/new_vault.dart';
import 'screens/settings.dart';
import 'screens/video_view.dart';
import 'screens/restore.dart';
import 'screens/unlock.dart';
import 'secret_key_store.dart';
import 'src/rust/api/vault.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme.dart';
import 'widgets/brand.dart';
import 'widgets/native_bar.dart';
import 'prefs.dart';
import 'privacy.dart';

Future<void> main() async {
  installNetworkGuard(); // before any plugin or library code runs
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final support = await getApplicationSupportDirectory();
  final libraryDir = '${support.path}${Platform.pathSeparator}library';
  Prefs.dir = support.path;
  Settings.apply(); // Android: honour "block screenshots" off
  PrivacyCover.listen(); // iOS: screenshots taken (they cannot be stopped there)
  clearPlaybackCopies(); // a decrypted video copy left by a crash or a kill
  final hasKey = await loadSecretKey(libraryDir);
  await AppLanguage.load();
  await NativeBar.probe(); // iOS 26: the system's own bottom bar
  DebugLog.sync(); // keep debug lines only if debug mode is on
  Appearance.load();
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
  const CozySafeApp({super.key, required this.libraryDir, required this.hasSecretKey, this.locale});

  final String libraryDir;
  final bool hasSecretKey;
  /// Null follows the system language (the browser preview pins Vietnamese).
  final Locale? locale;

  @override
  Widget build(BuildContext context) {
    // The open vault's colour themes every screen above it (design B).
    return ListenableBuilder(
      listenable: Listenable.merge([vaultTint, AppLanguage.current, Appearance.mode]),
      builder: (context, _) => MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      // From the system launch screen to the first screen without a jump.
      builder: (context, child) => LaunchHandoff(child: child ?? const SizedBox.shrink()),
      // Settings → Language (or the system's per-app language), else the device's.
      locale: locale ?? AppLanguage.current.value,
      localeResolutionCallback: (device, supported) => resolveLocale(device, supported),
      theme: buildTheme(Brightness.light, vault: vaultTint.value),
      darkTheme: buildTheme(Brightness.dark, vault: vaultTint.value),
      themeMode: Appearance.mode.value,
      // Follow the system language; English when the device language is unsupported.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: !rust.hasVaults(dir: libraryDir)
          ? NewVaultScreen(libraryDir: libraryDir, first: true)
          : hasSecretKey
              ? UnlockScreen(libraryDir: libraryDir)
              // Vaults are here but this device has no Secret Key (reinstall,
              // restored phone): ask for the Emergency Kit.
              : RestoreScreen(libraryDir: libraryDir, needFile: false),
      ),
    );
  }
}
