import 'dart:convert';
import 'dart:io';

import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/links.dart';
import 'package:cozysafe/note_format.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/quick_look.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/format_bar.dart';
import 'package:cozysafe/widgets/vault_bar.dart' show notePreviewsPref;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The note being previewed, and what the preview saved.
class _Fake implements RustLibApi {
  String note = '';
  final saved = <String>[];

  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('ItemContent')) return Future<Uint8List>.value(Uint8List.fromList(utf8.encode(note)));
    if (n.contains('UpdateNote')) {
      saved.add(call.namedArguments[#text] as String);
      return Future<ItemInfo>.value(_note);
    }
    return null;
  }
}

final _note = ItemInfo(
  id: 'n1'.padRight(32, '_'),
  kind: ItemKind.note,
  name: 'Groceries',
  mime: 'text/plain',
  createdMs: 0,
  sizeBytes: BigInt.from(80),
  tagIds: const [],
  isFavorite: false,
  modifiedMs: 0,
);

late _Fake _fake;

List<String> _urls(String s) => [for (final l in findLinks(s)) l.url];
List<String> _typed(String s) => [for (final l in findLinks(s)) s.substring(l.start, l.end)];

/// Taps the link whose text is [text] inside the rich text on screen.
void _tapLink(WidgetTester t, String text) {
  for (final rich in t.widgetList<RichText>(find.byType(RichText))) {
    TapGestureRecognizer? hit;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text && span.recognizer is TapGestureRecognizer) {
        hit = span.recognizer as TapGestureRecognizer;
        return false;
      }
      return true;
    });
    if (hit != null) return hit!.onTap!();
  }
  fail('no link "$text"');
}

