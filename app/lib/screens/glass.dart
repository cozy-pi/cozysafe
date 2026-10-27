import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../theme.dart' show CsType;

/// Controls over a photo or video (full screen viewers): white on a bright picture
/// vanished (owner 2026-10-21), so each sits on its own dark frosted glass.
final glassButton = TextButton.styleFrom(
  foregroundColor: Colors.white,
  iconSize: 26,
  minimumSize: const Size(0, 52),
  padding: const EdgeInsets.symmetric(horizontal: 22),
  shape: const StadiumBorder(),
);

/// Delete over a photo or video: red like Delete everywhere else (owner 2026-10-25), the
/// dark theme's red, which reads on the dark glass.
final glassDelete = glassButton.copyWith(foregroundColor: const WidgetStatePropertyAll(Color(0xFFFF453A)));

/// Dark frosted glass behind a control over a photo or video, so it reads on any picture.
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    // Shares one blur with the other pills under a [BackdropGroup] (the photo viewer).
    child: BackdropFilter.grouped(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .38),
          // A faint rim keeps the shape visible on a dark picture too.
          border: Border.all(color: Colors.white.withValues(alpha: .14)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: child,
      ),
    ),
  );
}

/// The label of a [glassButton] (styled here: a TextButton's textStyle loses the font).
Text glassLabel(String text) => Text(text, style: const TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w600));
