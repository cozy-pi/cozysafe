// Making a vault in a few taps (owner 2026-11-05): with the cloud copy of the 24 words the
// four words are not asked; without it they are, and can be skipped after a warning,
// which leaves a reminder; a Top secret vault gets neither the copy nor the skip. The copy
// names the vault by its code (ADR 0008), known from the draft before the password.
// The Rust core is a fake.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/platform.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final _key = Uint8List.fromList(List.filled(32, 9));

class _Fake implements RustLibApi {
  int created = 0;
  int drafts = 0;
  int forgotten = 0;
  bool topSecret = false;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('MinPasswordLength')) return 12;
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordProblem')) return PasswordProblem.none;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return false;
    if (name.contains('PrepareVault')) {
      drafts++;
      return '7F3A-9K2Q';
    }
    if (name.contains('ForgetVaultDraft')) {
      forgotten++;
      return null;
    }
    if (name.contains('CreateVaultWithPassword')) {
      created++;
      return Future<VaultInfo>.value(VaultInfo(
          code: '7F3A-9K2Q', libraryDir: '', id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: true, topSecret: topSecret));
    }
    if (name.contains('ParseSecretKey')) return _key;
    if (name.contains('SecretKeyFingerprint')) return 'a1b2';
    if (name.contains('ListItems') || name.contains('ListHeld') || name.contains('ListTrash')) {
      return Future<List<ItemInfo>>.value(const []);
    }
    if (name.contains('PurgeExpired')) return Future<int>.value(0);
    if (name.contains('BiometricEnabled') || name.contains('HasBiometricUnlock')) return false;
    if (name.contains('PinLengths')) return Uint32List(0);
    if (name.contains('AnyPassword')) return true;
    return null;
  }
}

late _Fake _fake;
final _cloud = <String, String>{};

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.pumpAndSettle();
}

Future<void> _start(WidgetTester t, {required bool topSecret}) async {
  t.view.physicalSize = const Size(430, 932) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  _fake.topSecret = topSecret;
  await t.pumpWidget(_app(const NewVaultScreen(libraryDir: 'lib', first: true)));
  await _settle(t);
  await t.tap(find.byKey(ValueKey(topSecret ? 'mode-top-secret' : 'mode-everyday')));
  await t.pump();
  await t.tap(find.byKey(const ValueKey('mode-next')));
  await _settle(t);
}

Future<void> _password(WidgetTester t) async {
  const password = 'orange kettle whispers at dawn';
  for (final k in ['new-password', 'new-password-again']) {
    await t.enterText(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(TextField)), password);
  }
  await t.pump();
  await t.tap(find.byKey(const ValueKey('password-next')));
  await _settle(t);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  setUp(() {
    _fake
      ..created = 0
      ..drafts = 0
      ..forgotten = 0;
    _cloud.clear();
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    BiometricUnlock.debugKind = null;
    Device.debugDesktop = false;
    VaultHomeScreen.debugReveal = false;
    NewVaultScreen.debugWords = List.filled(24, 'word').join(' ');
    KeyBackup.debugSupported = true;
    KeyBackup.debugGoogle = false;
    KeyBackup.debugStore = _cloud;
    FlutterSecureStorage.setMockInitialValues({'pin-fails': '0'});
  });

  tearDown(() {
    Device.debugDesktop = null;
    NewVaultScreen.debugWords = null;
    VaultHomeScreen.debugReveal = true;
    KeyBackup.debugSupported = null;
    KeyBackup.debugGoogle = null;
    KeyBackup.debugStore = null;
  });

  testWidgets('with the cloud copy (on by default) the words are not asked back, and the copy names the vault', (t) async {
    await _start(t, topSecret: false);
    expect(find.byKey(const ValueKey('words-cloud')), findsOneWidget);
    expect(t.widget<Switch>(find.byKey(const ValueKey('words-cloud-switch'))).value, isTrue);
    await t.tap(find.byKey(const ValueKey('words-done')));
    await _settle(t);
    // Straight to the password: no check.
    expect(find.byKey(const ValueKey('new-password')), findsOneWidget);
    expect(_cloud.keys, ['secret-key.a1b2']);
    expect(jsonDecode(_cloud['secret-key.a1b2']!)['vaults'], isEmpty);
    // The account the password manager keeps it under, from the draft.
    expect(t.widget<TextField>(find.byKey(const ValueKey('new-password-account'), skipOffstage: false)).controller!.text, 'Cozy Safe 7F3A-9K2Q');
    await _password(t);
    expect(_fake.created, 1);
    final copy = jsonDecode(_cloud['secret-key.a1b2']!) as Map<String, dynamic>;
    expect(copy['vaults'], ['7F3A-9K2Q']);
    expect(base64Decode(copy['key'] as String), _key);
    expect(KeyBackup.isOn(_key), isTrue);
    expect(Prefs.read(wordsUncheckedPref('v1')), isNot('1'));
  });

  testWidgets('without the copy the words are asked back; skipping warns first and leaves a reminder', (t) async {
    await _start(t, topSecret: false);
    await t.ensureVisible(find.byKey(const ValueKey('words-cloud-switch')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('words-cloud-switch')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('words-done')));
    await _settle(t);
    expect(_cloud, isEmpty);
    expect(find.byKey(const ValueKey('check-skip')), findsOneWidget);
    // The warning: "Check now" stays on the check.
    await t.tap(find.byKey(const ValueKey('check-skip')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('check-skip-no')));
    await _settle(t);
    expect(find.byKey(const ValueKey('check-skip')), findsOneWidget);
    // Skip anyway: on to the password; the vault is made with the reminder set.
    await t.tap(find.byKey(const ValueKey('check-skip')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('check-skip-yes')));
    await _settle(t);
    await _password(t);
    expect(_fake.created, 1);
    expect(Prefs.read(wordsUncheckedPref('v1')), '1');
  });

  testWidgets('a Top secret vault: no cloud copy, no skipping the check, no password manager', (t) async {
    await _start(t, topSecret: true);
    expect(find.byKey(const ValueKey('words-cloud')), findsNothing);
    await t.tap(find.byKey(const ValueKey('words-done')));
    await _settle(t);
    expect(find.byKey(const ValueKey('check-skip')), findsNothing);
    expect(_cloud, isEmpty);
  });

  testWidgets('leaving before the vault is made drops its draft', (t) async {
    await _start(t, topSecret: false);
    await t.tap(find.byKey(const ValueKey('words-done')));
    await _settle(t);
    // The password step drafts the vault, so its code is known before anything is typed.
    expect(_fake.drafts, 1);
    await t.pumpWidget(const SizedBox());
    expect(_fake.forgotten, 1);
  });
}
