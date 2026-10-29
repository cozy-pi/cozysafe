import 'dart:async';

import 'package:flutter/widgets.dart';

import '../error_log.dart';
import '../lock_resume.dart';
import '../prefs.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import 'drive.dart';
import 'status.dart';
import 'sync_log.dart';
import 'wifi.dart';

/// Google Drive kept up to date without a tap (owner 2026-10-27), while the vault is open:
/// when it opens or comes back, a little after something changes here (at once when the
/// app is left), and a cheap look every minute for the other devices' changes. On by default once a Google account is added (the card that
/// adds it has the switch), and in Settings → Sync. Never while the app is closed: the
/// phone would not let it run, and it would cost battery.
abstract final class AutoSync {
  static const pref = 'drive-auto-sync';
  static const wifiPref = 'drive-auto-wifi-only';

  /// After a change here, wait this long for more (twenty photos added: one sync).
  static const settle = Duration(seconds: 30);

  /// While the vault stays open, look for the other devices' changes this often: a cheap
  /// look at their small heads on Drive (one request), a full sync only when one moved.
  static const every = Duration(minutes: 1);

  /// A full sync at least this often anyway: a device of an older version writes no head,
  /// and one that wrote its journal but not yet its head is seen this way.
  static const fullEvery = Duration(minutes: 30);

  /// Set when the account is added (on unless the person turns it off there); an account
  /// added before automatic sync existed stays by hand until turned on.
  static bool get enabled => Prefs.read(pref) == '1';
  static set enabled(bool on) {
    Prefs.write(pref, on ? '1' : '0');
    _tick();
    if (on) run('on');
  }

  /// Only on Wi-Fi, not on mobile data (owner: a video over 4G costs).
  static bool get wifiOnly => Prefs.read(wifiPref) == '1';
  static set wifiOnly(bool on) => Prefs.write(wifiPref, on ? '1' : '0');

  /// A run under way (looking included).
  static final running = ValueNotifier(false);

  /// Items going to or coming from Drive right now: the only time the home page shows
  /// "syncing" (owner 2026-10-28: not while it merely looks for changes).
  static final moving = ValueNotifier(false);

  /// Something changed here and has not reached Drive yet, or the last run was cut off:
  /// "not synced" on the home page until a sync goes through.
  static final pending = ValueNotifier(false);

  /// When Google Drive last synced in full (automatic or by hand), for the line on the
  /// home page; kept across starts.
  static final lastOk = ValueNotifier<DateTime?>(_readTime());

  /// The last automatic sync failed (not merely cut off by the network): a red dot on
  /// Settings and on the Sync row until a sync goes through (owner 2026-10-27).
  static final failed = ValueNotifier<bool>(Prefs.read(_failedPref) == '1');

  static const _okPref = 'drive-auto-last-ok';
  static const _failedPref = 'drive-auto-failed';

