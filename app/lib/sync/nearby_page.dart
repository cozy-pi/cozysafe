import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import 'device_name.dart';
import 'join_page.dart';
import 'awake.dart';
import 'progress.dart';
import 'qr_view.dart';
import '../widgets/readable.dart';

/// Sync with a nearby device (owner 2026-10-26, like Bluetooth pairing): both devices
/// open this page and wait. Each listens on this Wi-Fi ([address], already allowed by
/// the person) and looks for the other; once they find each other and prove they hold
/// this vault, both ask "Sync with …?" next to the same number, and the sync starts when
/// both people tap Sync. No code to type; a QR stays for networks that block looking.
/// A new device restoring with the 24 words finds this one too: the person here allows
/// it after comparing the number (no switch to turn on first, owner 2026-10-26).
class NearbyPage extends StatefulWidget {
  const NearbyPage({super.key, required this.address, required this.mirror, required this.onSynced});
  final String address;
  /// A private folder for the sealed copy the other device reads (emptied after).
  final String mirror;
  final VoidCallback onSynced;

  /// For the mockup renders: a wait without starting anything.
  static sync.Hosting? debugHosting;
  /// For the mockup renders: what the session says.
  static Stream<sync.SyncEvent>? debugEvents;
  /// For the mockup renders: the QR shown, or the hints after a while with nothing.
  static bool debugQr = false;
  static bool debugNothingYet = false;

  @override
  State<NearbyPage> createState() => _NearbyPageState();
}

class _NearbyPageState extends State<NearbyPage> {
  sync.Hosting? _hosting;
  Stream<sync.SyncEvent>? _events;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Waiting counts as a sync: the screen stays on and the vault does not lock itself.
    Awake.set(true, who: 'nearby');
    _start();
  }

  Future<void> _start() async {
    try {
      final debug = NearbyPage.debugHosting;
      final h = debug ??
          await sync.p2PWaitStart(ip: widget.address, mirror: widget.mirror, name: await deviceName());
      if (!mounted) {
        sync.p2PCancel();
        return;
      }
      setState(() {
        _hosting = h;
        _events = debug != null ? (NearbyPage.debugEvents ?? const Stream.empty()) : sync.p2PWaitRun(ip: widget.address);
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    Awake.set(false, who: 'nearby');
    if (_events == null && NearbyPage.debugHosting == null) sync.p2PCancel();
    super.dispose();
  }

  /// Scan the other device's QR: this page gives way (its wait ends), the scanner asks
  /// before connecting where the code points.
  void _scan() {
    final l = AppLocalizations.of(context);
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => Readable(child: Scaffold(
        appBar: AppBar(title: Text(l.syncScanCode)),
        body: SafeArea(top: false, child: ScanCodePage(onSynced: widget.onSynced)),
      )),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final h = _hosting;
    if (_failed) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(l.syncFailed, textAlign: TextAlign.center)));
    if (h == null || _events == null) return const Center(child: CircularProgressIndicator());
    return SyncProgress(
      events: _events!,
      onSynced: widget.onSynced,
      waiting: NearbyLooking(
        seconds: h.seconds,
        lead: l.syncNearbyLead,
        qr: h.qr,
        qrOnly: !h.findable,
        onScan: _scan,
      ),
    );
  }
}

/// While looking: what is going on (one line that changes), what to do on the other
/// device, and the QR way round. Shared by sync and by a new device restoring.
class NearbyLooking extends StatefulWidget {
  const NearbyLooking({super.key, required this.lead, this.seconds, this.qr, this.qrOnly = false, this.onScan, this.extra, this.restoring = false});
  final String lead;
  /// How long the wait lasts (a countdown), or null.
  final int? seconds;
  /// This device's QR (sync), or null (a restoring device only scans).
  final String? qr;
  /// The other device cannot find this one here: the QR straight away.
  final bool qrOnly;
  final VoidCallback? onScan;
  final Widget? extra;
  final bool restoring;

  @override
  State<NearbyLooking> createState() => _NearbyLookingState();
}

class _NearbyLookingState extends State<NearbyLooking> {
  late final DateTime _from = DateTime.now();
  Timer? _tick;
  bool _qr = NearbyPage.debugQr;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    Awake.set(true, who: 'looking');
  }

  @override
  void dispose() {
    Awake.set(false, who: 'looking');
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final waited = DateTime.now().difference(_from);
    // Nothing after a minute: the reasons a person can fix (owner 2026-10-27: 12 s was
    // too soon, they came up while the other phone was still being opened).
    final hints = waited > const Duration(minutes: 1) || NearbyPage.debugNothingYet
        ? [widget.restoring ? l.syncNearbyNoneRestore : l.syncNearbyNone, if (Device.iOS) l.syncFindLocalNetwork]
        : const <String>[];
    String? left;
    final seconds = widget.seconds;
    if (seconds != null) {
      final s = (seconds - waited.inSeconds).clamp(0, seconds);
      left = l.syncWaitLeft('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}');
    }
    final showQr = _qr || widget.qrOnly;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The two devices with the lock between them, still: nothing travels until the
        // other device is found (owner 2026-10-27: a moving light read as sending).
        const SyncLink(key: ValueKey('sync-find-link'), moving: false),
        const SizedBox(height: 22),
        Text(l.syncFindSearching,
            key: const ValueKey('sync-find-status'), textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 8),
        Text(widget.lead, key: const ValueKey('sync-nearby-lead'), textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        if (left != null) ...[
          const SizedBox(height: 4),
          Text(left, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
        for (final h in hints)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(h, key: const ValueKey('sync-nearby-hint'), textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.35)),
          ),
        if (widget.extra != null) ...[const SizedBox(height: 14), widget.extra!],
        const SizedBox(height: 12),
        if (showQr) ...[
          Text(widget.qrOnly ? l.syncQrOnly : (widget.qr == null ? l.syncQrLeadRestore : l.syncQrLead),
              key: const ValueKey('sync-qr-lead'), textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.35)),
          if (widget.qr != null) ...[
            const SizedBox(height: 14),
            Center(child: QrView(key: const ValueKey('sync-qr'), text: widget.qr!, size: 200)),
          ],
          if (widget.onScan != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('sync-scan'),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l.syncScanCode),
              onPressed: widget.onScan,
            ),
          ],
        ] else
          TextButton.icon(
            key: const ValueKey('sync-use-qr'),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(l.syncUseQr),
            onPressed: () => setState(() => _qr = true),
          ),
      ],
    );
  }
}
