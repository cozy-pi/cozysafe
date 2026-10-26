// The quick tour after a vault is made: it shows once the new vault opens, Skip closes
// it, and "Set up sync now" lands on the Sync page (through Settings, so Back goes there).
// The Rust core is a fake.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/tour.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/sync_screen.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _vault = VaultInfo(id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: true);

class _Fake implements RustLibApi {
  int created = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('MinPasswordLength')) return 8;
    if (name.contains('MinPinLength')) return 6;
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordProblem')) return PasswordProblem.none;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return true;
    if (name.contains('CreateVaultWithPin')) {
      created++;
      return Future<VaultInfo>.value(_vault);
    }
    if (name.contains('SetPassword') || name.contains('SetIdentity')) return Future<VaultInfo>.value(_vault);
    if (name.contains('ListItems') || name.contains('ListHeld') || name.contains('ListTrash')) {
      return Future<List<ItemInfo>>.value(const []);
    }
    if (name.contains('PurgeExpired')) return Future<int>.value(0);
    if (name.contains('NewSecretKey')) return Uint8List.fromList(List.filled(16, 3));
    if (name.contains('BiometricEnabled') || name.contains('HasBiometricUnlock')) return false;
    if (name.contains('PinLengths')) return Uint32List.fromList([6]);
    if (name.contains('PinEnabled') || name.contains('AnyPassword')) return true;
    return null;
  }
}

late _Fake _fake;

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// The owner's phone (iPhone 15 Pro Max): Settings' Left | Middle | Right switch needs
/// its width in the test font.
Future<void> _pump(WidgetTester t, Widget app) async {
  t.view.physicalSize = const Size(430, 932) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(app);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.pumpAndSettle();
}

Future<void> _tapDigits(WidgetTester t, String digits) async {
  for (final d in digits.split('')) {
    await t.tap(find.text(d).last);
    await t.pump();
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  setUp(() {
    _fake.created = 0;
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    BiometricUnlock.debugKind = null;
    VaultHomeScreen.debugReveal = false;
    NewVaultScreen.debugWords = List.filled(24, 'word').join(' ');
    SyncScreen.debugLog = const [];
    SettingsScreen.debugSyncLog = const [];
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
    });
  });

  tearDown(() {
    NewVaultScreen.debugWords = null;
    VaultHomeScreen.debugReveal = true;
    SyncScreen.debugLog = null;
    SettingsScreen.debugSyncLog = null;
  });

  testWidgets('the tour shows after a vault is made, and Skip closes it', (t) async {
    await _pump(t, _app(const NewVaultScreen(libraryDir: 'lib', first: false)));
    await _settle(t);
    // What each key is for → the password → the PIN, twice → the look (skipped).
    await t.tap(find.byKey(const ValueKey('intro-start')));
    await _settle(t);
    const password = 'orange kettle whispers at dawn';
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('new-password')), matching: find.byType(TextField)), password);
    await t.enterText(
        find.descendant(of: find.byKey(const ValueKey('new-password-again')), matching: find.byType(TextField)), password);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('password-next')));
    await _settle(t);
    await _tapDigits(t, '135790');
    await t.tap(find.byKey(const ValueKey('pin-next')));
    await _settle(t);
    await _tapDigits(t, '135790');
    await _settle(t);
    expect(_fake.created, 1);
    await t.tap(find.byKey(const ValueKey('new-vault-skip')));
    await _settle(t);

    // The tour covers the vault that just opened.
    expect(find.byType(VaultHomeScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(TourScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-add')), findsOneWidget);
    // Skip closes the tour and leaves the vault open.
    await t.tap(find.byKey(const ValueKey('tour-next')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tour-open')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tour-skip')));
    await _settle(t);
    expect(find.byType(TourScreen), findsNothing);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('"Set up sync now" opens the Sync page', (t) async {
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault, tour: TourKind.created)));
    await _settle(t);
    expect(find.byType(TourScreen), findsOneWidget);
    // Swipe to the next card, then Next to the second-copy card.
    await t.drag(find.byKey(const ValueKey('tour-pages')), const Offset(-300, 0));
    await _settle(t);
    expect(find.byKey(const ValueKey('tour-open')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tour-next')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tour-keys')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tour-next')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('tour-sync')));
    await _settle(t);
    expect(find.byType(TourScreen), findsNothing);
    expect(find.byType(SyncScreen), findsOneWidget);
    // Back from Sync is Settings.
    await t.pageBack();
    await _settle(t);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('after a restore the tour is the short one, and Settings opens it again', (t) async {
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault, tour: TourKind.restored)));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('tour-next')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('tour-next')));
    await _settle(t);
    // Third and last card: the settings worth a look (no safety or second-copy card).
    expect(find.byKey(const ValueKey('tour-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-skip')), findsNothing);
    // A setting there opens Settings at that row.
    await t.tap(find.byKey(const ValueKey('tour-blurThumbs')));
    await _settle(t);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('blur-row')).hitTestable(), findsOneWidget);
    // Settings → Quick tour shows it again.
    await t.scrollUntilVisible(find.byKey(const ValueKey('tour-row')), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('tour-row')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tour-add')), findsOneWidget);
  });
}
