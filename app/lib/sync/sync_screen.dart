import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../error_log.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../theme.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show pushPage;
import '../platform.dart';
import 'auto_sync.dart';
import 'sync_log.dart';
import 'sync_status.dart';
import 'consent.dart';
import 'drive.dart';
import 'nearby_page.dart';
import 'progress.dart';
import 'wifi.dart';
import '../widgets/drive_logo.dart';

/// Settings → Sync: bring this vault up to date with the person's other device on the
/// same Wi-Fi (docs/adr/0003-sync.md). Every connection is started here and allowed by
/// hand; the log below lists them.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.libraryDir, required this.onSynced});
  final String libraryDir;
  final VoidCallback onSynced;

  /// For the mockup renders: the log without a vault.
  static List<String>? debugLog;
  /// For the mockup renders: the address without asking the system.
  static String? debugAddress;
  /// For the mockup renders: show Google Drive on any platform.
  static bool debugDrive = false;
  /// For the mockup renders: a signed-in Google account.
  static String? debugAccount;
  /// For the mockup renders: a signed-in account without Google (tests have none).
  static DriveSession? debugSession;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  List<String> _log = const [];

  @override
  void initState() {
    super.initState();
    _loadLog();
  }

  Future<void> _loadLog() async {
    try {
      final log = SyncScreen.debugLog ?? await sync.connectionLog();
      if (mounted) setState(() => _log = log);
    } catch (_) {}
  }

  void _synced() {
    widget.onSynced();
    _loadLog();
  }

  /// Both devices open this and wait: ask once to look and wait on this Wi-Fi, then they
  /// find each other and both people confirm (docs/adr/0003-sync.md).
  Future<void> _nearby() async {
    final l = AppLocalizations.of(context);
    final address = SyncScreen.debugAddress ?? await localAddress();
    if (!mounted) return;
    if (address == null) {
      showToast(context, l.syncNoWifi, icon: Icons.wifi_off_rounded);
      return;
    }
    if (!await allowConnection(context, l.syncAllowNearby) || !mounted) return;
    await AutoSync.idle();
    if (!mounted) return;
    await pushPage<void>(context,
        title: l.syncRow,
        builder: (_) => NearbyPage(address: address, mirror: '${widget.libraryDir}-sync', onSynced: _synced));
    _loadLog();
  }

  /// Google Drive: sign in, ask, then one sync (the vault's sealed files only).
  Future<void> _drive() async {
    final l = AppLocalizations.of(context);
    if (!driveReady) {
      showToast(context, l.driveSoon, icon: Icons.cloud_off_rounded);
      return;
    }
    // The account being added now: the card asking to connect also offers automatic
    // sync, on unless turned off there (owner 2026-10-27).
    final adding = _account == null;
    var auto = true;
    DriveSession? session;
    try {
      session = SyncScreen.debugSession ?? await driveSignIn();
    } catch (e) {
      ErrorLog.add('drive-sign-in', driveErrorCode(e));
      if (mounted) showToast(context, '${l.driveSignInFailed} (${driveErrorCode(e)})', icon: Icons.error_rounded);
      return;
    }
    if (session == null || !mounted) return;
    setState(() {}); // the account rows
    final below = !adding
        ? null
        : StatefulBuilder(
            // In line with the sentence above it: the icon where the lock is.
            builder: (context, set) => Row(
              key: const ValueKey('sync-allow-auto'),
              children: [
                Icon(Icons.sync_rounded, size: 20, color: CsColors.of(context).muted),
                const SizedBox(width: 10),
                Expanded(child: Text(l.syncAuto, style: const TextStyle(fontSize: CsType.callout))),
                _Toggle(value: auto, onChanged: (v) => set(() => auto = v)),
              ],
            ),
          );
    if (!await allowConnection(context, l.syncAllowDrive(session.email), below: below) || !mounted) return;
    if (adding) setState(() => AutoSync.enabled = auto);
    await AutoSync.idle();
    if (!mounted) return;
    final token = session.token;
    await pushPage<void>(context,
        title: l.syncDriveRow,
        builder: (_) => SyncProgress(
              place: SyncPlace.drive,
              events: sync.driveSync(token: token),
              retry: () => sync.driveSync(token: token),
              onSynced: () {
                AutoSync.succeeded();
                SyncLog.add('hand', 'done');
                widget.onSynced();
              },
              waiting: Column(mainAxisSize: MainAxisSize.min, children: [
                const SyncLink(place: SyncPlace.drive),
                const SizedBox(height: 22),
                Text(l.syncDriveWorking, textAlign: TextAlign.center, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700)),
              ]),
            ));
    _loadLog();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        // A picture instead of the explanations (owner 2026-10-26: people need to know
        // only that the data is safe): this device, the lock on the way, the other.
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: SyncLink(key: ValueKey('sync-hero'), moving: false),
        ),
        // Groups without names, apart by a gap, as in the iPhone's Settings (owner
        // 2026-10-26): the rows say what they do.
        const SizedBox(height: 24),
        // Google Drive: phones only for now (the desktop sign-in clients are not made yet).
        if (SyncScreen.debugDrive || Device.iOS || Device.android) ...[
          // One row (owner 2026-10-27: Drive's options on a page of their own, less to
          // take in here): with no account it signs in and syncs; with one it opens
          // that page.
          _Card(children: [
            _Action(
                key: const ValueKey('sync-drive'),
                icon: Icons.cloud_sync_rounded,
                color: const Color(0xFF34A853),
                logo: const DriveLogo(size: 20),
                title: 'Google Drive',
                alert: true,
                onTap: _account == null ? _drive : _openDrive),
          ]),
          const SizedBox(height: 24),
        ],
        _Card(children: [
          _Action(key: const ValueKey('sync-nearby'), icon: Icons.devices_rounded, color: const Color(0xFF007AFF), title: l.syncRow, onTap: _nearby),
        ]),
        const SizedBox(height: 24),
        // The log behind one row (owner 2026-10-26): most people never need it.
        _Card(children: [
          _Action(key: const ValueKey('sync-log'), icon: Icons.history_rounded, color: const Color(0xFF8E8E93), title: l.syncLog, detail: _log.isEmpty ? null : '${_log.length}', onTap: _openLog),
        ]),
      ],
    );
  }

  String? get _account => SyncScreen.debugAccount ?? driveAccount;

  /// Google Drive's page: sync now; the account, automatic sync, Wi-Fi only; remove.
  Future<void> _openDrive() async {
    await pushPage<void>(context,
        title: 'Google Drive', grouped: true,
        builder: (context) => StatefulBuilder(builder: (context, set) {
              final l = AppLocalizations.of(context);
              final account = _account;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  // Whose Drive, under its logo, as an account page on the iPhone (owner
                  // 2026-10-27). No "Sign in again": to change account, remove it and sync
                  // again, which asks for one.
                  Column(key: const ValueKey('sync-drive-account'), children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: CsColors.of(context).border),
                      ),
                      alignment: Alignment.center,
                      child: const DriveLogo(size: 40),
                    ),
                    if (account != null) ...[
                      const SizedBox(height: 10),
                      Text(account, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: CsColors.of(context).muted, fontSize: CsType.subhead)),
                    ],
                  ]),
                  const SizedBox(height: 24),
                  _Card(children: [
                    _Action(key: const ValueKey('sync-drive-now'), icon: Icons.sync_rounded, color: const Color(0xFF007AFF), title: l.syncNow, onTap: _drive),
                  ]),
                  const SizedBox(height: 24),
                  _Card(children: [
                    // Automatic sync, and whether mobile data may carry it (owner 2026-10-27).
                    // Not the same symbol as Sync now (owner 2026-10-27): a clock that
                    // turns, for "by itself, from time to time".
                    _Action(
                      key: const ValueKey('sync-auto'),
                      icon: Icons.update_rounded,
                      color: const Color(0xFF34A853),
                      title: l.syncAuto,
                      chevron: false,
                      trailing: _Toggle(value: AutoSync.enabled, onChanged: (v) => set(() => AutoSync.enabled = v)),
                    ),
                    if (AutoSync.enabled)
                      _Action(
                        key: const ValueKey('sync-wifi-only'),
                        icon: Icons.wifi_rounded,
                        color: const Color(0xFF007AFF),
                        title: l.syncWifiOnly,
                        chevron: false,
                        trailing: _Toggle(value: AutoSync.wifiOnly, onChanged: (v) => set(() => AutoSync.wifiOnly = v)),
                      ),
                  ]),
                  const SizedBox(height: 24),
                  _Card(children: [
                    // Red words only, as the iPhone's Sign Out: no symbol (owner 2026-10-27).
                    InkWell(
                      key: const ValueKey('sync-drive-remove'),
                      onTap: () async {
                        if (await _remove() && context.mounted) Navigator.of(context).pop();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Text(l.driveRemove, style: const TextStyle(fontSize: CsType.body, color: Color(0xFFFF3B30))),
                        ),
                      ),
                    ),
                  ]),
                ],
              );
            }));
    if (mounted) setState(() {});
  }

  /// Remove the Google account: asks first; the files on Drive stay. True once removed.
  Future<bool> _remove() async {
    final l = AppLocalizations.of(context);
    final account = _account;
    if (account == null) return false;
    final ok = await confirmDelete(context,
        title: l.driveRemoveTitle(account), body: l.driveRemoveBody, action: l.driveRemove, icon: Icons.person_remove_rounded);
    if (!ok) return false;
    try {
      await driveSignOut(revoke: true);
    } catch (_) {}
    if (mounted) setState(() {});
    return true;
  }

  Future<void> _openLog() => pushPage<void>(context,
      title: AppLocalizations.of(context).syncLog,
      builder: (context) {
        final l = AppLocalizations.of(context);
        final c = CsColors.of(context);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            if (_log.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(l.syncLogEmpty, style: TextStyle(color: c.muted)),
              )
            else
              _Card(indent: 46, children: [for (final line in _log) _LogRow(line: line)]),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(l.syncLogNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
            ),
          ],
        );
      });
}

