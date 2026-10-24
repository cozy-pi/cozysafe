import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/selectable_row.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart';
import 'search.dart' show MarkedText;

/// The colour of each section, the same as the storage bar in Settings.
Color searchKindColor(VaultSection s) => switch (s) {
      VaultSection.home => const Color(0xFF8E8E93),
      VaultSection.note => const Color(0xFFFFB300),
      VaultSection.library => const Color(0xFF0A84FF),
      VaultSection.audio => const Color(0xFFFF9F0A),
      VaultSection.file => const Color(0xFF30D158),
    };

IconData searchKindIcon(VaultSection s) => switch (s) {
      VaultSection.home => Icons.home_outlined,
      VaultSection.note => Icons.edit_note_rounded,
      VaultSection.library => Icons.photo_library_outlined,
      VaultSection.audio => Icons.mic_none_rounded,
      VaultSection.file => Icons.folder_outlined,
    };

VaultSection? sectionOf(rust.ItemInfo i) => switch (i.kind) {
      ItemKind.note => VaultSection.note,
      ItemKind.photo || ItemKind.video => VaultSection.library,
      ItemKind.audio => VaultSection.audio,
      ItemKind.file => VaultSection.file,
      _ => null,
    };


/// Everything in a vault at a glance (the home tab, and search before anything is
/// typed): the sections as tiles with their counts, the groups, and what was added
/// last. [header] sits on top (the home tab's search field and storage line).
class VaultOverview extends StatelessWidget {
  const VaultOverview({
    super.key,
    required this.items,
    required this.thumbnail,
    required this.onKind,
    required this.onGroup,
    required this.onOpen,
    this.onMenu,
    this.onGroupMenu,
    this.header,
    this.bottomPad = 24,
    this.recentCount = 5,
  });

  /// Everything in the vault, groups included.
  final List<rust.ItemInfo> items;
  final Future<Uint8List> Function(String id) thumbnail;
  final ValueChanged<VaultSection> onKind;
  final ValueChanged<rust.ItemInfo> onGroup;
  final ValueChanged<rust.ItemInfo> onOpen;
  /// A long press: the item's menu, or the group's (owner 2026-10-22).
  final ValueChanged<rust.ItemInfo>? onMenu;
  final ValueChanged<rust.ItemInfo>? onGroupMenu;
  final Widget? header;
  final double bottomPad;
  final int recentCount;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final things = items.where((i) => i.kind != ItemKind.tag).toList();
    int count(rust.ItemInfo tag) => things.where((i) => i.tagIds.contains(tag.id)).length;
    final sections = [
      for (final s in VaultSection.values)
        if (things.any((i) => sectionOf(i) == s)) s,
    ];
    final recent = [...things]..sort((a, b) => b.createdMs.compareTo(a.createdMs));
    final groups = items.where((g) => g.kind == ItemKind.tag && count(g) > 0).toList();
    final favorites = recent.where((i) => i.isFavorite).toList();
    // A card of rows (favourites, what was added last).
    Widget rows(List<rust.ItemInfo> list) => Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final (i, it) in list.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 70, color: c.border.withValues(alpha: .6)),
              OverviewRow(
                  item: it,
                  thumbnail: thumbnail,
                  onTap: () => onOpen(it),
                  onLongPress: onMenu == null ? null : () => onMenu!(it)),
            ],
          ]),
        );
    Widget title(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(6, 18, 6, 10),
          child: Text(t, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.muted)),
        );
    return ListView(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomPad),
      children: [
        ?header,
        if (sections.isNotEmpty) ...[
          title(l.searchKinds),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.3,
            children: [
              for (final s in sections)
                KindTile(
                  key: ValueKey('search-kind-${s.name}'),
                  section: s,
                  label: sectionLabel(l, s),
                  count: things.where((i) => sectionOf(i) == s).length,
                  onTap: () => onKind(s),
                ),
            ],
          ),
        ],
        // What the person marked: always on the home page, all of it.
        if (favorites.isNotEmpty) ...[
          title(l.favorites),
          KeyedSubtree(key: const ValueKey('home-favorites'), child: rows(favorites)),
        ],
        if (groups.isNotEmpty) ...[
          title(l.searchGroups),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final g in groups) GroupChip(
                  name: g.name,
                  count: count(g),
                  onTap: () => onGroup(g),
                  onLongPress: onGroupMenu == null ? null : () => onGroupMenu!(g))],
          ),
        ],
        if (recent.isNotEmpty) ...[
          title(l.searchRecent),
          rows(recent.take(recentCount).toList()),
        ],
      ],
    );
  }
}

/// One item: its kind's tile (or the photo), its name and date.
class OverviewRow extends StatelessWidget {
  const OverviewRow({super.key, required this.item, required this.thumbnail, required this.onTap, this.onLongPress});
  final rust.ItemInfo item;
  final Future<Uint8List> Function(String id) thumbnail;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final s = sectionOf(item) ?? VaultSection.file;
    final color = searchKindColor(s);
    final name = item.name.isEmpty
        ? l.untitledNote
        : item.kind == ItemKind.audio
            ? item.name.replaceAll(RegExp(r'\.m4a$'), '')
            : item.name;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 46,
              child: s == VaultSection.library
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: FutureBuilder<Uint8List>(
                        future: thumbnail(item.id),
                        builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                            ? privateThumb(Image.memory(snap.data!, fit: BoxFit.cover))
                            : ColoredBox(color: c.soft),
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
                      child: Icon(s == VaultSection.file ? fileIcon(item) : searchKindIcon(s), color: color),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                      ),
                      if (item.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(MaterialLocalizations.of(context).formatShortDate(dateOf(item.createdMs)),
                      style: TextStyle(color: c.muted, fontSize: 13.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section on the empty search screen: its colour, symbol, name and how many.
class KindTile extends StatelessWidget {
  const KindTile({super.key, required this.section, required this.label, required this.count, required this.onTap});
  final VaultSection section;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = searchKindColor(section);
    final c = CsColors.of(context);
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(Ui.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
                child: Icon(searchKindIcon(section), color: color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                    Text('$count', style: TextStyle(color: c.muted, fontSize: 13.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group: tap opens it in the vault, a long press shows its menu.
class GroupChip extends StatelessWidget {
  const GroupChip({super.key, required this.name, required this.count, required this.onTap, this.onLongPress, this.query = ''});
  final String name;
  final int count;
  final String query;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Material(
      color: Theme.of(context).cardColor,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: Ui.chip,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sell_outlined, size: 18, color: c.muted),
              const SizedBox(width: 8),
              MarkedText(name, query, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('$count', style: TextStyle(color: c.muted, fontSize: 13.5)),
            ],
          ),
        ),
      ),
    );
  }
}

