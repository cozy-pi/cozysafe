import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/app_localizations.dart';
import 'screens/create_vault.dart';
import 'screens/unlock.dart';
import 'src/rust/api/vault.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final support = await getApplicationSupportDirectory();
  final libraryDir = '${support.path}${Platform.pathSeparator}library';
  runApp(CozySafeApp(libraryDir: libraryDir));
}

class CozySafeApp extends StatelessWidget {
  const CozySafeApp({super.key, required this.libraryDir});

  final String libraryDir;

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
      home: rust.hasVaults(dir: libraryDir)
          ? UnlockScreen(libraryDir: libraryDir)
          : CreateVaultScreen(libraryDir: libraryDir, first: true),
    );
  }
}
