import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Every delete asks first, everywhere, in the same words and the same place (owner
/// 2026-10-26): moving items to Recently deleted, deleting them for good, deleting a
/// group. A card at the bottom, where the thumb is, the page dimmed and soft behind (like
/// the item menu); what goes and how many in the title, the red button that does it, Cancel
/// under it. A tap outside or Back cancels. True when confirmed.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String action,
  String? name,
  String? body,
  IconData icon = Icons.delete_outline_rounded,
  /// The icon's and the button's colour; red unless given (blue for Restore).
  Color? color,
}) async {
  HapticFeedback.lightImpact();
  final still = MediaQuery.disableAnimationsOf(context);
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context).cancel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration(milliseconds: still ? 0 : 220),
    pageBuilder: (context, _, _) => _ConfirmSheet(title: title, action: action, name: name, body: body, icon: icon, color: color),
    transitionBuilder: (context, a, _, child) {
      final curve = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, .08), end: Offset.zero).animate(curve),
          child: child,
        ),
      );
    },
  );
  return ok == true;
}

/// Moving to Recently deleted: [count] items, or one called [name].
Future<bool> confirmTrash(BuildContext context, {required int count, String? name}) {
  final l = AppLocalizations.of(context);
  return confirmDelete(
    context,
    title: l.confirmTrashTitle(count),
    name: count == 1 ? name : null,
    body: l.confirmTrashBody(count),
    action: l.delete,
  );
}

/// Bringing [count] items back from Recently deleted (owner 2026-10-27: it went without
/// asking). [held]: some came from another device's delete for good, and go back to
/// every device at the next sync.
Future<bool> confirmRestore(BuildContext context, {required int count, String? name, bool held = false}) {
  final l = AppLocalizations.of(context);
  return confirmDelete(
    context,
    title: l.confirmRestoreTitle(count),
    name: count == 1 ? name : null,
    body: held ? l.confirmRestoreHeldBody : l.confirmRestoreBody,
    action: l.restore,
    icon: Icons.restore_from_trash_rounded,
    color: restoreBlue,
  );
}

/// Restore's colour: the system blue, never the delete red.
const restoreBlue = Color(0xFF0A84FF);

/// Deleting from Recently deleted for good. [othersKeep]: some of them are synced, and the
/// other devices keep them for 30 days.
Future<bool> confirmDeleteForGood(BuildContext context, {required int count, String? name, bool othersKeep = false}) {
  final l = AppLocalizations.of(context);
  return confirmDelete(
    context,
    title: count == 1 ? l.deleteForGoodOne : l.deleteForGoodAll(count),
    name: count == 1 ? name : null,
    body: othersKeep ? '${l.deleteForGoodBody} ${l.deleteForGoodOthersKeep}' : l.deleteForGoodBody,
    action: l.deleteForGoodShort,
    icon: Icons.delete_forever_outlined,
  );
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.title, required this.action, required this.icon, this.name, this.body, this.color});
  final Color? color;
  final String title;
  final String action;
  final IconData icon;
  final String? name;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final red = color ?? recordRed(context);
    // A shade off the page, like the item menu: never a white slab in the dark.
    final fill = Color.alphaBlend(ink.withValues(alpha: dark ? .10 : .03), page);
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(false),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: ColoredBox(color: page.withValues(alpha: .5)),
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: Ui.edge + pad.bottom,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Material(
                key: const ValueKey('confirm-delete'),
                color: fill,
                elevation: 12,
                shadowColor: Colors.black45,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                  side: BorderSide(color: ink.withValues(alpha: .10)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(icon, size: 34, color: red),
                      const SizedBox(height: 10),
                      Text(title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.2, height: 1.25)),
                      if (name != null && name!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(name!,
                            key: const ValueKey('confirm-delete-name'),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: ink.withValues(alpha: .8))),
                      ],
                      if (body != null) ...[
                        const SizedBox(height: 8),
                        Text(body!, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.4)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const ValueKey('confirm-delete-go'),
                        onPressed: () => Navigator.of(context).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: red,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, Ui.bar),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(action, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        key: const ValueKey('confirm-delete-cancel'),
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: ink,
                          minimumSize: const Size(0, Ui.bar),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(l.cancel, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