void main() {
  group('links in a note', () {
    test('http, https and www., without the punctuation that ends a sentence', () {
      expect(_urls('Go to https://example.com/a?b=1.'), ['https://example.com/a?b=1']);
      expect(_urls('See www.example.com, then http://x.org!'), ['https://www.example.com', 'http://x.org']);
      expect(_typed('Quoted "https://a.com/x"; done'), ['https://a.com/x']);
      expect(_urls('HTTPS://EXAMPLE.COM/Path'), ['HTTPS://EXAMPLE.COM/Path']);
    });

    test('parentheses: kept when they belong to the address', () {
      expect(_typed('(see https://en.wikipedia.org/wiki/Mars_(planet))'), ['https://en.wikipedia.org/wiki/Mars_(planet)']);
      expect(_typed('(see https://example.com/a).'), ['https://example.com/a']);
      expect(_typed('[https://example.com]'), ['https://example.com']);
    });

    test('not an e-mail address, a half address or another scheme', () {
      expect(findLinks('me@www.example.com'), isEmpty);
      expect(findLinks('write to anna@example.com'), isEmpty);
      expect(findLinks('https:// and www. alone'), isEmpty);
      expect(findLinks('ftp://www.example.com javascript:alert(1) file:///etc'), isEmpty);
      expect(findLinks('xhttps://example.com'), isEmpty);
    });

    test('positions point at the address as typed', () {
      const s = 'a www.b.com c';
      final l = findLinks(s).single;
      expect(s.substring(l.start, l.end), 'www.b.com');
      expect(l.url, 'https://www.b.com');
    });
  });

  group('punycode', () {
    test('RFC 3492 labels', () {
      expect(punycode('bücher'), 'bcher-kva');
      expect(punycode('münchen'), 'mnchen-3ya');
      expect(punycode('мойдомен'), 'd1acklchcc');
      expect(punycode('рф'), 'p1ai');
      expect(punycode('例え'), 'r8jz45g');
      expect(punycode('テスト'), 'zckzah');
      expect(punycode('ñ'), 'ida');
    });

    test('hosts: only labels outside ASCII change, lower case', () {
      expect(asciiHost('bücher.de'), 'xn--bcher-kva.de');
      expect(asciiHost('мойдомен.рф'), 'xn--d1acklchcc.xn--p1ai');
      expect(asciiHost('Example.COM'), 'example.com');
      expect(asciiHost('例え。テスト'), 'xn--r8jz45g.xn--zckzah');
      // A Cyrillic "а" in place of the Latin one shows.
      expect(asciiHost('аpple.com'), startsWith('xn--'));
    });
  });

  group('what may be opened', () {
    test('http and https with a host, in ASCII', () {
      final l = safeLink('https://bücher.de/straße?q=ü#top')!;
      expect(l.host, 'xn--bcher-kva.de');
      expect(l.url, 'https://xn--bcher-kva.de/stra%C3%9Fe?q=%C3%BC#top');
      expect(safeLink('http://example.com:8080/x')!.url, 'http://example.com:8080/x');
      expect(safeLink('https://user@evil.example/')!.host, 'evil.example');
    });

    test('every other scheme, and no host, is refused', () {
      for (final bad in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://scan/#Intent;scheme=zxing;end',
        'data:text/html,<b>x</b>',
        'cozysafe://open',
        'tel:123',
        'https://',
        'https:///path',
        'https://a..b/',
        'ftp://example.com',
      ]) {
        expect(safeLink(bad), isNull, reason: bad);
      }
    });

    test('Links.openExternal hands nothing else to the system', () async {
      final sent = <MethodCall>[];
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('cozysafe/privacy'), (c) async {
        sent.add(c);
        return true;
      });
      Links.debugCanOpen = true;
      addTearDown(() => Links.debugCanOpen = false);
      expect(await Links.openExternal('javascript:alert(1)'), false);
      expect(await Links.openExternal('intent://x#Intent;end'), false);
      expect(sent, isEmpty);
      expect(await Links.openExternal('https://bücher.de/'), true);
      expect(sent.single.method, 'openExternal');
      expect(sent.single.arguments, 'https://xn--bcher-kva.de/');
    });
  });

  group('checklists', () {
    test('a box flips on its line only, the rest untouched', () {
      const s = 'Trip\r\n- [ ] passport\r\n  * [x] tickets\r\nnot - [ ] a box';
      expect(toggleChecklist(s, 1), 'Trip\r\n- [x] passport\r\n  * [x] tickets\r\nnot - [ ] a box');
      expect(toggleChecklist(s, 2), 'Trip\r\n- [ ] passport\r\n  * [ ] tickets\r\nnot - [ ] a box');
      expect(toggleChecklist(s, 0), isNull);
      expect(toggleChecklist(s, 3), isNull);
      expect(toggleChecklist(s, 9), isNull);
      expect(toggleChecklist('- [X] Done', 0), '- [ ] Done');
    });
  });

  group('format bar', () {
    TextEditingValue v(String text, int a, [int? b]) =>
        TextEditingValue(text: text, selection: TextSelection(baseOffset: a, extentOffset: b ?? a));

    test('bold and italic wrap the selection, and unwrap it', () {
      final b = NoteFormat.wrap(v('make it bold', 8, 12), '**');
      expect(b.text, 'make it **bold**');
      expect(b.selection.textInside(b.text), 'bold');
      expect(NoteFormat.wrap(b, '**').text, 'make it bold');
      final empty = NoteFormat.wrap(v('ab', 1), '*');
      expect(empty.text, 'a**b');
      expect(empty.selection.baseOffset, 2);
      // "*" inside "**" is not italic.
      expect(NoteFormat.wrap(b, '*').text, 'make it ***bold***');
    });

    test('line marks: put, swap and take off', () {
      final h = NoteFormat.line(v('Title\nwords', 8), '# ');
      expect(h.text, 'Title\n# words');
      expect(h.selection.baseOffset, 10);
      expect(NoteFormat.line(h, '# ').text, 'Title\nwords');
      final list = NoteFormat.line(v('a\nb\nc', 0, 3), '- ');
      expect(list.text, '- a\n- b\nc');
      final check = NoteFormat.line(list.copyWith(selection: const TextSelection(baseOffset: 0, extentOffset: 7)), '- [ ] ');
      expect(check.text, '- [ ] a\n- [ ] b\nc');
      expect(NoteFormat.line(v('  - [x] done', 5), '- ').text, '  - done');
    });

    test('link', () {
      expect(NoteFormat.link(v('go ', 3)).text, 'go https://');
      expect(NoteFormat.link(v('go example.com', 3, 14)).text, 'go https://example.com');
      expect(NoteFormat.link(v('https://a.com', 0, 13)).text, 'https://a.com');
    });
  });

  group('the note preview', () {
    setUpAll(() => RustLib.initMock(api: _fake = _Fake()));
    setUp(() {
      Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
      Prefs.write(notePreviewsPref, '1');
      _fake
        ..saved.clear()
        ..note = 'Groceries\n- [ ] milk\n- [x] eggs\nRecipe: https://bücher.de/kuchen.';
      QuickLook.edited.clear();
      QuickLook.lastSave = null;
    });

    Widget app() => MaterialApp(
          theme: buildTheme(Brightness.light),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: QuickLook(item: _note, vaultId: 'v'),
        );

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('ticking a box rewrites that line and saves the note', (t) async {
      await t.pumpWidget(app());
      await settle(t);
      expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('check-0')));
      await settle(t);
      expect(_fake.saved, ['Groceries\n- [x] milk\n- [x] eggs\nRecipe: https://bücher.de/kuchen.']);
      expect(QuickLook.edited, {_note.id});
      // The preview shows the new state.
      expect(find.byIcon(Icons.check_box_outline_blank_rounded), findsNothing);
      await t.tap(find.byKey(const ValueKey('check-1')));
      await settle(t);
      expect(_fake.saved.last, 'Groceries\n- [x] milk\n- [ ] eggs\nRecipe: https://bücher.de/kuchen.');
    });

    testWidgets('a link asks first, naming the real host', (t) async {
      await t.pumpWidget(app());
      await settle(t);
      _tapLink(t, 'https://bücher.de/kuchen');
      await t.pumpAndSettle();
      expect(find.text('Open xn--bcher-kva.de in the browser?'), findsOneWidget);
      expect(find.text('https://xn--bcher-kva.de/kuchen'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('link-cancel')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-card')), findsNothing);
    });

    testWidgets('"Hide note text" hides the boxes and links until the note is tapped', (t) async {
      Prefs.write(notePreviewsPref, '0');
      await t.pumpWidget(app());
      await settle(t);
      expect(find.byKey(const ValueKey('check-0')), findsNothing);
      expect(find.textContaining('bücher'), findsNothing);
      expect(find.text('Tap to show'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('note-reveal')));
      await t.pump();
      expect(find.byKey(const ValueKey('check-0')), findsOneWidget);
      expect(find.text('Tap to show'), findsNothing);
      // Shown for this preview only: the setting is unchanged.
      expect(Prefs.read(notePreviewsPref), '0');
    });
  });
}
