import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart';
import '../widgets/vault_bar.dart';
import '../item_kind.dart';

/// Recently deleted: items stay here, still encrypted, for 30 days, then go for good.
/// Tap items to select them, then Restore or Delete for good in the bottom bar (with
/// nothing selected, the bar acts on everything). The vault reloads when it closes.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  static const _days = 30;
  List<rust.ItemInfo>? _items;
  final Map<String, Future<Uint8List>> _thumbnails = {};
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await rust.listTrash();
      if (mounted) setState(() => _items = items);
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
      await rust.restoreItem(id: it.id);
    }
    _picked.clear();
    await _load();
  }

  Future<void> _deleteForGood(List<rust.ItemInfo> items) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(items.length == 1 ? l.deleteForGoodOne : l.deleteForGoodAll(items.length)),
        content: Text(l.deleteForGoodBody),
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
      await rust.deleteItem(id: it.id);
      _thumbnails.remove(it.id);
    }
    await _load();
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
    return PopScope(
      child: Scaffold(
        appBar: AppBar(
          title: Text(_picked.isEmpty ? l.recentlyDeleted : l.selectedCount(_picked.length)),
          actions: [
            if (_picked.isNotEmpty) TextButton(onPressed: () => setState(_picked.clear), child: Text(l.cancel)),
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
                      child: Text('${l.trashNote} ${l.trashTapHint}', style: TextStyle(color: c.muted, fontSize: 14.5)),
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
                          onTap: () => _toggle(it),
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
                              if (on) ColoredBox(color: Colors.white.withValues(alpha: .25)),
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
                                  onTap: () => _toggle(it),
                                  trailing: Icon(_picked.contains(it.id) ? Icons.check_circle : Icons.radio_button_unchecked,
                                      color: Theme.of(context).colorScheme.onSurface),
                                  leading: Icon(fileIcon(it), color: Theme.of(context).colorScheme.primary),
                                  title: Text(it.name.isEmpty ? l.untitledNote : it.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(l.daysLeft(_daysLeft(it))),
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
