// Settings → Check your 24 words and password (owner 2026-10-26): compared only, and
// what was typed is gone with the page.

import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/key_check.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The core's answers: words fit when they parse (and [fits]), the password is right
/// when it is [right].
class _Fake implements RustLibApi {
  bool fits = true;
  String right = '';

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('ParseSecretKey')) {
      final text = call.namedArguments[#text] as String;
      return text.trim().split(RegExp(r'\s+')).length == 24 ? Uint8List(32) : null;
    }
    if (name.contains('SecretKeyFits')) return fits;
    if (name.contains('CheckPassword')) return Future.value(call.namedArguments[#password] == right);
    return null;
  }
}

late _Fake _fake;

Widget app() => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: KeyCheckScreen(libraryDir: '/lib', hasPassword: true)),
    );

String words(String w) => List.filled(24, w).join(' ');

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  testWidgets('the right words and password say so', (t) async {
    _fake
      ..fits = true
      ..right = 'test-pass-1';
    await t.pumpWidget(app());
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('key-check-words')), matching: find.byType(TextField)).first, words('abandon'));
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('key-check-password')), matching: find.byType(TextField)), 'test-pass-1');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('key-check-go')));
    await t.pumpAndSettle();
    expect(find.text("Right: these are this vault's 24 words."), findsOneWidget);
    expect(find.text('Right password.'), findsOneWidget);
  });

  testWidgets('other words or a wrong password say so too', (t) async {
    _fake
      ..fits = false
      ..right = 'something-else';
    await t.pumpWidget(app());
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('key-check-words')), matching: find.byType(TextField)).first, words('zoo'));
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('key-check-password')), matching: find.byType(TextField)), 'nope-nope');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('key-check-go')));
    await t.pumpAndSettle();
    expect(find.text('No match. Check each word and their order.'), findsOneWidget);
    expect(find.text('Wrong password.'), findsOneWidget);
  });
}
