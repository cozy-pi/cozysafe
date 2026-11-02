import 'package:flutter/material.dart';

/// A swipe from the left edge that does what the screen's own back button does, for
/// steps inside one page (new vault steps, an open group) where the system swipe has no
/// route to pop (docs/ui.md: back button and swipe back go together).
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({
    super.key,
    required this.onBack,
    required this.child,
    this.enabled = true,
    this.bottomGap = 0,
    this.follow = false,
  });

  final VoidCallback onBack;
  final Widget child;
  final bool enabled;
  /// Leave the bottom of the edge alone (the add column's slide starts there).
  final double bottomGap;
  /// The page moves with the finger and slides back when let go too soon, as a pushed
  /// page does (owner 2026-11-03: the new vault steps had a back button but no swipe
  /// that could be felt).
  final bool follow;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> with SingleTickerProviderStateMixin {
  double _dx = 0;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _dx = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _end(DragEndDetails d) {
    final width = context.size?.width ?? 400;
    final go = widget.follow
        ? (_dx > width * .3 || (d.primaryVelocity ?? 0) > 400)
        : (_dx > 60 || (d.primaryVelocity ?? 0) > 400);
    if (go) {
      setState(() => _dx = 0);
      widget.onBack();
    } else if (widget.follow && _dx > 0) {
      _from = _dx;
      _back.forward(from: 0);
    } else {
      _dx = 0;
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          widget.follow && _dx > 0
              ? Transform.translate(offset: Offset(_dx, 0), child: widget.child)
              : widget.child,
          if (widget.enabled)
            Positioned(
              left: 0,
              top: 0,
              bottom: widget.bottomGap,
              width: widget.follow ? 28 : 20,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) {
                  _back.stop();
                  _dx = 0;
                },
                onHorizontalDragUpdate: (d) {
                  final dx = (_dx + d.delta.dx).clamp(0.0, double.infinity);
                  widget.follow ? setState(() => _dx = dx) : _dx = dx;
                },
                onHorizontalDragEnd: _end,
              ),
            ),
        ],
      );
}
