import 'dart:async';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/lock_resume.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/awake.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/sync/status.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stopping a session (the lock does) is the only call into Rust here.
class _Fake implements RustLibApi {
  int cancels = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName.toString().contains('P2PCancel')) cancels++;
    return null;
  }
}

late _Fake _fake;

SyncEvent ev(SyncStep k, {int done = 0, int total = 0, int bytes = 0, int bytesTotal = 0}) =>
    SyncEvent(kind: k, check: 0, name: '', peers: const [], peerIds: const [], received: 0, sent: 0, removed: 0, copies: 0, done: done, total: total, bytes: BigInt.from(bytes), bytesTotal: BigInt.from(bytesTotal), moved: 0);

Widget app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

Future<void> leave(WidgetTester t) async {
  for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
  await t.pump();
}

Future<void> comeBack(WidgetTester t) async {
  for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
  await t.pump();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    _fake.cancels = 0;
  });
  tearDown(() {
    vaultLock.set(false);
    syncStatus.value = null;
  });

  testWidgets('Google Drive stopped by the vault locking continues once it opens again', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    var again = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        again = StreamController<SyncEvent>();
        return again.stream;
      },
    )));
    first.add(ev(SyncStep.receiving, done: 10, total: 100));
    await t.pump();
    await leave(t);
    vaultLock.set(true);
    await t.pump();
    // Stopped at once, so the vault can lock.
    expect(_fake.cancels, 1);
    // Back on the lock screen: nothing runs while the vault is locked.
    await comeBack(t);
    expect(retries, 0);
    vaultLock.set(false);
    await t.pump();
    expect(retries, 1);
    expect(find.byKey(const ValueKey('sync-continue')), findsNothing);
    again.add(ev(SyncStep.done));
    await t.pump();
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('a session with another device stopped by leaving the app says so and can be closed', (t) async {
    final first = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(events: first.stream, onSynced: () {})));
    first.add(ev(SyncStep.sending, done: 3, total: 9));
    await t.pump();
    await leave(t);
    vaultLock.set(true);
    await t.pump();
    expect(_fake.cancels, 1);
    await comeBack(t);
    vaultLock.set(false);
    await t.pump();
    expect(find.text('The vault locked. Open it and try again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('Google Drive keeps going when the vault locks in the app, and the lock screen can show it', (t) async {
    final first = StreamController<SyncEvent>();
    var synced = 0;
    await t.pumpWidget(app(SyncProgress(place: SyncPlace.drive, events: first.stream, onSynced: () => synced++, retry: () => const Stream.empty())));
    first.add(ev(SyncStep.receiving, done: 4, total: 10, bytes: 40, bytesTotal: 100));
    await t.pump();
    expect(Awake.busy, isTrue);
    // Idle lock, Hold Home: the app stays in front.
    vaultLock.set(true);
    await t.pump();
    expect(_fake.cancels, 0, reason: 'the run is not stopped');
    expect(Awake.busy, isTrue, reason: 'the screen stays on');
    expect(syncStatus.value?.drive, isTrue);
    expect(syncStatus.value?.fraction, closeTo(.4, 1e-9));
    first.add(ev(SyncStep.sending, done: 9, total: 10, bytes: 90, bytesTotal: 100));
    await t.pump();
    expect(syncStatus.value?.fraction, closeTo(.9, 1e-9));
    first.add(ev(SyncStep.done));
    await t.pump();
    expect(synced, 1);
    expect(Awake.busy, isFalse, reason: 'let go once the run ends');
    expect(syncStatus.value?.finished, isTrue, reason: 'the lock screen says it is done');
    vaultLock.set(false);
    await t.pump();
    expect(syncStatus.value, isNull);
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('a session with another device moving items keeps going when the vault locks in the app', (t) async {
    final first = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(events: first.stream, onSynced: () {})));
    first.add(ev(SyncStep.sending, done: 3, total: 9));
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    expect(_fake.cancels, 0);
    expect(Awake.busy, isTrue);
    expect(syncStatus.value?.drive, isFalse);
    expect(syncStatus.value?.fraction, closeTo(3 / 9, 1e-9));
    first.add(ev(SyncStep.done));
    await t.pump();
    vaultLock.set(false);
    await t.pump();
    expect(find.text('The vault locked. Open it and try again.'), findsNothing);
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('a session still waiting for this screen\'s answer stops when the vault locks', (t) async {
    final first = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(events: first.stream, onSynced: () {})));
    first.add(ev(SyncStep.confirm));
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    expect(_fake.cancels, 1);
    expect(Awake.busy, isFalse);
    expect(syncStatus.value, isNull);
    vaultLock.set(false);
    await t.pump();
    expect(find.text('The vault locked. Open it and try again.'), findsOneWidget);
  });

  testWidgets('going on behind the lock, then leaving the app: stopped, and Google Drive continues once open', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    var again = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(
      place: SyncPlace.drive,
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        again = StreamController<SyncEvent>();
        return again.stream;
      },
    )));
    first.add(ev(SyncStep.receiving, done: 1, total: 10));
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    expect(_fake.cancels, 0);
    await leave(t);
    expect(_fake.cancels, 1, reason: 'the system would suspend it: the vault goes');
    expect(syncStatus.value, isNull);
    expect(Awake.busy, isFalse);
    await comeBack(t);
    expect(retries, 0, reason: 'nothing runs again while locked');
    vaultLock.set(false);
    await t.pump();
    expect(retries, 1);
    again.add(ev(SyncStep.done));
    await t.pump();
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('Google Drive cut behind the lock continues once the vault opens', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    await t.pumpWidget(app(SyncProgress(
      place: SyncPlace.drive,
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        return Stream.value(ev(SyncStep.done));
      },
    )));
    first.add(ev(SyncStep.receiving, done: 1, total: 10));
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    first.add(ev(SyncStep.interrupted));
    await t.pump();
    expect(syncStatus.value, isNull);
    expect(retries, 0);
    vaultLock.set(false);
    await t.pump();
    expect(retries, 1);
  });

  testWidgets('interrupted while the phone was locked: continues once on return, no tap', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    var again = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        again = StreamController<SyncEvent>();
        return again.stream;
      },
    )));
    first.add(ev(SyncStep.receiving, done: 10, total: 100));
    await t.pump();
    await leave(t);
    first.add(ev(SyncStep.interrupted));
    await t.pump();
    // Still away: nothing happens yet (no frames are drawn either).
    expect(retries, 0);

    await comeBack(t);
    expect(retries, 1);
    expect(find.byKey(const ValueKey('sync-continue')), findsNothing);

    // Back again with nothing interrupted: no second run.
    await leave(t);
    await comeBack(t);
    expect(retries, 1);

    again.add(ev(SyncStep.done));
    await t.pump();
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('the drop surfaces just after coming back: continues once', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    var again = StreamController<SyncEvent>();
    await t.pumpWidget(app(SyncProgress(
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        again = StreamController<SyncEvent>();
        return again.stream;
      },
    )));
    first.add(ev(SyncStep.sending, done: 3, total: 9));
    await t.pump();
    await leave(t);
    await comeBack(t);
    expect(retries, 0);
    // The broken stream counts as an interruption.
    first.addError(StateError('suspended'));
    await t.pump();
    expect(retries, 1);

    // A second interruption without leaving the app waits for a tap.
    again.add(ev(SyncStep.interrupted));
    await t.pump();
    expect(retries, 1);
    expect(find.byKey(const ValueKey('sync-continue')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sync-continue')));
    await t.pump();
    expect(retries, 2);
    again.add(ev(SyncStep.done));
    await t.pump();
  });

  testWidgets('an interruption without leaving the app keeps the Continue button', (t) async {
    final first = StreamController<SyncEvent>();
    var retries = 0;
    await t.pumpWidget(app(SyncProgress(
      events: first.stream,
      onSynced: () {},
      retry: () {
        retries++;
        return Stream.value(ev(SyncStep.done));
      },
    )));
    first.add(ev(SyncStep.interrupted));
    await t.pump();
    // A system sheet over the app (a permission question, the notification shade).
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(retries, 0);
    expect(find.byKey(const ValueKey('sync-continue')), findsOneWidget);
  });
}
