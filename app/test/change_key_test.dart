// A new Recovery Key asks for the vault password again after a lock (and for another
// vault's): a password typed there is a try like any other, with the same count and
// waits as the lock screen, or the open vault would be where it is guessed for free.

import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/change_key.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake implements RustLibApi {
  String right = '';
  int tries = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('NewSecretKey')) return Uint8List(32);
    if (name.contains('FinishSecretKeyChange')) return Future<void>.value();
    if (name.contains('ChangeSecretKey')) {
      tries++;
      final all = call.namedArguments[#passwords] as List<String>;
      return Future.value(
          KeyChangeResult(step: all.last == right ? KeyChangeStep.changed : KeyChangeStep.wrongPassword));
    }
    return null;
  }
}

late _Fake _fake;

Widget _app() => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // No password handed over: the vault locked since, so the check step asks for it.
      home: ChangeKeyScreen(libraryDir: '/lib', onBackup: () async {}),
    );

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(430, 932) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app());
  await t.pump();
  // The four words asked back (fixed in a test: 3, 9, 15 and 22).
  for (final i in [2, 8, 14, 21]) {
    await t.enterText(find.byKey(ValueKey('words-field-$i')), 'abandon');
    await t.pump();
  }
}

Future<void> _try(WidgetTester t, String password) async {
  await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('change-password')), matching: find.byType(TextField)), password);
  await t.pump();
  await t.tap(find.byKey(const ValueKey('change-apply')));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
  setUp(() {
    _fake
      ..right = 'the-right-password'
      ..tries = 0;
    ChangeKeyScreen.debugWords = List.filled(24, 'abandon').join(' ');
    ChangeKeyScreen.debugStep = 2;
  });
  tearDown(() {
    ChangeKeyScreen.debugWords = null;
    ChangeKeyScreen.debugStep = null;
  });

  testWidgets('wrong passwords count here as anywhere, and then it waits', (t) async {
    FlutterSecureStorage.setMockInitialValues({'password-fails': '9'});
    await _open(t);
    await _try(t, 'nope-nope');
    expect(_fake.tries, 1);
    expect(find.text('No vault opens with this password.'), findsOneWidget);
    // The tenth wrong one started a wait: the next is not even tried, the right one too.
    await _try(t, 'the-right-password');
    expect(_fake.tries, 1);
    expect(find.textContaining('Too many tries'), findsOneWidget);
    expect(find.byKey(const ValueKey('change-backup')), findsNothing);
  });

  testWidgets('a wrong password is counted', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    await _open(t);
    await _try(t, 'nope-nope');
    expect(await const FlutterSecureStorage().read(key: 'password-fails'), '1');
  });

  testWidgets('the right password changes the key and clears the count', (t) async {
    FlutterSecureStorage.setMockInitialValues({'password-fails': '4'});
    await _open(t);
    await _try(t, 'the-right-password');
    expect(_fake.tries, 1);
    expect(find.byKey(const ValueKey('change-backup')), findsOneWidget);
    expect(await const FlutterSecureStorage().read(key: 'password-fails'), '0');
  });
}
