import 'package:flutter/material.dart';

import '../theme.dart';
import 'vault_bar.dart';

/// Short messages ("Moved to Recently deleted · Undo", "Copied", errors): a glass capsule in
/// the app's black-and-white language (docs/ui.md), never the Material default box.
///
/// Inside a vault the bottom row is our own floating glass (the lock and the sections),
/// not a real bottom bar, so a SnackBar does not know to keep clear of it and lands on top
/// of it (reported 2026-10-20). There, pass [besideAction]: the message sits on the row of
/// the main action button, beside it (on the side away from the screen edge), above the bar.
void showToast(
  BuildContext context,
  String text, {
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  bool besideAction = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    // Over the vault's bottom row: above the centred action button (its bottom
    // Ui.actionLift above the safe area, Ui.primary tall).
    margin: !besideAction
        ? const EdgeInsets.fromLTRB(12, 0, 12, 10)
        : const EdgeInsets.fromLTRB(12, 0, 12, Ui.actionLift + Ui.primary + 10),
    duration: Duration(seconds: actionLabel == null ? 3 : 5),
    content: _Toast(
      text: text,
      icon: icon,
      actionLabel: actionLabel,
      onAction: onAction == null
          ? null
          : () {
              messenger.hideCurrentSnackBar();
              onAction();
            },
    ),
  ));
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text, this.icon, this.actionLabel, this.onAction});
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    return Glass(
      radius: 26,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: EdgeInsets.fromLTRB(icon == null ? 18 : 14, 6, actionLabel == null ? 18 : 6, 6),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: ink), const SizedBox(width: 10)],
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ink, fontSize: 14.5, fontWeight: FontWeight.w600, height: 1.25),
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                // The one thing to tap: a solid ink capsule with page-coloured words.
                Semantics(
                  button: true,
                  child: Material(
                    color: ink,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: onAction,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 40, minWidth: 64),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Center(
                            widthFactor: 1,
                            child: Text(actionLabel!, style: TextStyle(color: page, fontSize: 14.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
