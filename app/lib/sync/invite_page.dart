import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/readable.dart';
import '../widgets/toast.dart';
import '../widgets/words_awake.dart';
import 'consent.dart';
import 'device_name.dart';
import 'progress.dart';
import 'qr_view.dart';
import 'wifi.dart';

/// "Add a device" (ADR 0003, point 11): this device, with the vault open, shows a QR code
/// holding a one-time secret. The new device scans it, pairs with a key from that secret
/// alone (nothing on the network can be in the middle), and its person types the vault
/// password; only a right one makes this device send the 24 words and the vault. The
/// code lasts two minutes and one device; screenshots are blocked while it shows.
class InvitePage extends StatefulWidget {
  const InvitePage({super.key, required this.address, required this.mirror, required this.onSynced});
  final String address;
  /// A private folder for the sealed copy the other device reads (emptied after).
  final String mirror;
  final VoidCallback onSynced;

  /// For the mockup renders: an invite without starting anything, and what it says.
  static sync.Invitation? debugInvitation;
  static Stream<sync.SyncEvent>? debugEvents;

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  sync.Invitation? _invitation;
  Stream<sync.SyncEvent>? _events;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final debug = InvitePage.debugInvitation;
      final i = debug ?? await sync.p2PInviteStart(ip: widget.address, mirror: widget.mirror, name: await deviceName());
      if (!mounted) {
        sync.p2PCancel();
        return;
      }
      setState(() {
        _invitation = i;
        _events = debug != null ? (InvitePage.debugEvents ?? const Stream.empty()) : sync.p2PWaitRun(ip: widget.address);
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    if (_events == null && InvitePage.debugInvitation == null) sync.p2PCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final i = _invitation;
    if (_failed) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(l.syncFailed, textAlign: TextAlign.center)));
    if (i == null || _events == null) return const Center(child: CircularProgressIndicator());
    // Kept awake, out of screenshots and recordings, while the code is up.
    return WordsAwake(
      child: SyncProgress(
        events: _events!,
        onSynced: widget.onSynced,
        waiting: InviteShown(invitation: i),
      ),
    );
  }
}

/// The code to scan, the same code to type, and the time left.
class InviteShown extends StatefulWidget {
  const InviteShown({super.key, required this.invitation});
  final sync.Invitation invitation;

  @override
  State<InviteShown> createState() => _InviteShownState();
}

class _InviteShownState extends State<InviteShown> {
  late final DateTime _from = DateTime.now();
  Timer? _tick;
  bool _typed = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final i = widget.invitation;
    final s = (i.seconds - DateTime.now().difference(_from).inSeconds).clamp(0, i.seconds);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.inviteTitle,
            key: const ValueKey('invite-title'), textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, height: 1.3)),
        const SizedBox(height: 8),
        Text(l.inviteLead, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        const SizedBox(height: 18),
        Center(child: QrView(key: const ValueKey('invite-qr'), text: i.qr, size: 220)),
        const SizedBox(height: 12),
        Text(l.syncWaitLeft('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}'),
            key: const ValueKey('invite-left'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: CsType.subhead, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 6),
        if (_typed)
          SelectableText(i.typed,
              key: const ValueKey('invite-typed'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: CsType.title3, fontFamily: 'monospace', fontWeight: FontWeight.w600, letterSpacing: 1))
        else
          TextButton(
            key: const ValueKey('invite-show-typed'),
            onPressed: () => setState(() => _typed = true),
            child: Text(l.inviteShowTyped),
          ),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_rounded, size: 18, color: c.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(l.inviteSafety, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.35))),
        ]),
      ],
    );
  }
}

/// A new device came by an invite (scanned or typed) into `dir`: ask before connecting,
/// naming where, then pair, ask the password, restore. Returns the vault opened here, its
/// 24 words kept under the library it went into; null otherwise.
Future<rust.VaultInfo?> restoreByInvite(BuildContext context, {required String dir, required String code}) async {
  final l = AppLocalizations.of(context);
  final address = sync.p2PInviteAddress(code: code);
  if (address == null) {
    showToast(context, l.inviteInvalid, icon: Icons.error_outline_rounded);
    return null;
  }
  // Typed: the old device is found on this Wi-Fi.
  final ip = address.isEmpty ? await localAddress() : '';
  if (!context.mounted) return null;
  if (ip == null) {
    showToast(context, l.syncNoWifi, icon: Icons.wifi_off_rounded);
    return null;
  }
  if (!await allowConnection(context, address.isEmpty ? l.syncAllowFindRestore : l.syncAllowJoin)) return null;
  final name = await deviceName();
  if (!context.mounted) return null;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => Readable(child: Scaffold(
      appBar: AppBar(title: Text(l.restoreFromDevice), automaticallyImplyLeading: false),
      body: SafeArea(
        top: false,
        child: SyncProgress(
          restoring: true,
          events: sync.p2PInviteRestore(dir: dir, code: code, ip: ip, name: name),
          onSynced: () {},
        ),
      ),
    )),
  ));
  final vault = rust.openVaultInfo();
  final key = sync.p2PInviteKey();
  if (vault == null || key == null) return null;
  await SecretKeyStore.write(key, vault.libraryDir);
  return vault;
}

/// Type the code shown on the old device (a device without a camera).
class InviteTypePage extends StatefulWidget {
  const InviteTypePage({super.key, required this.onCode});
  final Future<void> Function(BuildContext context, String code) onCode;

  @override
  State<InviteTypePage> createState() => _InviteTypePageState();
}

class _InviteTypePageState extends State<InviteTypePage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.clear();
    _text.dispose();
    super.dispose();
  }

  bool get _ready => sync.p2PInviteAddress(code: _text.text) != null;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.inviteTypeLead, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        const SizedBox(height: 14),
        TextField(
          key: const ValueKey('invite-type-field'),
          controller: _text,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: 'monospace', fontSize: CsType.title3, letterSpacing: 1),
          decoration: const InputDecoration(hintText: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX'),
          onChanged: (_) => setState(() {}),
        ),
        const Spacer(),
        FilledButton(
          key: const ValueKey('invite-type-next'),
          onPressed: _ready ? () => widget.onCode(context, _text.text) : null,
          child: Text(l.pinNext),
        ),
      ]),
    );
  }
}
