import 'package:flutter/material.dart';

import '../lock_guard.dart';
import '../theme.dart';

/// Reading and writing text (docs/ui.md, design language): book-like margins and line
/// height; a note's first line is its title, shown large and bold as it is typed;
/// Markdown, JSON and code read well without any extra library.

/// A note's text field controller: the first line (the title) is drawn large and bold.
class NoteTextController extends TextEditingController {
  NoteTextController({super.text});

  static const body = TextStyle(fontSize: 17.5, height: 1.6);
  static const title = TextStyle(fontSize: 26, height: 1.3, fontWeight: FontWeight.w800, letterSpacing: -.4);

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = (style ?? const TextStyle()).merge(body);
    final nl = text.indexOf('\n');
    final head = nl < 0 ? text : text.substring(0, nl);
    final rest = nl < 0 ? '' : text.substring(nl);
    // While the keyboard composes a word (Vietnamese Telex and the like), keep its
    // underline so the person sees what is being composed.
    final c = value.composing;
    if (withComposing && c.isValid && !c.isCollapsed) {
      // Cut at the title's end and at the composing range; each piece takes the title or
      // body style, and the composing piece keeps its underline.
      final split = nl < 0 ? text.length : nl;
      final cuts = {0, split, c.start, c.end, text.length}.where((x) => x >= 0 && x <= text.length).toList()..sort();
      return TextSpan(style: base, children: [
        for (var k = 0; k + 1 < cuts.length; k++)
          if (cuts[k] < cuts[k + 1])
            TextSpan(
              text: text.substring(cuts[k], cuts[k + 1]),
              style: (cuts[k] < split ? base.merge(title) : base).merge(cuts[k] >= c.start && cuts[k + 1] <= c.end
                  ? const TextStyle(decoration: TextDecoration.underline)
                  : null),
            ),
      ]);
    }
    return TextSpan(style: base, children: [
      TextSpan(text: head, style: base.merge(title)),
      TextSpan(text: rest),
    ]);
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

const _mono = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Roboto Mono'], fontSize: 13.5, height: 1.5);

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
        style: const TextStyle(fontSize: 17.5, height: 1.6),
      );
}

/// The common part of Markdown, drawn by the app itself (no library to review):
/// headings, lists, quotes, code blocks, rules, **bold**, *italic* and `code`.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final muted = CsColors.of(context).muted;
    final blocks = <Widget>[];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    const body = TextStyle(fontSize: 17.5, height: 1.6);
    Widget para(String s, {TextStyle style = body}) =>
        SelectableText.rich(TextSpan(style: style.copyWith(color: style.color ?? ink), children: _inline(s, ink)),
            contextMenuBuilder: copyAwareMenu);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trimLeft();
      if (t.startsWith('```')) {
        final code = <String>[];
        for (i++; i < lines.length && !lines[i].trimLeft().startsWith('```'); i++) {
          code.add(lines[i]);
        }
        blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: CodeCard(text: code.join('\n'))));
      } else if (t.isEmpty) {
        blocks.add(const SizedBox(height: 10));
      } else if (RegExp(r'^#{1,6} ').hasMatch(t)) {
        final level = t.indexOf(' ');
        final size = [28.0, 22.0, 19.0, 17.5, 17.5, 17.5][level - 1];
        blocks.add(Padding(
          padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 14, bottom: 4),
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
      } else if (RegExp(r'^([-*+]|\d+[.)]) ').hasMatch(t)) {
        final m = RegExp(r'^([-*+]|\d+[.)]) ').firstMatch(t)!;
        final mark = RegExp(r'^\d').hasMatch(m.group(1)!) ? m.group(1)! : '•';
        final indent = (line.length - t.length) ~/ 2;
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 18, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text(mark, style: body.copyWith(color: muted, fontWeight: FontWeight.w700))),
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

  static final _inlineRe = RegExp(r'\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_|`(.+?)`');

  static List<InlineSpan> _inline(String s, Color ink) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _inlineRe.allMatches(s)) {
      if (m.start > at) out.add(TextSpan(text: s.substring(at, m.start)));
      if (m.group(1) != null || m.group(2) != null) {
        out.add(TextSpan(text: m.group(1) ?? m.group(2), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(3) != null || m.group(4) != null) {
        out.add(TextSpan(text: m.group(3) ?? m.group(4), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else {
        out.add(TextSpan(
          text: m.group(5),
          style: _mono.copyWith(fontSize: 15, backgroundColor: ink.withValues(alpha: .08)),
        ));
      }
      at = m.end;
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at)));
    return out;
  }
}
