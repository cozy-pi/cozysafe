// Settings → the copy of the 24 words in iCloud Keychain / the Google account. Turning
// it off removed the copy for every device on the account on one tap of the switch. Now
// off asks for the owner as on does, then a card says what goes and offers to check the
// 24 words first.

import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/key_check.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/secret_key_store.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) =>
      call.memberName.toString().contains('SecretKeyFingerprint') ? 'a1b2' : null;
}

void main() {
  final key = Uint8List.fromList(List.filled(32, 9));
  final cloud = <String, String>{};

  setUpAll(() => RustLib.initMock(api: _Fake()));

  setUp(() async {
    cloud.clear();
    forgetOwnerCheck(); // an owner check of the test before covers two minutes
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Settings.debugIOS = true;
    KeyBackup.debugSupported = true;
    KeyBackup.debugGoogle = false;
    KeyBackup.debugStore = cloud;
    SettingsScreen.debugSyncLog = const [];
    SettingsScreen.debugPage = settingsPageOf(SettingsSpot.keyBackup);
    FlutterSecureStorage.setMockInitialValues({});
    await SecretKeyStore.write(key);
    expect(await KeyBackup.save(key, vault: '7F3A-9K2Q'), isTrue);
    expect(cloud, hasLength(1));
  });

  tearDown(() {
    Settings.debugIOS = false;
    KeyBackup.debugSupported = null;
    KeyBackup.debugGoogle = null;
    KeyBackup.debugStore = null;
    SettingsScreen.debugPage = null;
    SettingsScreen.debugSyncLog = null;
    debugOwnerConfirmed = false;
  });

  Future<Finder> open(WidgetTester t) async {
    t.view.physicalSize = const Size(430, 932) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(
        libraryDir: '',
        vault: () => const VaultInfo(code: '7F3A-9K2Q', libraryDir: '', id: 'v', name: '', icon: 'home', color: 'green', hasPassword: true, topSecret: false),
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
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final row = find.byKey(const ValueKey('key-backup-row'));
    if (row.evaluate().isEmpty) {
      await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    }
    final toggle = find.descendant(of: row, matching: find.byType(Switch));
    expect(t.widget<Switch>(toggle).value, isTrue);
    return toggle;
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('off asks first: Cancel keeps the copy, Remove takes it out', (t) async {
    debugOwnerConfirmed = true;
    final toggle = await open(t);
    await t.tap(toggle);
    await settle(t);
    expect(find.text('Remove the cloud copy of the 24 words?'), findsOneWidget);
    expect(find.textContaining('every device on this account'), findsOneWidget);
    expect(cloud, hasLength(1));
    await t.tap(find.byKey(const ValueKey('key-backup-off-cancel')));
    await settle(t);
    expect(cloud, hasLength(1));
    expect(t.widget<Switch>(toggle).value, isTrue);

    await t.tap(toggle);
    await settle(t);
    await t.tap(find.byKey(const ValueKey('key-backup-off-go')));
    await settle(t);
    expect(cloud, isEmpty);
    expect(t.widget<Switch>(toggle).value, isFalse);
  });

  testWidgets('the card leads to Check your 24 words, and the copy stays', (t) async {
    debugOwnerConfirmed = true;
    final toggle = await open(t);
    await t.tap(toggle);
    await settle(t);
    await t.tap(find.byKey(const ValueKey('key-backup-off-check')));
    await settle(t);
    expect(find.byType(KeyCheckScreen), findsOneWidget);
    expect(cloud, hasLength(1));
  });

  testWidgets('without the owner nothing is asked and nothing goes', (t) async {
    final toggle = await open(t);
    await t.tap(toggle);
    await settle(t);
    expect(find.byKey(const ValueKey('key-backup-off-go')), findsNothing);
    expect(cloud, hasLength(1));
    expect(t.widget<Switch>(toggle).value, isTrue);
    // The toast of the owner check that could not run here goes by itself.
    await t.pump(const Duration(seconds: 9));
    await t.pump(const Duration(seconds: 1));
  });
}