  static DateTime? _readTime() {
    final ms = int.tryParse(Prefs.read(_okPref) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// A sync with Google Drive went through.
  static void succeeded() {
    final now = DateTime.now();
    lastOk.value = now;
    Prefs.write(_okPref, '${now.millisecondsSinceEpoch}');
    pending.value = false;
    _cutOff = 0;
    _fail(false);
  }

  /// Runs cut off in a row. One now and then is the network going (nothing wrong); this
  /// many in a row is a problem the person should see: every run hung on a Wi-Fi with
  /// broken IPv6 for an afternoon with nothing on screen (owner 2026-10-29).
  static int _cutOff = 0;
  static const cutOffShown = 3;

  /// The app left the screen during this run: a run cut off then is the system's doing,
  /// not counted in [_cutOff].
  static bool _wentAway = false;

  static void _fail(bool on) {
    if (failed.value == on) return;
    failed.value = on;
    Prefs.write(_failedPref, on ? '1' : '0');
  }

  /// Syncs by hand open: none of these starts meanwhile.
  static int _held = 0;
  static void hold() => _held++;
  static void release() => _held = _held > 0 ? _held - 1 : 0;

  /// Once no run is under way (a sync by hand waits for one to end, not to clash).
  static Future<void> idle() async {
    while (running.value) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static VoidCallback? _onSynced;
  static AppLifecycleListener? _life;
  static Timer? _settle;
  static Timer? _every;
  static int? _seen;
  static bool _ours = false;

  /// The vault opened: sync now, then every few minutes. [onSynced] reloads its items.
  static void start({required VoidCallback onSynced}) {
    _onSynced = onSynced;
    _seen = null;
    _tick();
    vaultLock.addListener(_lockChanged);
    _life?.dispose();
    _life = AppLifecycleListener(
      // Leaving with a change not sent yet: send it now, before the vault locks, rather
      // than at the next opening (iOS gives an app leaving a few seconds).
      onInactive: () {
        if (_settle?.isActive ?? false) run('leave');
      },
      onHide: () => _wentAway = true,
      // Back without the lock in between: the others may have changed meanwhile.
      onResume: () {
        if (!vaultLock.locked) _look('back');
      },
    );
    run('open');
  }

  /// The every-few-minutes look, only while on and a vault is open.
  static void _tick() {
    final want = enabled && _onSynced != null;
    if (want && _every == null) _every = Timer.periodic(every, (_) => _look('minute'));
    if (!want) {
      _every?.cancel();
      _every = null;
    }
  }

  /// The vault closed.
  static void stop() {
    _onSynced = null;
    _settle?.cancel();
    _every?.cancel();
    _settle = _every = null;
    vaultLock.removeListener(_lockChanged);
    _life?.dispose();
    _life = null;
  }

  /// Opened again after the lock: the others may have changed meanwhile.
  static void _lockChanged() {
    if (!vaultLock.locked) run('unlock');
  }

  /// The vault's items as just listed: when they differ from the last list (and the
  /// difference is not a sync's own), something changed here, and a sync follows soon.
  static void seen(List<rust.ItemInfo> items) {
    final sig = Object.hashAll([for (final it in items) Object.hash(it.id, it.modifiedMs, it.deletedMs)]);
    final before = _seen;
    _seen = sig;
    if (_ours) {
      _ours = false;
      return;
    }
    if (before != null && before != sig) {
      pending.value = true;
      if (enabled) changed();
    }
  }

  /// Something changed here.
  static void changed() {
    _settle?.cancel();
    _settle = Timer(settle, () => run('change'));
  }

  /// The every-minute look: a full sync when it is due anyway or when another device's
  /// head moved; otherwise nothing more than one small request.
  static Future<void> _look(String why) async {
    if (!enabled || running.value || _onSynced == null || vaultLock.locked) return;
    if (_held > 0 || syncStatus.value != null || driveAccount == null) return;
    final last = lastOk.value;
    if (last == null || DateTime.now().difference(last) >= fullEvery) return run('$why-due');
    if (wifiOnly && !await onWifi()) return SyncLog.add('look', 'skip-mobile-data');
    final session = await driveSignInQuietly();
    if (session == null) return SyncLog.add('look', 'skip-no-sign-in');
    if (running.value || _onSynced == null || vaultLock.locked) return;
    bool changed;
    try {
      changed = await sync.driveChanged(token: session.token);
      SyncLog.add('look', changed ? 'moved' : 'same');
    } catch (e) {
      changed = true; // unsure: the full sync tells
      SyncLog.add('look', 'unsure-${e.runtimeType}');
    }
    if (changed) await run('$why-moved');
  }

  /// How a run can end other than done (each written to [SyncLog]).
  static const _ends = {
    sync.SyncStep.interrupted,
    sync.SyncStep.failed,
    sync.SyncStep.signIn,
    sync.SyncStep.locked,
    sync.SyncStep.cancelled,
    sync.SyncStep.driveFull,
  };

  static const _moves = {sync.SyncStep.receiving, sync.SyncStep.sending, sync.SyncStep.removing, sync.SyncStep.repairing};

  /// One quiet sync, when everything allows it; otherwise nothing (the next chance comes).
  static Future<void> run(String why) async {
    _settle?.cancel();
    final skip = !enabled
        ? 'off'
        : running.value
            ? 'busy'
            : _onSynced == null
                ? 'closed'
                : vaultLock.locked
                    ? 'locked'
                    : _held > 0 || syncStatus.value != null
                        ? 'by-hand' // a sync by hand is on
                        : driveAccount == null
                            ? 'no-account'
                            : null;
    if (skip != null) return SyncLog.add('run', '$why-skip-$skip');
    if (wifiOnly && !await onWifi()) return SyncLog.add('run', '$why-skip-mobile-data');
    final session = await driveSignInQuietly();
    if (session == null) return SyncLog.add('run', '$why-skip-no-sign-in');
    if (_onSynced == null || vaultLock.locked) return SyncLog.add('run', '$why-skip-locked');
    SyncLog.add('run', 'start-$why');
    final watch = Stopwatch()..start();
    running.value = true;
    _wentAway = false;
    var changes = false;
    var ended = false;
    try {
      await for (final e in sync.driveSync(token: session.token)) {
        if (_moves.contains(e.kind) && e.total > 0) moving.value = true;
        if (e.kind == sync.SyncStep.interrupted) {
          pending.value = true;
          if (!_wentAway && ++_cutOff >= cutOffShown) {
            ErrorLog.add('auto-sync', 'interrupted-$_cutOff');
            _fail(true);
          }
        }
        if (e.kind == sync.SyncStep.done) {
          changes = e.received + e.removed + e.copies > 0;
          succeeded();
          SyncLog.add('run', 'done-r${e.received}-s${e.sent}-x${e.removed}-${watch.elapsedMilliseconds}ms');
          ended = true;
        } else if (_ends.contains(e.kind)) {
          SyncLog.add('run', '${e.kind.name}${e.code.isEmpty ? '' : '-${e.code}'}-${watch.elapsedMilliseconds}ms');
          ended = true;
        }
        if (e.kind == sync.SyncStep.signIn) {
          ErrorLog.add('auto-sync', 'sign-in');
          _fail(true);
        }
        if (e.kind == sync.SyncStep.failed) {
          ErrorLog.add('auto-sync', e.code.isEmpty ? 'failed' : e.code);
          _fail(true);
        }
        // Interrupted (the network went): nothing is wrong, the next run goes on, unless
        // it keeps happening ([cutOffShown]).
      }
    } catch (e) {
      ErrorLog.add('auto-sync', e.runtimeType.toString());
      SyncLog.add('run', 'threw-${e.runtimeType}');
      ended = true;
      _fail(true);
    } finally {
      if (!ended) SyncLog.add('run', 'no-end-${watch.elapsedMilliseconds}ms');
      running.value = false;
      moving.value = false;
    }
    if (changes) {
      _ours = true; // the reload that follows is the sync's, not a change here
      _onSynced?.call();
    }
  }
}
