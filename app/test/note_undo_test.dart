// Undo and Redo in the note editor's bar (owner 2026-10-27: the editor had none): they
// step back through typing and through the marks the bar puts.

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/format_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bold, then undo and redo it', (t) async {
    final text = TextEditingController();
    final undo = UndoHistoryController();
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(children: [
          TextField(controller: text, undoController: undo, autofocus: true),
          NoteFormatBar(controller: text, undo: undo),
        ]),
      ),
    ));
    await t.tap(find.byType(TextField));
    await t.pump(const Duration(seconds: 1));
    await t.enterText(find.byType(TextField), 'hello');
    await t.pump(const Duration(seconds: 1));
    expect(undo.value.canUndo, isTrue, reason: '${undo.value}');
    text.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byKey(const ValueKey('format-bold')));
    await t.pump(const Duration(seconds: 1));
    expect(text.text, '**hello**');
    await t.tap(find.byKey(const ValueKey('format-undo')));
    await t.pump(const Duration(seconds: 1));
    expect(text.text, 'hello');
    await t.tap(find.byKey(const ValueKey('format-redo')));
    await t.pump(const Duration(seconds: 1));
    expect(text.text, '**hello**');
  });
}
