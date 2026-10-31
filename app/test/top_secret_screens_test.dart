// A Top secret run never builds a photo viewer, a player, a PDF view or a preview, and
// never reads a thumbnail (ADR 0005). The same items in a Private run do open, so the
// test would notice if the gate went away.

import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/platform.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/photo_viewer.dart';
import 'package:cozysafe/screens/quick_look.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/top_secret_mode.dart';
import 'package:cozysafe/widgets/private_thumb.dart';
import 'package:cozysafe/widgets/vault_bar.dart'
    show VaultSection, debugVoice, vaultSections;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cozysafe/widgets/file_name.dart';

ItemInfo _item(String id, String kind, String name, String mime) => ItemInfo(
  id: id,
  kind: kind,
  name: name,
  mime: mime,
  createdMs: 1,
  sizeBytes: BigInt.from(2048),
  tagIds: const [],
  isFavorite: false,
  modifiedMs: 1,
);

final _items = [
  _item('p1', 'photo', 'ID card front.jpg', 'image/jpeg'),
  _item('v1', 'video', 'clip.mp4', 'video/mp4'),
  _item('a1', 'audio', 'memo.m4a', 'audio/mp4'),
  _item('f1', 'file', 'contract.pdf', 'application/pdf'),
];

class _Fake implements RustLibApi {
  int thumbnails = 0;

  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(_items);
    if (n.contains('ListHeld') || n.contains('ListTrash')) {
      return Future<List<ItemInfo>>.value(const []);
    }
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('ItemThumbnail')) {
      thumbnails++;
      return Future<Uint8List>.value(Uint8List(0));
    }
    if (n.contains('ItemContent')) return Future<Uint8List>.value(Uint8List(0));
    if (n.contains('BiometricEnabled') || n.contains('PinEnabled')) {
      return false;
    }
    return null;
  }
}

late _Fake _fake;

/// A file's name as the lists draw it ([FileNameText]: the name and its extension apart).
Finder _name(String name) => find.byWidgetPredicate((w) => w is FileNameText && w.name == name);

const _vault = VaultInfo(
  id: 'v1',
  name: '',
  icon: 'home',
  color: 'green',
  hasPassword: true,
  topSecret: false,
);

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const VaultHomeScreen(libraryDir: '', vault: _vault),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.pumpAndSettle();
}

/// Tap as a finger does, then let the async opening run (as the mockups' openRow).
Future<void> _tapRow(WidgetTester t, Finder row) async {
  await t.tap(row);
  for (var i = 0; i < 6; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// No viewer, player or picture of an item anywhere on screen.
void _nothingDecoded() {
  expect(find.byType(PhotoViewerScreen), findsNothing);
  expect(find.byType(QuickLook), findsNothing);
  expect(find.byType(PrivateThumb), findsNothing);
  expect(
    find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
    findsNothing,
  );
  expect(find.byType(RawImage), findsNothing);
}

void main() {
  setUpAll(() {
    Device.debugDesktop = false;
    RustLib.initMock(api: _fake = _Fake());
  });
  setUp(() {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Prefs.write('vault-section', 'file');
    Prefs.write('add-column-hint', '3'); // the drag hint has been seen
    _fake.thumbnails = 0;
  });
  tearDown(() => TopSecretMode.on = false);

  testWidgets(
    'Top secret: every item is a sealed row; tapping one opens nothing',
    (t) async {
      TopSecretMode.on = true;
      await _open(t);
      for (final it in _items.where((i) => i.kind != 'audio')) {
        final row = _name(it.name);
        expect(row, findsWidgets, reason: '${it.kind} shows among the files');
        await _tapRow(t, row.first);
        expect(
          find.byKey(const ValueKey('sealed-item')),
          findsOneWidget,
          reason: it.kind,
        );
        _nothingDecoded();
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
      }
      expect(_fake.thumbnails, 0, reason: 'no thumbnail is read');
      // No Library tab: photos and videos are files here.
      expect(vaultSections(), isNot(contains(VaultSection.library)));
    },
  );

  testWidgets('Top secret: a recording is sealed too, never played', (t) async {
    TopSecretMode.on = true;
    debugVoice = true;
    addTearDown(() => debugVoice = false);
    Prefs.write('vault-section', 'audio');
    await _open(t);
    await _tapRow(t, find.text('memo').first);
    expect(find.byKey(const ValueKey('sealed-item')), findsOneWidget);
    _nothingDecoded();
  });

  test('Everyday keeps the Library and every way to add', () {
    TopSecretMode.on = false;
    expect(vaultSections(), contains(VaultSection.library));
  });

  testWidgets(
    'Everyday: the same file opens its preview (the gate above is real)',
    (t) async {
      TopSecretMode.on = false;
      await _open(t);
      await _tapRow(t, _name('contract.pdf').first);
      expect(find.byType(QuickLook), findsOneWidget);
      expect(find.byKey(const ValueKey('sealed-item')), findsNothing);
    },
  );
}
