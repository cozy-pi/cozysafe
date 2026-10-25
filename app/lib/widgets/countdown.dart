import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The red of a step that cannot be undone (the theme's own error colour is the ink,
/// which on a dark page made a white button with white text).
const dangerRed = Color(0xFFFF3B30);

/// The last chance before something that cannot be undone (owner 2026-10-25: deleting a
/// vault): a countdown of [seconds] with Cancel. True when it ran out, false if cancelled.
Future<bool> confirmCountdown(BuildContext context, {required String title, int seconds = 10}) async {
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Countdown(title: title, seconds: seconds),
  );
  return done == true;
}

class _Countdown extends StatefulWidget {
  const _Countdown({required this.title, required this.seconds});
  final String title;
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
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$_left',
              key: const ValueKey('countdown-left'),
              style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: dangerRed)),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: 1 - _t.value,
            color: dangerRed,
            backgroundColor: c.border,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
          Text(l.countdownNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.4)),
        ]),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('countdown-cancel'),
              onPressed: () {
                _cancelled = true;
                Navigator.of(context).pop(false);
              },
              child: Text(l.cancel),
            ),
          ),
        ],
      ),
    );
  }
}
