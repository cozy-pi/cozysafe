import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../prefs.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';

/// A vault kept only on this device is lost with it (owner 2026-10-24): until it is also
/// somewhere else (another device, Google Drive, a backup file), the home page says so
/// once, with a way to fix it. Closing it hides it for 30 days.
class SecondPlaceNudge extends StatefulWidget {
  const SecondPlaceNudge({super.key, required this.onAdd});

  /// Opens the ways to keep a second copy (Sync).
  final VoidCallback onAdd;

  static const _hiddenKey = 'second-place-hidden';
  static const _hideFor = Duration(days: 30);

  /// For the mockup renders: show it whatever the log says.
  static bool debugShow = false;

  @override
  State<SecondPlaceNudge> createState() => _SecondPlaceNudgeState();
}

class _SecondPlaceNudgeState extends State<SecondPlaceNudge> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (SecondPlaceNudge.debugShow) {
      setState(() => _show = true);
      return;
    }
    final hidden = int.tryParse(Prefs.read(SecondPlaceNudge._hiddenKey) ?? '');
    if (hidden != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(hidden)) < SecondPlaceNudge._hideFor) {
      return;
    }
    // A backup file made, or any sync that went through, is a second place.
    if (Prefs.read('last-backup') != null) return;
    try {
      final log = await sync.connectionLog();
      if (log.any((line) => line.split('|').elementAtOrNull(3) == 'ok')) return;
    } catch (_) {
      return; // no log to read: say nothing rather than nag
    }
    if (mounted) setState(() => _show = true);
  }

  void _hide() {
    Prefs.write(SecondPlaceNudge._hiddenKey, '${DateTime.now().millisecondsSinceEpoch}');
    setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    const amber = Color(0xFFFF9F0A);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        key: const ValueKey('second-place'),
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: amber.withValues(alpha: .16), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.phonelink_erase_rounded, color: amber),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.secondPlaceTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(l.secondPlaceBody, style: TextStyle(color: c.muted, fontSize: 14, height: 1.35)),
                const SizedBox(height: 6),
                TextButton(
                  key: const ValueKey('second-place-add'),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36)),
                  onPressed: widget.onAdd,
                  child: Text(l.secondPlaceAdd, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
            IconButton(
              key: const ValueKey('second-place-hide'),
              tooltip: l.close,
              icon: Icon(Icons.close_rounded, color: c.muted, size: 20),
              onPressed: _hide,
            ),
          ]),
        ),
      ),
    );
  }
}
