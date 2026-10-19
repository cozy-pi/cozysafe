import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import 'delete_vault.dart';
import 'file_view.dart';
import 'set_pin.dart';

/// Per-device choices, kept next to the library (not secret).
abstract final class Settings {
  static const _autoLock = 'auto-lock-min';
  static const _secure = 'block-screenshots';
  static const autoLockChoices = [1, 2, 5, 10];

  /// Minutes without a touch before the open vault locks.
  static int get autoLockMinutes {
    final m = int.tryParse(Prefs.read(_autoLock) ?? '');
    return autoLockChoices.contains(m) ? m! : 2;
  }

  static set autoLockMinutes(int m) => Prefs.write(_autoLock, '$m');

  /// Android only: keep the vault out of screenshots and the recent-apps preview.
  static bool get blockScreenshots => Prefs.read(_secure) != '0';

  static const _privacy = MethodChannel('cozysafe/privacy');

  static Future<void> setBlockScreenshots(bool on) async {
    Prefs.write(_secure, on ? '1' : '0');
    await apply();
  }

  /// Called at start-up: the window starts protected, this turns it off if asked.
  static Future<void> apply() async {
    if (!Platform.isAndroid) return;
    try {
      await _privacy.invokeMethod<void>('setSecure', blockScreenshots);
    } catch (_) {}
  }
}

/// Everything about the open vault in one place (docs/ui.md, review 6).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.libraryDir,
    required this.vault,
    required this.canBiometric,
    required this.biometricOn,
    required this.onToggleBiometric,
    required this.onPassword,
    required this.onShowKit,
    required this.lastBackup,
  });

  final String libraryDir;
  final rust.VaultInfo vault;
  final bool canBiometric;
  final bool Function() biometricOn;
  final Future<void> Function() onToggleBiometric;
  final Future<void> Function() onPassword;
  final Future<void> Function() onShowKit;
  final String lastBackup;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _minutes = Settings.autoLockMinutes;
  bool _secure = Settings.blockScreenshots;
  BigInt _bytes = BigInt.zero;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final all = [...await rust.listItems(), ...await rust.listTrash()];
      if (!mounted) return;
      setState(() {
        _count = all.length;
        _bytes = all.fold(BigInt.zero, (a, i) => a + i.size);
      });
    } catch (_) {}
  }

  String get _sizeText => AppLocalizations.of(context).storageUsed(fileSize(_bytes), _count);

  Future<void> _deleteVault() async {
    // The PIN confirms it; a vault opened with its password on this phone gets one first.
    if (!rust.pinEnabled()) {
      final set = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const SetPinScreen(skippable: true, forThisPhone: true)),
      );
      if (set != true || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeleteVaultScreen(libraryDir: widget.libraryDir, vault: widget.vault, sizeText: _sizeText),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final danger = Theme.of(context).colorScheme.error;
    Widget group(String title, List<Widget> rows) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(title, style: TextStyle(color: c.muted, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              Material(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(children: ListTile.divideTiles(context: context, tiles: rows).toList()),
              ),
            ],
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: ListView(
        children: [
          group(l.settingsLock, [
            ListTile(
              title: Text(l.autoLock),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final m in Settings.autoLockChoices) ButtonSegment(value: m, label: Text(l.minutesShort(m))),
                  ],
                  selected: {_minutes},
                  onSelectionChanged: (v) {
                    setState(() => _minutes = v.first);
                    Settings.autoLockMinutes = v.first;
                  },
                ),
              ),
            ),
            if (widget.canBiometric)
              SwitchListTile(
                title: Text(l.biometricThisVault),
                value: widget.biometricOn(),
                onChanged: (_) async {
                  await widget.onToggleBiometric();
                  if (mounted) setState(() {});
                },
              ),
            ListTile(
              title: Text(l.changePin),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SetPinScreen())),
            ),
          ]),
          group(l.backup, [
            ListTile(title: Text(l.lastBackupLabel), trailing: Text(widget.lastBackup, style: TextStyle(color: c.muted))),
            ListTile(
              title: Text(widget.vault.hasPassword ? l.changePasswordTitle : l.backupPasswordTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onPassword,
            ),
            if (widget.vault.hasPassword)
              ListTile(title: Text(l.showKit), trailing: const Icon(Icons.chevron_right), onTap: widget.onShowKit),
          ]),
          if (Platform.isAndroid)
            group(l.settingsPrivacy, [
              SwitchListTile(
                title: Text(l.blockScreenshots),
                subtitle: Text(l.blockScreenshotsNote),
                value: _secure,
                onChanged: (v) {
                  setState(() => _secure = v);
                  Settings.setBlockScreenshots(v);
                },
              ),
            ]),
          group(l.settingsThisVault, [
            ListTile(title: Text(l.storage), trailing: Text(_sizeText, style: TextStyle(color: c.muted))),
            ListTile(
              title: Text(l.deleteVault, style: TextStyle(color: danger)),
              onTap: _deleteVault,
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
