import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../screens/file_view.dart' show fileSize;
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import 'awake.dart';

/// The live part of a session: [waiting] until the other device proves it holds this
/// vault, then the number to compare while it syncs, then the result. Leaving before
/// the end cancels. A Google Drive run stopped while the app was away (phone locked)
/// continues by itself when the person comes back.
/// Who is on the other end, to draw and name it.
enum SyncPlace { drive, device }

class SyncProgress extends StatefulWidget {
  const SyncProgress({
    super.key,
    required this.events,
    required this.onSynced,
    this.waiting,
    this.retry,
    this.place = SyncPlace.device,
  });
  final Stream<sync.SyncEvent> events;
  final SyncPlace place;

  /// For the mockup renders: a steady speed (bytes and items a second).
  static (double, double)? debugRate;
  /// After an interruption: a fresh run (Google Drive), shown by "Continue".
  final Stream<sync.SyncEvent> Function()? retry;
  /// The vault changed: the screens behind reload.
  final VoidCallback onSynced;
  final Widget? waiting;

  @override
  State<SyncProgress> createState() => _SyncProgressState();
}

class _SyncProgressState extends State<SyncProgress> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  StreamSubscription<sync.SyncEvent>? _sub;
  sync.SyncEvent? _last;
  int? _check;
  /// A device with another vault tried while this one waits (it keeps waiting).
  bool _rejected = false;
  /// A device has just connected and is proving the vault (host only).
  bool _knock = false;

  static const _running = {
    sync.SyncStep.connected,
    sync.SyncStep.checking,
    sync.SyncStep.receiving,
    sync.SyncStep.sending,
    sync.SyncStep.removing,
  };

  bool get _over => _last != null && !_running.contains(_last!.kind);

  bool get _canContinue => _over && _last?.kind == sync.SyncStep.interrupted && widget.retry != null;

  bool _started = false;
  /// The app left the screen (phone locked, another app) since the last automatic
  /// Continue; iOS stops a sync soon after.
  bool _wasAway = false;
  /// When the app last came back to the screen.
  DateTime? _backAt;
  DateTime? _notifiedAt;
  sync.SyncStep? _notifiedKind;
  /// The dots running between the two ends.
  late final AnimationController _flow = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  /// Recent (time, bytes, items) of the step under way, for the speed.
  final _samples = <(DateTime, int, int)>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than initState: the notification text needs the language.
    if (_started) return;
    _started = true;
    _listen(widget.events);
  }

  void _listen(Stream<sync.SyncEvent> events) {
    Awake.set(true);
    _notify(null);
    _sub?.cancel();
    _sub = events.listen((e) {
      if (!mounted) return;
      if (e.kind == sync.SyncStep.rejected || e.kind == sync.SyncStep.knock) {
        setState(() {
          _knock = e.kind == sync.SyncStep.knock;
          if (!_knock) _rejected = true;
        });
        return;
      }
      setState(() {
        if (_last?.kind != e.kind) _samples.clear();
        _last = e;
        if (e.kind == sync.SyncStep.connected) _check = e.check;
        _samples.add((DateTime.now(), e.bytes.toInt(), e.done));
        // A few seconds back is enough for a steady figure.
        final from = DateTime.now().subtract(const Duration(seconds: 4));
        while (_samples.length > 2 && _samples.first.$1.isBefore(from)) {
          _samples.removeAt(0);
        }
      });
      if (_over) {
        Awake.set(false);
      } else {
        _notify(e);
      }
      if (e.kind == sync.SyncStep.done) widget.onSynced();
      if (e.kind == sync.SyncStep.interrupted) _autoContinue();
    }, onError: (Object _) {
      // The stream itself broke (the app was suspended mid-way): the same as an
      // interruption, which the engine's journal makes safe to continue.
      if (!mounted) return;
      setState(() => _last = sync.SyncEvent(kind: sync.SyncStep.interrupted, check: 0, received: 0, sent: 0, removed: 0, copies: 0, done: 0, total: 0, bytes: BigInt.zero, bytesTotal: BigInt.zero));
      Awake.set(false);
      _autoContinue();
    });
  }

  void _continue() {
    setState(() => _last = null);
    _listen(widget.retry!());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _wasAway = true;
    } else if (state == AppLifecycleState.resumed) {
      _backAt = DateTime.now();
      _autoContinue();
    }
  }

  /// Back from being away and the run was interrupted (on return, or just after it, as
  /// the dropped connection surfaces): Continue once without a tap. The button stays
  /// for any other interruption.
  void _autoContinue() {
    final back = _backAt;
    if (!mounted || !_wasAway || !_canContinue || back == null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    if (DateTime.now().difference(back) > const Duration(seconds: 30)) return;
    _wasAway = false;
    _continue();
  }

  /// The Android notification (lib/sync/awake.dart): at most about twice a second, and
  /// at once when the step changes.
  void _notify(sync.SyncEvent? e) {
    final now = DateTime.now();
    final last = _notifiedAt;
    if (e != null && e.kind == _notifiedKind && last != null && now.difference(last) < const Duration(milliseconds: 500)) return;
    _notifiedAt = now;
    _notifiedKind = e?.kind;
    final l = AppLocalizations.of(context);
    Awake.progress(
      title: l.syncNotifyTitle,
      text: e == null ? l.syncWorking : _title(l, e),
      channel: l.syncNotifyChannel,
      done: e?.done ?? 0,
      total: e?.total ?? 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flow.dispose();
    if (!_over) sync.p2PCancel();
    Awake.set(false);
    _sub?.cancel();
    super.dispose();
  }

  static String _title(AppLocalizations l, sync.SyncEvent e) => switch (e.kind) {
    sync.SyncStep.receiving => l.syncReceiving(e.done.toString(), e.total.toString()),
    sync.SyncStep.sending => l.syncSending(e.done.toString(), e.total.toString()),
    sync.SyncStep.checking => l.syncChecking,
    sync.SyncStep.removing => l.syncRemoving,
    _ => l.syncWorking,
  };

  /// Bytes and items a second over the recent samples, or null before there is enough.
  (double, double)? get _rate {
    if (SyncProgress.debugRate != null) return SyncProgress.debugRate;
    if (_samples.length < 2) return null;
    final (t0, b0, i0) = _samples.first;
    final (t1, b1, i1) = _samples.last;
    final secs = t1.difference(t0).inMilliseconds / 1000;
    if (secs < 1) return null;
    return ((b1 - b0) / secs, (i1 - i0) / secs);
  }

  Widget _runningBody(AppLocalizations l, CsColors c, sync.SyncEvent e) {
    final drive = widget.place == SyncPlace.drive;
    final title = switch (e.kind) {
      sync.SyncStep.sending => drive ? l.syncSendingDrive : l.syncSendingDevice,
      sync.SyncStep.receiving => drive ? l.syncReceivingDrive : l.syncReceivingDevice,
      sync.SyncStep.removing => drive ? l.syncRemovingDrive : l.syncRemovingDevice,
      _ => drive ? l.syncCheckingDrive : l.syncCheckingDevice,
    };
    final bytes = e.bytes.toInt();
    final bytesTotal = e.bytesTotal.toInt();
    final rate = _rate;
    String? left;
    if (rate != null) {
      final secs = bytesTotal > 0 && rate.$1 > 0
          ? (bytesTotal - bytes) / rate.$1
          : rate.$2 > 0
              ? (e.total - e.done) / rate.$2
              : null;
      if (secs != null) left = secs < 60 ? l.syncLeftUnderMinute : l.syncLeftMinutes((secs / 60).ceil());
    }
    final small = TextStyle(color: c.muted, fontSize: 14, fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Ends(
        flow: _flow,
        place: widget.place,
        // Toward this phone when bringing in, away from it when sending.
        direction: switch (e.kind) {
          sync.SyncStep.receiving => -1,
          sync.SyncStep.sending || sync.SyncStep.removing => 1,
          _ => 0,
        },
      ),
      const SizedBox(height: 26),
      Text(title, key: const ValueKey('sync-progress'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(e.kind == sync.SyncStep.removing ? l.syncRemovingWhat : l.syncWhat, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 14.5, height: 1.35)),
      const SizedBox(height: 22),
      LinearProgressIndicator(
        value: bytesTotal > 0 ? (bytes / bytesTotal).clamp(0, 1) : (e.total > 0 ? e.done / e.total : null),
        minHeight: 8,
        // The black-and-white theme would draw track and bar alike.
        backgroundColor: c.border,
        borderRadius: BorderRadius.circular(4),
      ),
      const SizedBox(height: 10),
      if (e.total > 0)
        Row(children: [
          Text(l.syncItems(e.done, e.total), key: const ValueKey('sync-items'), style: small),
          const Spacer(),
          if (e.kind != sync.SyncStep.removing)
          Text(
            bytesTotal > 0 ? '${fileSize(BigInt.from(bytes))} / ${fileSize(BigInt.from(bytesTotal))}' : fileSize(BigInt.from(bytes)),
            key: const ValueKey('sync-bytes'),
            style: small,
          ),
        ]),
      if (rate != null) ...[
        const SizedBox(height: 4),
        Row(children: [
          Text('${fileSize(BigInt.from(rate.$1.round()))}/s', key: const ValueKey('sync-speed'), style: small),
          const Spacer(),
          if (left != null) Text(left, style: small),
        ]),
      ],
      // Android keeps going with the phone locked (a notification shows it, when that service
      // is on); iOS does not.
      if (Device.iOS || (Device.android && !Awake.androidSyncService)) ...[
        const SizedBox(height: 18),
        Text(l.syncKeepOpen, key: const ValueKey('sync-keep-open'), textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 14)),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final e = _last;
    Widget body;
    if (e == null) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        if (_knock) _Status(icon: null, title: l.syncKnock) else widget.waiting ?? _Status(icon: null, title: l.syncWorking),
        if (_rejected) ...[
          const SizedBox(height: 16),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.warning_amber_rounded, size: 20, color: Color(0xFFFF9500)),
            const SizedBox(width: 8),
            Flexible(child: Text(l.syncRejected, key: const ValueKey('sync-rejected'), style: const TextStyle(fontSize: 14, height: 1.3))),
          ]),
        ],
      ]);
    } else {
      body = switch (e.kind) {
        sync.SyncStep.connected => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.syncConnected, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 18),
              Text(
                (_check ?? 0).toString().padLeft(4, '0'),
                key: const ValueKey('sync-check'),
                style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, letterSpacing: 10, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 8),
              Text(l.syncCheckNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.35)),
              const SizedBox(height: 28),
              const SizedBox(width: 160, child: LinearProgressIndicator()),
              const SizedBox(height: 10),
              Text(l.syncWorking, style: TextStyle(color: c.muted)),
            ],
          ),
        sync.SyncStep.done => _Status(
            icon: Icons.check_circle_rounded,
            color: const Color(0xFF34C759),
            title: l.syncDone,
            lines: [
              l.syncDoneCounts(e.received.toString(), e.sent.toString()),
              if (e.copies > 0) l.syncDoneCopies(e.copies.toString()),
            ],
          ),
        sync.SyncStep.expired => _Status(icon: Icons.timer_off_outlined, title: l.syncExpired),
        sync.SyncStep.cancelled => _Status(icon: Icons.close_rounded, title: l.syncCancelled),
        sync.SyncStep.locked => _Status(icon: Icons.lock_outline_rounded, title: l.syncLocked),
        sync.SyncStep.otherVault => _Status(icon: Icons.no_encryption_gmailerrorred_outlined, color: const Color(0xFFFF9500), title: l.syncOtherVault),
        sync.SyncStep.unreachable => _Status(icon: Icons.wifi_off_rounded, color: const Color(0xFFFF3B30), title: l.syncUnreachable),
        sync.SyncStep.failed => _Status(icon: Icons.error_outline_rounded, color: const Color(0xFFFF3B30), title: l.syncFailed),
        sync.SyncStep.signIn => _Status(icon: Icons.account_circle_outlined, color: const Color(0xFFFF9500), title: l.syncSignInAgain),
        sync.SyncStep.wrongWords => _Status(icon: Icons.key_off_outlined, color: const Color(0xFFFF9500), title: l.restoreWrongWords),
        sync.SyncStep.wrongPassword => _Status(icon: Icons.password_rounded, color: const Color(0xFFFF9500), title: l.wrongPassword),
        sync.SyncStep.interrupted => _Status(icon: Icons.pause_circle_outline_rounded, color: const Color(0xFFFF9500), title: l.syncInterrupted),
        sync.SyncStep.checking || sync.SyncStep.receiving || sync.SyncStep.sending || sync.SyncStep.removing =>
          _runningBody(l, c, e),
        // Never the last word (handled above); kept for an exhaustive switch.
        sync.SyncStep.rejected || sync.SyncStep.knock => _Status(icon: null, title: l.syncWorking),
      };
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        children: [
          Expanded(child: Center(child: SingleChildScrollView(child: body))),
          SizedBox(
            width: double.infinity,
            child: _canContinue
                ? FilledButton(
                    key: const ValueKey('sync-continue'),
                    onPressed: _continue,
                    child: Text(l.syncContinue),
                  )
                : _over
                ? FilledButton(
                    key: const ValueKey('sync-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l.close),
                  )
                : OutlinedButton(
                    key: const ValueKey('sync-cancel'),
                    onPressed: () {
                      sync.p2PCancel();
                      Navigator.of(context).pop();
                    },
                    child: Text(l.cancel),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.icon, this.color, required this.title, this.lines = const []});
  final IconData? icon;
  final Color? color;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon == null) const CircularProgressIndicator() else Icon(icon, size: 64, color: color ?? c.muted),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.3)),
        for (final s in lines) ...[
          const SizedBox(height: 8),
          Text(s, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.35)),
        ],
      ],
    );
  }
}

