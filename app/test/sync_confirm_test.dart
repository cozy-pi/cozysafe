// Nearby sync pairs like Bluetooth (owner 2026-10-26): both screens ask "Sync with …?"
// next to the same number, several devices are listed by name, and a Cancel on the other
// device is said so.

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/device_name.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The answers the person gives, the only calls into Rust here.
class _Fake implements RustLibApi {
  final answers = <bool>[];

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName.toString().contains('P2PAnswer')) answers.add(call.namedArguments[#yes] as bool);
    return null;
  }
}

late _Fake _fake;

SyncEvent ev(SyncStep k, {String name = '', int check = 0, List<String> peers = const []}) => SyncEvent(
    kind: k,
    check: check,
    name: name,
    peers: peers,
    peerIds: [for (var i = 0; i < peers.length; i++) 'id$i'],
    received: 0,
    sent: 0,
    removed: 0,
    copies: 0,
    done: 0,
    total: 0,
    bytes: BigInt.zero,
    bytesTotal: BigInt.zero,
    moved: 0);

Widget app(Stream<SyncEvent> events) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SyncProgress(events: events, onSynced: () {}, waiting: const Text('looking'))),
    );

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
  setUp(() => _fake.answers.clear());

  testWidgets('the card names the other device and shows the number to compare', (t) async {
    await t.pumpWidget(app(Stream.value(ev(SyncStep.confirm, name: 'iPhone 15 Pro Max', check: 47))));
    await t.pump();
    expect(find.text('Sync with iPhone 15 Pro Max?'), findsOneWidget);
    // Three digits, as on the other screen.
    expect(find.text('Code: 047'), findsOneWidget);
    expect(find.text('Check that the other device shows the same number.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-confirm-yes')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-confirm-no')), findsOneWidget);
  });

  testWidgets('after Sync it waits for the other device; the buttons go', (t) async {
    await t.pumpWidget(app(Stream.value(ev(SyncStep.confirm, name: 'iPad', check: 472))));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('sync-confirm-yes')));
    await t.pump();
    expect(_fake.answers, [true]);
    expect(find.text('Waiting for iPad…'), findsOneWidget);
    expect(find.text('Tap Sync on the other device too.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-confirm-yes')), findsNothing);
    // Cancel stays, to stop waiting.
    expect(find.byKey(const ValueKey('sync-cancel')), findsOneWidget);
  });

  testWidgets('a Cancel on the other device is said so', (t) async {
    await t.pumpWidget(app(Stream.fromIterable([
      ev(SyncStep.confirm, name: 'iPad', check: 472),
      ev(SyncStep.peerCancelled),
    ])));
    await t.pump();
    await t.pump();
    expect(find.text('Cancelled on the other device.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('several devices: listed by name, the person picks one', (t) async {
    await t.pumpWidget(app(Stream.value(ev(SyncStep.found, peers: ['iPad', '']))));
    await t.pump();
    expect(find.text('Found 2 devices with this vault. Tap the one to sync with.'), findsOneWidget);
    expect(find.text('iPad'), findsOneWidget);
    expect(find.text('Another device with this vault'), findsOneWidget);
    expect(find.text('looking'), findsNothing);
  });

  testWidgets('one device found: it connects by itself', (t) async {
    await t.pumpWidget(app(Stream.value(ev(SyncStep.found, peers: ['']))));
    await t.pump();
    expect(find.text('Found your other device. Connecting…'), findsOneWidget);
  });

  testWidgets('a new device asking to restore is named, with the number', (t) async {
    await t.pumpWidget(app(Stream.value(ev(SyncStep.askRestore, name: 'iPhone 16', check: 318))));
    await t.pump();
    expect(find.text('Let iPhone 16 restore this vault?'), findsOneWidget);
    expect(find.text('Code: 318'), findsOneWidget);
  });

  test('device names: the model, the maker once', () {
    expect(appleModelName('iPhone16,2'), 'iPhone 15 Pro Max');
    expect(appleModelName('iPhone99,1'), 'iPhone');
    expect(appleModelName('iPad14,1'), 'iPad');
    expect(androidModelName('Google', 'Pixel 8'), 'Google Pixel 8');
    expect(androidModelName('samsung', 'SM-S918B'), 'Samsung SM-S918B');
    expect(androidModelName('OnePlus', 'OnePlus 12'), 'OnePlus 12');
  });
}
