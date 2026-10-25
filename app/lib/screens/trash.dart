import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart';
import 'video_view.dart';
import '../widgets/item_menu.dart';
import '../widgets/vault_bar.dart';
import '../item_kind.dart';

/// Recently deleted: items stay here, still encrypted, for 30 days, then go for good.
/// A tap shows the item (owner 2026-10-22), a long press offers Restore or Delete for
/// good; Select picks several, and the bottom bar acts on them (with nothing selected,
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
  /// Full pictures for the preview, decrypted once per screen.
  final Map<String, Future<Uint8List>> _full = {};
  bool _selectMode = false;
  bool get _selecting => _selectMode || _picked.isNotEmpty;
  void _endSelect() {
    _selectMode = false;
    _picked.clear();
  }

  /// What was deleted, before deciding: the picture, the note's first lines, or the
  /// file's name and size, with Restore and Delete for good.
  Future<void> _preview(rust.ItemInfo it) async {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final size = MediaQuery.sizeOf(context);
    Widget body;
    if (it.kind == ItemKind.photo || it.kind == ItemKind.video) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * .45),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          // The thumbnail at once; a photo's full picture replaces it when decrypted.
          child: FutureBuilder<Uint8List>(
            future: _thumbnails[it.id] ??= rust.itemThumbnail(id: it.id),
            builder: (context, thumb) {
              final small = thumb.hasData && thumb.data!.isNotEmpty
                  ? Image.memory(thumb.data!, fit: BoxFit.contain, gaplessPlayback: true)
                  : const SizedBox(height: 200);
              if (it.kind == ItemKind.video) {
                return VideoViewScreen.supported ? _TrashVideo(item: it, still: small) : small;
              }
              if (it.sizeBytes > BigInt.from(60 << 20)) return small;
              return FutureBuilder<Uint8List>(
                future: _full[it.id] ??= rust.itemContent(id: it.id),
                builder: (context, full) => full.hasData && full.data!.isNotEmpty
                    ? Image.memory(full.data!,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        cacheWidth: (size.width * MediaQuery.devicePixelRatioOf(context)).round())
                    : small,
              );
            },
          ),
        ),
      );
    } else if (it.kind == ItemKind.note) {
      body = FutureBuilder<Uint8List>(
        future: rust.itemContent(id: it.id),
        builder: (context, snap) {
          final full = snap.hasData ? utf8.decode(snap.data!, allowMalformed: true).trim() : '';
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * .4),
            child: SingleChildScrollView(
              child: Text(full.length > 2000 ? '${full.substring(0, 2000)}…' : full,
                  style: const TextStyle(fontSize: 15.5, height: 1.45)),
            ),
          );
        },
      );
    } else {
      body = Row(
        children: [
          Icon(fileIcon(it), size: 40, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(child: Text(fileSize(it.sizeBytes), style: TextStyle(color: c.muted))),
        ],
      );
    }
    final pick = await showCard<int>(
      context,
      title: it.name.isEmpty ? l.untitledNote : it.name,
      builder: (context) => Padding(
        key: const ValueKey('trash-preview'),
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            const SizedBox(height: 12),
            Text(_held.contains(it.id) ? '${l.trashHeldLabel} · ${l.daysLeft(_daysLeft(it))}' : l.daysLeft(_daysLeft(it)),
                style: TextStyle(color: c.muted, fontSize: 13.5)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(1),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, Ui.circle),
                        shape: const StadiumBorder(),
                        foregroundColor: recordRed(context)),
                    child: Text(l.deleteForGoodShort),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('preview-restore'),
                    onPressed: () => Navigator.of(context).pop(0),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                    child: Text(l.restore),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 0) await _restore([it]);
    if (pick == 1) await _deleteForGood([it]);
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
          actions: [
            if (_selecting)
              TextButton(key: const ValueKey('trash-done'), onPressed: () => setState(_endSelect), child: Text(l.done))
            else if (items != null && items.isNotEmpty)
              TextButton(
                  key: const ValueKey('trash-select'), onPressed: () => setState(() => _selectMode = true), child: Text(l.select)),
            const SizedBox(width: 8),
          ],
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
        bottomNavigationBar: (items == null || items.isEmpty)
            ? null
            : Padding(
                padding: EdgeInsets.fromLTRB(10, 0, 10, Ui.edge + MediaQuery.paddingOf(context).bottom),
                child: Glass(
                  radius: Ui.bar / 2,
                  child: SizedBox(
                    height: Ui.bar,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            key: const ValueKey('restore'),
                            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                            onPressed: () => _restore(_picked.isEmpty ? items : items.where((i) => _picked.contains(i.id)).toList()),
                            child: Text(_picked.isEmpty ? l.restoreAll : l.restore,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            key: const ValueKey('delete-all'),
                            style: TextButton.styleFrom(foregroundColor: recordRed(context)),
                            onPressed: () => _deleteForGood(_picked.isEmpty ? items : items.where((i) => _picked.contains(i.id)).toList()),
                            child: Text(_picked.isEmpty ? l.deleteAll : l.deleteForGoodShort,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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

/// A deleted video in the preview: its still with a play button; a tap decrypts it into
/// the private playback folder and plays it there (owner 2026-10-23: videos in the trash
/// could not be watched). The copy is deleted when the preview closes.
class _TrashVideo extends StatefulWidget {
  const _TrashVideo({required this.item, required this.still});

  final rust.ItemInfo item;
  final Widget still;

  @override
  State<_TrashVideo> createState() => _TrashVideoState();
}

class _TrashVideoState extends State<_TrashVideo> {
  VideoPlayerController? _player;
  File? _copy;
  bool _opening = false;

  Future<void> _tap() async {
    final p = _player;
    if (p != null) {
      p.value.isPlaying ? await p.pause() : await p.play();
      return;
    }
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final copy = await playbackCopy(widget.item);
      _copy = copy;
      final player = VideoPlayerController.file(copy);
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      player.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _player = player);
      await player.play();
    } catch (_) {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    try {
      _copy?.deleteSync();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final playing = p?.value.isPlaying ?? false;
    return GestureDetector(
      key: const ValueKey('trash-video'),
      onTap: _tap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (p != null) AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p)) else widget.still,
          if (!playing)
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
              child: _opening && p == null
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
            ),
        ],
      ),
    );
  }
}