/// This phone and the other end (Google Drive or another device), with dots running
/// the way the items go.
class _Ends extends StatelessWidget {
  const _Ends({required this.flow, required this.place, required this.direction});
  final Animation<double> flow;
  final SyncPlace place;
  /// 1: from this phone to the other end; -1: back; 0: looking (the dots pulse).
  final int direction;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final c = CsColors.of(context);
    Widget end(IconData icon, Color tint) => Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(color: tint.withValues(alpha: .14), shape: BoxShape.circle),
          child: Icon(icon, size: 38, color: tint),
        );
    const blue = Color(0xFF0A84FF);
    const green = Color(0xFF30D158);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      end(Icons.smartphone_rounded, ink),
      SizedBox(
        width: 96,
        height: 20,
        child: AnimatedBuilder(
          animation: flow,
          builder: (context, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < 5; i++)
                Builder(builder: (context) {
                  // Each dot lights up in turn along the direction of travel.
                  final pos = direction >= 0 ? i / 5 : (4 - i) / 5;
                  final phase = (flow.value - pos) % 1.0;
                  final lit = direction == 0 ? (0.5 + 0.5 * (1 - (flow.value * 2 - 1).abs())) : (1 - phase).clamp(0.0, 1.0);
                  return Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(c.border, place == SyncPlace.drive ? blue : green, lit),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
      place == SyncPlace.drive ? end(Icons.cloud_rounded, blue) : end(Icons.phone_android_rounded, green),
    ]);
  }
}
