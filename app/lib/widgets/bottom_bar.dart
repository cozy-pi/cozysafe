import 'package:flutter/material.dart';

import '../theme.dart';
import 'vault_bar.dart' show Glass;

// Every action button sits at the bottom, within the thumb's reach (owner 2026-10-25).
// On top stay only the back arrow and the page's title. Two shapes, one for each kind of
// page: a glass bar of actions where the vault bar is ([BottomBar]), and a form's main
// button pinned under its fields, riding above the keyboard ([PinnedAction]).

/// A page's actions in a glass bar at the vault bar's place, its height and shape, the
/// buttons spread evenly (the preview's bar, quick_look.dart). For a Scaffold's
/// `bottomNavigationBar`, or the last child of a page's column.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key, required this.children});

  /// [BarIcon]s, or [BarText]s for a few worded actions.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(10, 6, 10, Ui.edge + MediaQuery.paddingOf(context).bottom),
        child: Glass(
          radius: Ui.bar / 2,
          child: SizedBox(
            height: Ui.bar,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children),
          ),
        ),
      );
}

/// A round icon button in a [BottomBar]; [onTap] gets the button's own context (Send
/// anchors the iPad share sheet to it).
class BarIcon extends StatelessWidget {
  const BarIcon({super.key, required this.icon, required this.tooltip, required this.onTap, this.color});
  final IconData icon;
  final String tooltip;
  final void Function(BuildContext)? onTap;
  /// Red for Delete; the ink colour otherwise.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    return IconButton(
      tooltip: tooltip,
      onPressed: tap == null ? null : () => tap(context),
      iconSize: 24,
      style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
      icon: Icon(icon, color: tap == null ? null : color ?? Theme.of(context).colorScheme.onSurface),
    );
  }
}

/// A worded button in a [BottomBar], sharing the width with the others; a short one
/// ([expand] false) keeps its own width so the long ones get the room. A label too long
/// for its share shrinks rather than being cut.
class BarText extends StatelessWidget {
  const BarText({super.key, required this.label, required this.onTap, this.color, this.expand = true});
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final button = TextButton(
      style: TextButton.styleFrom(
        foregroundColor: color ?? Theme.of(context).colorScheme.onSurface,
        minimumSize: const Size(0, Ui.bar),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: const StadiumBorder(),
      ),
      onPressed: onTap,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
    );
    return expand ? Expanded(child: button) : button;
  }
}

/// A form page: its fields in [child] (scrolling if they need to), and its main button
/// (with any second one under it) pinned to the bottom, clear of the home indicator, and
/// just above the keyboard while it is open, so it never floats mid-page or hides. The
/// same on every form.
class PinnedAction extends StatelessWidget {
  const PinnedAction({super.key, required this.child, required this.actions, this.padding = 24});

  final Widget child;
  /// The main button first, stretched to the page's width; a quieter one may follow.
  final List<Widget> actions;
  /// The page's side margins.
  final double padding;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: child),
          // padding.bottom is 0 while the keyboard is up: the button rests on it.
          SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 8, padding, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: actions,
              ),
            ),
          ),
        ],
      );
}
