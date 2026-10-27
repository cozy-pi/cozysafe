// Storage, part by part (owner 2026-10-28): every part listed with its size, Recently
// deleted and Version history included; a tap goes where the part is managed; figures
// that change (Recently deleted emptied) show at once.

import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/storage.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    );

BigInt mb(int n) => BigInt.from(n << 20);

void main() {
  testWidgets('every part, largest first; a tap opens it; emptying the trash shows at once', (t) async {
    t.view.physicalSize = const Size(430, 932) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final figures = ValueNotifier(StorageFigures(
      bytes: {ItemKind.photo: mb(20), ItemKind.video: mb(120), storageTrash: mb(60), storageHistory: mb(5)},
      counts: {ItemKind.photo: 12, ItemKind.video: 3, storageTrash: 4},
    ));
    final opened = <String>[];
    await t.pumpWidget(_app(StorageScreen(figures: figures, onOpen: opened.add)));
    for (final (part, _) in storageParts) {
      expect(find.byKey(ValueKey('storage-$part')), findsOneWidget);
    }
    double y(String part) => t.getTopLeft(find.byKey(ValueKey('storage-$part'))).dy;
    expect(y(ItemKind.video), lessThan(y(storageTrash)));
    expect(y(storageTrash), lessThan(y(ItemKind.photo)));
    expect(find.text('205.0 MB · 19 items'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('storage-trash')));
    await t.tap(find.byKey(const ValueKey('storage-history')));
    await t.tap(find.byKey(const ValueKey('storage-photo')));
    expect(opened, [storageTrash, storageHistory, ItemKind.photo]);

    figures.value = StorageFigures(
      bytes: {ItemKind.photo: mb(20), ItemKind.video: mb(120), storageTrash: BigInt.zero, storageHistory: mb(5)},
      counts: {ItemKind.photo: 12, ItemKind.video: 3, storageTrash: 0},
    );
    await t.pump();
    expect(find.text('145.0 MB · 15 items'), findsOneWidget);
  });
}
