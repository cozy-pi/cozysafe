import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// What keeps an open vault open. The vault screen locks after 2 minutes with no
/// activity; activity is any touch anywhere in the app (also on screens pushed above
/// the vault) and typing, which on phones produces no pointer or key events.
///
/// When the app itself sends the person to another app (share sheet, file or photo
/// picker), the vault stays open for 60 seconds: docs/ui.md, locking.
abstract final class LockGuard {
  static DateTime? _until;
  static void allowAway() => _until = DateTime.now().add(const Duration(seconds: 60));
  static bool get away => _until != null && DateTime.now().isBefore(_until!);
  static void clear() => _until = null;

  /// Set by the open vault screen; called on every touch and keystroke.
  static void Function()? onActivity;
  static void activity() => onActivity?.call();

  /// Set by a screen holding unsaved text (the note editor): the vault calls it
  /// before locking so nothing typed is lost.
  static Future<void> Function()? beforeLock;

  /// Text copied out of the vault: cleared from the clipboard after 60 s and on lock,
  /// unless something else has been copied since.
  static String? _copied;
  static Timer? _clipTimer;

  static void copied(String text) {
    _copied = text;
    _clipTimer?.cancel();
    _clipTimer = Timer(const Duration(seconds: 60), clearCopied);
  }

  static Future<void> clearCopied() async {
    _clipTimer?.cancel();
    final mine = _copied;
    _copied = null;
    if (mine == null) return;
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == mine) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {}
  }
}

/// How long the app has been away (Settings → "Lock as soon as I leave the app" off: the
/// vault locks once this reaches the auto-lock time). Two clocks, and the longer one
/// counts: a monotonic one, which moving the phone's date and time cannot change, and
/// the wall clock, which keeps counting while the phone sleeps (the monotonic one may
/// not). Setting the date back can therefore only make the vault lock sooner.
class AwayClock {
  AwayClock.start()
      : _mono = monotonic(),
        _wall = wall();

  static final _running = Stopwatch()..start();
  @visibleForTesting
  static Duration Function() monotonic = () => _running.elapsed;
  @visibleForTesting
  static DateTime Function() wall = DateTime.now;

  final Duration _mono;
  final DateTime _wall;

  Duration get elapsed {
    final mono = monotonic() - _mono;
    final wallGone = wall().difference(_wall);
    return wallGone > mono ? wallGone : mono;
  }
}
