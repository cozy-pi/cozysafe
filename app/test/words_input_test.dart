// The 24-word grid (owner 2026-10-30): numbered cells, dots once a cell is left, four
// letters enough, a pasted list spread over the cells (numbers left out), a word not on
// the list marked, and a word wrong or out of place said once all 24 are in.

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/words_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm '
    'frown notice actor mom surround nurse feature ski gadget volume cousin cancel';

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Finder _field(int i) => find.byKey(ValueKey('words-field-$i'));

void main() {
  late TextEditingController c;
  setUp(() {
    c = TextEditingController();
    RecoveryWords.makesKey = (w) => w == _words;
  });
  tearDown(() => c.dispose());

  test('four letters stand for the word; a short word stands only for itself', () {
    expect(RecoveryWords.expand('boun'), 'bounce');
    expect(RecoveryWords.expand('BOUNC'), 'bounce');
    expect(RecoveryWords.expand('act'), 'act');
    expect(RecoveryWords.expand('bou'), isNull);
    expect(RecoveryWords.expand('xyzw'), isNull);
    expect(RecoveryWords.finished('zoo'), isTrue);
    expect(RecoveryWords.finished('act'), isFalse); // action, actor… start the same
  });

  test('a pasted list loses its numbers and bullets', () {
    final numbered = [for (final (i, w) in _words.split(' ').indexed) '${i + 1}. $w'].join('\n');
    expect(RecoveryWords.fromText(numbered).join(' '), _words);
    expect(RecoveryWords.fromText('• bounce\n• announce').join(' '), 'bounce announce');
  });

  testWidgets('pasting a numbered list into one cell fills all 24, in order', (t) async {
    await t.pumpWidget(_app(WordsInput(controller: c)));
    final numbered = [for (final (i, w) in _words.split(' ').indexed) '${i + 1}. $w'].join('\n');
    await t.enterText(_field(5), numbered);
    await t.pump();
    expect(c.text, _words);
    expect(find.text('•••••'), findsNWidgets(24)); // all hidden once spread
    expect(find.byKey(const ValueKey('words-no-key')), findsNothing);
  });

  testWidgets('four letters complete the word and move on; a cell left turns to dots', (t) async {
    await t.pumpWidget(_app(WordsInput(controller: c)));
    await t.enterText(_field(0), 'boun');
    await t.pump();
    expect(c.text, 'bounce');
    expect(t.widget<TextField>(_field(1)).focusNode!.hasFocus, isTrue);
    expect(find.text('•••••'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('words-show')));
    await t.pump();
    expect(find.text('•••••'), findsNothing);
  });

  testWidgets('a word not on the list is marked once its cell is left', (t) async {
    await t.pumpWidget(_app(WordsInput(controller: c)));
    await t.enterText(_field(0), 'qqq');
    await t.pump();
    BoxDecoration box() => t.widget<Container>(find.byKey(const ValueKey('words-cell-0'))).decoration! as BoxDecoration;
    expect((box().border! as Border).top.color, isNot(const Color(0xFFFF3B30)));
    await t.tap(find.byKey(const ValueKey('words-cell-3')));
    t.widget<TextField>(_field(3)).focusNode!.requestFocus();
    await t.pump();
    expect((box().border! as Border).top.color, const Color(0xFFFF3B30)); // the system red
  });

  testWidgets('24 real words that make no key: one is wrong or out of place', (t) async {
    await t.pumpWidget(_app(WordsInput(controller: c)));
    final swapped = _words.split(' ');
    final first = swapped[0];
    swapped[0] = swapped[1];
    swapped[1] = first;
    await t.enterText(_field(0), swapped.join(' '));
    await t.pump();
    expect(find.byKey(const ValueKey('words-no-key')), findsOneWidget);
  });

  testWidgets('Paste spreads the words and empties the clipboard', (t) async {
    String? clip = _words;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clip};
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.pumpWidget(_app(WordsInput(controller: c)));
    await t.tap(find.byKey(const ValueKey('words-paste')));
    await t.pumpAndSettle();
    expect(c.text, _words);
    expect(clip, isEmpty);
  });
}
