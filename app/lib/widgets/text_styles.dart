import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../lock_guard.dart';
import '../note_format.dart';
import '../theme.dart';

/// Reading and writing text (docs/ui.md, design language): book-like margins and line
/// height; a note's first line is its title, shown large and bold as it is typed;
/// Markdown, JSON and code read well without any extra library.

/// A note's text field controller: the first line (the title) is drawn large and bold;
/// Markdown marks typed with the format bar show lightly (**bold** bold with its stars
/// quieter, list and box marks quieter, addresses underlined). Only styles change, never
/// the text, so the cursor is unaffected; a very long note keeps the title style alone.
class NoteTextController extends TextEditingController {
  NoteTextController({super.text});

  static const body = TextStyle(fontSize: CsType.body, height: 1.6);
  static const title = TextStyle(fontSize: CsType.title1, height: 1.3, fontWeight: FontWeight.w800, letterSpacing: -.4);

  /// Longer notes skip the Markdown styling (it runs on every key).
  static const styledMax = 20000;

  static final _bold = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*');
  static final _italic = RegExp(r'(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])|(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)');
  static final _lineMark = RegExp(r'^[ \t]*(#{1,6} |[-*+] \[[ xX]\] |[-*+] )', multiLine: true);
  static final _heading = RegExp(r'^[ \t]*#{1,6} .*$', multiLine: true);

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = (style ?? const TextStyle()).merge(body);
    final quiet = TextStyle(color: CsColors.of(context).muted);
    final nl = text.indexOf('\n');
    final split = nl < 0 ? text.length : nl;
    // Ranges and their styles; later ones are merged over earlier ones.
    final ranges = <(int, int, TextStyle)>[(0, split, title)];
    if (text.length <= styledMax) {
      for (final m in _heading.allMatches(text)) {
        if (m.start > split) ranges.add((m.start, m.end, const TextStyle(fontWeight: FontWeight.w800)));
      }
      for (final m in _lineMark.allMatches(text)) {
        ranges.add((m.start, m.end, quiet));
      }
      for (final m in _bold.allMatches(text)) {
        // The title is already heavier than bold.
        if (m.start >= split) ranges.add((m.start + 2, m.end - 2, const TextStyle(fontWeight: FontWeight.w700)));
        ranges.add((m.start, m.start + 2, quiet));
        ranges.add((m.end - 2, m.end, quiet));
      }
      for (final m in _italic.allMatches(text)) {
        ranges.add((m.start + 1, m.end - 1, const TextStyle(fontStyle: FontStyle.italic)));
        ranges.add((m.start, m.start + 1, quiet));
        ranges.add((m.end - 1, m.end, quiet));
      }
      for (final f in findLinks(text)) {
        ranges.add((f.start, f.end, const TextStyle(decoration: TextDecoration.underline)));
      }
    }
    // While the keyboard composes a word (Vietnamese Telex and the like), keep its
    // underline so the person sees what is being composed.
    final c = value.composing;
    if (withComposing && c.isValid && !c.isCollapsed && c.end <= text.length) {
      ranges.add((c.start, c.end, const TextStyle(decoration: TextDecoration.underline)));
    }
    return TextSpan(style: base, children: _pieces(text, ranges));
  }

  /// [text] cut at every range edge, each piece with the styles of the ranges over it.
  static List<TextSpan> _pieces(String text, List<(int, int, TextStyle)> ranges) {
    final cuts = <int>{0, text.length};
    for (final (s, e, _) in ranges) {
      cuts..add(s.clamp(0, text.length))..add(e.clamp(0, text.length));
    }
    final at = cuts.toList()..sort();
    // Sweep: ranges start and end at cuts; the open ones style the piece.
    final starts = <int, List<int>>{};
    for (final (i, r) in ranges.indexed) {
      if (r.$1 < r.$2) (starts[r.$1] ??= []).add(i);
    }
    final open = <int>[];
    final out = <TextSpan>[];
    for (var k = 0; k + 1 < at.length; k++) {
      final from = at[k], to = at[k + 1];
      open
        ..removeWhere((i) => ranges[i].$2 <= from)
        ..addAll(starts[from] ?? const []);
      if (from >= to) continue;
      TextStyle? st;
      for (final i in open.toList()..sort()) {
        st = st == null ? ranges[i].$3 : st.merge(ranges[i].$3);
      }
      out.add(TextSpan(text: text.substring(from, to), style: st));
    }
    return out;
  }
}

