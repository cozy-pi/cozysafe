import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../links.dart';
import '../lock_guard.dart';
import '../note_format.dart';
import '../theme.dart';
import 'vault_bar.dart' show showCard;

/// A link tapped in a note never opens straight away (docs/security.md, links in notes):
/// a card names the real host first, an international one in its xn-- form so a
/// look-alike shows, with the whole address under it. Cancel or Open; where the app
/// cannot hand it to a browser (desktop), Copy.
Future<void> confirmOpenLink(BuildContext context, String url) async {
  final link = safeLink(url);
  if (link == null) return;
  final l = AppLocalizations.of(context);
  final c = CsColors.of(context);
  final open = await showCard<bool>(
    context,
    title: l.noteLinkTitle(link.host),
    builder: (context) => Padding(
      key: const ValueKey('link-card'),
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(link.url,
              key: const ValueKey('link-url'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, height: 1.4, color: c.muted)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('link-cancel'),
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                  child: Text(l.cancel),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('link-open'),
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                  child: Text(Links.canOpen ? l.openItem : l.kitCopy),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (open != true) return;
  if (Links.canOpen) {
    await Links.openExternal(link.url);
  } else {
    await Clipboard.setData(ClipboardData(text: link.url));
    LockGuard.copied(link.url);
  }
}
