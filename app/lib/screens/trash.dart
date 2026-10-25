import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart';
import 'quick_look.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/item_menu.dart';
import '../widgets/vault_bar.dart';
import '../item_kind.dart';

/// Recently deleted: items stay here, still encrypted, for 30 days, then go for good.
/// A tap shows the item (owner 2026-10-22), a long press offers Restore or Delete for
/// good; Select (in the bottom bar) picks several, and the bar acts on them (with nothing selected,
/// on everything). The vault reloads when it closes.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  static const _days = 30;
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

  /// What was deleted, before deciding: the same preview as in the vault (the picture,
  /// the video, the note's first lines, the recording, the file), with Restore and Delete
  /// for good, and how long it stays.
  Future<void> _preview(rust.ItemInfo it) async {
    final pick = await QuickLook.show(context, it,
        vaultId: '', trash: TrashLook(daysLeft: _daysLeft(it), held: _held.contains(it.id)));
    if (!mounted) return;
    if (pick == QuickLook.restoreRequest) await _restore([it]);
    if (pick == QuickLook.purgeRequest) await _deleteForGood([it]);
  }

  void _open(rust.ItemInfo it) => _selecting ? _toggle(it) : _preview(it);

  @override
  void initState() {
    super.initState();
    _load();
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
        });
      }
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  int _daysLeft(rust.ItemInfo it) {
    final gone = DateTime.fromMillisecondsSinceEpoch(it.deletedMs?.toInt() ?? 0).add(const Duration(days: _days));
    final left = gone.difference(DateTime.now()).inHours / 24;
    return left.ceil().clamp(0, _days);
  }

  Future<void> _restore(List<rust.ItemInfo> items) async {
    for (final it in items) {
      _held.contains(it.id) ? await rust.restoreHeld(id: it.id) : await rust.restoreItem(id: it.id);
    }
    _endSelect();
    await _load();
  }

  Future<void> _deleteForGood(List<rust.ItemInfo> items) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(items.length == 1 ? l.deleteForGoodOne : l.deleteForGoodAll(items.length)),
        content: Text(items.every((i) => _held.contains(i.id)) ? l.deleteForGoodBody : '${l.deleteForGoodBody} ${l.deleteForGoodOthersKeep}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final it in items) {
      _held.contains(it.id) ? await rust.purgeHeld(id: it.id) : await rust.deleteItem(id: it.id);
      _thumbnails.remove(it.id);
    }
    _endSelect();
    await _load();
  }

  /// A long press: Restore or Delete for good, for that one item (owner 2026-10-22).
  Future<void> _menu(rust.ItemInfo it) {
    final l = AppLocalizations.of(context);
    return showItemMenu(context, title: it.name.isEmpty ? l.untitledNote : it.name, entries: [
      MenuEntry(Icons.restore_rounded, l.restore, () => _restore([it]), key: const ValueKey('menu-restore')),
      MenuEntry(Icons.delete_forever_outlined, l.deleteForGoodShort, () => _deleteForGood([it]), danger: true),
    ]);
  }

  /// Tap selects, as in the Library; what to do sits in the bar at the bottom.
  void _toggle(rust.ItemInfo it) => setState(() => _picked.contains(it.id) ? _picked.remove(it.id) : _picked.add(it.id));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final items = _items;
    final photos = items?.where((i) => i.kind == ItemKind.photo).toList() ?? const [];
    final others = items?.where((i) => i.kind != ItemKind.photo).toList() ?? const [];
    // No canPop: false here: it would switch off the iOS swipe back. A swipe pops null
    // and the vault reloads anyway.
    return MenuPointer(child: PopScope(
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
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text('${l.trashNote} ${l.trashTapHint}${_held.isEmpty ? '' : ' ${l.trashHeldNote}'}',
                          style: TextStyle(color: c.muted, fontSize: 14.5)),
                    ),
                  ),
                  if (items.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text(l.trashEmpty, style: TextStyle(color: c.muted))),
                    ),
                  SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final it = photos[i];
                        final on = _picked.contains(it.id);
                        return GestureDetector(
                          key: ValueKey('trash-${it.id}'),
                          onTap: () => _open(it),
                          onLongPress: () => _menu(it),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FutureBuilder<Uint8List>(
                                future: _thumbnails[it.id] ??= rust.itemThumbnail(id: it.id),
                                builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                                    ? privateThumb(Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true))
                                    : ColoredBox(color: c.soft),
                              ),
                              Positioned(left: 4, bottom: 4, child: _DaysLeft(l.daysLeft(_daysLeft(it)))),
                              // Deleted on another device: a mark, so it is told apart.
                              if (_held.contains(it.id))
                                const Positioned(
                                  left: 5,
                                  top: 5,
                                  child: Icon(Icons.devices_rounded,
                                      key: ValueKey('trash-held'),
                                      size: 18,
                                      color: Colors.white,
                                      shadows: [Shadow(color: Color(0x88000000), blurRadius: 6)]),
                                ),
                              if (on) ColoredBox(color: Colors.white.withValues(alpha: .25)),
                              if (_selecting)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                                      color: Colors.white, shadows: const [Shadow(color: Color(0x88000000), blurRadius: 6)]),
                                ),
                            ],
                          ),
                        );
                      },
                      childCount: photos.length,
                    ),
                  ),
                  if (others.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        child: Material(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (final it in others)
                                ListTile(
                                  onTap: () => _open(it),
                                  onLongPress: () => _menu(it),
                                  trailing: _selecting
                                      ? Icon(_picked.contains(it.id) ? Icons.check_circle : Icons.radio_button_unchecked,
                                          color: Theme.of(context).colorScheme.onSurface)
                                      : null,
                                  leading: Icon(fileIcon(it), color: Theme.of(context).colorScheme.primary),
                                  title: Text(it.name.isEmpty ? l.untitledNote : it.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(_held.contains(it.id)
                                      ? '${l.trashHeldLabel} · ${l.daysLeft(_daysLeft(it))}'
                                      : l.daysLeft(_daysLeft(it))),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
        // Glass like the vault's selection bar: Restore, and Delete for good in red, apart.
        // Nothing selected: they act on everything.
        // Glass like the vault's selection bar: Select (Done while selecting), Restore,
        // and Delete for good in red. Nothing selected: they act on everything.
        bottomNavigationBar: (items == null || items.isEmpty)
            ? null
            : BottomBar(
                children: [
                  if (_selecting)
                    BarText(key: const ValueKey('trash-done'), label: l.done, expand: false, onTap: () => setState(_endSelect))
                  else
                    BarText(
                        key: const ValueKey('trash-select'), label: l.select, expand: false, onTap: () => setState(() => _selectMode = true)),
                  BarText(
                    key: const ValueKey('restore'),
                    label: _picked.isEmpty ? l.restoreAll : l.restore,
                    onTap: () => _restore(_picked.isEmpty ? items : items.where((i) => _picked.contains(i.id)).toList()),
                  ),
                  BarText(
                    key: const ValueKey('delete-all'),
                    label: _picked.isEmpty ? l.deleteAll : l.deleteForGoodShort,
                    color: recordRed(context),
                    onTap: () => _deleteForGood(_picked.isEmpty ? items : items.where((i) => _picked.contains(i.id)).toList()),
                  ),
                ],
              ),
      ),
    ));
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