/// Copy from a reader: what was copied is noted so it is wiped from the clipboard later.
Widget copyAwareMenu(BuildContext context, EditableTextState state) {
  final sel = state.textEditingValue.selection;
  final picked = sel.isValid && !sel.isCollapsed ? sel.textInside(state.textEditingValue.text) : null;
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: [
      for (final it in state.contextMenuButtonItems)
        if (it.type == ContextMenuButtonType.copy && picked != null)
          it.copyWith(onPressed: () {
            it.onPressed?.call();
            LockGuard.copied(picked);
          })
        else
          it,
    ],
  );
}

const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Roboto Mono'], fontSize: CsType.footnote, height: 1.5);

/// Code or data in a soft rounded card, fixed-width; JSON keys strong, values quieter.
class CodeCard extends StatelessWidget {
  const CodeCard({super.key, required this.text, this.json = false});
  final String text;
  final bool json;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final spans = json ? _jsonSpans(text, ink) : [TextSpan(text: text)];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: ink.withValues(alpha: .06), borderRadius: BorderRadius.circular(Ui.radius)),
      child: SelectableText.rich(
        TextSpan(style: _mono.copyWith(color: ink), children: spans),
        key: const ValueKey('text-view'),
        contextMenuBuilder: copyAwareMenu,
      ),
    );
  }

  static final _token = RegExp(r'"(?:[^"\\]|\\.)*"(\s*:)?|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\btrue\b|\bfalse\b|\bnull\b');

  static List<TextSpan> _jsonSpans(String s, Color ink) {
    final out = <TextSpan>[];
    var at = 0;
    for (final m in _token.allMatches(s)) {
      if (m.start > at) out.add(TextSpan(text: s.substring(at, m.start), style: TextStyle(color: ink.withValues(alpha: .45))));
      final t = m.group(0)!;
      if (m.group(1) != null) {
        out.add(TextSpan(text: t, style: const TextStyle(fontWeight: FontWeight.w700))); // a key
      } else if (t.startsWith('"')) {
        out.add(TextSpan(text: t, style: TextStyle(color: ink.withValues(alpha: .78))));
      } else {
        out.add(TextSpan(text: t, style: TextStyle(color: ink.withValues(alpha: .62), fontStyle: FontStyle.italic)));
      }
      at = m.end;
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at), style: TextStyle(color: ink.withValues(alpha: .45))));
    return out;
  }
}

