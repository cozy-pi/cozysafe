// What could not be done is said (2026-11-15 review): deleting, restoring and deleting
// for good count their failures instead of always reporting success; a note that cannot
// be read shows why instead of turning for ever; a search says it is still searching;
// Enter does not start a second restore. The Rust core is a fake.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/bulk_text.dart';
import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/restore_flow.dart';
import 'package:cozysafe/screens/search.dart';
import 'package:cozysafe/screens/trash.dart';
import 'package:cozysafe/screens/vault_home.dart' show DeleteOriginalsSheet;
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/toast.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:cozysafe/widgets/working_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, {bool deleted = true}) => ItemInfo(
      id: id,
      kind: kind,
      name: name,
      mime: kind == 'photo' ? 'image/jpeg' : 'text/plain',
      createdMs: _now,
      sizeBytes: BigInt.from(1000),
      deletedMs: deleted ? _now - 86400000 : null,
      tagIds: const [],
      isFavorite: false,
      modifiedMs: _now, account: '', hosts: const [],
    );

class _Fake implements RustLibApi {
  final calls = <String>[];
  List<ItemInfo> trash = [];
  /// Ids the vault refuses to restore or delete.
  final stuck = <String>{};
  /// What reading a note gives: bytes, an error, or a wait that never ends.
  Object? content;
  final clashAsked = Completer<PasswordClash>();

  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    String id() => call.namedArguments[#id] as String;
    if (n.contains('ListTrash')) return Future<List<ItemInfo>>.value(trash);
    if (n.contains('ListHeld')) return Future<List<ItemInfo>>.value(const []);
    if (n.contains('ItemThumbnail')) return Future<Uint8List>.value(Uint8List(0));
    if (n.contains('ItemContent')) {
      final c = content;
      if (c is Uint8List) return Future<Uint8List>.value(c);
      if (c is Completer<Uint8List>) return c.future;
      return Future<Uint8List>.error(c ?? VaultError.storage);
    }
    for (final verb in ['DeleteItem', 'RestoreItem']) {
      if (n.contains(verb)) {
        calls.add('$verb ${id()}');
        if (stuck.contains(id())) return Future<void>.error(VaultError.storage);
        trash = trash.where((i) => i.id != id()).toList();
        return Future<void>.value();
      }
    }
    if (n.contains('ParseSecretKey')) return Uint8List(32);
    if (n.contains('PasswordClash')) {
      calls.add('PasswordClash');
      return clashAsked.future;
    }
    return null;
  }
}

