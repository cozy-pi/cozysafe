// Flows that can lock someone out of their vault if they break: PIN, wrong tries,
// password fallback, type-to-unlock, an add action picked while locked, setting a PIN,
// the Emergency Kit confirmation. The Rust core is replaced by a _fake with state.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/screens/set_pin.dart';
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
  bool pinForgotten = false;
  String? enabledPin;
  int unlockCalls = 0;

  T _arg<T>(Invocation c, String name) => c.namedArguments[Symbol(name)] as T;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    final vault = VaultInfo(id: 'v1', name: 'Personal');
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return true;
    if (name.contains('ListItems')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('HasBiometricUnlock')) return false;
    if (name.contains('BiometricEnabled')) return false;
    if (name.contains('PinLength')) return pinForgotten ? 0 : pinLength;
    if (name.contains('PinEnabled')) return enabledPin != null;
    if (name.contains('ForgetPin')) {
      pinForgotten = true;
      return Future<void>.value();
    }
    if (name.contains('UnlockWithPin')) {
      final ok = !pinForgotten && _arg<String>(call, 'pin') == _pin;
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
      ..pinForgotten = false
      ..enabledPin = null
      ..unlockCalls = 0;
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
    });
  });

  testWidgets('right PIN opens the vault', (t) async {
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    expect(find.text('Enter PIN'), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('wrong PIN says how many tries are left', (t) async {
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, '1111');
    await _settle(t);
    expect(find.text('Wrong PIN. 4 tries left.'), findsOneWidget);
    expect(find.byType(VaultHomeScreen), findsNothing);
    await _tapDigits(t, '1112');
    await _settle(t);
    expect(find.text('Wrong PIN. 3 tries left.'), findsOneWidget);
  });

  testWidgets('five wrong PINs turn the PIN off and show the password', (t) async {
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    for (var i = 0; i < 5; i++) {
      await _tapDigits(t, '9999');
      await _settle(t);
    }
    expect(_fake.pinForgotten, isTrue);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('PIN turned off'), findsOneWidget);
    // The password still opens the vault.
    await t.enterText(find.byType(TextField), _password);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('the right password opens without pressing Enter', (t) async {
    _fake.pinLength = 0;
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), _password);
    await t.pump(const Duration(milliseconds: 400)); // past the typing pause
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('a wrong password typed quietly says nothing; Enter says it is wrong', (t) async {
    _fake.pinLength = 0;
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), 'not the password');
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsNothing);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsOneWidget);
  });

  testWidgets('an add action picked while locked runs right after unlocking', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(_app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    // The big dock button (Photo mode by default).
    await t.tap(find.bySemanticsLabel('Photo').last);
    await t.pump();
    expect(find.text('Unlock first; it opens right after.'), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    final home = t.widget<VaultHomeScreen>(find.byType(VaultHomeScreen));
    expect(home.initialAction?.name, 'camera');
    semantics.dispose();
  });

  testWidgets('setting a PIN needs the same digits twice', (t) async {
    await t.pumpWidget(_app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '1234');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '1235');
    await t.pump();
    expect(find.text("The PINs didn't match. Start again."), findsOneWidget);
    expect(_fake.enabledPin, isNull);
    await _tapDigits(t, '1234');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '1234');
    await _settle(t);
    expect(_fake.enabledPin, '1234');
  });

  testWidgets('a PIN shorter than 4 digits cannot go on', (t) async {
    await t.pumpWidget(_app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '123');
    final next = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'));
    expect(next.onPressed, isNull);
  });

  testWidgets('Emergency Kit goes on only with the last 4 characters', (t) async {
    var done = false;
    const key = 'CS1-ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345';
    await t.pumpWidget(_app(EmergencyKitScreen(keyText: key, confirm: true, onDone: () => done = true)));
    await t.pump();
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, "I've saved it"));
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2344');
    await t.pump();
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2345');
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, "I've saved it"));
    expect(done, isTrue);
  });
}
