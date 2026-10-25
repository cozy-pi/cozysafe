import 'dart:async';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEvent ev(SyncStep k, {int done = 0, int total = 0}) =>
    SyncEvent(kind: k, check: 0, received: 0, sent: 0, removed: 0, copies: 0, done: done, total: total, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0);

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
  setUp(() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

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
