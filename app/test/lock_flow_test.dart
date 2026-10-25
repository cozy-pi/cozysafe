// Flows that can lock someone out of their vault if they break: PIN, wrong tries,
// waits after wrong tries, password fallback, type-to-unlock, an add action picked while locked, setting a PIN,
// the Emergency Kit confirmation, pages kept under the lock. The Rust core is replaced by a fake with state.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/lock_resume.dart';
import 'package:cozysafe/screens/kit_password.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/secret_key_store.dart';
import 'package:cozysafe/screens/set_pin.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _pin = '2468';
const _password = 'orange kettle whispers at dawn';

class _Fake implements RustLibApi {
  int pinLength = 4;
  bool anyPassword = true;
  String? enabledPin;
  int unlockCalls = 0;
  bool biometric = false;
  int biometricCalls = 0;
  int notesAdded = 0;
  int notesUpdated = 0;

  T _arg<T>(Invocation c, String name) => c.namedArguments[Symbol(name)] as T;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('MinPasswordLength')) return 8;
    if (name.contains('MinPinLength')) return 6;
    final vault = VaultInfo(id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: anyPassword);
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordProblem')) return PasswordProblem.none;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return true;
    if (name.contains('ListItems')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListHeld')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListTrash')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('PurgeExpired')) return Future<int>.value(0);
    if (name.contains('HasBiometricUnlock')) return biometric;
    if (name.contains('UnlockWithBiometric')) {
      biometricCalls++;
      return Future<VaultInfo?>.value(null);
    }
    if (name.contains('ForgetBiometricUnlock')) return Future<void>.value();
    final note = ItemInfo(
      id: 'n1', kind: 'note', name: '', mime: 'text/plain', createdMs: 0,
      sizeBytes: BigInt.zero, tagIds: const [], isFavorite: false, modifiedMs: 0,
    );
    if (name.contains('AddNote')) {
      notesAdded++;
      return Future<ItemInfo>.value(note);
    }
    if (name.contains('UpdateNote')) {
      notesUpdated++;
      return Future<ItemInfo>.value(note);
    }
    if (name.contains('BiometricEnabled')) return false;
    if (name.contains('PinLengths')) return Uint32List.fromList(pinLength == 0 ? [] : [pinLength]);
    if (name.contains('AnyPassword')) return anyPassword;
    if (name.contains('PinEnabled')) return true; // the open vault has a PIN here
    if (name.contains('UnlockWithPin')) {
      final ok = _arg<String>(call, 'pin') == _pin;
      return Future<VaultInfo?>.value(ok ? vault : null);
    }
    if (name.contains('EnablePin')) {
      enabledPin = _arg<String>(call, 'pin');
      return Future<void>.value();
    }
    if (name.contains('NewSecretKey')) return Uint8List.fromList(List.filled(16, 3));
    if (name.contains('Unlock')) {
      unlockCalls++;
      return Future<VaultInfo?>.value(_arg<String>(call, 'password') == _password ? vault : null);
    }
    if (name.contains('Lock')) return null;
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

/// A phone-sized screen (iPhone 14), not the 800 × 600 test default.
Future<void> _pump(WidgetTester t, Widget app) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(app);
}

Future<void> _tapDigits(WidgetTester t, String digits) async {
  for (final d in digits.split('')) {
    await t.tap(find.text(d).last);
    await t.pump();
  }
}

