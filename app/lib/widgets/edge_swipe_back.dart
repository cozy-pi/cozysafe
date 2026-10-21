import 'package:flutter/material.dart';

/// A swipe from the left edge that does what the screen's own back button does, for
/// steps inside one page (new vault steps, an open group) where the system swipe has no
/// route to pop (docs/ui.md: back button and swipe back go together).
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({super.key, required this.onBack, required this.child, this.enabled = true, this.bottomGap = 0});

  final VoidCallback onBack;
  final Widget child;
  final bool enabled;
  /// Leave the bottom of the edge alone (the add column's slide starts there).
  final double bottomGap;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          widget.child,
          if (widget.enabled)
            Positioned(
              left: 0,
              top: 0,
              bottom: widget.bottomGap,
              width: 20,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _dx = 0,
                onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
                onHorizontalDragEnd: (d) {
                  if (_dx > 60 || (d.primaryVelocity ?? 0) > 400) widget.onBack();
                },
              ),
            ),
        ],
      );
}
