import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// One line of [showItemMenu].
class MenuEntry {
  const MenuEntry(this.icon, this.label, this.onTap, {this.danger = false, this.key});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  /// Delete and the like: the system red.
  final bool danger;
  final Key? key;
}

/// Where the finger last went down, so a menu opens next to what was held. Set by a
/// [MenuPointer] around a screen (owner 2026-10-22: a long press opens a menu, as in the
/// iPhone's Files app; selecting many goes through the Select button).
Offset _lastDown = Offset.zero;

/// Remembers where each touch lands, for [showItemMenu]. Put one around a screen.
class MenuPointer extends StatelessWidget {
  const MenuPointer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _lastDown = e.position,
        child: child,
      );
}

/// A small menu at the finger, the page dimmed and soft behind: the actions for one
/// item. In the page's own colour, a shade off it (like the lock screen's ⋯ menu), never
/// a white slab. Each entry closes the menu, then runs.
Future<void> showItemMenu(BuildContext context, {String? title, required List<MenuEntry> entries}) async {
  HapticFeedback.mediumImpact();
  final at = _lastDown;
  final picked = await showGeneralDialog<MenuEntry>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).closeButtonLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, _, _) => _Menu(at: at, title: title, entries: entries),
    transitionBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(a), child: child),
    ),
  );
  picked?.onTap();
}

class _Menu extends StatelessWidget {
  const _Menu({required this.at, required this.title, required this.entries});
  final Offset at;
  final String? title;
  final List<MenuEntry> entries;

  static const double _width = 250, _row = 48;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = CsColors.of(context);
    final fill = Color.alphaBlend(ink.withValues(alpha: dark ? .10 : .05), page);
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final height = entries.length * _row + (title == null ? 12 : 44);
    // Beside the finger, inside the screen: below it when there is room, else above.
    final left = (at.dx - _width / 2).clamp(12.0, size.width - _width - 12);
    final below = at.dy + 16;
    final top = below + height < size.height - pad.bottom - 12
        ? below
        : (at.dy - 16 - height).clamp(pad.top + 12, size.height - height - 12).toDouble();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: ColoredBox(color: page.withValues(alpha: .45)),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: _width,
          child: Material(
            key: const ValueKey('item-menu'),
            color: fill,
            elevation: 12,
            shadowColor: Colors.black45,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: ink.withValues(alpha: .10)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                      child: Text(title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  for (final e in entries)
                    InkWell(
                      key: e.key,
                      onTap: () => Navigator.of(context).pop(e),
                      child: SizedBox(
                        height: _row,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(e.label,
                                    style: TextStyle(
                                        fontSize: 16, color: e.danger ? recordRed(context) : ink, fontWeight: FontWeight.w500)),
                              ),
                              Icon(e.icon, size: 21, color: e.danger ? recordRed(context) : ink),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
