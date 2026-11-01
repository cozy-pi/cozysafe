import 'package:flutter/material.dart';

import '../theme.dart';

/// [work] with a card over the page saying what is under way, so a slow network call
/// never looks like nothing happened (owner 2026-11-01: deleting from Google Drive showed
/// nothing). The card cannot be dismissed; it goes when [work] ends, done or failed.
Future<T> whileWorking<T>(BuildContext context, String what, Future<T> Function() work) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var shown = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
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
              Flexible(child: Text(what, style: const TextStyle(fontSize: CsType.body))),
            ]),
          ),
        ),
      ),
    ),
  ).whenComplete(() => shown = false);
  try {
    return await work();
  } finally {
    if (shown && nav.mounted) nav.pop();
  }
}
