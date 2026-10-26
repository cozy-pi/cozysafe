import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/vault_bar.dart' show showCard;

/// Ask before every connection, naming where it goes (docs/decisions.md, "Network only
/// by hand"). Only a tap on Allow returns true; closing the card is a no.
Future<bool> allowConnection(BuildContext context, String message) async {
  final l = AppLocalizations.of(context);
  final yes = await showCard<bool>(
    context,
    title: l.syncAllowTitle,
    builder: (context) {
      final c = CsColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, key: const ValueKey('sync-allow-message'), style: const TextStyle(fontSize: 16, height: 1.35)),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: c.muted),
                const SizedBox(width: 8),
                Expanded(child: Text(l.syncAllowSafe, style: TextStyle(color: c.muted, fontSize: 14, height: 1.3))),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('sync-allow'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l.syncAllow),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  return yes ?? false;
}
