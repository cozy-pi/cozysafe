import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../biometric.dart';
import '../build_info.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/toast.dart';
import 'file_view.dart';
import 'settings.dart';
import 'video_view.dart';

/// Hidden debug mode (docs/security.md, debug): seven taps on the version in Settings →
/// About, after the owner check. Technical facts and a few safe actions only: it never
/// shows keys, PINs, passwords or anything stored in the vault, and changes no setting
/// that protects it.
const debugPref = 'debug-mode';
bool debugModeOn() => Prefs.read(debugPref) == '1';

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

  static String get _platform {
    if (Device.iOS) return 'iOS ${Platform.operatingSystemVersion}';
    if (Device.android) return 'Android ${Platform.operatingSystemVersion}';
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final pkg = _pkg;
    final items = _items ?? const <rust.ItemInfo>[];
    int count(String k) => items.where((i) => i.kind == k).length;
    final blocked = _networkBlocked;
    Widget row(String label, String value, {Color? color, Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 15.5))),
              const SizedBox(width: 12),
              Flexible(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 15, color: color ?? c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ],
          ),
        );
    Widget group(String title, List<Widget> rows) => Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 7),
                child: Text(title, style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Material(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(Ui.radius),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, r) in rows.indexed) ...[
                    if (i > 0) Divider(height: 1, indent: 16, color: c.border.withValues(alpha: .6)),
                    r,
                  ],
                ]),
              ),
            ],
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.debugMode)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(l.debugNote, style: TextStyle(color: c.muted, fontSize: 13.5)),
          ),
          group(l.debugBuild, [
            row(l.aboutVersion, pkg == null ? '…' : '${pkg.version} (${pkg.buildNumber})'),
            row(l.aboutBuilt, buildDate.isEmpty ? l.aboutLocal : buildDate),
            row(l.aboutCommit, buildCommit.isEmpty ? l.aboutLocal : buildCommitShort),
            row('Package', pkg?.packageName ?? '…'),
          ]),
          group(l.debugDevice, [
            row(l.debugPlatform, _platform),
            row(l.debugBiometric, switch (_bio) {
              BiometricKind.face => 'Face ID',
              BiometricKind.fingerprint => 'Touch ID / fingerprint',
              _ => l.debugNone,
            }),
            row(l.debugAutoLock, l.debugMinutes(Settings.autoLockMinutes)),
          ]),
          group(l.debugChecks, [
            row(l.debugNetwork, blocked ? l.debugNetworkOn : l.debugNetworkOff,
                color: blocked ? const Color(0xFF30D158) : recordRed(context), key: const ValueKey('debug-network')),
            row(l.debugItems, '${l.kindPhotos} ${count(ItemKind.photo)} · ${l.cameraVideo} ${count(ItemKind.video)} · '
                '${l.kindNotes} ${count(ItemKind.note)} · ${l.modeAudio} ${count(ItemKind.audio)} · ${l.kindFiles} ${count(ItemKind.file)}'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${l.debugPlayback}: ${_temp == null ? '…' : fileSize(BigInt.from(_temp!))}',
                        style: const TextStyle(fontSize: 15.5)),
                  ),
                  TextButton(
                    onPressed: () async {
                      await clearPlaybackCopies();
                      if (!context.mounted) return;
                      showToast(context, l.debugCleared, icon: Icons.check_rounded);
                      _load();
                    },
                    child: Text(l.debugClear),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 24),
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(Ui.radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('debug-off'),
              onTap: () {
                Prefs.write(debugPref, '0');
                Navigator.of(context).pop(true);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(child: Text(l.debugOff, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
