// The 24 words never leave the screen (owner 2026-10-30: "never written to disk,
// absolutely"): no Copy, no Save to a file, no share, no Open file, unless the app is
// built with --dart-define=WORDS_EXPORT=true. The screens that show them stay on for a
// few minutes after the last touch, so they can be written down by hand.

import 'dart:io';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/sync/awake.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/recovery_words.dart';
import 'package:cozysafe/widgets/secret.dart';
import 'package:cozysafe/widgets/words_awake.dart';
import 'package:cozysafe/words_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm '
    'frown notice actor mom surround nurse feature ski gadget volume cousin cancel';

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  test('builds keep the words in the app unless told otherwise', () {
    expect(wordsExport, isFalse);
  });

  testWidgets('new vault and key change: no Copy, no Save', (t) async {
    await t.pumpWidget(_app(Scaffold(body: SingleChildScrollView(child: RecoveryWordsPanel(words: _words.split(' '))))));
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
    expect(find.byKey(const ValueKey('words-save')), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });

  testWidgets('Recovery Key page: no Copy, no Save, and the words typed back are not learnt', (t) async {
    await t.pumpWidget(_app(const EmergencyKitScreen(keyText: _words, confirm: true)));
    expect(find.byIcon(Icons.copy_rounded), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsNothing);
    final fields = find.descendant(of: find.byKey(const ValueKey('kit-confirm-words')), matching: find.byType(TextField));
    expect(fields, findsNWidgets(4));
    for (final field in t.widgetList<TextField>(fields)) {
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
    }
  });

  testWidgets('typing the words in to restore: Paste, but no Open file', (t) async {
    final c = TextEditingController();
    addTearDown(c.dispose);
    await t.pumpWidget(_app(Scaffold(body: SecretField(controller: c, label: 'Words', paste: true))));
    expect(find.byKey(const ValueKey('secret-paste')), findsOneWidget);
    expect(find.byKey(const ValueKey('secret-open-file')), findsNothing);
  });

  testWidgets('the screen stays on for 3 minutes after the last touch', (t) async {
    await t.pumpWidget(_app(const WordsAwake(child: SizedBox.expand())));
    expect(Awake.busy, isTrue);
    await t.pump(const Duration(minutes: 2));
    await t.tapAt(const Offset(10, 10)); // a touch starts the 3 minutes again
    await t.pump(const Duration(minutes: 2));
    expect(Awake.busy, isTrue);
    await t.pump(const Duration(minutes: 1, seconds: 1));
    expect(Awake.busy, isFalse);
    await t.tapAt(const Offset(10, 10));
    expect(Awake.busy, isTrue);
    await t.pumpWidget(_app(const SizedBox())); // leaving the page lets go at once
    expect(Awake.busy, isFalse);
  });

  test('every way out for the words is behind the switch', () {
    // Each function that copies, saves, shares or opens the words starts by checking it.
    final guarded = {
      'lib/widgets/recovery_words.dart': ['Future<void> _copy(', 'Future<void> saveWordsFile('],
      'lib/screens/emergency_kit.dart': ['Future<void> _copy(', 'Future<void> _share('],
      'lib/widgets/secret.dart': ['Future<void> _openFile('],
      'lib/widgets/words_input.dart': <String>[],
    };
    for (final MapEntry(key: path, value: heads) in guarded.entries) {
      final source = File(path).readAsStringSync();
      for (final head in heads) {
        final at = source.indexOf(head);
        expect(at, isNot(-1), reason: '$path: $head');
        final body = source.substring(at, source.indexOf('\n}', at).clamp(at, source.length));
        final firstLines = body.split('\n').skip(1).take(2).join('\n');
        expect(firstLines, contains('if (!wordsExport) return;'), reason: '$path: $head');
      }
      // And nothing else in these files reaches the clipboard, a file or the share sheet.
      final reaches = RegExp(r'Clipboard\.setData|SharePlus\.instance|getSaveLocation|writeAsString|openFile\(')
          .allMatches(source)
          .length;
      final allowed = {
        'lib/widgets/recovery_words.dart': 5, // _copy; saveWordsFile: save dialog, two writes, share
        'lib/screens/emergency_kit.dart': 2, // _copy, _share
        'lib/widgets/secret.dart': 3, // _openFile, the picker it calls; Paste empties the clipboard
        'lib/widgets/words_input.dart': 2, // both empty the clipboard after a paste
      }[path];
      expect(reaches, allowed, reason: '$path: a new way out must sit behind wordsExport');
    }
  });
}
