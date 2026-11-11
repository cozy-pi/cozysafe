import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// What keeps an open vault open. The vault screen locks after 2 minutes with no
/// activity; activity is any touch anywhere in the app (also on screens pushed above
/// the vault) and typing, which on phones produces no pointer or key events.
///
/// When the app itself sends the person to another app (share sheet, file or photo
/// picker), the vault stays open for a while: 60 seconds unless the caller says how
/// long ([forPicking], [afterCopy]); docs/security.md, leaving.
abstract final class LockGuard {
  static DateTime? _until;
  static void allowAway([Duration time = const Duration(seconds: 60)]) => _until = DateTime.now().add(time);
  static bool get away => _until != null && DateTime.now().isBefore(_until!);
  /// Until when leaving is allowed (null: it is not); read as the app leaves, so coming
  /// back is measured against the time it was given, not a fixed 60 seconds.
  static DateTime? get until => _until;
  static void clear() => _until = null;

  /// A photo or file picker: as long as the person needs to choose, with a cap (2026-11-11
  /// review: past 60 seconds the vault locked and the photos chosen were lost).
  static const forPicking = Duration(minutes: 10);

  /// After a password, account or code is copied: time to paste it in the app that asks
  /// and come back for the next one (2026-11-11 review: copy the password, paste it in
  /// Safari, back for the 2FA code meant Face ID and the opening again). Not in Top
  /// Secret Mode, which locks as it leaves.
  static const afterCopy = Duration(minutes: 2);

  /// Set by the open vault screen; called on every touch and keystroke.
  static void Function()? onActivity;
  static void activity() => onActivity?.call();

  static DateTime? _played;

  /// A video or recording playing is use, as recording is (2026-11-11 review: a long
  /// video locked the vault mid-way, nobody touches the screen while watching). Called
  /// on the player's every update; passed on at most every 15 seconds.
  static void playing() {
    final now = DateTime.now();
    if (_played != null && now.difference(_played!) < const Duration(seconds: 15)) return;
    _played = now;
    activity();
  }

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