late _Fake _fake;

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  final l = lookupAppLocalizations(const Locale('en'));

  setUpAll(() {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    KeyBackup.debugSupported = false;
    debugHoldToasts = true;
  });
  setUp(() {
    _fake = _Fake();
    RustLib.initMock(api: _fake);
  });
  tearDown(RustLib.dispose);

  group('the words', () {
    test('all moved: as before', () {
      expect(trashedText(l, moved: 1, failed: 0), 'Moved to Recently deleted');
      expect(trashedText(l, moved: 3, failed: 0), '3 items moved to Recently deleted');
    });

    test('some not moved: both counts', () {
      expect(trashedText(l, moved: 2, failed: 1), '2 moved to Recently deleted, 1 could not be moved.');
      expect(trashedText(l, moved: 0, failed: 4), '0 moved to Recently deleted, 4 could not be moved.');
    });

    test('restore and delete for good: silent when all went, counts when not', () {
      expect(restoredText(l, restored: 5, failed: 0), isNull);
      expect(restoredText(l, restored: 3, failed: 2), '3 restored, 2 could not be restored.');
      expect(deletedForGoodText(l, deleted: 5, failed: 0), isNull);
      expect(deletedForGoodText(l, deleted: 1, failed: 2), '1 deleted for good, 2 could not be deleted.');
    });

    test('every language has both counts in each message', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final x = lookupAppLocalizations(locale);
        for (final text in [x.movedToTrashSome(41, 73), x.restoredSome(41, 73), x.deletedForGoodSome(41, 73), x.sendPreparing(41, 73)]) {
          expect(text, allOf(contains('41'), contains('73')), reason: '$locale');
        }
      }
    });
  });

  group('Recently deleted', () {
    testWidgets('a restore the vault refuses is said, and the item stays', (t) async {
      _fake.trash = [_item('f1', 'file', 'Contract.pdf'), _item('f2', 'file', 'Lease.pdf')];
      _fake.stuck.add('f1');
      await t.pumpWidget(_app(const TrashScreen()));
      await _settle(t);
      await t.longPress(find.text('Contract.pdf'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-restore')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
      await _settle(t);
      expect(_fake.calls, ['RestoreItem f1']);
      expect(find.text('0 restored, 1 could not be restored.'), findsOneWidget);
      expect(find.text('Contract.pdf'), findsOneWidget);
    });

    testWidgets('a restore that works says nothing more: the item is gone from the list', (t) async {
      _fake.trash = [_item('f1', 'file', 'Contract.pdf'), _item('f2', 'file', 'Lease.pdf')];
      await t.pumpWidget(_app(const TrashScreen()));
      await _settle(t);
      await t.longPress(find.text('Contract.pdf'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-restore')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
      await _settle(t);
      expect(find.textContaining('could not'), findsNothing);
      expect(find.text('Contract.pdf'), findsNothing);
    });

    testWidgets('a delete for good the vault refuses is said', (t) async {
      _fake.trash = [_item('f1', 'file', 'Contract.pdf'), _item('f2', 'file', 'Lease.pdf')];
      _fake.stuck.add('f1');
      await t.pumpWidget(_app(const TrashScreen()));
      await _settle(t);
      await t.longPress(find.text('Contract.pdf'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-purge')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
      await _settle(t);
      expect(_fake.calls, ['DeleteItem f1']);
      expect(find.text('0 deleted for good, 1 could not be deleted.'), findsOneWidget);
    });
  });

  group('a note', () {
    testWidgets('that cannot be read says so, with its code, instead of turning for ever', (t) async {
      _fake.content = VaultError.storage;
      await t.pumpWidget(_app(NoteScreen(item: _item('n1', 'note', 'Shopping', deleted: false))));
      await _settle(t);
      expect(find.byKey(const ValueKey('note-failed')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('storage'), findsOneWidget);
    });

    testWidgets('read while the vault is locked keeps waiting for it to open', (t) async {
      _fake.content = VaultError.locked;
      await t.pumpWidget(_app(NoteScreen(item: _item('n1', 'note', 'Shopping', deleted: false))));
      await _settle(t);
      expect(find.byKey(const ValueKey('note-failed')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('search', () {
    final items = [_item('n1', 'note', 'Shopping', deleted: false), _item('f1', 'file', 'Contract.pdf', deleted: false)];

    testWidgets('says it is searching while the notes are still being read, then answers', (t) async {
      final reading = Completer<Uint8List>();
      _fake.content = reading;
      await t.pumpWidget(_app(SearchScreen(items: items, thumbnail: (_) => Future.value(Uint8List(0)))));
      await t.pump();
      await t.enterText(find.byType(TextField), 'milk');
      await t.pump();
      expect(find.byKey(const ValueKey('search-searching')), findsOneWidget);
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.textContaining('Nothing'), findsNothing);

      reading.complete(Uint8List.fromList(utf8.encode('Shopping\nmilk and bread')));
      await _settle(t);
      expect(find.byKey(const ValueKey('search-searching')), findsNothing);
      expect(find.textContaining('Shopping'), findsWidgets);
    });

    testWidgets('once everything is read, nothing found is nothing found', (t) async {
      _fake.content = Uint8List.fromList(utf8.encode('Shopping\nmilk'));
      await t.pumpWidget(_app(SearchScreen(items: items, thumbnail: (_) => Future.value(Uint8List(0)))));
      await _settle(t);
      await t.enterText(find.byType(TextField), 'zebra');
      await t.pump();
      expect(find.byKey(const ValueKey('search-searching')), findsNothing);
    });
  });

  testWidgets('restore from a file: Enter while it is working does not start it again', (t) async {
    await t.pumpWidget(_app(const RestoreKeysScreen(libraryDir: '/nowhere', filePath: '/nowhere/b.cozysafe', fileName: 'b.cozysafe')));
    await t.pump();
    final password = find.descendant(of: find.byKey(const ValueKey('restore-password')), matching: find.byType(TextField));
    await t.enterText(find.descendant(of: find.byKey(const ValueKey('restore-words')), matching: find.byType(TextField)).first, 'abandon ability');
    await t.enterText(password, 'correct horse battery staple');
    await t.pump();
    for (var i = 0; i < 3; i++) {
      t.widget<TextField>(password).onSubmitted!('');
      await t.pump();
    }
    expect(_fake.calls.where((c) => c == 'PasswordClash'), hasLength(1));
  });

  testWidgets('the working card follows the count, and goes when the work ends', (t) async {
    await t.pumpWidget(_app(const Scaffold(body: SizedBox.expand(key: ValueKey('host')))));
    final context = t.element(find.byKey(const ValueKey('host')));
    final progress = ValueNotifier(l.sendPreparing(0, 3));
    final work = Completer<int>();
    final done = whileWorking(context, progress.value, () => work.future, live: progress);
    await t.pump();
    expect(find.byKey(const ValueKey('working-card')), findsOneWidget);
    expect(find.text('Getting 0 of 3 ready to send'), findsOneWidget);
    progress.value = l.sendPreparing(2, 3);
    await t.pump();
    expect(find.text('Getting 2 of 3 ready to send'), findsOneWidget);
    work.complete(7);
    expect(await done, 7);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('working-card')), findsNothing);
    progress.dispose();
  });

  testWidgets('removing the originals: the only-copy sentence shows only when the vault is nowhere else', (t) async {
    await t.pumpWidget(_app(const Scaffold(body: DeleteOriginalsSheet(count: 5, photos: true, onlyCopy: true))));
    expect(find.byKey(const ValueKey('originals-only-copy')), findsOneWidget);
    expect(find.textContaining('the only copy'), findsOneWidget);
    await t.pumpWidget(_app(const Scaffold(body: DeleteOriginalsSheet(count: 5, photos: true))));
    expect(find.byKey(const ValueKey('originals-only-copy')), findsNothing);
  });

  testWidgets('the vault bar shows icons only, the words kept for tooltips and screen readers', (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final centre in [const SizedBox.square(dimension: centrePlusSize), null]) {
      await t.pumpWidget(_app(Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: VaultBar(
            section: VaultSection.note,
            sections: VaultSection.values,
            home: const SizedBox.square(dimension: 32),
            onSection: (_) {},
            centre: centre,
          ),
        ),
      )));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Notes'), findsNothing, reason: 'centre: ${centre != null}');
      expect(find.byIcon(sectionIcon(VaultSection.note)), findsOneWidget);
      expect(find.bySemanticsLabel('Notes'), findsOneWidget);
    }
  });
}
