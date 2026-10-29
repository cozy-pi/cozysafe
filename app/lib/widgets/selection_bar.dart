import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'bottom_bar.dart';

/// One action of a [SelectionBar]: an icon; [label] is its tooltip.
class SelectionAction {
  const SelectionAction(this.icon, this.label, this.onTap, {this.color, this.key});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  /// Red for Delete and Delete for good; the ink colour otherwise.
  final Color? color;
  final Key? key;
}

/// What can be done with the items selected, in frosted glass at the bottom like the
/// vault bar (no bright slab in a dark room): Done first, where the back arrow would be,
/// then Select all, then the [actions], Delete last in the system's red (owner
/// 2026-10-21). The same bar in the vault and in Recently deleted.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.onDone,
    required this.onSelectAll,
    required this.allSelected,
    required this.actions,
    this.enabled = true,
  });

  /// Leaves Select mode.
  final VoidCallback onDone;
  final VoidCallback onSelectAll;
  /// Everything shown is selected: the button reads Deselect all.
  final bool allSelected;
  /// Nothing chosen yet (Select mode just opened): the actions wait, dimmed.
  final bool enabled;
  final List<SelectionAction> actions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Icons only, Done apart on the left like Close on an item (ActionBar, owner
    // 2026-10-28); each icon's word is its tooltip and what a screen reader says.
    return ActionBar(
      leave: LeaveButton(Icons.check_rounded, l.done, onDone, key: const ValueKey('select-done')),
      actions: [
        BarIcon(
          key: const ValueKey('select-all'),
          icon: allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          tooltip: allSelected ? l.deselectAll : l.selectAll,
          onTap: (_) => onSelectAll(),
        ),
        for (final a in actions.take(actions.length - 1)) _icon(a),
      ],
      // Delete (or Delete for good) is always the last action: alone on the right.
      end: actions.isEmpty ? null : _icon(actions.last),
    );
  }

  Widget _icon(SelectionAction a) =>
      BarIcon(key: a.key, icon: a.icon, tooltip: a.label, onTap: enabled ? (_) => a.onTap() : null, color: a.color);
}
