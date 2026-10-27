// Version history (owner 2026-10-27): an item's older versions, opened and restored;
// this device's limits.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/history.dart';
import 'package:cozysafe/src/rust/api/history.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ItemInfo _note(String name) => ItemInfo(
      id: 'n'.padRight(32, '_'),
      kind: 'note',
      name: name,
      mime: 'text/plain',
      createdMs: 0,
      sizeBytes: BigInt.from(5),
      tagIds: const [],
      isFavorite: false,
      modifiedMs: 0,
    );

/// The core's answers, and what the screens asked of it.
class _Fake implements RustLibApi {
  final calls = <String>[];
  var days = 30;
  var maxBytes = BigInt.from(1 << 30);

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    final a = call.namedArguments;
    if (name.contains('ItemHistory')) {
      return Future.value([
        HistoryVersion(rev: 'r2', replacedMs: 2000, item: _note('List'), thisDevice: true, hasContent: true, sameContent: false),
        HistoryVersion(rev: 'r1', replacedMs: 1000, item: _note('Old list'), thisDevice: false, hasContent: false, sameContent: false),
      ]);
    }
    if (name.contains('HistoryContent')) return Future.value(Uint8List.fromList(utf8.encode('milk')));
    if (name.contains('RestoreVersion')) {
      calls.add('restore ${a[#rev]}');
      return Future.value(_note('List'));
    }
    if (name.contains('SetHistorySettings')) {
      days = a[#days] as int;
      maxBytes = a[#maxBytes] as BigInt;
      calls.add('set $days $maxBytes');
      return Future.value();
    }
    if (name.contains('HistorySettings')) return Future.value(HistorySettings(days: days, maxBytes: maxBytes));
    if (name.contains('HistoryBytes')) return Future.value(BigInt.from(4096));
    if (name.contains('ClearAllHistory')) {
      calls.add('clear all');
      return Future.value();
    }
    return null;
  }
}

late _Fake _fake;

Widget app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    );

void main() {
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
  setUp(() => _fake
    ..calls.clear()
    ..days = 30
    ..maxBytes = BigInt.from(1 << 30));

  testWidgets('a version opens with its content and Restore brings it back', (t) async {
    ItemInfo? restored;
    await t.pumpWidget(app(HistoryScreen(item: _note('List'), onRestored: (i) => restored = i)));
    await t.pumpAndSettle();
    expect(find.text('This device · 5 B'), findsOneWidget);
    // Pruned for space: shown, not opened.
    expect(find.text('Another device · Content removed to save space'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('history-r1')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-restore')), findsNothing);

    await t.tap(find.byKey(const ValueKey('history-r2')));
    await t.pumpAndSettle();
    expect(find.text('milk'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('history-restore')));
    await t.pumpAndSettle();
    expect(_fake.calls, ['restore r2']);
    expect(restored?.name, 'List');
  });

  testWidgets('the limits are chosen here; off hides the space limit', (t) async {
    await t.pumpWidget(app(const HistorySettingsScreen()));
    await t.pumpAndSettle();
    expect(find.textContaining('History uses'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('history-days-90')));
    await t.pumpAndSettle();
    expect(_fake.calls.last, 'set 90 ${1 << 30}');
    await t.tap(find.byKey(ValueKey('history-max-${BigInt.zero}')));
    await t.pumpAndSettle();
    expect(_fake.calls.last, 'set 90 0');
    await t.tap(find.byKey(const ValueKey('history-days-0')));
    await t.pumpAndSettle();
    expect(_fake.calls.last, 'set 0 0');
    expect(find.byKey(ValueKey('history-max-${BigInt.zero}')), findsNothing);
  });
}
