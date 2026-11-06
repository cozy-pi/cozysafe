// Dragging a full-screen photo down fades its bars and the black behind it. Those faded
// bars still took taps: a second finger on ⋯ opened a menu over the viewer, letting go
// then closed the menu instead of the viewer, and the viewer stayed see-through over the
// page, taking its taps (owner 2026-11-03, after heavy use on iPhone).

import 'dart:io';

import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/preview/fake_vault.dart';
import 'package:cozysafe/screens/photo_viewer.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ItemInfo _photo(String id) => ItemInfo(
      id: id.padRight(32, '_'),
      kind: ItemKind.photo,
      name: '$id.jpg',
      mime: 'image/jpeg',
      createdMs: 0,
      sizeBytes: BigInt.from(1000),
      deletedMs: null,
      durationMs: null,
      tagIds: const [],
      isFavorite: false,
      modifiedMs: 0, account: '', hosts: const [],
    );

void main() {
  setUpAll(() => RustLib.initMock(api: FakeVault(const [])));
  setUp(() => Prefs.dir = Directory.systemTemp.createTempSync('prefs').path);

  testWidgets('faded bars take no taps mid-drag; letting go closes the viewer', (t) async {
    var menus = 0;
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(PageRouteBuilder<void>(
            opaque: false,
            pageBuilder: (_, _, _) => PhotoViewerScreen(
              items: [_photo('a'), _photo('b')],
              initial: 0,
              vaultId: 'v',
              menu: (button, item) async {
                menus++;
                await showDialog<void>(context: button, builder: (_) => const Text('menu'));
                return null;
              },
            ),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    final more = t.getCenter(find.byKey(const ValueKey('photo-more')));

    final drag = await t.startGesture(t.getCenter(find.byType(PhotoViewerScreen)));
    for (var i = 0; i < 8; i++) {
      await drag.moveBy(const Offset(0, 40));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.tapAt(more); // a second finger on the faded ⋯
    await t.pump();
    expect(menus, 0);
    await drag.up();
    await t.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
  });
}
