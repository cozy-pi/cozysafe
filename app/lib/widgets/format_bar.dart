import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'vault_bar.dart' show Glass;

/// What the editor's format bar does to the text: it only types Markdown marks, the
/// note stays plain text (the preview draws them, `MarkdownLite`).
abstract final class NoteFormat {
  /// Wrap the selection in [mark] ("**" bold, "*" italic), or take it off when the
  /// selection is already wrapped. With nothing selected, a pair with the cursor inside.
  static TextEditingValue wrap(TextEditingValue v, String mark) {
    final text = v.text;
    final sel = _selection(v);
    final before = text.substring(0, sel.start);
    final inside = sel.textInside(text);
    final after = text.substring(sel.end);
    // Already wrapped (and "*" is not half of a "**"): unwrap.
    bool wrapped(String a, String b) =>
        a.endsWith(mark) && b.startsWith(mark) && (mark != '*' || (!a.endsWith('**') && !b.startsWith('**')));
    if (wrapped(before, after)) {
      final start = sel.start - mark.length;
      return TextEditingValue(
        text: before.substring(0, start) + inside + after.substring(mark.length),
        selection: TextSelection(baseOffset: start, extentOffset: start + inside.length),
      );
    }
    final start = sel.start + mark.length;
    return TextEditingValue(
      text: '$before$mark$inside$mark$after',
      selection: TextSelection(baseOffset: start, extentOffset: start + inside.length),
    );
  }

  static final _prefix = RegExp(r'^(\s*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] )?');

  /// Put [prefix] ("# ", "- ", "- [ ] ") at the start of every line the selection
  /// touches, in place of another one; a line that already has it loses it.
  static TextEditingValue line(TextEditingValue v, String prefix) {
    final text = v.text;
    final sel = _selection(v);
    final first = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
    var last = text.indexOf('\n', sel.end);
    if (last < 0) last = text.length;
    final lines = text.substring(first, last).split('\n');
    final kind = _kind(prefix);
    // All the touched lines have it already: take it off; otherwise give it to all.
    final allHave = lines.every((l) => _kind(_prefix.firstMatch(l)!.group(2)) == kind);
    var base = sel.baseOffset, extent = sel.extentOffset;
    var at = first;
    final out = <String>[];
    for (final l in lines) {
      final m = _prefix.firstMatch(l)!;
      final indent = m.group(1)!;
      final old = m.group(2) ?? '';
      final put = allHave ? '' : prefix;
      final next = '$indent$put${l.substring(m.end)}';
      // Offsets after the changed prefix move by the difference.
      final pos = at + indent.length;
      final delta = put.length - old.length;
      int shift(int x) => x >= pos + old.length ? x + delta : (x >= pos ? pos + put.length : x);
      base = shift(base);
      extent = shift(extent);
      out.add(next);
      at += next.length + 1;
    }
    return TextEditingValue(
      text: text.substring(0, first) + out.join('\n') + text.substring(last),
      selection: TextSelection(baseOffset: base, extentOffset: extent),
    );
  }

  static String _kind(String? prefix) {
    if (prefix == null || prefix.isEmpty) return '';
    if (prefix.startsWith('#')) return '#';
    return prefix.contains('[') ? '[]' : '-';
  }

  /// A web address: "https://" typed at the cursor, or put in front of the selected text
  /// (a site name typed earlier) unless it already starts with http.
  static TextEditingValue link(TextEditingValue v) {
    final text = v.text;
    final sel = _selection(v);
    final inside = sel.textInside(text);
    if (inside.toLowerCase().startsWith(RegExp('https?://'))) return v;
    final put = 'https://$inside';
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, put),
      selection: TextSelection.collapsed(offset: sel.start + put.length),
    );
  }

  /// The selection, or the end of the text when the field has none yet.
  static TextSelection _selection(TextEditingValue v) =>
      v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
}

/// The small bar over the keyboard while a note is edited: Undo · Redo (owner
/// 2026-10-27: the editor had none), then Bold · Italic · Heading · List · Checklist ·
/// Link, each typing its Markdown marks at the selection, then Done typing, which puts
/// the keyboard away. It scrolls sideways on a narrow phone.
class NoteFormatBar extends StatelessWidget {
  const NoteFormatBar({super.key, required this.controller, this.undo, this.onDoneTyping});
  final TextEditingController controller;
  /// The field's history: typing and the marks these buttons put (Cmd+Z / Shift+Cmd+Z
  /// on a keyboard too).
  final UndoHistoryController? undo;
  /// Hides the keyboard; the note's own buttons come back at the bottom.
  final VoidCallback? onDoneTyping;

  void _apply(TextEditingValue Function(TextEditingValue) f) {
    // The keyboard may be composing a word (Vietnamese Telex): it is finished first.
    final v = controller.value.copyWith(composing: TextRange.empty);
    controller.value = f(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget button(String key, IconData icon, String tip, TextEditingValue Function(TextEditingValue) f) => IconButton(
          key: ValueKey('format-$key'),
          tooltip: tip,
          onPressed: () => _apply(f),
          iconSize: 24,
          style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
          icon: Icon(icon, color: ink),
        );
    final done = onDoneTyping;
    return Glass(
      key: const ValueKey('format-bar'),
      radius: 28,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (undo case final u?)
              ValueListenableBuilder<UndoHistoryValue>(
                valueListenable: u,
                builder: (context, h, _) => Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    key: const ValueKey('format-undo'),
                    tooltip: l.formatUndo,
                    onPressed: h.canUndo ? u.undo : null,
                    iconSize: 24,
                    style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
                    icon: Icon(Icons.undo_rounded, color: h.canUndo ? ink : ink.withValues(alpha: .3)),
                  ),
                  IconButton(
                    key: const ValueKey('format-redo'),
                    tooltip: l.formatRedo,
                    onPressed: h.canRedo ? u.redo : null,
                    iconSize: 24,
                    style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
                    icon: Icon(Icons.redo_rounded, color: h.canRedo ? ink : ink.withValues(alpha: .3)),
                  ),
                  Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: 2), color: ink.withValues(alpha: .15)),
                ]),
              ),
            button('bold', Icons.format_bold_rounded, l.formatBold, (v) => NoteFormat.wrap(v, '**')),
            button('italic', Icons.format_italic_rounded, l.formatItalic, (v) => NoteFormat.wrap(v, '*')),
            button('heading', Icons.title_rounded, l.formatHeading, (v) => NoteFormat.line(v, '# ')),
            button('list', Icons.format_list_bulleted_rounded, l.formatList, (v) => NoteFormat.line(v, '- ')),
            button('checklist', Icons.checklist_rounded, l.formatChecklist, (v) => NoteFormat.line(v, '- [ ] ')),
            button('link', Icons.link_rounded, l.formatLink, NoteFormat.link),
            if (done != null) ...[
              Container(width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: 2), color: ink.withValues(alpha: .15)),
              IconButton(
                key: const ValueKey('format-done-typing'),
                tooltip: l.doneTyping,
                onPressed: done,
                iconSize: 24,
                style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
                icon: Icon(Icons.keyboard_hide_rounded, color: ink),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
