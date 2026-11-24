import 'dart:async';

import 'package:flutter/material.dart';

import '../entries/entry.dart';
import '../entries/totp.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../screens/entry_page.dart' show CodeRing, codeColor, copySecret, groupedCode;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'entry_row.dart';
import 'selectable_row.dart';

/// A one-time code in the Passwords list, as authenticator apps show it (owner
/// 2026-11-24): its name and account on one line, the code of this moment big under it
/// in the kind's colour, the time it has left as a small pie on the right. A tap copies
/// the code; the item's page is in its menu (long press).
///
/// The row reads its own document when it comes on screen and drops it as the vault
/// locks (ADR 0009, "codes in the list"); a login's document is never read for a list.
class CodeRow extends StatefulWidget {
  const CodeRow({
    super.key,
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onOpen,
    this.onLongPress,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 12, 10),
    this.badge,
  });
  final rust.ItemInfo item;
  final bool selected;
  final bool selecting;
  /// The list's own tap: selects while selecting, else opens the item's page. Used
  /// while selecting, and when the code cannot be shown.
  final VoidCallback onOpen;
  /// Null in the vault's list, where the [DragSelectItem] around the row takes it.
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  /// The mark as a square of this side (search results); null: the list's own shape.
  final double? badge;

  @override
  State<CodeRow> createState() => _CodeRowState();
}

class _CodeRowState extends State<CodeRow> with VaultLockAware {
  Totp? _totp;
  /// Read and found without a usable key: the row opens the page instead of copying.
  bool _failed = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CodeRow old) {
    super.didUpdateWidget(old);
    // Another item in this place of the list, or this one edited.
    if (old.item.id != widget.item.id || old.item.modifiedMs != widget.item.modifiedMs) {
      _totp = null;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.item.id;
    Totp? totp;
    try {
      final doc = await rust.entryJson(id: id);
      totp = Entry.decode(ItemKind.otp, doc.json).totp;
    } catch (_) {
      totp = null;
    }
    if (!mounted || widget.item.id != id || vaultLock.locked) return;
    setState(() {
      _totp = totp;
      _failed = totp == null;
    });
    _tick?.cancel();
    if (totp != null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// The vault locks: the key goes, read again when it opens.
  @override
  void vaultLocking() {
    _tick?.cancel();
    setState(() => _totp = null);
  }

  @override
  void vaultUnlocked() => _load();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final item = widget.item;
    final totp = _totp;
    final now = codeClock();
    final code = totp?.code(now);
    final left = totp?.secondsLeft(now);
    return SelectableRow(
      selected: widget.selected,
      selecting: widget.selecting,
      onTap: widget.selecting || code == null ? widget.onOpen : () => copySecret(context, code),
      onLongPress: widget.onLongPress,
      padding: widget.padding,
      child: Row(
        children: [
          widget.badge == null ? EntryBadge(kind: item.kind) : EntryBadge(kind: item.kind, width: widget.badge!, height: widget.badge!),
          SizedBox(width: widget.badge == null ? 14 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: item.name.isEmpty ? entryKindLabel(l, item.kind) : item.name),
                          if (item.account.isNotEmpty)
                            TextSpan(text: '  ${item.account}', style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                        ]),
                        key: ValueKey('entry-name-${item.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w400),
                      ),
                    ),
                    if (item.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  // Until it is read, and when it cannot be: dots, never a made-up code.
                  code == null ? '••• •••' : groupedCode(code),
                  key: ValueKey('code-row-value-${item.id}'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: CsType.title1,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: code == null ? c.muted.withValues(alpha: _failed ? .5 : 1) : codeColor(context, left!),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          if (totp != null && left != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: CodeRing(left: left, period: totp.period),
            ),
        ],
      ),
    );
  }
}
