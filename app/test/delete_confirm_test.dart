// Every delete asks first (owner 2026-10-26), Recently deleted has no "Restore all" or
// "Delete all", its menus match the preview, and hold-then-drag selects a run of items.
// The Rust core is a fake that records what was asked of it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/hidden_features.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/trash.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/confirm_delete.dart';
import 'package:cozysafe/widgets/drag_select.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, [int order = 0]) => ItemInfo(
      id: id,
      kind: kind,
      name: name,
      mime: kind == 'photo' ? 'image/jpeg' : (kind == 'video' ? 'video/quicktime' : 'text/plain'),
      createdMs: _now,
      sizeBytes: BigInt.from(1000),
      deletedMs: _now - 86400000 - order * 1000, // newest first, in the order given
      tagIds: const [],
      isFavorite: false,
      modifiedMs: _now,
    );

class _Fake implements RustLibApi {
  final calls = <String>[];
  List<ItemInfo> trash = [];

  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    String id() => call.namedArguments[#id] as String;
    if (n.contains('ListTrash')) return Future<List<ItemInfo>>.value(trash);
    if (n.contains('ListHeld')) return Future<List<ItemInfo>>.value(const []);
    if (n.contains('ItemThumbnail')) return Future<Uint8List>.value(Uint8List(0));
    if (n.contains('ItemContent')) return Future<Uint8List>.value(Uint8List.fromList(utf8.encode('Shopping\nmilk')));
    for (final verb in ['TrashItem', 'DeleteItem', 'RestoreItem', 'PurgeHeld', 'RestoreHeld']) {
      if (n.contains(verb)) {
        calls.add('$verb ${id()}');
        if (verb != 'TrashItem') trash = trash.where((i) => i.id != id()).toList();
        return Future<void>.value();
      }
    }
    if (n.contains('UpdateNote') || n.contains('AddNote')) {
      return Future<ItemInfo>.value(_item('n1', 'note', 'Shopping'));
    }
    return null;
  }
}

final _fake = _Fake();

