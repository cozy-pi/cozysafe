import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'vault_bar.dart' show showCard;

/// The last chance before something that cannot be undone (owner 2026-10-25: deleting a
/// vault): a countdown of [seconds] with Cancel. True when it ran out, false if cancelled.
Future<bool> confirmCountdown(BuildContext context, {required String title, int seconds = 10}) async {
  // A card as every short question (docs/design-language.md); a tap outside does not
  // stop it, only Cancel does.
  final done = await showCard<bool>(
    context,
    title: title,
    dismissible: false,
    builder: (_) => _Countdown(seconds: seconds),
  );
  return done == true;
}

class _Countdown extends StatefulWidget {
  const _Countdown({required this.seconds});
  final int seconds;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> with SingleTickerProviderStateMixin {
  // Frames, not a Timer: nothing is left pending if the page goes away.
  late final _t = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))
    ..addListener(() => setState(() {}))
    ..forward().whenComplete(() {
      // Only while on top: closed by a lock, its last frames must not pop the lock screen.
      if (mounted && !_cancelled && (ModalRoute.of(context)?.isCurrent ?? false)) Navigator.of(context).pop(true);
    });
  bool _cancelled = false;

  int get _left => (widget.seconds * (1 - _t.value)).ceil().clamp(1, widget.seconds);

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final red = recordRed(context);
    return PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('$_left',
              key: const ValueKey('countdown-left'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: CsType.display, fontWeight: FontWeight.w800, color: red, fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: 1 - _t.value,
            color: red,
            backgroundColor: c.border,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
          Text(l.countdownNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('countdown-cancel'),
            onPressed: () {
              _cancelled = true;
              Navigator.of(context).pop(false);
            },
            child: Text(l.cancel),
          ),
        ]),
      ),
    );
  }
}
