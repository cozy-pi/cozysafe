import 'dart:typed_data';

import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/overview.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';

ItemInfo _item(int n, String kind) => ItemInfo(
      id: '$kind-$n',
      kind: kind,
      name: '$kind $n',
      mime: kind == ItemKind.audio ? 'audio/mp4' : (kind == ItemKind.photo ? 'image/jpeg' : 'text/plain'),
      createdMs: PlatformInt64Util.from(n),
      sizeBytes: BigInt.from(10),
      tagIds: const [],
      isFavorite: false,
      modifiedMs: PlatformInt64Util.from(n),
      account: '',
      hosts: const [],
    );

void main() {
  testWidgets('the kinds on the overview are ranked by how many there are, most first', (tester) async {
    final items = [
      _item(1, ItemKind.photo),
      for (var i = 0; i < 3; i++) _item(10 + i, ItemKind.note),
      for (var i = 0; i < 2; i++) _item(20 + i, ItemKind.audio),
      _item(30, ItemKind.video),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: VaultOverview(
          items: items,
          thumbnail: (_) async => Uint8List(0),
          onKind: (_) {},
          onCategory: (_) {},
          onGroup: (_) {},
          onOpen: (_) {},
        ),
      ),
    ));
    await tester.pump();
    final order = [
      for (final w in tester.widgetList(find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('kind-row-'))))
        (w.key as ValueKey<String>).value.substring('kind-row-'.length),
    ];
    // Notes 3, voice 2, then photo and video (1 each, in the fixed order), Passwords 0 last.
    expect(order, ['note', 'audio', 'photo', 'video', 'password']);
  });
}
