import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/private_thumb.dart';
import 'file_view.dart' show fileIcon, fileSize;
import 'item_info.dart' show itemKindLabel;

/// The column a computer's list is ordered by, and which way.
enum DeskColumn { name, kind, size, date }

/// A computer's list view, as Finder's (owner 2026-10-28): small rows across the whole
/// column, Name · Kind · Size · Date, a header to order by, stripes. One click picks a
/// row, a double click (or Enter) opens it, a right click shows its menu.
class DeskTable extends StatefulWidget {
  const DeskTable({
    super.key,
    required this.items,
    required this.thumbnail,
    required this.onOpen,
    required this.onMenu,
    required this.sortColumn,
    required this.ascending,
    required this.onSort,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    this.dateIsAdded = false,
  });

  final List<rust.ItemInfo> items;
  /// A photo or video's thumbnail; null for other kinds.
  final Future<Uint8List>? Function(rust.ItemInfo) thumbnail;
  final ValueChanged<rust.ItemInfo> onOpen;
  final ValueChanged<rust.ItemInfo> onMenu;
  final DeskColumn sortColumn;
  final bool ascending;
  final ValueChanged<DeskColumn> onSort;
  /// Select mode (the vault's): a click ticks the row instead.
  final Set<String> selected;
  final bool selecting;
  final ValueChanged<String> onToggle;
  /// The date column is when it was added (photos), not when it last changed.
  final bool dateIsAdded;

  static const rowHeight = 30.0;

  /// A picked row, white text on it, in light and dark alike (Finder's accent).
  static const pickColor = Color(0xFF0A64D2);

  @override
  State<DeskTable> createState() => _DeskTableState();
}

class _DeskTableState extends State<DeskTable> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final ml = MaterialLocalizations.of(context);
    String when(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${ml.formatShortDate(d)}, ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true)}';
    }

    const small = TextStyle(fontSize: 13);
    Widget cells(List<Widget> four) => Row(children: [
          Expanded(flex: 6, child: four[0]),
          Expanded(flex: 2, child: four[1]),
          SizedBox(width: 90, child: four[2]),
          SizedBox(width: 170, child: four[3]),
        ]);

    Widget head(DeskColumn col, String label, {bool end = false}) {
      final on = widget.sortColumn == col;
      return InkWell(
        key: ValueKey('desk-head-${col.name}'),
        onTap: () => widget.onSort(col),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: end ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: on ? ink : c.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
              ),
              if (on) Icon(widget.ascending ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: ink),
            ],
          ),
        ),
      );
    }

    final dateLabel = widget.dateIsAdded ? l.deskAdded : l.deskModified;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 28,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: cells([
            head(DeskColumn.name, l.sortName),
            head(DeskColumn.kind, l.deskKind),
            head(DeskColumn.size, l.deskSize, end: true),
            head(DeskColumn.date, dateLabel),
          ]),
        ),
        Expanded(
          child: Scrollbar(
            child: ListView.builder(
              key: const ValueKey('desk-table'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              itemExtent: DeskTable.rowHeight,
              itemCount: widget.items.length,
              itemBuilder: (context, i) {
                final it = widget.items[i];
                final ticked = widget.selected.contains(it.id);
                final picked = widget.selecting ? ticked : _picked == it.id;
                final stripe = i.isOdd ? ink.withValues(alpha: .035) : Colors.transparent;
                final fg = picked ? Colors.white : ink;
                final muted = picked ? Colors.white.withValues(alpha: .85) : c.muted;
                final thumb = widget.thumbnail(it);
                final ms = (widget.dateIsAdded ? it.createdMs : it.modifiedMs).toInt();
                return Listener(
                  onPointerDown: (e) {
                    if (e.buttons == kSecondaryMouseButton) {
                      setState(() => _picked = it.id);
                      widget.onMenu(it);
                    }
                  },
                  child: GestureDetector(
                    key: ValueKey('desk-row-${it.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.selecting ? widget.onToggle(it.id) : setState(() => _picked = it.id),
                    onDoubleTap: widget.selecting ? null : () => widget.onOpen(it),
                    child: Container(
                      decoration: BoxDecoration(
                        color: picked ? DeskTable.pickColor : stripe,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: cells([
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(children: [
                            SizedBox.square(
                              dimension: 20,
                              child: thumb != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: FutureBuilder<Uint8List>(
                                        future: thumb,
                                        builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                                            ? PrivateThumb(snap.data!)
                                            : ColoredBox(color: c.soft),
                                      ),
                                    )
                                  : Icon(it.kind == ItemKind.note ? Icons.book_outlined : fileIcon(it),
                                      size: 18, color: picked ? Colors.white : Theme.of(context).colorScheme.primary),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(it.name.isEmpty ? '—' : it.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: small.copyWith(color: fg)),
                            ),
                            if (it.isFavorite) Icon(Icons.star_rounded, size: 14, color: picked ? Colors.white : const Color(0xFFFFB300)),
                          ]),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(itemKindLabel(l, it), maxLines: 1, overflow: TextOverflow.ellipsis, style: small.copyWith(color: muted)),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(fileSize(it.sizeBytes),
                              textAlign: TextAlign.end,
                              maxLines: 1,
                              style: small.copyWith(color: muted, fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(when(ms), maxLines: 1, overflow: TextOverflow.ellipsis, style: small.copyWith(color: muted)),
                        ),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
