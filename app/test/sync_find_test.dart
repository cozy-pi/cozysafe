// Enter a code: the person always knows where the look is, and a code no device shows
// says so at once (owner 2026-10-25: nearby sync should be six digits, found by itself).

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/sync/find_page.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app() => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FindDevicePage(address: '192.168.1.52', onFound: (a, b) async {}, onScanned: (a, b) async {}),
      ),
    );

void main() {
  tearDown(() => FindDevicePage.debugFound = null);

  testWidgets('found, then six digits no device shows: wrong code', (t) async {
    FindDevicePage.debugFound = 1;
    await t.pumpWidget(_app());
    expect(find.text('Found your other device'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sync-digits-field')), '48291');
    await t.pump();
    expect(find.byKey(const ValueKey('sync-find-note')), findsNothing);
    await t.enterText(find.byKey(const ValueKey('sync-digits-field')), '482913');
    await t.pump();
    expect(find.text('No device shows this code. Check the digits.'), findsOneWidget);
  });

  testWidgets('nothing found yet: the digits wait for the next look', (t) async {
    FindDevicePage.debugFound = 0;
    await t.pumpWidget(_app());
    expect(find.textContaining('No device found yet'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sync-digits-field')), '48 29a13');
    await t.pump();
    // Only digits are taken, up to six.
    expect(find.text('Looking for the device showing this code…'), findsOneWidget);
  });
}
