import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import 'progress.dart';
import 'qr_view.dart';

/// This device waits at [address] (already allowed by the person) and shows the code.
class HostSyncPage extends StatefulWidget {
  const HostSyncPage({super.key, required this.address, required this.mirror, required this.onSynced});
  final String address;
  /// A private folder for the sealed copy the other device reads (emptied after).
  final String mirror;
  final VoidCallback onSynced;

  /// For the mockup renders: a code without starting anything.
  static sync.Hosting? debugHosting;

  @override
  State<HostSyncPage> createState() => _HostSyncPageState();
}

class _HostSyncPageState extends State<HostSyncPage> {
  sync.Hosting? _hosting;
  Stream<sync.SyncEvent>? _events;
  bool _failed = false;
  late DateTime _until;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final h = HostSyncPage.debugHosting ?? await sync.p2PHostStart(ip: widget.address, mirror: widget.mirror);
      if (!mounted) {
        sync.p2PCancel();
        return;
      }
      _until = DateTime.now().add(Duration(seconds: h.seconds));
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _hosting = h;
        _events = HostSyncPage.debugHosting != null ? const Stream.empty() : sync.p2PHostRun();
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_events == null) sync.p2PCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final h = _hosting;
    if (_failed) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(l.syncFailed, textAlign: TextAlign.center)));
    if (h == null || _events == null) return const Center(child: CircularProgressIndicator());
    final left = _until.difference(DateTime.now());
    final secs = left.isNegative ? 0 : left.inSeconds;
    final time = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    return SyncProgress(
      events: _events!,
      onSynced: widget.onSynced,
      waiting: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrView(key: const ValueKey('sync-qr'), text: h.qr),
          const SizedBox(height: 18),
          SelectableText(
            h.typed,
            key: const ValueKey('sync-typed'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 2, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 6),
          Text(l.syncCodeWorks(time), style: TextStyle(color: c.muted, fontSize: 14)),
          const SizedBox(height: 22),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Flexible(child: Text(l.syncWaiting, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ],
          ),
          const SizedBox(height: 6),
          Text(l.syncScanHint, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 14, height: 1.3)),
        ],
      ),
    );
  }
}
