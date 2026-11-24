import 'package:flutter/material.dart';

import '../build_info.dart';
import '../theme.dart';

/// "beta", small, in a quiet pill: Cozy Safe Beta says which app it is on the lock
/// screen and beside the page's title (owner 2026-11-24). Nothing in Cozy Safe itself.
/// Not translated: it is the app's name.
class BetaTag extends StatelessWidget {
  const BetaTag({super.key});

  @override
  Widget build(BuildContext context) {
    if (!betaBuild) return const SizedBox.shrink();
    final ink = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: 'Beta',
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('beta-tag'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: ink.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: ink.withValues(alpha: .18)),
        ),
        child: Text('beta',
            style: TextStyle(fontSize: CsType.caption1, fontWeight: FontWeight.w700, letterSpacing: .4, color: ink.withValues(alpha: .7))),
      ),
    );
  }
}
