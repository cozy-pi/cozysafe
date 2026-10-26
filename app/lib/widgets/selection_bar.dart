import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'vault_bar.dart' show Glass;

/// One action of a [SelectionBar]: an icon over a short word.
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
    final bottom = MediaQuery.paddingOf(context).bottom;
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget action(SelectionAction a, {bool always = false}) => Expanded(
          child: Opacity(
            opacity: enabled || always ? 1 : .35,
            child: InkWell(
              key: a.key,
              onTap: enabled || always ? a.onTap : null,
              customBorder: const StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon, color: a.color ?? ink),
                    const SizedBox(height: 3),
                    // Six buttons on a narrow phone: a long label shrinks rather than wraps.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(a.label,
                          maxLines: 1, style: TextStyle(color: a.color ?? ink, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, Ui.edge + bottom),
      child: Glass(
        radius: Ui.bar / 2 + 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              action(SelectionAction(Icons.check_rounded, l.done, onDone, key: const ValueKey('select-done')), always: true),
              action(
                  SelectionAction(allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
                      allSelected ? l.deselectAll : l.selectAll, onSelectAll,
                      key: const ValueKey('select-all')),
                  always: true),
              for (final a in actions) action(a),
            ],
          ),
        ),
      ),
    );
  }
}