/// Plain text, like a page in a book.
class ProseText extends StatelessWidget {
  const ProseText({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SelectableText(
        text,
        key: const ValueKey('text-view'),
        contextMenuBuilder: copyAwareMenu,
        style: const TextStyle(fontSize: CsType.body, height: 1.6),
      );
}

/// The common part of Markdown, drawn by the app itself (no library to review):
/// headings, lists, checklists ("- [ ] task", "- [x] done"), quotes, code blocks, rules,
/// **bold**, *italic*, `code` and web addresses. The text itself stays plain; this is
/// only how it is read.
class MarkdownLite extends StatefulWidget {
  const MarkdownLite(
      {super.key, required this.text, this.onToggle, this.onLink, this.fontSize = 17.5, this.selectable = true});
  final String text;

  /// A tap on a checklist box, with its line (0-based, in [text]); null: boxes are drawn only.
  final void Function(int line)? onToggle;

  /// A tap on a web address; null: addresses are underlined only. Callers confirm the host
  /// before anything opens (`confirmOpenLink`).
  final void Function(String url)? onLink;

  /// The body size; headings scale with it.
  final double fontSize;

  /// Text can be selected and copied (a reader); off for a preview that takes taps.
  final bool selectable;

  @override
  State<MarkdownLite> createState() => _MarkdownLiteState();
}

class _MarkdownLiteState extends State<MarkdownLite> {
  /// A tap on a link: one per link drawn, released on every rebuild.
  final _taps = <TapGestureRecognizer>[];

  void _release() {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  static final _list = RegExp(r'^([-*+]|\d+[.)]) ');
  static final _check = RegExp(r'^[-*+] \[([ xX])\] ');

  @override
  Widget build(BuildContext context) {
    _release();
    final ink = Theme.of(context).colorScheme.onSurface;
    final muted = CsColors.of(context).muted;
    final blocks = <Widget>[];
    final lines = widget.text.replaceAll('\r\n', '\n').split('\n');
    final k = widget.fontSize / 17.5;
    final body = TextStyle(fontSize: widget.fontSize, height: 1.6);
    Widget para(String s, {TextStyle? style}) {
      final span = TextSpan(style: (style ?? body).copyWith(color: (style ?? body).color ?? ink), children: _inline(s, ink));
      return widget.selectable ? SelectableText.rich(span, contextMenuBuilder: copyAwareMenu) : Text.rich(span);
    }
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trimLeft();
      final indent = (line.length - t.length) ~/ 2;
      if (t.startsWith('```')) {
        final code = <String>[];
        for (i++; i < lines.length && !lines[i].trimLeft().startsWith('```'); i++) {
          code.add(lines[i]);
        }
        blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: CodeCard(text: code.join('\n'))));
      } else if (t.isEmpty) {
        blocks.add(SizedBox(height: 10 * k));
      } else if (RegExp(r'^#{1,6} ').hasMatch(t)) {
        final level = t.indexOf(' ');
        final size = [28.0, 22.0, 19.0, 17.5, 17.5, 17.5][level - 1] * k;
        blocks.add(Padding(
          padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 14 * k, bottom: 4),
          child: para(t.substring(level + 1),
              style: TextStyle(fontSize: size, height: 1.3, fontWeight: FontWeight.w800, letterSpacing: size > 20 ? -.4 : 0)),
        ));
      } else if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
        blocks.add(Divider(height: 28, color: ink.withValues(alpha: .15)));
      } else if (t.startsWith('> ')) {
        blocks.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: ink.withValues(alpha: .25), width: 3))),
          child: para(t.substring(2), style: body.copyWith(color: muted, fontStyle: FontStyle.italic)),
        ));
      } else if (_check.firstMatch(t) case final m?) {
        // A box to tick: ink when done (the text quieter and struck through), an outline
        // when still to do. The whole row takes the tap, a link inside it its own.
        final done = m.group(1) != ' ';
        final line = i;
        final box = widget.fontSize * 1.25;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: (widget.fontSize * 1.6 - box) / 2, right: 10 * k),
              child: Icon(done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  key: ValueKey('check-$line'), size: box, color: done ? ink : muted),
            ),
            Expanded(
              child: para(t.substring(m.end),
                  style: done ? body.copyWith(color: muted, decoration: TextDecoration.lineThrough, decorationColor: muted) : null),
            ),
          ],
        );
        final toggle = widget.onToggle;
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 2.0 + indent * 18),
          child: toggle == null
              ? Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: row)
              : Semantics(
                  checked: done,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => toggle(line),
                    child: Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: row),
                  ),
                ),
        ));
      } else if (_list.firstMatch(t) case final m?) {
        final mark = RegExp(r'^\d').hasMatch(m.group(1)!) ? m.group(1)! : '•';
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 18, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24 * k, child: Text(mark, style: body.copyWith(color: muted, fontWeight: FontWeight.w700))),
              Expanded(child: para(t.substring(m.end))),
            ],
          ),
        ));
      } else {
        blocks.add(para(line));
      }
    }
    return Column(key: const ValueKey('text-view'), crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }

  /// Underscores only count at word edges, so "file_name_here" and an address with "_"
  /// in it stay as typed.
  static final _inlineRe = RegExp(r'\*\*(.+?)\*\*|(?<!\w)__(.+?)__(?!\w)|\*(.+?)\*|(?<!\w)_(.+?)_(?!\w)|`(.+?)`');

  List<InlineSpan> _inline(String s, Color ink) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _inlineRe.allMatches(s)) {
      if (m.start > at) out.addAll(_links(s.substring(at, m.start), ink));
      if (m.group(1) != null || m.group(2) != null) {
        out.add(TextSpan(style: const TextStyle(fontWeight: FontWeight.w700), children: _links(m.group(1) ?? m.group(2)!, ink)));
      } else if (m.group(3) != null || m.group(4) != null) {
        out.add(TextSpan(style: const TextStyle(fontStyle: FontStyle.italic), children: _links(m.group(3) ?? m.group(4)!, ink)));
      } else {
        out.add(TextSpan(
          text: m.group(5),
          style: _mono.copyWith(fontSize: CsType.subhead, backgroundColor: ink.withValues(alpha: .08)),
        ));
      }
      at = m.end;
    }
    if (at < s.length) out.addAll(_links(s.substring(at), ink));
    return out;
  }

  /// [s] with its web addresses underlined in ink, each taking a tap when [onLink] is set.
  List<InlineSpan> _links(String s, Color ink) {
    final found = findLinks(s);
    if (found.isEmpty) return [TextSpan(text: s)];
    final out = <InlineSpan>[];
    var at = 0;
    final onLink = widget.onLink;
    for (final f in found) {
      if (f.start > at) out.add(TextSpan(text: s.substring(at, f.start)));
      TapGestureRecognizer? tap;
      if (onLink != null) {
        tap = TapGestureRecognizer()..onTap = () => onLink(f.url);
        _taps.add(tap);
      }
      out.add(TextSpan(
        text: s.substring(f.start, f.end),
        recognizer: tap,
        style: TextStyle(
          color: ink,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.underline,
          decorationColor: ink.withValues(alpha: .55),
          decorationThickness: 1.6,
        ),
      ));
      at = f.end;
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at)));
    return out;
  }
}
