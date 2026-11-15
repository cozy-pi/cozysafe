// Setting up a new device by a code (ADR 0003, point 11): the new device shows the
// code, the person types it on the old one, which is the one that compares it, and the
// old device asks who is holding it before it starts.

import 'dart:io';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/invite_page.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/sync/sync_screen.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The codes the person typed, the only calls into Rust that matter here.
class _Fake implements RustLibApi {
  final codes = <String?>[];

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName.toString().contains('P2PAddCode')) codes.add(call.namedArguments[#code] as String?);
    return null;
  }
}

late _Fake _fake;

SyncEvent ev(SyncStep k, {String name = '', int check = 0}) => SyncEvent(
    kind: k,
    check: check,
    name: name,
    peers: const [],
    peerIds: const [],
    received: 0,
    sent: 0,
    removed: 0,
    copies: 0,
    done: 0,
    total: 0,
    bytes: BigInt.zero,
    bytesTotal: BigInt.zero,
    moved: 0, repaired: 0, unrepaired: 0, code: '');

Widget app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Widget progress(SyncEvent e, {required bool restoring}) =>
    app(Scaffold(body: SyncProgress(restoring: restoring, events: Stream.value(e), onSynced: () {}, waiting: const Text('looking'))));

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
  setUp(() {
    _fake.codes.clear();
    Prefs.dir = Directory.systemTemp.createTempSync('add-code').path;
  });
  tearDown(() {
    debugOwnerConfirmed = false;
    SyncScreen.debugLog = null;
    SyncScreen.debugAddress = null;
    InvitePage.debugSeconds = null;
    InvitePage.debugEvents = null;
  });

  testWidgets('the new device shows the code and has nothing to type', (t) async {
    await t.pumpWidget(progress(ev(SyncStep.addCode, name: '12345678'), restoring: true));
    await t.pump();
    expect(find.text('Type this code on your other device'), findsOneWidget);
    expect(find.text('1234 - 5678'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-code-field')), findsNothing);
    expect(_fake.codes, isEmpty);
  });

  testWidgets('the old device asks for the code; the 8th digit gives it, digits alone', (t) async {
    await t.pumpWidget(progress(ev(SyncStep.askCode, check: 3), restoring: false));
    await t.pump();
    expect(find.text('Type the code shown on the new device'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-code-digits')), findsNothing);
    await t.enterText(find.byKey(const ValueKey('add-code-field')), '1234567');
    await t.pump();
    expect(_fake.codes, isEmpty);
    await t.enterText(find.byKey(const ValueKey('add-code-field')), '12345678');
    await t.pump();
    expect(find.text('1234 - 5678'), findsOneWidget);
    expect(_fake.codes, ['12345678']);
  });

  testWidgets('a wrong code on the old device says how many tries are left', (t) async {
    await t.pumpWidget(progress(ev(SyncStep.askCode, check: 2), restoring: false));
    await t.pump();
    expect(find.text('The code does not match, 2 tries left'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-code-field')), findsOneWidget);
  });

  testWidgets('three wrong codes end it with the same words on both devices', (t) async {
    for (final restoring in [false, true]) {
      await t.pumpWidget(progress(ev(SyncStep.addWrongCode), restoring: restoring));
      await t.pump();
      expect(find.byKey(const ValueKey('add-code-ended-wrongCode')), findsOneWidget);
      expect(find.text('The code does not match'), findsOneWidget);
      expect(find.text('The connection is closed. Start again on both devices.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('Set up a new device starts only once the owner is confirmed', (t) async {
    SyncScreen.debugLog = const [];
    SyncScreen.debugAddress = '192.168.1.37';
    InvitePage.debugSeconds = 107;
    InvitePage.debugEvents = const Stream.empty();
    await t.pumpWidget(app(SyncScreen(libraryDir: '', onSynced: () {})));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sync-local')));
    await t.pumpAndSettle();
    // No owner check passes here (no Face ID, fingerprint or passcode answers in a test).
    await t.tap(find.byKey(const ValueKey('sync-invite')));
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('add-code-waiting')), findsNothing);
    // Confirmed: the wait for the new device starts. A fresh page: the first tap is still
    // waiting for an answer no one gives here, and one start runs at a time.
    debugOwnerConfirmed = true;
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(SyncScreen(libraryDir: '', onSynced: () {})));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sync-local')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sync-invite')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('add-code-waiting')), findsOneWidget);
    // Leave the page so its timers end with the test.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
