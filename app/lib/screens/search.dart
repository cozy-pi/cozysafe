import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/private_thumb.dart';
import '../widgets/item_menu.dart';
import '../widgets/vault_bar.dart';
import 'overview.dart';
import '../item_kind.dart';
import '../file_kinds.dart';

/// Search the open vault by name, and inside notes. Note text is decrypted into memory
/// for this screen only and dropped when it closes. Typing "hoa" finds "Hoá đơn":
/// accents and case are ignored. Pops with the item to open.
/// A long press on a result: the vault shows that item's (or group's) menu.
class SearchMenu {
  const SearchMenu(this.item);
  final rust.ItemInfo item;
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.items, required this.thumbnail});

  /// Everything in the vault, groups included (a group matches by its name).
  final List<rust.ItemInfo> items;
  final Future<Uint8List> Function(String id) thumbnail;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  /// Note id → plain text, folded for matching. Filled once, in the background.
  final Map<String, String> _noteText = {};
  final Map<String, String> _noteRaw = {};
  /// Narrowed to one section (a chip, or a tile on the empty screen).
  VaultSection? _kind;

  List<rust.ItemInfo> get _things => widget.items.where((i) => i.kind != ItemKind.tag).toList();
  List<rust.ItemInfo> get _groups => widget.items.where((i) => i.kind == ItemKind.tag).toList();

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    for (final it in widget.items.where((i) => i.kind == ItemKind.note)) {
      try {
        final text = utf8.decode(await rust.itemContent(id: it.id), allowMalformed: true);
        _noteRaw[it.id] = text;
        _noteText[it.id] = fold(text);
      } catch (_) {}
      if (!mounted) return;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _query.dispose();
    _noteText.clear();
    _noteRaw.clear();
    super.dispose();
  }

  /// A few words around the first match in a note.
  String? _snippet(String id, String q) {
    final folded = _noteText[id];
    final raw = _noteRaw[id];
    if (folded == null || raw == null) return null;
    final at = folded.indexOf(q);
    if (at < 0 || folded.length != raw.length) return null;
    final start = (at - 30).clamp(0, raw.length);
    final end = (at + q.length + 60).clamp(0, raw.length);
    return '${start > 0 ? '…' : ''}${raw.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim()}${end < raw.length ? '…' : ''}';
  }

  String _shownName(AppLocalizations l, rust.ItemInfo it) => it.name.isEmpty
      ? l.untitledNote
      : it.kind == ItemKind.audio
          ? it.name.replaceAll(RegExp(r'\.m4a$'), '')
          : it.name;

  int _count(rust.ItemInfo tag) => _things.where((i) => i.tagIds.contains(tag.id)).length;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final q = fold(_query.text.trim());
    final browsing = q.isEmpty && _kind == null;
    final hits = q.isEmpty
        ? _things
        : _things.where((i) => fold(i.name).contains(q) || (_noteText[i.id]?.contains(q) ?? false)).toList();
    final groupHits = q.isEmpty ? const <rust.ItemInfo>[] : _groups.where((g) => fold(g.name).contains(q)).toList();
    final counts = <VaultSection, int>{
      for (final s in VaultSection.values) s: hits.where((i) => sectionOf(i) == s).length,
    }..removeWhere((_, n) => n == 0);
    final shown = _kind == null ? hits : hits.where((i) => sectionOf(i) == _kind).toList();
    return MenuPointer(child: Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(Ui.circle + 16),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                GlassButton(icon: Icons.arrow_back_ios_new, tooltip: l.back, onTap: () => Navigator.of(context).maybePop()),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(l.search,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, letterSpacing: -.2)),
                ),
              ],
            ),
          ),
        ),
      ),
      // The field and the section chips at the bottom, riding above the keyboard, the
      // results above them (owner 2026-10-25: every control within the thumb's reach).
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: browsing
                ? _browse(context, l)
                : shown.isEmpty && groupHits.isEmpty
                    ? _nothing(context, l)
                    : _results(context, l, q, shown, _kind == null ? groupHits : const []),
          ),
          if (!browsing && (counts.isNotEmpty || _kind != null)) _chips(context, l, hits.length, counts),
          Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, Ui.edge + MediaQuery.paddingOf(context).bottom),
            child: _field(context, l),
          ),
        ],
      ),
    ));
  }

  /// The vault bar's height and shape. Solid, not glass: nothing scrolls under it, and
  /// the blur only smeared the chips above into it.
  Widget _field(BuildContext context, AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final none = OutlineInputBorder(borderRadius: BorderRadius.circular(Ui.bar / 2), borderSide: BorderSide.none);
    return SizedBox(
      height: Ui.bar,
      child: TextField(
        key: const ValueKey('search-field'),
        controller: _query,
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: CsType.body),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: _kind == null ? l.searchHint : sectionLabel(l, _kind!),
          filled: true,
          fillColor: ink.withValues(alpha: .07),
          contentPadding: EdgeInsets.zero,
          prefixIcon: Icon(Icons.search, color: ink.withValues(alpha: .6)),
          suffixIcon: _query.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l.clear,
                  onPressed: () => setState(_query.clear),
                  icon: Icon(Icons.cancel_rounded, color: ink.withValues(alpha: .45)),
                ),
          border: none,
          enabledBorder: none,
          focusedBorder: none,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  /// Nothing typed: the vault's overview (the same as the home tab), tap to narrow.
  Widget _browse(BuildContext context, AppLocalizations l) => VaultOverview(
        items: widget.items,
        thumbnail: widget.thumbnail,
        onKind: (s) => setState(() => _kind = s),
        onGroup: (g) => Navigator.of(context).pop(g),
        onOpen: (it) => Navigator.of(context).pop(it),
        onMenu: (it) => Navigator.of(context).pop(SearchMenu(it)),
        onGroupMenu: (g) => Navigator.of(context).pop(SearchMenu(g)),
      );

  Widget _chips(BuildContext context, AppLocalizations l, int all, Map<VaultSection, int> counts) {
    Widget chip(String label, int? n, bool on, VoidCallback tap, {Key? key}) {
      final cs = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          key: key,
          color: on ? cs.onSurface : cs.onSurface.withValues(alpha: .07),
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: tap,
            child: Container(
              height: Ui.chip,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              child: Text(n == null ? label : '$label  $n',
                  style: TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600, color: on ? cs.surface : cs.onSurface)),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: Ui.chip + 12,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 2, 6, 8),
        children: [
          chip(l.searchAll, _query.text.trim().isEmpty ? null : all, _kind == null, () => setState(() => _kind = null)),
          for (final e in counts.entries)
            chip(sectionLabel(l, e.key), e.value, _kind == e.key, () => setState(() => _kind = _kind == e.key ? null : e.key),
                key: ValueKey('search-chip-${e.key.name}')),
        ],
      ),
    );
  }

  Widget _nothing(BuildContext context, AppLocalizations l) {
    final c = CsColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 52, color: c.muted),
            const SizedBox(height: 14),
            Text(l.searchNothingFor(_query.text.trim()),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(l.searchNothingHint, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.45)),
          ],
        ),
      ),
    );
  }

  /// Matching groups as chips, photos and videos as a grid of thumbnails, the rest as
  /// rows with the matched words in bold.
  Widget _results(BuildContext context, AppLocalizations l, String q, List<rust.ItemInfo> shown, List<rust.ItemInfo> groups) {
    final media = shown.where((i) => sectionOf(i) == VaultSection.library).toList();
    final rest = shown.where((i) => sectionOf(i) != VaultSection.library).toList();
    final c = CsColors.of(context);
    Widget title(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
          child: Text(t, style: TextStyle(fontSize: CsType.footnote, fontWeight: FontWeight.w700, color: c.muted)),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: [
        if (groups.isNotEmpty) ...[
          title(l.searchGroups),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final g in groups) GroupChip(
                  name: g.name,
                  count: _count(g),
                  query: q,
                  onTap: () => Navigator.of(context).pop(g),
                  onLongPress: () => Navigator.of(context).pop(SearchMenu(g)))],
          ),
          const SizedBox(height: 6),
        ],
        if (media.isNotEmpty) ...[
          title('${sectionLabel(l, VaultSection.library)}  ${media.length}'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (final it in media)
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(it),
                  onLongPress: () => Navigator.of(context).pop(SearchMenu(it)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: FutureBuilder<Uint8List>(
                      future: widget.thumbnail(it.id),
                      builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                          ? PrivateThumb(snap.data!)
                          : ColoredBox(color: c.soft),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        for (final s in [VaultSection.note, VaultSection.audio, VaultSection.file])
          if (rest.any((i) => sectionOf(i) == s)) ...[
            title('${sectionLabel(l, s)}  ${rest.where((i) => sectionOf(i) == s).length}'),
            _card(context, [for (final it in rest.where((i) => sectionOf(i) == s)) _row(context, l, it, q)]),
            const SizedBox(height: 6),
          ],
      ],
    );
  }

  Widget _card(BuildContext context, List<Widget> rows) {
    final c = CsColors.of(context);
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (final (i, r) in rows.indexed) ...[
          if (i > 0) Divider(height: 1, indent: 70, color: c.border.withValues(alpha: .6)),
          r,
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, AppLocalizations l, rust.ItemInfo it, String q) {
    final c = CsColors.of(context);
    final s = sectionOf(it) ?? VaultSection.file;
    final color = searchKindColor(s);
    final snippet = q.isEmpty ? null : _snippet(it.id, q);
    final date = MaterialLocalizations.of(context).formatShortDate(dateOf(it.createdMs));
    final media = s == VaultSection.library;
    // The words around the match only when note text may show (Settings → Display);
    // otherwise just that it matched inside.
    final under = snippet == null ? null : (notePreviews() ? snippet : l.foundInText);
    return InkWell(
      onTap: () => Navigator.of(context).pop(it),
      onLongPress: () => Navigator.of(context).pop(SearchMenu(it)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 46,
              child: media
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: FutureBuilder<Uint8List>(
                        future: widget.thumbnail(it.id),
                        builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                            ? PrivateThumb(snap.data!)
                            : ColoredBox(color: c.soft),
                      ),
                    )
                  : s == VaultSection.file
                      ? FileKindBadge(name: it.name, mime: it.mime, width: 46, height: 46)
                      : DecoratedBox(
                          decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
                          child: Icon(searchKindIcon(s), color: color),
                        ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Plain weight while searching so the matched words stand out in bold.
                  MarkedText(_shownName(l, it), q,
                      maxLines: 1, style: TextStyle(fontSize: CsType.callout, fontWeight: q.isEmpty ? FontWeight.w600 : FontWeight.w400)),
                  const SizedBox(height: 3),
                  if (under != null && notePreviews())
                    MarkedText(under, q, maxLines: 2, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.3))
                  else
                    Text(under ?? date, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text with every match of [q] (already folded) in bold, in the ink colour.
class MarkedText extends StatelessWidget {
  const MarkedText(this.text, this.q, {super.key, required this.style, this.maxLines = 1});
  final String text;
  final String q;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final folded = fold(text);
    final spans = <TextSpan>[];
    var at = 0;
    if (q.isNotEmpty && folded.length == text.length) {
      var i = folded.indexOf(q);
      while (i >= 0) {
        if (i > at) spans.add(TextSpan(text: text.substring(at, i)));
        spans.add(TextSpan(
          text: text.substring(i, i + q.length),
          style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
        ));
        at = i + q.length;
        i = folded.indexOf(q, at);
      }
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(children: spans), maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
  }
}

/// Lower case without Vietnamese (and other Latin) accents, keeping string length, so
/// "Hoá Đơn" and "hoa don" match and positions line up with the original.
String fold(String s) {
  const from = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ'
      'ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
  const to = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'
      'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i < 0 ? ch : to[i]);
  }
  return b.toString();
}
