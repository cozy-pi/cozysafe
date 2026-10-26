import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/drag_select.dart';
import '../widgets/item_menu.dart';
import '../widgets/selectable_row.dart';
import '../widgets/selection_bar.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart';
import 'item_info.dart';
import 'quick_look.dart';

/// Recently deleted (owner 2026-10-26, "cho tử tế"): items stay here, still encrypted, for
/// 30 days, then go for good. Laid out like the vault: photos and videos as a grid of
/// thumbnails, then notes, recordings and files as rows, each with the days it has left;
/// items deleted for good on another device carry a mark. A tap shows the item, a long
/// press opens its menu (Restore · Info · Delete for good, the same as the preview's bar),
/// or turns into a drag that selects. Select (at the bottom) picks several, and the
/// selection bar acts on the selection only: there is no "Restore all" or "Delete all"
/// (owner: too dangerous). Deleting for good always asks first. The vault reloads when it
/// closes.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

/// The kinds, in the order they show (the vault's sections).
const _sections = [VaultSection.library, VaultSection.note, VaultSection.audio, VaultSection.file];

VaultSection _sectionOf(rust.ItemInfo it) => switch (it.kind) {
      ItemKind.photo || ItemKind.video => VaultSection.library,
      ItemKind.note => VaultSection.note,
      ItemKind.audio => VaultSection.audio,
      _ => VaultSection.file,
    };

class _TrashScreenState extends State<TrashScreen> {
  List<rust.ItemInfo>? _items;
  /// Items another device deleted for good, held here (not synced, owner 2026-10-25).
  Set<String> _held = const {};
  final Map<String, Future<Uint8List>> _thumbnails = {};
  final Set<String> _picked = {};
  bool _selectMode = false;
  bool get _selecting => _selectMode || _picked.isNotEmpty;
  void _endSelect() {
    _selectMode = false;
    _picked.clear();
  }

