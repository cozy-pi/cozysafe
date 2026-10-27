// The running sync screen keeps still (owner 2026-10-27: it kept growing and shrinking as
// counts, bytes, the speed and the time left came and went).

import 'dart:async';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) => null;
}

SyncEvent ev(SyncStep k, {int done = 0, int total = 0, int bytes = 0, int bytesTotal = 0}) => SyncEvent(
    kind: k,
    check: 0,
    name: '',
    peers: const [],
    peerIds: const [],
    received: 0,
    sent: 0,
    removed: 0,
    copies: 0,
    done: done,
    total: total,
    bytes: BigInt.from(bytes),
    bytesTotal: BigInt.from(bytesTotal),
    moved: 0,
    repaired: 0,
    unrepaired: 0,
    code: '');

void main() {
  setUpAll(() => RustLib.initMock(api: _Fake()));
  tearDown(() => SyncProgress.debugRate = null);

  testWidgets('nothing moves as the figures come in', (t) async {
    final events = StreamController<SyncEvent>();
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SyncProgress(events: events.stream, onSynced: () {}, place: SyncPlace.drive)),
    ));
    final tops = <double>[];
    Future<void> show(SyncEvent e) async {
      events.add(e);
      await t.pump();
      tops.add(t.getTopLeft(find.byType(LinearProgressIndicator)).dy);
    }

    await show(ev(SyncStep.driveListing));
    await show(ev(SyncStep.driveListing, done: 120));
    await show(ev(SyncStep.checking));
    await show(ev(SyncStep.preparing, done: 3, total: 40));
    await show(ev(SyncStep.sending, total: 40, bytesTotal: 80 << 20));
    await show(ev(SyncStep.sending, done: 2, total: 40, bytes: 5 << 20, bytesTotal: 80 << 20));
    SyncProgress.debugRate = (2.5 * (1 << 20), 1);
    await show(ev(SyncStep.sending, done: 3, total: 40, bytes: 9 << 20, bytesTotal: 80 << 20));
    expect(find.byKey(const ValueKey('sync-speed')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-left')), findsOneWidget);
    expect(tops.toSet(), hasLength(1), reason: 'the bar moved: $tops');
    await events.close();
  });
}
