import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import 'awake.dart';

/// The live part of a session: [waiting] until the other device proves it holds this
/// vault, then the number to compare while it syncs, then the result. Leaving before
/// the end cancels.
class SyncProgress extends StatefulWidget {
  const SyncProgress({super.key, required this.events, required this.onSynced, this.waiting, this.retry});
  final Stream<sync.SyncEvent> events;
  /// After an interruption: a fresh run (Google Drive), shown by "Continue".
  final Stream<sync.SyncEvent> Function()? retry;
  /// The vault changed: the screens behind reload.
  final VoidCallback onSynced;
  final Widget? waiting;

  @override
  State<SyncProgress> createState() => _SyncProgressState();
}

class _SyncProgressState extends State<SyncProgress> {
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
  };

  bool get _over => _last != null && !_running.contains(_last!.kind);

  @override
  void initState() {
    super.initState();
    _listen(widget.events);
  }

  void _listen(Stream<sync.SyncEvent> events) {
    Awake.set(true);
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
        _last = e;
        if (e.kind == sync.SyncStep.connected) _check = e.check;
      });
      if (_over) Awake.set(false);
      if (e.kind == sync.SyncStep.done) widget.onSynced();
    });
  }

  @override
  void dispose() {
    if (!_over) sync.p2PCancel();
    Awake.set(false);
    _sub?.cancel();
    super.dispose();
  }

  Widget _runningBody(AppLocalizations l, CsColors c, sync.SyncEvent e) {
    final title = switch (e.kind) {
      sync.SyncStep.receiving => l.syncReceiving(e.done.toString(), e.total.toString()),
      sync.SyncStep.sending => l.syncSending(e.done.toString(), e.total.toString()),
      _ => l.syncChecking,
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(title, key: const ValueKey('sync-progress'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      const SizedBox(height: 18),
      SizedBox(
        width: 240,
        child: LinearProgressIndicator(
          value: e.total > 0 ? e.done / e.total : null,
          minHeight: 6,
          // The black-and-white theme would draw track and bar alike.
          backgroundColor: c.border,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(height: 12),
      Text(l.syncKeepOpen, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 14)),
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
        sync.SyncStep.checking || sync.SyncStep.receiving || sync.SyncStep.sending => _runningBody(l, c, e),
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
            child: _over && _last?.kind == sync.SyncStep.interrupted && widget.retry != null
                ? FilledButton(
                    key: const ValueKey('sync-continue'),
                    onPressed: () {
                      setState(() => _last = null);
                      _listen(widget.retry!());
                    },
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