/// A tall phone, so the whole list shows without scrolling.
void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(430, 2000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// Let the fake's futures and the frames settle.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _fake);
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
  });
  setUp(() {
    _fake.calls.clear();
    _fake.trash = [
      for (var i = 0; i < 6; i++) _item('p$i', 'photo', 'IMG_$i.jpg', i),
      _item('v1', 'video', 'Beach.MOV', 6),
      _item('n1', 'note', 'Shopping', 7),
      _item('f1', 'file', 'Contract.pdf', 8),
    ];
  });

  group('drag range', () {
    const order = ['a', 'b', 'c', 'd', 'e'];
    test('selects from where the finger came down to where it is', () {
      expect(dragRange(order: order, base: {}, anchor: 'b', over: 'd', adding: true), {'b', 'c', 'd'});
      // Upwards too.
      expect(dragRange(order: order, base: {}, anchor: 'd', over: 'b', adding: true), {'b', 'c', 'd'});
    });
    test('dragging back gives the passed items their old state again', () {
      final base = {'a', 'e'};
      expect(dragRange(order: order, base: base, anchor: 'b', over: 'd', adding: true), {'a', 'b', 'c', 'd', 'e'});
      expect(dragRange(order: order, base: base, anchor: 'b', over: 'b', adding: true), {'a', 'b', 'e'});
    });
    test('starting on a selected item deselects the run', () {
      expect(dragRange(order: order, base: {'a', 'b', 'c', 'd'}, anchor: 'b', over: 'c', adding: false), {'a', 'd'});
    });
    test('an id that is not shown changes nothing', () {
      expect(dragRange(order: order, base: {'a'}, anchor: 'x', over: 'c', adding: true), {'a'});
    });
  });

  testWidgets('the delete question names the count, and only Delete confirms', (t) async {
    await t.pumpWidget(_app(const SizedBox.expand(key: ValueKey('host'))));
    final context = t.element(find.byKey(const ValueKey('host')));

    var answer = confirmTrash(context, count: 3);
    await t.pumpAndSettle();
    expect(find.text('Move 3 items to Recently deleted?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('confirm-delete-cancel')));
    await t.pumpAndSettle();
    expect(await answer, isFalse);

    answer = confirmTrash(context, count: 1, name: 'Passport.pdf');
    await t.pumpAndSettle();
    expect(find.text('Move to Recently deleted?'), findsOneWidget);
    expect(find.text('Passport.pdf'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
    await t.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('deleting a note from its editor asks first', (t) async {
    await t.pumpWidget(_app(NoteScreen(item: _item('n1', 'note', 'Shopping'))));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('note-delete')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-delete')), findsOneWidget);
    expect(_fake.calls, isEmpty);
    await t.tap(find.byKey(const ValueKey('confirm-delete-cancel')));
    await _settle(t);
    expect(_fake.calls, isEmpty);
    await t.tap(find.byKey(const ValueKey('note-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
    await _settle(t);
    expect(_fake.calls, ['TrashItem n1']);
  });

  testWidgets('Recently deleted: no Restore all / Delete all; grouped by kind', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const TrashScreen()));
    await _settle(t);
    expect(find.text('Restore all'), findsNothing);
    expect(find.text('Delete all'), findsNothing);
    expect(find.byKey(const ValueKey('restore')), findsNothing);
    expect(find.byKey(const ValueKey('delete-all')), findsNothing);
    // The video sits in the grid with the photos, with its play mark.
    expect(find.byKey(const ValueKey('trash-video-mark')), findsOneWidget);
    expect(find.textContaining('Library'), findsOneWidget);
    expect(find.textContaining('Notes'), findsOneWidget);
    expect(find.textContaining('Files'), findsOneWidget);
  });

  testWidgets('Recently deleted: the long-press menu is Restore, Info, Delete for good', (t) async {
    _tall(t);
    await t.pumpWidget(_app(const TrashScreen()));
    await _settle(t);
    await t.longPress(find.text('Contract.pdf'));
    await t.pumpAndSettle();
    final labels = [
      for (final k in ['menu-restore', 'menu-info', 'menu-purge'])
        t.getTopLeft(find.byKey(ValueKey(k))).dy,
    ];
    expect(labels, orderedEquals([...labels]..sort()));
    expect(find.text('Delete for good'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('menu-purge')));
    await t.pumpAndSettle();
    // Asked first; nothing deleted yet.
    expect(find.byKey(const ValueKey('confirm-delete')), findsOneWidget);
    expect(_fake.calls, isEmpty);
    await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
    await _settle(t);
    expect(_fake.calls, ['DeleteItem f1']);
  });

  testWidgets('Recently deleted: the selection bar acts on the selection only, and asks', (t) async {
    if (!selectShown) return; // selecting many is hidden for the beta
    _tall(t);
    await t.pumpWidget(_app(const TrashScreen()));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('trash-more')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('trash-select')));
    await t.pump();
    // Nothing selected: Delete for good does nothing.
    await t.tap(find.byKey(const ValueKey('trash-purge')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-delete')), findsNothing);
    await t.tap(find.text('Shopping'));
    await t.tap(find.text('Contract.pdf'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('trash-purge')));
    await t.pumpAndSettle();
    expect(find.text('Delete 2 items for good?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
    await _settle(t);
    expect(_fake.calls, unorderedEquals(['DeleteItem n1', 'DeleteItem f1']));
  });

  testWidgets('hold, then drag across the grid selects the run, and back deselects', (t) async {
    if (!selectShown) return; // selecting many is hidden for the beta
    _tall(t);
    await t.pumpWidget(_app(const TrashScreen()));
    await _settle(t);
    Offset at(String id) => t.getCenter(find.byKey(ValueKey('trash-$id')));
    // Held still: the item's menu, without a lift.
    final still = await t.startGesture(at('p0'));
    await t.pump(kLongPressTimeout + DragSelect.menuDelay + const Duration(milliseconds: 50));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-menu')), findsOneWidget);
    await still.up();
    await t.tapAt(const Offset(5, 1990)); // outside the menu: closes it
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-menu')), findsNothing);
    // Held, then moved: a run is selected, and no menu.
    final g = await t.startGesture(at('p0'));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveTo(at('p1'));
    await t.pump();
    await g.moveTo(at('p4')); // the next row, second column: p0…p4 in order
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-menu')), findsNothing);
    expect(find.text('5 selected'), findsOneWidget);
    await g.moveTo(at('p2'));
    await t.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(_fake.calls, isEmpty);
  });
}
