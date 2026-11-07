import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'selectable_row.dart';
import 'symbols.dart';
import 'vault_bar.dart' show entryKindColor;

/// A secure item's symbol (ADR 0009): a key for a login, a shield with a lock for a
/// one-time code, a keypad for recovery codes; each in its colour ([entryKindColor]).
IconData entryIcon(String kind) => switch (kind) {
      ItemKind.otp => Sym.shieldLock,
      ItemKind.codes => Sym.pin,
      _ => Sym.key,
    };

/// What a secure item is, in words.
String entryKindLabel(AppLocalizations l, String kind) => switch (kind) {
      ItemKind.otp => l.entryKindOtp,
      ItemKind.codes => l.entryKindCodes,
      _ => l.entryKindLogin,
    };

/// A secure item's second line in a list: its account, then its first web site, from
/// the item's summary. Never the content: a list decrypts nothing (ADR 0009).
String entryLine(rust.ItemInfo it) => [
      if (it.account.isNotEmpty) it.account,
      if (it.hosts.isNotEmpty) it.hosts.first,
    ].join(' · ');

/// A secure item's mark: its symbol on a soft tile in its kind's colour.
class EntryBadge extends StatelessWidget {
  const EntryBadge({super.key, required this.kind, this.width = 42, this.height = 48, this.big = false});
  final String kind;
  final double width;
  final double height;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final color = entryKindColor(kind);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(big ? 12 : 8)),
      child: Icon(entryIcon(kind), color: color, size: big ? 34 : (width < 36 ? 18 : 24)),
    );
  }
}

/// A secure item's kind, as a line over its page and its editor: the mark, then the word.
class EntryKindLine extends StatelessWidget {
  const EntryKindLine({super.key, required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey('entry-kind-line'),
        children: [
          EntryBadge(kind: kind, width: 30, height: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(entryKindLabel(AppLocalizations.of(context), kind),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: CsColors.of(context).muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
          ),
        ],
      );
}

/// A secure item in a vault list: its mark, its name on one line, then the account and
/// the first web site.
class EntryRow extends StatelessWidget {
  const EntryRow({
    super.key,
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onTap,
    this.favorite = true,
  });
  final rust.ItemInfo item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  /// Show the star of a favourite after the name.
  final bool favorite;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final line = entryLine(item);
    return SelectableRow(
      selected: selected,
      selecting: selecting,
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      child: Row(
        children: [
          EntryBadge(kind: item.kind),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name.isEmpty ? entryKindLabel(l, item.kind) : item.name,
                        key: ValueKey('entry-name-${item.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w400),
                      ),
                    ),
                    if (favorite && item.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  line.isEmpty ? entryKindLabel(l, item.kind) : line,
                  key: ValueKey('entry-line-${item.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: CsType.footnote),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