class _Card extends StatelessWidget {
  const _Card({required this.children, this.indent = 56});
  final List<Widget> children;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, indent: indent, color: c.border.withValues(alpha: .6)),
          children[i],
        ],
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({super.key, required this.icon, required this.color, required this.title, this.onTap, this.detail, this.chevron = true, this.logo, this.trailing, this.alert = false});
  /// The red dot of a failed automatic sync after the title (the Google Drive row).
  final bool alert;
  final IconData icon;
  /// A service's own logo on a white tile instead of [icon] (Google Drive).
  final Widget? logo;
  final Color color;
  final String title;
  /// Null for a line that only shows something (the account).
  final VoidCallback? onTap;
  /// Muted, on the right before the chevron (an account, a count).
  final String? detail;
  final bool chevron;
  /// A switch at the end, in place of the chevron.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: logo != null ? Colors.white : color,
              borderRadius: BorderRadius.circular(8),
              border: logo != null ? Border.all(color: c.border) : null,
            ),
            alignment: Alignment.center,
            child: logo ?? Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: CsType.body, color: chevron || onTap == null || trailing != null ? null : color))),
          if (alert) const SyncAlertDot(),
          if (detail case final d?)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Padding(
                padding: const EdgeInsets.only(left: 8, right: 2),
                child: Text(d, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: CsType.body)),
              ),
            ),
          ?trailing,
          if (chevron) Icon(Icons.chevron_right, color: c.muted, size: 20),
        ]),
      ),
    );
  }
}

