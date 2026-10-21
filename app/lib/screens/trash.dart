import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart';
import '../item_kind.dart';

/// Recently deleted: items stay here, still encrypted, for 30 days, then go for good.
/// Tap an item to restore it or delete it now. Pops `true` when something changed.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  static const _days = 30;
  List<rust.ItemInfo>? _items;
  final Map<String, Future<Uint8List>> _thumbnails = {};
  bool _changed = false;

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
    _changed = true;
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

  Future<void> _actions(rust.ItemInfo it) async {
    final l = AppLocalizations.of(context);
    final pick = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.restore),
              title: Text(l.restore),
              onTap: () => Navigator.pop(context, 1),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
              title: Text(l.deleteNow, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 2),
            ),
          ],
        ),
      ),
    );
    if (pick == 1) await _restore([it]);
    if (pick == 2) await _deleteForGood([it]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final items = _items;
    final photos = items?.where((i) => i.kind == ItemKind.photo).toList() ?? const [];
    final others = items?.where((i) => i.kind != ItemKind.photo).toList() ?? const [];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l.recentlyDeleted)),
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
                        return GestureDetector(
                          onTap: () => _actions(it),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FutureBuilder<Uint8List>(
                                future: _thumbnails[it.id] ??= rust.itemThumbnail(id: it.id),
                                builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                                    ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
                                    : ColoredBox(color: c.soft),
                              ),
                              Positioned(left: 4, bottom: 4, child: _DaysLeft(l.daysLeft(_daysLeft(it)))),
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
                                  onTap: () => _actions(it),
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
        bottomNavigationBar: (items == null || items.isEmpty)
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context).cardColor,
                            foregroundColor: Theme.of(context).colorScheme.primary,
                          ),
                          onPressed: () => _restore(items),
                          child: Text(l.restoreAll),
                        ),
                      ),
                      // Apart from Restore, and red: it cannot be undone.
                      const SizedBox(width: 28),
                      TextButton(
                        key: const ValueKey('delete-all'),
                        style: TextButton.styleFrom(
                          // The system's destructive red (an exception to black and white,
                          // proposed 2026-10-21 after user testing).
                          foregroundColor: recordRed(context),
                          minimumSize: const Size(0, Ui.circle),
                        ),
                        onPressed: () => _deleteForGood(items),
                        child: Text(l.deleteAll, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ],
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
