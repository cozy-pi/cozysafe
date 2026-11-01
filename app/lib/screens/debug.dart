import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../biometric.dart';
import '../build_info.dart';
import '../debug_log.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';
import '../src/rust/api/vault.dart' as rust;
import '../temp_files.dart';
import '../sync/drive_check.dart';
import '../sync/sync_log.dart';
import '../theme.dart';
import '../widgets/native_bar.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart';
import 'settings.dart';
import 'vault_manager.dart';
import 'video_view.dart';
import '../widgets/readable.dart';

/// Hidden debug mode (docs/security.md, debug): seven taps on the version in Settings →
/// About, after the owner check. Technical facts and a few safe actions only: it never
/// shows keys, PINs, passwords or anything stored in the vault, and changes no setting
/// that protects it.
const debugPref = 'debug-mode';
bool debugModeOn() => Prefs.read(debugPref) == '1';

/// Laid out like Settings (owner 2026-10-28: "make the debug page decent, we will need
/// many tools there"): the build on top, then tools that open their own page, what this
/// device says, trials, and Turn off on its own at the end.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  /// For the mockup renders: the test harness swaps in its own HTTP client, so the real
  /// network check cannot run there.
  static bool? debugNetworkBlocked;

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  BiometricKind? _bio;
  int? _temp;
  List<rust.ItemInfo>? _items;
  PackageInfo? _pkg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _mb(int bytes) => '${(bytes / (1 << 20)).round()}';

  Future<void> _load() async {
    final bio = await BiometricUnlock.available();
    final temp = await playbackBytes();
    final pkg = await PackageInfo.fromPlatform();
    List<rust.ItemInfo> items;
    try {
      items = await rust.listItems();
    } catch (_) {
      items = const [];
    }
    if (!mounted) return;
    setState(() {
      _bio = bio;
      _temp = temp;
      _pkg = pkg;
      _items = items;
    });
  }

  /// The app's own guard (lib/offline.dart) makes HttpClient throw; this checks it is on.
  static bool get _networkBlocked {
    if (DebugScreen.debugNetworkBlocked != null) return DebugScreen.debugNetworkBlocked!;
    try {
      HttpClient().close(force: true);
      return false;
    } catch (_) {
      return true;
    }
  }

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

  static String get _platform {
    if (Device.iOS) return 'iOS ${Platform.operatingSystemVersion}';
    if (Device.android) return 'Android ${Platform.operatingSystemVersion}';
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  void _open(String title, WidgetBuilder page) =>
      pushPage<void>(context, title: title, grouped: true, builder: page).then((_) => mounted ? setState(() {}) : null);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final pkg = _pkg;
    final items = _items ?? const <rust.ItemInfo>[];
    int count(String k) => items.where((i) => i.kind == k).length;
    final blocked = _networkBlocked;
    final debugLines = DebugLog.lines().length;
    final syncLines = SyncLog.lines().length;
    return groupedPage(
      context,
      Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(l.debugMode)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              // The build, as the top card of Settings shows the vault.
              SettingsGroup(rows: [
                Padding(
                  key: const ValueKey('debug-build'),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Row(children: [
                    const SettingTile(icon: Icons.build_rounded, color: SettingsHue.xam),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Cozy Safe ${pkg == null ? '…' : '${pkg.version} (${pkg.buildNumber})'}',
                            style: const TextStyle(fontSize: CsType.headline, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          [buildCommit.isEmpty ? l.aboutLocal : buildCommitShort, if (buildDate.isNotEmpty) buildDate, _platform].join(' · '),
                          style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(l.debugNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
              ),
              // Tools: each opens its own page.
              SettingsGroup(rows: [
                SettingsRow(
                  key: const ValueKey('debug-drive-check'),
                  icon: Icons.cloud_rounded,
                  color: SettingsHue.xanhLa,
                  title: l.debugDriveCheck,
                  onTap: () => _open(l.debugDriveCheck, (_) => const DriveCheckScreen()),
                ),
                SettingsRow(
                  key: const ValueKey('debug-sync-log'),
                  icon: Icons.sync_rounded,
                  color: SettingsHue.xanh,
                  title: l.debugSyncLog,
                  value: l.debugLines(syncLines),
                  onTap: () => _open(l.debugSyncLog, (_) => _LogPage(lines: SyncLog.lines, clear: SyncLog.clear)),
                ),
                SettingsRow(
                  key: const ValueKey('debug-log-row'),
                  icon: Icons.receipt_long_rounded,
                  color: SettingsHue.xam,
                  title: l.debugLog,
                  value: l.debugLines(debugLines),
                  onTap: () => _open(l.debugLog, (_) => _LogPage(lines: () => DebugLog.lines().reversed.toList(), clear: DebugLog.clear)),
                ),
                SettingsRow(
                  key: const ValueKey('debug-vaults'),
                  icon: Icons.lock_rounded,
                  color: SettingsHue.cham,
                  title: l.vaultManagerTitle,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Readable(child: VaultManagerScreen(libraryDir: '${Prefs.dir}${Platform.pathSeparator}library')),
                  )),
                ),
              ]),
              // What this device says.
              SettingsGroup(rows: [
                SettingsRow(
                  key: const ValueKey('debug-network'),
                  icon: Icons.wifi_off_rounded,
                  color: blocked ? SettingsHue.xanhLa : SettingsHue.doTuoi,
                  title: l.debugNetwork,
                  trailing: Text(blocked ? l.debugNetworkOn : l.debugNetworkOff,
                      style: TextStyle(fontSize: CsType.body, color: blocked ? c.muted : recordRed(context), fontWeight: blocked ? null : FontWeight.w600)),
                ),
                SettingsRow(
                  icon: Icons.fingerprint_rounded,
                  color: SettingsHue.hong,
                  title: l.debugBiometric,
                  value: switch (_bio) {
                    BiometricKind.face => 'Face ID',
                    BiometricKind.fingerprint => 'Touch ID',
                    _ => l.debugNone,
                  },
                ),
                SettingsRow(icon: Icons.timer_rounded, color: SettingsHue.cam, title: l.debugAutoLock, value: l.debugMinutes(Settings.autoLockMinutes)),
                SettingsRow(
                  key: const ValueKey('debug-items'),
                  icon: Icons.grid_view_rounded,
                  color: SettingsHue.ngoc,
                  title: l.debugItems,
                  value: '${items.length}',
                  onTap: () => _open(l.debugItems, (_) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
                        SettingsGroup(rows: [
                          SettingsRow(icon: Icons.photo_rounded, color: SettingsHue.xanh, title: l.kindPhotos, value: '${count(ItemKind.photo)}'),
                          SettingsRow(icon: Icons.videocam_rounded, color: SettingsHue.tim, title: l.cameraVideo, value: '${count(ItemKind.video)}'),
                          SettingsRow(icon: Icons.book_rounded, color: SettingsHue.vang, title: l.kindNotes, value: '${count(ItemKind.note)}'),
                          SettingsRow(icon: Icons.mic_rounded, color: SettingsHue.cam, title: l.modeAudio, value: '${count(ItemKind.audio)}'),
                          SettingsRow(icon: Icons.folder_rounded, color: SettingsHue.xanhLa, title: l.kindFiles, value: '${count(ItemKind.file)}'),
                        ]),
                      ])),
                ),
                SettingsRow(
                  icon: Icons.file_download_rounded,
                  color: SettingsHue.troi,
                  title: l.debugImport,
                  value: ImportStats.items == null ? l.debugImportNone : '${ImportStats.items} · ${_seconds(ImportStats.totalMs)}',
                  onTap: ImportStats.items == null
                      ? null
                      : () => _open(l.debugImport, (_) => ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
                            SettingsGroup(rows: [
                              SettingsRow(icon: Icons.tag_rounded, color: SettingsHue.xam, title: l.debugImportCount, value: '${ImportStats.items}'),
                              SettingsRow(icon: Icons.photo_library_rounded, color: SettingsHue.xam, title: l.debugImportPick, value: _seconds(ImportStats.pickMs)),
                              SettingsRow(icon: Icons.image_rounded, color: SettingsHue.xam, title: l.debugImportThumbnails, value: _seconds(ImportStats.thumbnailMs)),
                              SettingsRow(icon: Icons.lock_rounded, color: SettingsHue.xam, title: l.debugImportVault, value: _seconds(ImportStats.vaultMs)),
                              SettingsRow(icon: Icons.functions_rounded, color: SettingsHue.xam, title: l.debugImportTotal, value: _seconds(ImportStats.totalMs)),
                            ]),
                          ])),
                ),
                // Owner 2026-10-30: memory kept tight; this shows it on the phone itself.
                SettingsRow(
                  key: const ValueKey('debug-memory'),
                  icon: Icons.memory_rounded,
                  color: SettingsHue.tim,
                  title: l.debugMemory,
                  // Now / the most since the app started; a tap reads it again.
                  value: '${_mb(ProcessInfo.currentRss)} / ${_mb(ProcessInfo.maxRss)} MB',
                  onTap: () => setState(() {}),
                ),
                SettingsRow(
                  key: const ValueKey('debug-playback'),
                  icon: Icons.play_circle_rounded,
                  color: SettingsHue.tim,
                  title: l.debugPlayback,
                  value: _temp == null ? '…' : fileSize(BigInt.from(_temp!)),
                  trailing: TextButton(
                    onPressed: (_temp ?? 0) == 0
                        ? null
                        : () async {
                            await clearTemp();
                            if (!context.mounted) return;
                            showToast(context, l.debugCleared, icon: Icons.check_rounded);
                            _load();
                          },
                    child: Text(l.debugClearShort),
                  ),
                ),
              ]),
              // Trials (owner 2026-10-21: to compare the two bottom bars on a real phone).
              SettingsGroup(rows: [
                SettingsRow(
                  key: const ValueKey('debug-native-bar'),
                  icon: Icons.space_bar_rounded,
                  color: SettingsHue.xanh,
                  title: l.debugNativeBar,
                  value: NativeBar.available ? null : l.debugNativeBarNone,
                  trailing: NativeBar.available
                      ? SettingsSwitch(value: nativeBarOn(), onChanged: (v) => setState(() => Prefs.write(nativeBarPref, v ? '1' : '0')))
                      : null,
                ),
              ]),
              SettingsGroup(rows: [
                InkWell(
                  key: const ValueKey('debug-off'),
                  onTap: () {
                    Prefs.write(debugPref, '0');
                    DebugLog.sync();
                    SyncLog.clear(); // nothing kept with debug off (owner 2026-10-28)
                    Navigator.of(context).pop(true);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    child: Center(child: Text(l.debugOff, style: TextStyle(fontSize: CsType.body, color: recordRed(context)))),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// One log on its own page, newest first, to read, copy or clear.
class _LogPage extends StatefulWidget {
  const _LogPage({required this.lines, required this.clear});
  final List<String> Function() lines;
  final VoidCallback clear;

  @override
  State<_LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<_LogPage> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final lines = widget.lines();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        SettingsGroup(rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: lines.isEmpty
                ? Text(l.debugLogEmpty, style: TextStyle(color: c.muted, fontSize: CsType.subhead))
                : SelectableText(
                    lines.join('\n'),
                    key: const ValueKey('debug-log'),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: CsType.caption1, height: 1.45),
                  ),
          ),
        ]),
        SettingsGroup(rows: [
          SettingsRow(
            key: const ValueKey('debug-log-copy'),
            icon: Icons.copy_rounded,
            color: SettingsHue.xanh,
            title: l.debugLogCopy,
            chevron: false,
            onTap: lines.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
                    if (context.mounted) showToast(context, l.debugLogCopied, icon: Icons.check_rounded);
                  },
          ),
          SettingsRow(
            icon: Icons.delete_rounded,
            color: SettingsHue.doTuoi,
            title: l.debugLogClear,
            chevron: false,
            onTap: lines.isEmpty ? null : () => setState(widget.clear),
          ),
        ]),
      ],
    );
  }
}