/// A switch as in Settings: the iPhone's green with a white knob.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF30D158) : const Color(0xFF34C759),
        activeThumbColor: Colors.white,
      );
}

/// One line of the connection log: `<ms>|<host|join>|<address or ->|<outcome>|<in>|<out>`.
class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});
  final String line;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final p = line.split('|');
    if (p.length < 6) return const SizedBox.shrink();
    final when = DateTime.fromMillisecondsSinceEpoch(int.tryParse(p[0]) ?? 0);
    final tag = Localizations.localeOf(context).toLanguageTag();
    // This year's without the year: the line stays short.
    final day = when.year == DateTime.now().year ? DateFormat.MMMd(tag) : DateFormat.yMMMd(tag);
    final date = '${day.format(when)} ${DateFormat.Hm(tag).format(when)}';
    // Since 0.1.73 the other device's name; before, its address (or "-" when this one
    // showed the code). An address is never shown: it says nothing to the person.
    final address = RegExp(r'^[0-9.:a-fA-F]+$').hasMatch(p[2]) && !RegExp(r'^[a-zA-Z]+$').hasMatch(p[2]);
    final title = switch (p[1]) {
      'drive' => l.syncLogDrive,
      _ when p[2] == '-' => p[1] == 'host' ? l.syncLogHost : l.syncLogNearby,
      _ when address => l.syncLogNearby,
      _ => p[2],
    };
    final (outcome, ok) = switch (p[3]) {
      'ok' => (l.syncLogCounts(p[4], p[5]), true),
      'cancelled' => (l.syncLogCancelled, false),
      'expired' => (l.syncLogExpired, false),
      'othervault' => (l.syncLogOtherVault, false),
      'unreachable' => (l.syncLogUnreachable, false),
      _ => (l.syncLogFailed, false),
    };
    // Compact (owner 2026-10-26): one line each, the outcome at the end.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.remove_circle_rounded,
            color: ok ? const Color(0xFF34C759) : c.muted, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: title),
              TextSpan(text: '  $date', style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: CsType.subhead),
          ),
        ),
        const SizedBox(width: 8),
        Text(outcome, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
      ]),
    );
  }
}
