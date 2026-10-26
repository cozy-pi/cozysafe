import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/vault_bar.dart' show showCard;
import 'file_view.dart' show fileSize;

/// Items stay in Recently deleted this many days, then go for good.
const trashDays = 30;

/// Days before an item in Recently deleted goes for good (0: today).
int trashDaysLeft(rust.ItemInfo it) {
  final gone = DateTime.fromMillisecondsSinceEpoch(it.deletedMs?.toInt() ?? 0).add(const Duration(days: trashDays));
  final left = gone.difference(DateTime.now()).inHours / 24;
  return left.ceil().clamp(0, trashDays);
}

/// The name an item shows: a recording without ".m4a", a note without a title "Untitled".
String shownName(AppLocalizations l, rust.ItemInfo it) => it.name.isEmpty
    ? l.untitledNote
    : it.kind == ItemKind.audio
        ? it.name.replaceAll(RegExp(r'\.m4a$'), '')
        : it.name;

/// What an item is, in a card: name, kind, size, when it was added, its length, its
/// [groups] (null: not shown, as in Recently deleted). An item in Recently deleted also
/// says when it was deleted ([held]: on another device) and until when it is kept. The
/// same card from the vault, the preview and Recently deleted.
Future<void> showItemInfo(BuildContext context, rust.ItemInfo item, {List<String>? groups, bool held = false}) async {
  final l = AppLocalizations.of(context);
  final ml = MaterialLocalizations.of(context);
  String when(DateTime d) =>
      '${ml.formatShortDate(d)}, ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true)}';
  final dot = item.name.lastIndexOf('.');
  final ext = dot > 0 ? item.name.substring(dot + 1).toUpperCase() : '';
  final kind = switch (item.kind) {
    ItemKind.photo => '${l.kindPhotos}${ext.isEmpty ? '' : ' · $ext'}',
    ItemKind.video => '${l.cameraVideo}${ext.isEmpty ? '' : ' · $ext'}',
    ItemKind.note => l.modeNote,
    ItemKind.audio => l.modeAudio,
    _ => ext.isEmpty ? l.modeFile : '${l.modeFile} · $ext',
  };
  final ms = item.durationMs?.toInt();
  String clock(int ms) {
    final d = Duration(milliseconds: ms);
    final mm = (d.inSeconds % 3600 ~/ 60).toString().padLeft(d.inHours > 0 ? 2 : 1, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
  }

  final deleted = item.deletedMs;
  final rows = <(String, String)>[
    (l.infoName, shownName(l, item)),
    (l.infoKind, kind),
    (l.infoSize, fileSize(item.sizeBytes)),
    (l.infoAdded, when(dateOf(item.createdMs))),
    if (ms != null && ms > 0) (l.infoLength, clock(ms)),
    if (groups != null) (l.infoGroups, groups.isEmpty ? l.infoNoGroup : groups.join(', ')),
    if (deleted != null) ...[
      (l.infoDeleted, held ? '${when(dateOf(deleted))}\n${l.trashHeldLabel}' : when(dateOf(deleted))),
      (l.infoKeptUntil, '${ml.formatShortDate(dateOf(deleted).add(const Duration(days: trashDays)))} · ${l.daysLeft(trashDaysLeft(item))}'),
    ],
  ];
  final c = CsColors.of(context);
  await showCard<void>(
    context,
    title: l.info,
    closeButton: true,
    builder: (context) => Padding(
      key: const ValueKey('item-info'),
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 110, child: Text(k, style: TextStyle(color: c.muted, fontSize: 15))),
                  Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
