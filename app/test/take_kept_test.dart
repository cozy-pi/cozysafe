// A finished recording or video that cannot be encrypted (no space left) used to be
// deleted with the error. Now the plain file stays while a card says what failed, with
// Try Again and Discard; it is deleted once saved or discarded, and never waits for the
// next session.

import 'dart:io';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/lock_resume.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/take_kept.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late File take;
  late List<Object?> failures;
  var saves = 0;
  bool? result;

  Future<void> save() async {
    saves++;
    final e = failures.isEmpty ? null : failures.removeAt(0);
    if (e != null) throw e;
  }

  Future<void> open(WidgetTester t, Object error) async {
    t.view.physicalSize = const Size(430, 932) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await retryOrDiscardTake(context,
                path: take.path, error: error, sentence: "Couldn't record. Try again.", save: save),
            child: const Text('fail'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('fail'));
    await t.pumpAndSettle();
  }

  setUp(() {
    take = File('${Directory.systemTemp.createTempSync('take').path}/1.m4a')..writeAsStringSync('sound');
    failures = [];
    saves = 0;
    result = null;
    vaultLock.reset();
  });
  tearDown(vaultLock.reset);

  testWidgets('the real error shows, the file stays, and Try Again saves it', (t) async {
    failures = [VaultError.storage];
    await open(t, VaultError.storage);
    expect(find.text('Not saved yet'), findsOneWidget);
    expect(find.textContaining('Error code: storage'), findsOneWidget);
    expect(find.textContaining('only until the vault locks'), findsOneWidget);
    expect(take.existsSync(), isTrue);
    // Still no space: the card is back, the file still there.
    await t.tap(find.byKey(const ValueKey('take-kept-retry')));
    await t.pumpAndSettle();
    expect(saves, 1);
    expect(find.byKey(const ValueKey('take-kept-retry')), findsOneWidget);
    expect(take.existsSync(), isTrue);
    await t.tap(find.byKey(const ValueKey('take-kept-retry')));
    await t.pumpAndSettle();
    expect(saves, 2);
    expect(result, isTrue);
    expect(find.byKey(const ValueKey('card')), findsNothing);
    expect(take.existsSync(), isFalse);
  });

  testWidgets('Discard deletes it; a tap beside the card does not', (t) async {
    await open(t, 'no-space');
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(result, isNull);
    expect(take.existsSync(), isTrue);
    expect(find.byKey(const ValueKey('take-kept-discard')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('take-kept-discard')));
    await t.pumpAndSettle();
    expect(result, isFalse);
    expect(saves, 0);
    expect(take.existsSync(), isFalse);
  });

  testWidgets('the vault locking closes the card and the plain file goes', (t) async {
    await open(t, VaultError.storage);
    vaultLock.set(true);
    t.state<NavigatorState>(find.byType(Navigator)).popUntil(keptOnLock);
    await t.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byKey(const ValueKey('card')), findsNothing);
    expect(take.existsSync(), isFalse);
  });
}
