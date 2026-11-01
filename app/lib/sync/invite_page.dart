import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../screens/top_secret_page.dart' show restartForMode;
import '../screens/common.dart';
import '../widgets/readable.dart';
import '../widgets/toast.dart';
import '../widgets/words_awake.dart';
import 'consent.dart';
import 'device_name.dart';
import 'awake.dart';
import 'add_code.dart';
import 'progress.dart';
import 'wifi.dart';

/// "Set up a new device" (ADR 0003, point 11): this device, with the vault open, waits
/// for a new device on the Wi-Fi. When one connects, the two make a key together and this
/// device shows 8 digits from it; the person types them on the new device, then the vault
/// password. Only both right make this device send the 24 words and the vault. It waits
/// two minutes; screenshots are blocked while it shows the code.
class InvitePage extends StatefulWidget {
  const InvitePage({super.key, required this.address, required this.mirror, required this.onSynced});
  final String address;
  /// A private folder for the sealed copy the other device reads (emptied after).
  final String mirror;
  final VoidCallback onSynced;

  /// For the mockup renders: the seconds it waits without starting anything, and what
  /// it says.
  static int? debugSeconds;
  static Stream<sync.SyncEvent>? debugEvents;

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  int? _seconds;
  Stream<sync.SyncEvent>? _events;
  /// What stopped the start, for the code under the message; null while all is well.
  Object? _failure;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final debug = InvitePage.debugSeconds;
      final seconds = debug ?? await sync.p2PAddStart(ip: widget.address, mirror: widget.mirror, name: await deviceName());
      if (!mounted) {
        sync.p2PCancel();
        return;
      }
      setState(() {
        _seconds = seconds;
        _events = debug != null ? (InvitePage.debugEvents ?? const Stream.empty()) : sync.p2PWaitRun(ip: widget.address);
      });
    } catch (e) {
      if (mounted) setState(() => _failure = e);
    }
  }

  @override
  void dispose() {
    if (_events == null && InvitePage.debugSeconds == null) sync.p2PCancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final failure = _failure;
    if (failure != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(withCode(l, l.syncFailed, failure), textAlign: TextAlign.center)));
    }
    final seconds = _seconds;
    if (seconds == null || _events == null) return const Center(child: CircularProgressIndicator());
    // Kept awake, out of screenshots and recordings, while the code is up.
    return WordsAwake(
      child: SyncProgress(
        events: _events!,
        onSynced: widget.onSynced,
        waiting: _Countdown(seconds: seconds),
      ),
    );
  }
}

/// The wait before a new device connects, with the time left.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.seconds});
  final int seconds;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final DateTime _from = DateTime.now();
  Timer? _tick;

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
    final s = (widget.seconds - DateTime.now().difference(_from).inSeconds).clamp(0, widget.seconds);
    return AddCodeWaiting(left: '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}');
  }
}

/// The new device, with no vault in `dir`, is added: ask before looking on the Wi-Fi,
/// then find the old device, the code, the password, restore. Returns the vault opened
/// here, its 24 words kept under the library it went into; null otherwise.
Future<rust.VaultInfo?> restoreByCode(BuildContext context, {required String dir}) async {
  final l = AppLocalizations.of(context);
  final ip = await localAddress();
  if (!context.mounted) return null;
  if (ip == null) {
    showToast(context, l.syncNoWifi, icon: Icons.wifi_off_rounded);
    return null;
  }
  if (!await allowConnection(context, l.syncAllowFindRestore)) return null;
  final name = await deviceName();
  if (!context.mounted) return null;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => Readable(child: KeepAwake(who: 'add-code', child: Scaffold(
      appBar: AppBar(title: Text(l.restoreFromDevice)),
      body: SafeArea(
        top: false,
        child: SyncProgress(
          restoring: true,
          events: sync.p2PAddRestore(dir: dir, ip: ip, name: name),
          onSynced: () {},
          waiting: const AddCodeSearching(),
        ),
      ),
    ))),
  ));
  // The vault came in whenever its words did: keep them first, whatever comes next.
  final key = sync.p2PInviteKey();
  if (key == null) return null;
  await SecretKeyStore.write(key, dir);
  final vault = rust.openVaultInfo();
  // Top secret after an everyday vault in this run: the app starts again, then it opens.
  if (vault == null && context.mounted) await restartForMode(context);
  return vault;
}
