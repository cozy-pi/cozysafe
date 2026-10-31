import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'file_view.dart' show fileSize;

/// Storage keys that are not item kinds: deleted items and older versions.
const storageTrash = 'trash';
const storageHistory = 'history';

/// What the vault takes, part by part: items by kind, Recently deleted, older versions
/// (owner 2026-10-28: every part, each leading to where it is managed).
@immutable
class StorageFigures {
  const StorageFigures({this.bytes = const {}, this.counts = const {}});

  /// Bytes per part ([storageParts] keys).
  final Map<String, BigInt> bytes;

  /// Items per part (none for older versions).
  final Map<String, int> counts;

  BigInt get total => bytes.values.fold(BigInt.zero, (a, b) => a + b);
  int get count => counts.values.fold(0, (a, b) => a + b);
  BigInt size(String part) => bytes[part] ?? BigInt.zero;
}

/// Every part in the storage bar, each in its own iOS system colour (owner 2026-10-21:
/// grey shades were hard to tell apart).
const storageParts = [
  (ItemKind.photo, Color(0xFF0A84FF)),
  (ItemKind.video, Color(0xFFBF5AF2)),
  (ItemKind.note, Color(0xFF5E5CE6)),
  (ItemKind.audio, Color(0xFFFF375F)),
  (ItemKind.file, Color(0xFF30D158)),
  (storageTrash, Color(0xFFFF453A)),
  (storageHistory, Color(0xFF8E8E93)),
];

String storagePartName(AppLocalizations l, String part) => switch (part) {
      ItemKind.photo => l.kindPhotos,
      ItemKind.video => l.cameraVideo,
      ItemKind.note => l.kindNotes,
      ItemKind.audio => l.modeAudio,
      ItemKind.file => l.kindFiles,
      storageTrash => l.recentlyDeleted,
      _ => l.kindHistory,
    };

IconData _icon(String part) => switch (part) {
      ItemKind.photo => Icons.photo_rounded,
      ItemKind.video => Icons.videocam_rounded,
      ItemKind.note => Icons.book_rounded,
      ItemKind.audio => Icons.mic_none_rounded,
      ItemKind.file => Icons.insert_drive_file_rounded,
      storageTrash => Icons.delete_sweep_rounded,
      _ => Icons.history_rounded,
    };

/// The bar split by part, a hairline between parts.
class StorageBar extends StatelessWidget {
  const StorageBar({super.key, required this.figures, this.height = 8});
  final StorageFigures figures;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final total = figures.total;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: total == BigInt.zero
            ? ColoredBox(color: fg.withValues(alpha: .2), child: const SizedBox.expand())
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (k, color) in storageParts)
                    if (figures.size(k) > BigInt.zero)
                      Expanded(
                        flex: ((figures.size(k) * BigInt.from(1000)) ~/ total).toInt().clamp(1, 1000),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: ColoredBox(color: color),
                        ),
                      ),
                ],
              ),
      ),
    );
  }
}

/// Storage: the total, the bar, then one row per part, largest first; a tap goes where
/// that part is managed (its section, Recently deleted, Version history). The figures
/// follow [figures], so a part emptied elsewhere shrinks here at once.
class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key, required this.figures, required this.onOpen});

  final ValueListenable<StorageFigures> figures;
  final void Function(String part) onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return ValueListenableBuilder<StorageFigures>(
      valueListenable: figures,
      builder: (context, f, _) {
        // Every part is listed, even empty: a row that comes and goes would move the rest.
        final parts = [...storageParts]..sort((a, b) => f.size(b.$1).compareTo(f.size(a.$1)));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Text(l.storageUsed(fileSize(f.total), f.count),
                key: const ValueKey('storage-total'), style: const TextStyle(fontSize: CsType.title2, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            StorageBar(figures: f, height: 12),
            const SizedBox(height: 22),
            Material(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final (i, (part, color)) in parts.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 58, color: c.border),
                  InkWell(
                    key: ValueKey('storage-$part'),
                    onTap: () => onOpen(part),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                      child: Row(children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                          child: Icon(_icon(part), color: Colors.white, size: 19),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(storagePartName(l, part), style: const TextStyle(fontSize: CsType.callout)),
                            if (f.counts[part] case final n?)
                              Text(l.storageItems(n), style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                          ]),
                        ),
                        Text(fileSize(f.size(part)),
                            style: TextStyle(color: c.muted, fontSize: CsType.subhead, fontFeatures: const [FontFeature.tabularFigures()])),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: c.muted, size: 20),
                      ]),
                    ),
                  ),
                ],
              ]),
            ),
          ],
        );
      },
    );
  }
}
