// The quick tour after a vault is made: tips over the vault's own page show once the new
// vault opens, Next moves on, Skip closes it, and "Set up sync now" lands on the Sync page
// (through Settings, so Back goes there). Settings → User guide runs it again and
// goes on into Settings.
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

    // The tips cover the vault that just opened, starting at the add tiles (it is empty).
    expect(find.byType(VaultHomeScreen), findsOneWidget);
    expect(find.byType(CoachTour), findsOneWidget);
    expect(find.byKey(const ValueKey('tip-add')), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);
    // A tap on the dim does nothing.
    await t.tapAt(const Offset(20, 300));
    await _settle(t);
    expect(find.byKey(const ValueKey('tip-add')), findsOneWidget);
    // Next moves on; Skip closes the tour and leaves the vault open.
    await t.tap(find.byKey(const ValueKey('tip-next')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tip-items')), findsOneWidget);
    expect(find.text('2/5'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tip-skip')));
    await _settle(t);
    expect(find.byType(CoachTour), findsNothing);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('"Set up sync now" opens the Sync page', (t) async {
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault, tour: TourKind.created)));
    await _settle(t);
    expect(find.byType(CoachTour), findsOneWidget);
    // Add → items → Settings → the lock → a second copy.
    for (final id in ['add', 'items', 'settings', 'lock']) {
      expect(find.byKey(ValueKey('tip-$id')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tip-next')));
      await _settle(t);
    }
    expect(find.byKey(const ValueKey('tip-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('tip-skip')), findsNothing); // Later instead
    await t.tap(find.byKey(const ValueKey('tip-action')));
    await _settle(t);
    expect(find.byType(CoachTour), findsNothing);
    expect(find.byType(SyncScreen), findsOneWidget);
    // Back from Sync is Settings.
    await t.pageBack();
    await _settle(t);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('after a restore the tour is the short one, and Settings runs it again', (t) async {
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault, tour: TourKind.restored)));
    await _settle(t);
    // Add → items → Settings (an empty vault has no tabs yet), then Done.
    expect(find.byKey(const ValueKey('tip-add')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tip-next')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('tip-next')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tip-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('tip-skip')), findsNothing);
    await t.tap(find.byKey(const ValueKey('tip-next')));
    await _settle(t);
    expect(find.byType(CoachTour), findsNothing);
    // Settings → User guide (near the top): Settings closes and the tips start again on
    // the vault, then go on into Settings, counting on.
    await t.tap(find.byKey(const ValueKey('settings-button')));
    await _settle(t);
    expect(find.byType(CoachTour), findsNothing); // opening Settings alone shows no tips
    // Help is near the end of Settings since 2026-10-27: scroll to it first.
    await t.scrollUntilVisible(find.byKey(const ValueKey('guide-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('guide-row')));
    await _settle(t);
    expect(find.byType(SettingsScreen), findsNothing);
    // Add → items → Settings → the lock → a second copy (no button: Sync comes next).
    for (final (i, id) in ['add', 'items', 'settings', 'lock', 'copy'].indexed) {
      expect(find.byKey(ValueKey('tip-$id')), findsOneWidget);
      expect(find.text('${i + 1}/9'), findsOneWidget);
      expect(find.byKey(const ValueKey('tip-action')), findsNothing);
      await t.tap(find.byKey(const ValueKey('tip-next')));
      await _settle(t);
    }
    // In Settings: Sync → Security → Back up → the guide's own row, then Done.
    expect(find.byType(SettingsScreen), findsOneWidget);
    for (final (i, id) in ['sync', 'security', 'backup', 'guide'].indexed) {
      expect(find.byKey(ValueKey('tip-$id')), findsOneWidget, reason: id);
      expect(find.text('${i + 6}/9'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tip-next')));
      await _settle(t);
    }
    expect(find.byType(CoachTour), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Skip on the vault page does not go on into Settings', (t) async {
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault)));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('settings-button')));
    await _settle(t);
    // Help is near the end of Settings since 2026-10-27: scroll to it first.
    await t.scrollUntilVisible(find.byKey(const ValueKey('guide-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.byKey(const ValueKey('guide-row')));
    await _settle(t);
    expect(find.byKey(const ValueKey('tip-add')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tip-skip')));
    await _settle(t);
    expect(find.byType(CoachTour), findsNothing);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('with "Lock as soon as I leave" off, the lock tip says so', (t) async {
    Prefs.write('lock-on-leave', '0');
    await _pump(t, _app(const VaultHomeScreen(libraryDir: 'lib', vault: _vault, tour: TourKind.created)));
    await _settle(t);
    for (var i = 0; i < 3; i++) {
      await t.tap(find.byKey(const ValueKey('tip-next')));
      await _settle(t);
    }
    expect(find.byKey(const ValueKey('tip-lock')), findsOneWidget);
    expect(find.textContaining('also while you are away'), findsOneWidget);
  });
}
