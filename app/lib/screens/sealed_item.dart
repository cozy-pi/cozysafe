import 'package:flutter/material.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/vault_bar.dart' show showCard;
import 'file_view.dart' show fileSize, openWithById;
import 'item_info.dart' show itemKindLabel, shownName;

/// A Top secret item that is not a note (ADR 0005): never opened, previewed or played in
/// the app. Tapping it shows what it is, says why it does not open, and offers Open in
/// another app (owner 2026-10-31: not "Send"): a plain copy for the app picked, after the
/// same warning every time (no "don't ask again" here).
Future<void> showSealedItem(
  BuildContext context,
  rust.ItemInfo item, {
  required String vaultId,
}) async {
  final l = AppLocalizations.of(context);
  final ml = MaterialLocalizations.of(context);
  final added = dateOf(item.createdMs);
  final c = CsColors.of(context);
  final send = await showCard<bool>(
    context,
    title: shownName(l, item),
    builder: (context) => Padding(
      key: const ValueKey('sealed-item'),
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${itemKindLabel(l, item)} · ${fileSize(item.sizeBytes)} · ${ml.formatShortDate(added)}',
            style: TextStyle(color: c.muted, fontSize: CsType.footnote),
          ),
          const SizedBox(height: 14),
          Text(
            l.sealedLead,
            style: const TextStyle(fontSize: CsType.subhead, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            l.shareOutBody,
            style: TextStyle(
              color: c.muted,
              fontSize: CsType.subhead,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const ValueKey('sealed-send'),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(l.openWith),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
        ],
      ),
    ),
  );
  if (send != true || !context.mounted) return;
  await openWithById(
    context,
    item.id,
    item.mime,
    item.name,
    vaultId,
    askFirst: false,
  );
}

/// Name a photo just taken in a Top secret vault, at once (ADR 0005: it is never shown,
/// so its name is how it is found: "ID card, front"). Skip keeps the made-up name.
Future<void> nameNewItem(BuildContext context, rust.ItemInfo item) async {
  final l = AppLocalizations.of(context);
  final dot = item.name.lastIndexOf('.');
  final ext = dot > 0 && item.name.length - dot <= 6
      ? item.name.substring(dot)
      : '';
  final text = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(item.kind == ItemKind.photo ? l.namePhotoTitle : l.rename),
      content: TextField(
        key: const ValueKey('name-new-item'),
        controller: text,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: l.namePhotoHint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.lookSkip),
        ),
        TextButton(
          key: const ValueKey('name-new-item-save'),
          onPressed: () => Navigator.pop(context, text.text.trim()),
          child: Text(l.save),
        ),
      ],
    ),
  );
  text.dispose();
  if (name == null || name.isEmpty) return;
  try {
    await rust.renameItem(id: item.id, name: '$name$ext');
  } catch (_) {} // the made-up name stays; it can be renamed from the list
}