  /// The items in the order they show, for a hold-and-drag selection.
  List<String> _order = const [];
  late final _drag = DragSelect(
    order: () => _order,
    selected: () => _picked,
    onBegin: () => setState(() => _selectMode = true),
    onChanged: (next) => setState(() => _picked
      ..clear()
      ..addAll(next)),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await rust.listTrash();
      final held = await rust.listHeld();
      final all = [...items, ...held]..sort((a, b) => (b.deletedMs?.toInt() ?? 0).compareTo(a.deletedMs?.toInt() ?? 0));
      if (mounted) {
        setState(() {
          _items = all;
          _held = {for (final h in held) h.id};
          _picked.removeWhere((id) => !all.any((i) => i.id == id));
        });
      }
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  List<rust.ItemInfo> get _chosen => (_items ?? const <rust.ItemInfo>[]).where((i) => _picked.contains(i.id)).toList();

  /// What was deleted, before deciding: the same preview as in the vault (the picture,
  /// the video, the note's first lines, the recording, the file), with Restore, Info and
  /// Delete for good, and how long it stays.
  Future<void> _preview(rust.ItemInfo it) async {
    final pick = await QuickLook.show(context, it,
        vaultId: '', trash: TrashLook(daysLeft: trashDaysLeft(it), held: _held.contains(it.id)));
    if (!mounted) return;
    if (pick == QuickLook.restoreRequest) await _restore([it]);
    // Asked in the preview already.
    if (pick == QuickLook.purgeRequest) await _deleteForGood([it], asked: true);
  }

  void _open(rust.ItemInfo it) => _selecting ? _toggle(it) : _preview(it);

  Future<void> _restore(List<rust.ItemInfo> items) async {
    for (final it in items) {
      try {
        _held.contains(it.id) ? await rust.restoreHeld(id: it.id) : await rust.restoreItem(id: it.id);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(_endSelect);
    await _load();
  }

  /// Deleting for good always asks first ([asked]: the preview did).
  Future<void> _deleteForGood(List<rust.ItemInfo> items, {bool asked = false}) async {
    if (items.isEmpty) return;
    if (!asked) {
      final ok = await confirmDeleteForGood(context,
          count: items.length,
          name: items.length == 1 ? shownName(AppLocalizations.of(context), items.first) : null,
          othersKeep: !items.every((i) => _held.contains(i.id)));
      if (!ok || !mounted) return;
    }
    for (final it in items) {
      try {
        _held.contains(it.id) ? await rust.purgeHeld(id: it.id) : await rust.deleteItem(id: it.id);
      } catch (_) {}
      _thumbnails.remove(it.id);
    }
    if (!mounted) return;
    setState(_endSelect);
    await _load();
  }

  /// A long press: the same actions, icons and order as the preview's bar (owner
  /// 2026-10-26). In Select mode it selects, as in the vault.
  Future<void> _menu(rust.ItemInfo it) async {
    if (_selecting) return _toggle(it);
    final l = AppLocalizations.of(context);
    await showItemMenu(context, title: shownName(l, it), entries: [
      MenuEntry(Icons.restore_rounded, l.restore, () => _restore([it]), key: const ValueKey('menu-restore')),
      MenuEntry(Icons.info_outline, l.info, () => showItemInfo(context, it, held: _held.contains(it.id)),
          key: const ValueKey('menu-info')),
      MenuEntry(Icons.delete_forever_outlined, l.deleteForGoodShort, () => _deleteForGood([it]),
          danger: true, key: const ValueKey('menu-purge')),
    ]);
  }

  void _toggle(rust.ItemInfo it) {
    HapticFeedback.selectionClick();
    setState(() => _picked.contains(it.id) ? _picked.remove(it.id) : _picked.add(it.id));
  }

  Future<Uint8List> _thumb(String id) => _thumbnails[id] ??= rust.itemThumbnail(id: id);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = _items;
    final bySection = {
      for (final s in _sections) s: [for (final it in items ?? const <rust.ItemInfo>[]) if (_sectionOf(it) == s) it],
    };
    _order = [for (final s in _sections) for (final it in bySection[s]!) it.id];
    final all = items != null && items.isNotEmpty && _picked.length == items.length;
    // Swipe back pops null and the vault reloads anyway. While selecting, Back ends the
    // selection first, as in the vault.
    return MenuPointer(
      child: PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(_endSelect);
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(!_selecting
                ? l.recentlyDeleted
                : _picked.isEmpty
                    ? l.selectItems
                    : l.selectedCount(_picked.length)),
          ),
          body: items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? const _Empty()
                  : DragSelectArea(
                      drag: _drag,
                      child: Scrollbar(
                        child: CustomScrollView(
                          key: const ValueKey('trash-list'),
                          slivers: [
                            SliverToBoxAdapter(child: _Lead(held: _held.isNotEmpty)),
                            for (final s in _sections)
                              if (bySection[s]!.isNotEmpty) ...[
                                SliverToBoxAdapter(child: _SectionTitle(sectionLabel(l, s), bySection[s]!.length)),
                                if (s == VaultSection.library) _grid(bySection[s]!) else _rows(bySection[s]!),
                              ],
                            const SliverToBoxAdapter(child: SizedBox(height: 24)),
                          ],
                        ),
                      ),
                    ),
          // Every action at the bottom (owner 2026-10-25): Select; while selecting, the
          // vault's selection bar with Restore and Delete for good (red), acting on the
          // selection only.
          bottomNavigationBar: (items == null || items.isEmpty)
              ? null
              : _selecting
                  ? SelectionBar(
                      enabled: _picked.isNotEmpty,
                      onDone: () => setState(_endSelect),
                      allSelected: all,
                      onSelectAll: () => setState(() {
                        all ? _picked.clear() : _picked.addAll(items.map((i) => i.id));
                      }),
                      actions: [
                        SelectionAction(Icons.restore_rounded, l.restore, () => _restore(_chosen),
                            key: const ValueKey('trash-restore')),
                        SelectionAction(Icons.delete_forever_outlined, l.deleteForGoodShort, () => _deleteForGood(_chosen),
                            color: recordRed(context), key: const ValueKey('trash-purge')),
                      ],
                    )
                  : BottomBar(
                      children: [
                        BarText(
                            key: const ValueKey('trash-select'),
                            label: l.select,
                            onTap: () => setState(() => _selectMode = true)),
                      ],
                    ),
        ),
      ),
    );
  }

  /// Photos and videos: squares edge to edge, 2 px apart, as in the vault's Library.
  Widget _grid(List<rust.ItemInfo> media) {
    final l = AppLocalizations.of(context);
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          final it = media[i];
          return DragSelectItem(
            key: ValueKey('trash-${it.id}'),
            id: it.id,
            drag: _drag,
            onMenu: () => _menu(it),
            child: _Tile(
              item: it,
              thumbnail: _thumb(it.id),
              days: l.daysLeft(trashDaysLeft(it)),
              held: _held.contains(it.id),
              selected: _picked.contains(it.id),
              selecting: _selecting,
              onTap: () => _open(it),
            ),
          );
        },
        childCount: media.length,
      ),
    );
  }

  /// Notes, recordings or files: one card of rows, as in the vault.
  Widget _rows(List<rust.ItemInfo> list) {
    final c = CsColors.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, it) in list.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 70, color: c.border.withValues(alpha: .6)),
                DragSelectItem(
                  key: ValueKey('trash-${it.id}'),
                  id: it.id,
                  drag: _drag,
                  onMenu: () => _menu(it),
                  child: _Row(
                    item: it,
                    held: _held.contains(it.id),
                    selected: _picked.contains(it.id),
                    selecting: _selecting,
                    onTap: () => _open(it),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The line on top: what happens here, and how to pick several.
class _Lead extends StatelessWidget {
  const _Lead({required this.held});
  final bool held;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.auto_delete_outlined, size: 20, color: c.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              key: const ValueKey('trash-lead'),
              '${l.trashNote} ${l.trashHint}${held ? ' ${l.trashHeldNote}' : ''}',
              style: TextStyle(color: c.muted, fontSize: 14.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, this.count);
  final String text;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: text),
            TextSpan(text: '  $count', style: TextStyle(color: CsColors.of(context).muted, fontWeight: FontWeight.w600)),
          ]),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      );
}

