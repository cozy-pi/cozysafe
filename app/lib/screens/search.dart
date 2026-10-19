import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart';

/// Search the open vault by name, and inside notes. Note text is decrypted into memory
/// for this screen only and dropped when it closes. Typing "hoa" finds "Hoá đơn":
/// accents and case are ignored. Pops with the item to open.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.items, required this.thumb});

  final List<rust.ItemInfo> items;
  final Future<Uint8List> Function(String id) thumb;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  /// Note id → plain text, folded for matching. Filled once, in the background.
  final Map<String, String> _noteText = {};
  final Map<String, String> _noteRaw = {};

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    for (final it in widget.items.where((i) => i.kind == 'note')) {
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final q = fold(_query.text.trim());
    final results = q.isEmpty
        ? const <rust.ItemInfo>[]
        : widget.items
            .where((i) => fold(i.name).contains(q) || (_noteText[i.id]?.contains(q) ?? false))
            .toList();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l.searchHint,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              tooltip: l.clear,
              onPressed: () => setState(_query.clear),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: q.isEmpty
          ? const SizedBox.shrink()
          : results.isEmpty
              ? Center(child: Text(l.searchNoResults, style: TextStyle(color: c.muted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  children: [
                    Material(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(14),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (final (i, it) in results.indexed) ...[
                            if (i > 0) Divider(height: 1, indent: 70, color: c.border.withValues(alpha: .6)),
                            ListTile(
                              onTap: () => Navigator.of(context).pop(it),
                              leading: SizedBox.square(
                                dimension: 44,
                                child: it.kind == 'photo' || it.kind == 'video'
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: FutureBuilder<Uint8List>(
                                          future: widget.thumb(it.id),
                                          builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                                              ? Image.memory(snap.data!, fit: BoxFit.cover)
                                              : ColoredBox(color: c.soft),
                                        ),
                                      )
                                    : DecoratedBox(
                                        decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(10)),
                                        child: Icon(fileIcon(it), color: Theme.of(context).colorScheme.primary),
                                      ),
                              ),
                              title: Text(it.name.isEmpty ? l.untitledNote : it.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                _snippet(it.id, q) ??
                                    MaterialLocalizations.of(context)
                                        .formatShortDate(DateTime.fromMillisecondsSinceEpoch(it.createdMs)),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
    );
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
