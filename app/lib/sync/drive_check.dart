import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/file_view.dart';
import '../screens/settings.dart';
import '../theme.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/toast.dart';
import '../src/rust/api/sync.dart' as sync;
import 'drive.dart';
import 'sync_log.dart';

/// What Google Drive holds for this vault, sorted by what it is for (owner 2026-10-28:
/// "I fear there is junk on Google Drive"). Junk is a file no item of this vault uses;
/// a file the app cannot place yet (an item another device has not told this one
/// about) is "unknown", never junk. Only junk is ever cleaned, and only on a tap.
class DriveCounts {
  const DriveCounts({
    required this.items,
    required this.folders,
    required this.current,
    required this.currentBytes,
    required this.old,
    required this.oldBytes,
    required this.journal,
    required this.junk,
    required this.junkBytes,
    required this.unknown,
    required this.summary,
  });
  final int items, folders, current, old, journal, junk, unknown;
  final int currentBytes, oldBytes, junkBytes;

  /// One line for the sync log: counts only, no names or ids.
  final String summary;
}

/// The Debug page's "Check Google Drive": look, then clean the junk if there is any.
class DriveCheckScreen extends StatefulWidget {
  const DriveCheckScreen({super.key});

  /// The look and the clean, given an access token; the core's by default.
  static Future<DriveCounts> Function(String token) check = _coreCheck;
  static Future<int> Function(String token) clean = _coreClean;

  /// For the mockup renders: a result already there.
  static DriveCounts? debugResult;

  @override
  State<DriveCheckScreen> createState() => _DriveCheckScreenState();
}

Future<DriveCounts> _coreCheck(String token) async {
  final a = await sync.driveAudit(token: token);
  return DriveCounts(
    items: a.itemsLive + a.itemsTrash,
    folders: a.folders,
    current: a.currentFiles,
    currentBytes: a.currentBytes.toInt(),
    old: a.oldFiles,
    oldBytes: a.oldBytes.toInt(),
    // Change lists, the devices' heads and the lock: what syncing needs to work.
    journal: a.journalFiles + a.headFiles + a.lockFiles,
    junk: a.orphanFiles,
    junkBytes: a.orphanBytes.toInt(),
    // Not junk for sure, or already on the way out at the next sync: never cleaned here.
    unknown: a.unknownFiles + a.deletingFiles,
    summary: a.summary,
  );
}

Future<int> _coreClean(String token) => sync.driveClean(token: token);

class _DriveCheckScreenState extends State<DriveCheckScreen> {
  DriveCounts? _result = DriveCheckScreen.debugResult;
  bool _busy = false;
  bool _failed = false;

  Future<void> _run(Future<void> Function(String token) job) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final session = await driveSignIn();
      if (session == null) throw StateError('no session');
      await job(session.token);
    } catch (e) {
      SyncLog.add('check', 'failed-${e.runtimeType}');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() => _run((token) async {
        final r = await DriveCheckScreen.check(token);
        SyncLog.add('check', r.summary);
        if (mounted) setState(() => _result = r);
      });

  Future<void> _clean() async {
    final l = AppLocalizations.of(context);
    final junk = _result?.junk ?? 0;
    final ok = await confirmDelete(context, title: l.debugDriveCleanTitle(junk), action: l.debugDriveCleanAction, body: l.debugDriveCleanBody);
    if (!ok || !mounted) return;
    await _run((token) async {
      final n = await DriveCheckScreen.clean(token);
      SyncLog.add('check', 'cleaned-$n');
      if (!mounted) return;
      showToast(context, l.debugDriveCleaned(n), icon: Icons.check_rounded);
      final r = await DriveCheckScreen.check(token);
      SyncLog.add('check', r.summary);
      if (mounted) setState(() => _result = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final r = _result;
    String withSize(int n, int bytes) => bytes > 0 ? '$n · ${fileSize(BigInt.from(bytes))}' : '$n';
    final red = recordRed(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(driveAccount == null ? l.debugDriveNoAccount : l.debugDriveCheckBody,
              style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
        ),
        if (r != null) ...[
          SettingsGroup(boxKey: const ValueKey('drive-check-result'), rows: [
            SettingsRow(icon: Icons.grid_view_rounded, color: SettingsHue.ngoc, title: l.debugDriveItems, value: '${r.items}'),
            SettingsRow(icon: Icons.insert_drive_file_rounded, color: SettingsHue.xanh, title: l.debugDriveCurrent, value: withSize(r.current, r.currentBytes)),
            SettingsRow(icon: Icons.history_rounded, color: SettingsHue.cam, title: l.debugDriveOld, value: withSize(r.old, r.oldBytes)),
            SettingsRow(icon: Icons.receipt_long_rounded, color: SettingsHue.xam, title: l.debugDriveJournal, value: '${r.journal}'),
            SettingsRow(icon: Icons.folder_rounded, color: SettingsHue.xam, title: l.debugDriveFolders, value: '${r.folders}'),
            if (r.unknown > 0) SettingsRow(icon: Icons.help_rounded, color: SettingsHue.tim, title: l.debugDriveUnknown, value: '${r.unknown}'),
            SettingsRow(
              key: const ValueKey('drive-check-junk'),
              icon: r.junk > 0 ? Icons.delete_rounded : Icons.check_rounded,
              color: r.junk > 0 ? SettingsHue.doTuoi : SettingsHue.xanhLa,
              title: l.debugDriveJunk,
              trailing: Text(r.junk > 0 ? withSize(r.junk, r.junkBytes) : l.debugDriveNoJunk,
                  style: TextStyle(fontSize: CsType.body, color: r.junk > 0 ? red : c.muted, fontWeight: r.junk > 0 ? FontWeight.w600 : null)),
            ),
          ]),
          if (r.junk > 0)
            SettingsGroup(rows: [
              InkWell(
                key: const ValueKey('drive-check-clean'),
                onTap: _busy ? null : _clean,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: Center(child: Text(l.debugDriveCleanAction, style: TextStyle(fontSize: CsType.body, color: red, fontWeight: FontWeight.w600))),
                ),
              ),
            ]),
        ],
        if (_failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text(l.debugDriveFailed, style: TextStyle(color: red, fontSize: CsType.footnote)),
          ),
        SettingsGroup(rows: [
          InkWell(
            key: const ValueKey('drive-check-run'),
            onTap: _busy || driveAccount == null ? null : _check,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Center(
                child: _busy
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                    : Text(r == null ? l.debugDriveCheckRun : l.debugDriveCheckAgain,
                        style: TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w600, color: driveAccount == null ? c.muted : null)),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}
