// Scrolling the small photos at the bottom of the full-screen viewer moves the photo
// above with them, with a tick for each one passed, and settles on the one in the middle
// (owner 2026-11-13).

import 'dart:io';

import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/preview/fake_vault.dart';
import 'package:cozysafe/screens/photo_viewer.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('scrolling the strip moves the photo, a tick per photo', (t) async {
    var ticks = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') ticks++;
      return null;
    });
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PhotoViewerScreen(
        items: [for (var i = 0; i < 12; i++) _photo('p$i')],
        initial: 0,
        vaultId: 'v',
      ),
    ));
    await t.pumpAndSettle();
    final pages = t.widget<PageView>(find.byType(PageView)).controller!;
    expect(pages.page, 0);

    // Four photos' worth to the left, slowly: no fling.
    final strip = find.byKey(const ValueKey('photo-strip'));
    final drag = await t.startGesture(t.getCenter(strip));
    for (var i = 0; i < 16; i++) {
      await drag.moveBy(const Offset(-9, 0));
      await t.pump(const Duration(milliseconds: 50));
    }
    final scroll = t.widget<ListView>(find.descendant(of: strip, matching: find.byType(ListView))).controller!;
    final at = (scroll.offset / 36).round();
    expect(at, greaterThanOrEqualTo(3));
    expect(pages.page, at, reason: 'the photo follows the strip while the finger is down');
    expect(ticks, at, reason: 'a tick for each photo passed');
    await drag.up();
    await t.pumpAndSettle();
    expect(pages.page, at);
    expect(scroll.offset, at * 36.0, reason: 'settled with that photo in the middle');
  });
}
