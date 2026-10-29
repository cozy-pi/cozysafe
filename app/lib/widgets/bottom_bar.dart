import 'package:flutter/material.dart';

import '../theme.dart';
import '../screens/glass.dart' show GlassPill;
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
      iconSize: 28,
      style: IconButton.styleFrom(minimumSize: const Size(Ui.action, Ui.action)),
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
        child: Text(label, maxLines: 1, style: const TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w700)),
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

/// The way out of an item, in its own round glass on the left of an [ActionBar]: × to
/// close, ✓ to save and leave (a note), ⤡ to leave full screen.
class LeaveButton {
  const LeaveButton(this.icon, this.tooltip, this.onTap, {this.key});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Key? key;
}

/// An item's actions, one look everywhere (owner 2026-10-29, as the iPhone's own apps):
/// every button its own glass circle, apart from the others. The way out on the left (×,
/// ✓, ⤡), [end] on the right (Delete, red, far from the rest so it is not hit by
/// mistake), the [actions] between them (Open · Send · ⋯). Icons only; the word is the
/// tooltip. Over a photo or video ([onMedia]) the glass is dark and the icons white.
class ActionBar extends StatelessWidget {
  const ActionBar(
      {super.key, this.leave, this.start, required this.actions, this.end, this.onMedia = false, this.inset = true, this.barKey});

  final LeaveButton? leave;
  /// A [BarIcon] on the left in place of [leave], where the view closes some other way
  /// (a tap beside it, Back on top): Share, as in Photos (owner 2026-10-29).
  final Widget? start;
  /// [BarIcon]s.
  final List<Widget> actions;
  /// Delete: alone on the right.
  final Widget? end;
  final bool onMedia;
  /// Its own margins and the safe area; false where the caller places it.
  final bool inset;
  final Key? barKey;

  @override
  Widget build(BuildContext context) {
    Widget circle(Widget child) => SizedBox.square(
          dimension: Ui.action,
          child: onMedia ? GlassPill(child: Center(child: child)) : Glass(radius: Ui.action / 2, child: Center(child: child)),
        );
    final out = leave;
    Widget row = Row(
      key: barKey,
      children: [
        if (start != null)
          circle(start!)
        else if (out != null)
          circle(Builder(
            builder: (context) => BarIcon(
              key: out.key,
              icon: out.icon,
              tooltip: out.tooltip,
              onTap: out.onTap == null ? null : (_) => out.onTap!(),
            ),
          ))
        else if (end != null)
          const SizedBox(width: Ui.action),
        Expanded(
          // Spread over the room between the ends; on a narrow phone with many buttons
          // they shrink together rather than overflow (the iPhone's own bars give way too).
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, a) in actions.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  circle(a),
                ],
              ],
            ),
          ),
        ),
        if (end != null) circle(end!) else if (out != null || start != null) const SizedBox(width: Ui.action),
      ],
    );
    if (onMedia) {
      final t = Theme.of(context);
      row = Theme(data: t.copyWith(colorScheme: t.colorScheme.copyWith(onSurface: Colors.white)), child: row);
    }
    if (!inset) return row;
    return Padding(
      padding: EdgeInsets.fromLTRB(Ui.side, 6, Ui.side, Ui.edge + MediaQuery.paddingOf(context).bottom),
      child: row,
    );
  }
}

/// The top of every viewer, as in Photos (owner 2026-10-29: one look for photos, videos,
/// notes, recordings and files): Back on the left, [center] (the date) in the middle, ⋯
/// on the right. Over a photo or video ([onMedia]) the glass is dark and the icons white.
class ViewerTopBar extends StatelessWidget {
  const ViewerTopBar({super.key, required this.back, required this.center, this.more, this.onMedia = false});

  final BarIcon back;
  final Widget center;
  /// ⋯; none (Recently deleted): the room stays so the date keeps the middle.
  final BarIcon? more;
  final bool onMedia;

  @override
  Widget build(BuildContext context) {
    // As big as the bottom bar's circles (owner 2026-10-29: smaller, they looked lost).
    Widget circle(Widget child) => SizedBox.square(
          dimension: Ui.action,
          child: onMedia ? GlassPill(child: Center(child: child)) : Glass(radius: Ui.action / 2, child: Center(child: child)),
        );
    Widget row = Row(
      children: [
        circle(back),
        Expanded(child: Center(child: center)),
        if (more != null) circle(more!) else const SizedBox(width: Ui.action),
      ],
    );
    if (onMedia) {
      final t = Theme.of(context);
      row = Theme(data: t.copyWith(colorScheme: t.colorScheme.copyWith(onSurface: Colors.white)), child: row);
    }
    return Padding(padding: const EdgeInsets.fromLTRB(10, 4, 10, 0), child: row);
  }
}
