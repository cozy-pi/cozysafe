import 'package:flutter/material.dart';

import '../entries/secure_clipboard.dart';

/// The text menu of a field holding a secret (a password, a one-time code's key, recovery
/// codes, a secure item's notes): Copy and Cut go through [SecureClipboard], so what
/// leaves is cleared on time and kept off other devices, never the plain clipboard.
/// Paste and the rest stay as they are.
Widget secureContextMenu(BuildContext context, EditableTextState state) {
  final value = state.textEditingValue;
  final sel = value.selection;
  final picked = sel.isValid && !sel.isCollapsed ? sel.textInside(value.text) : null;
  final items = [
    for (final it in state.contextMenuButtonItems)
      if (it.type == ContextMenuButtonType.copy)
        if (picked == null)
          null
        else
          it.copyWith(onPressed: () {
            SecureClipboard.copy(picked);
            state.hideToolbar();
          })
      else if (it.type == ContextMenuButtonType.cut)
        if (picked == null)
          null
        else
          it.copyWith(onPressed: () {
            SecureClipboard.copy(picked);
            state.userUpdateTextEditingValue(value.replaced(sel, ''), SelectionChangedCause.toolbar);
            state.hideToolbar();
          })
      else
        it,
  ].nonNulls.toList();
  return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
}

/// Keyboard Copy and Cut (⌘C, ⌘X, Ctrl+C, Ctrl+X) in a field holding a secret go the
/// same way as the menu's: through [SecureClipboard], never the plain clipboard. While
/// [allowed] says no (the secret is masked) they do nothing, as the system does for a
/// hidden password.
class SecureCopy extends StatelessWidget {
  const SecureCopy({super.key, required this.controller, required this.child, this.allowed});
  final TextEditingController controller;
  final Widget child;
  final bool Function()? allowed;

  @override
  Widget build(BuildContext context) => Actions(
        actions: {CopySelectionTextIntent: _SecureCopyAction(controller, allowed)},
        child: child,
      );
}

class _SecureCopyAction extends Action<CopySelectionTextIntent> {
  _SecureCopyAction(this.controller, this.allowed);
  final TextEditingController controller;
  final bool Function()? allowed;

  @override
  Object? invoke(CopySelectionTextIntent intent) {
    if (!(allowed?.call() ?? true)) return null;
    final value = controller.value;
    final sel = value.selection;
    if (!sel.isValid || sel.isCollapsed) return null;
    SecureClipboard.copy(sel.textInside(value.text));
    if (intent.collapseSelection) controller.value = value.replaced(sel, '');
    return null;
  }
}