/// Let async storage + bridge calls and the unlock animation finish.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  setUp(() {
    _fake
      ..pinLength = 4
      ..anyPassword = true
      ..enabledPin = null
      ..unlockCalls = 0
      ..biometric = false
      ..biometricCalls = 0
      ..notesAdded = 0
      ..notesUpdated = 0;
    BiometricUnlock.debugKind = null;
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
    });
  });

  testWidgets('right PIN opens the vault', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    expect(find.text('Enter PIN'), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('wrong PIN says so and clears the dots', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, '1111');
    await _settle(t);
    expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
    expect(find.byType(VaultHomeScreen), findsNothing);
  });

  testWidgets('the fifth wrong PIN makes you wait, and never locks the PIN out', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    for (var i = 0; i < 5; i++) {
      await _tapDigits(t, '9999');
      await _settle(t);
    }
    expect(find.text('Too many tries. Wait 1 minute.'), findsOneWidget);
    // While waiting, digits are ignored, even the right PIN.
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsNothing);
    expect(PinStore.waitFor(5), const Duration(minutes: 1));
    expect(PinStore.waitFor(8) > PinStore.waitFor(6), isTrue);
  });

  testWidgets('without a backup password there is no password option', (t) async {
    _fake.anyPassword = false;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    expect(find.text('Use password'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the right password opens without pressing Enter', (t) async {
    _fake.pinLength = 0;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), _password);
    await t.pump(const Duration(milliseconds: 400)); // past the typing pause
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('a wrong password typed quietly says nothing; Enter says it is wrong', (t) async {
    _fake.pinLength = 0;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), 'not the password');
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsNothing);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsOneWidget);
  });

  testWidgets('locking by hand does not ask for Face ID again at once', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
    await t.tap(find.byTooltip('Lock'));
    await _settle(t);
    final lock = t.widget<UnlockScreen>(find.byType(UnlockScreen));
    expect(lock.askBiometricNow, isFalse);
  });

  testWidgets('locking on Settings comes back to Settings, and Back cannot skip the lock', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    await t.tap(find.byTooltip('Settings'));
    await _settle(t);
    expect(find.byType(SettingsScreen), findsOneWidget);
    // Leaving the app locks it.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsOneWidget);
    // Back (Android) or a swipe: still the lock.
    await t.binding.handlePopRoute();
    await _settle(t);
    expect(find.byType(UnlockScreen), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('setting a PIN needs the same digits twice', (t) async {
    await _pump(t, _app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '123456');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '123457');
    await t.pump();
    expect(find.text("The PINs didn't match. Start again."), findsOneWidget);
    expect(_fake.enabledPin, isNull);
    await _tapDigits(t, '123456');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '123456');
    await _settle(t);
    expect(_fake.enabledPin, '123456');
  });

  testWidgets('a PIN shorter than 6 digits cannot go on', (t) async {
    await _pump(t, _app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '12345');
    final next = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'));
    expect(next.onPressed, isNull);
  });

  testWidgets('Emergency Kit goes on only with the last 4 characters', (t) async {
    var done = false;
    const key = 'CS1-ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345';
    await _pump(t, _app(EmergencyKitScreen(keyText: key, confirm: true, onDone: () => done = true)));
    await t.pump();
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, "I've saved it"));
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2344');
    await t.pump();
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2345');
    await t.pump();
    await t.ensureVisible(find.widgetWithText(FilledButton, "I've saved it"));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, "I've saved it"));
    expect(done, isTrue);
  });

  testWidgets('Recovery Key (24 words) goes on only with the asked word', (t) async {
    var done = false;
    const words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm frown notice actor mom surround nurse feature ski gadget volume cousin cancel';
    await _pump(t, _app(EmergencyKitScreen(keyText: words, confirm: true, onDone: () => done = true)));
    await t.pump();
    final label = t.widget<TextField>(find.byType(TextField)).decoration!.labelText!;
    final n = int.parse(RegExp(r'\d+').firstMatch(label)!.group(0)!);
    final want = words.split(' ')[n - 1];
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, "I've saved it"));
    await t.enterText(find.byType(TextField), want == 'zoo' ? 'abandon' : 'zoo');
    await t.pump();
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), want.toUpperCase());
    await t.pump();
    await t.ensureVisible(find.widgetWithText(FilledButton, "I've saved it"));
    await t.tap(find.widgetWithText(FilledButton, "I've saved it"));
    expect(done, isTrue);
  });

  Future<void> leaveAndComeBack(WidgetTester t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
  }

  testWidgets('a note being written stays open with its text through a lock, written once', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    Navigator.of(t.element(find.byType(VaultHomeScreen))).push(MaterialPageRoute<void>(builder: (_) => const NoteScreen()));
    await _settle(t);
    await t.enterText(find.byType(TextField), 'Shopping list');
    await t.pump();
    await leaveAndComeBack(t);
    // Written before the key went, then the lock over the editor.
    expect(_fake.notesAdded, 1);
    expect(find.byType(UnlockScreen), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsNothing);
    expect(find.byType(NoteScreen), findsOneWidget);
    expect(find.text('Shopping list'), findsOneWidget);
    // More typing updates the same note, never a second one.
    await t.enterText(find.byType(TextField), 'Shopping list\nmilk');
    await t.pump(const Duration(seconds: 2));
    await _settle(t);
    expect(_fake.notesAdded, 1);
    expect(_fake.notesUpdated, 1);
  });

  testWidgets('shown words are hidden again when the vault locks', (t) async {
    const words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm frown notice actor mom surround nurse feature ski gadget volume cousin cancel';
    addTearDown(() => vaultLock.set(false));
    await _pump(t, _app(const EmergencyKitScreen(keyText: words, confirm: false)));
    await t.pump();
    expect(find.text('bounce'), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('secret-show')));
    await t.tap(find.byKey(const ValueKey('secret-show')));
    await t.pump();
    expect(find.text('bounce'), findsOneWidget);
    vaultLock.set(true);
    await t.pump();
    expect(find.text('bounce'), findsNothing);
    vaultLock.set(false);
    await t.pump();
    expect(find.text('bounce'), findsNothing);
  });

  testWidgets('a password typed before the lock is gone after it', (t) async {
    addTearDown(() => vaultLock.set(false));
    await _pump(t, _app(const KitPasswordScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), _password);
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    vaultLock.set(false);
    await t.pump();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('Face ID is not asked on return while something covers the lock screen', (t) async {
    _fake.biometric = true;
    BiometricUnlock.debugKind = BiometricKind.face;
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
      'vault-unlock-key': base64Encode(List.filled(32, 5)),
    });
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib', askBiometricNow: false)));
    await _settle(t);
    // A New vault or Restore opened from the lock screen, half done.
    Navigator.of(t.element(find.byType(UnlockScreen)))
        .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('half done'))));
    await _settle(t);
    await leaveAndComeBack(t);
    expect(_fake.biometricCalls, 0);
    expect(find.text('half done'), findsOneWidget);
    // On the lock screen itself, coming back asks.
    Navigator.of(t.element(find.text('half done'))).pop();
    await _settle(t);
    await leaveAndComeBack(t);
    expect(_fake.biometricCalls, 1);
  });
}
