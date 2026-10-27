import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A page that is all rows and text (Settings, Sync, Recently deleted…) in a column a
/// person can read on a computer or an iPad: at most [maxWidth], in the middle, the page
/// colour on both sides (owner 2026-10-28: Settings stretched across a MacBook, a label
/// at one edge and its switch at the other, the middle empty). A phone is narrower than
/// that, so nothing changes there.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child});

  final Widget child;

  static const maxWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth <= maxWidth) return child;
          return Center(
            child: SizedBox(width: math.min(box.maxWidth, maxWidth), height: box.maxHeight, child: child),
          );
        },
      ),
    );
  }
}
