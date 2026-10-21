import 'package:flutter/material.dart';

import '../theme.dart';

/// One row of a vault list (notes, files, recordings, and any kind added later): the
/// same way to select everywhere (owner 2026-10-21). A long press selects; while
/// anything is selected every row shows a circle, filled on the chosen ones, like the
/// photo grid, so people see that a tap now selects. New lists use this, not their own
/// InkWell (docs/ui.md, selection).
class SelectableRow extends StatelessWidget {
  const SelectableRow({
    super.key,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 12, 10),
    this.highlight,
  });

  final bool selected;
  /// Something in the list is selected: show the circles.
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final EdgeInsetsGeometry padding;
  /// A row's own tint when not selected (a recording playing or open).
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? primary.withValues(alpha: .12) : highlight,
        padding: padding,
        child: Row(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: selecting
                  ? Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SelectCircle(selected: selected),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// The selection circle of lists: an empty ring, or filled with a tick.
class SelectCircle extends StatelessWidget {
  const SelectCircle({super.key, required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        key: ValueKey(selected ? 'select-on' : 'select-off'),
        size: 24,
        color: selected ? Theme.of(context).colorScheme.primary : CsColors.of(context).muted,
      );
}