/// Nothing deleted: say what this place is for.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            key: const ValueKey('trash-empty'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, size: 48, color: c.muted),
              const SizedBox(height: 14),
              Text(l.trashEmptyTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(l.trashEmptyBody, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A deleted photo or video: its thumbnail, the days it has left, a video's play mark and
/// length, a mark when it was deleted on another device, the selection circle.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.thumbnail,
    required this.days,
    required this.held,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });
  final rust.ItemInfo item;
  final Future<Uint8List> thumbnail;
  final String days;
  final bool held;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  static const _shadow = [Shadow(color: Color(0x88000000), blurRadius: 6)];

  static String _length(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final video = item.kind == ItemKind.video;
    final duration = item.durationMs;
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: c.soft,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: thumbnail,
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null || bytes.isEmpty) {
                  // No preview stored (an old video): its kind, as in the vault.
                  return video
                      ? const ColoredBox(color: Color(0xFF2A3133), child: Icon(Icons.movie_outlined, color: Colors.white54))
                      : const SizedBox.expand();
                }
                return privateThumb(Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true));
              },
            ),
            // A light shade at the foot so the white marks read on any picture.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 34,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0x55000000)],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(left: 5, bottom: 4, child: _DaysLeft(days)),
            if (video)
              Positioned(
                right: 5,
                bottom: 5,
                child: Row(
                  key: const ValueKey('trash-video-mark'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 15, shadows: _shadow),
                    if (duration != null)
                      Text(_length(duration.toInt()),
                          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600, shadows: _shadow)),
                  ],
                ),
              ),
            // Deleted on another device: a mark, so it is told apart.
            if (held)
              const Positioned(
                left: 5,
                top: 5,
                child: Icon(Icons.devices_rounded, key: ValueKey('trash-held'), size: 18, color: Colors.white, shadows: _shadow),
              ),
            if (selected) const ColoredBox(color: Color(0x40FFFFFF)),
            if (selecting)
              Positioned(
                top: 5,
                right: 5,
                child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 22, color: Colors.white, shadows: _shadow),
              ),
          ],
        ),
      ),
    );
  }
}

/// A deleted note, recording or file: its kind, name, and the days it has left (and that
/// another device deleted it, when it did).
class _Row extends StatelessWidget {
  const _Row({required this.item, required this.held, required this.selected, required this.selecting, required this.onTap});
  final rust.ItemInfo item;
  final bool held;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final dot = item.name.lastIndexOf('.');
    final ext = item.kind != ItemKind.file || dot < 0 ? '' : item.name.substring(dot + 1).toUpperCase();
    final icon = switch (item.kind) {
      ItemKind.note => Icons.edit_note_rounded,
      ItemKind.audio => Icons.mic_none_rounded,
      _ => fileIcon(item),
    };
    final days = l.daysLeft(trashDaysLeft(item));
    return SelectableRow(
      selected: selected,
      selecting: selecting,
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(8)),
            child: ext.isEmpty || ext.length > 4
                ? Icon(icon, color: primary)
                : Text(ext, style: TextStyle(color: primary, fontSize: 11, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shownName(l, item), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (held) ...[
                      Icon(Icons.devices_rounded, key: const ValueKey('trash-held'), size: 14, color: c.muted),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        held ? '${l.trashHeldLabel} · $days' : '${fileSize(item.sizeBytes)} · $days',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DaysLeft extends StatelessWidget {
  const _DaysLeft(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      );
}
