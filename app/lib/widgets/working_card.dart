import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme.dart';

/// [work] with a card over the page saying what is under way, so a slow network call
/// never looks like nothing happened (owner 2026-11-01: deleting from Google Drive showed
/// nothing). The card cannot be dismissed; it goes when [work] ends, done or failed.
/// With [live] the words follow it ("Getting 3 of 12 ready"), starting from [what].
Future<T> whileWorking<T>(
  BuildContext context,
  String what,
  Future<T> Function() work, {
  ValueListenable<String>? live,
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  // Its own route, so the end of the work closes this card and nothing else (a lock
  // screen that came on top meanwhile stays).
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    themes: InheritedTheme.capture(from: context, to: nav.context),
    builder: (context) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          key: const ValueKey('working-card'),
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(Ui.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 14),
              Flexible(
                child: live == null
                    ? Text(what, style: const TextStyle(fontSize: CsType.body))
                    : ValueListenableBuilder<String>(
                        valueListenable: live,
                        builder: (context, text, _) => Text(text, style: const TextStyle(fontSize: CsType.body)),
                      ),
              ),
            ]),
          ),
        ),
      ),
    ),
  );
  nav.push(route);
  try {
    return await work();
  } finally {
    if (nav.mounted) {
      if (route.isCurrent) {
        nav.pop();
      } else if (route.isActive) {
        nav.removeRoute(route);
      }
    }
  }
}
