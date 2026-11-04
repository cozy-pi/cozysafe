// Text that sends someone to a setting names the page with settingsPath (owner
// 2026-11-04: two texts said "Settings → Display", a page that no longer exists). Here
// each setting is looked for on the page settingsPath names, under the title it gives:
// move a row to another page without updating _pageOf and this fails.

import 'dart:io';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Settings.debugIOS = true; // the screenshots row shows on phones only
    SettingsScreen.debugSyncLog = const [];
  });
  tearDown(() {
    Settings.debugIOS = false;
    SettingsScreen.debugPage = null;
    SettingsScreen.debugSyncLog = null;
  });

  for (final spot in SettingsSpot.values) {
    testWidgets('${spot.name} is where settingsPath says', (t) async {
      t.view.physicalSize = const Size(430, 932) * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      SettingsScreen.debugPage = settingsPageOf(spot);
      late AppLocalizations l;
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) {
          l = AppLocalizations.of(context);
          return SettingsScreen(
            libraryDir: '',
            vault: () => const VaultInfo(libraryDir: '', id: 'v', name: '', icon: 'home', color: 'green', hasPassword: true, topSecret: false),
            canBiometric: false,
            biometricOn: () => false,
            onToggleBiometric: () async {},
            onPassword: () async {},
            onShowKit: () async {},
            onBackup: () async {},
            lastBackup: () => '',
            onChangeIdentity: () async {},
            onOpenTrash: () async {},
            onNewVault: () async {},
          );
        }),
      ));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final row = find.byKey(ValueKey('spot-${spot.name}'));
      if (row.evaluate().isEmpty) {
        await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      }
      expect(row, findsOneWidget);
      // The page's own title is the last part of the path.
      expect(find.text(settingsPath(l, spot).split(' → ').last), findsWidgets);
    });
  }
}
