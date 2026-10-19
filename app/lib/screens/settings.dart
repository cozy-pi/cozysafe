import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/identity.dart';
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

/// Everything about the open vault in one place, laid out like the system's own
/// Settings: the vault's card on top, grouped rows with a coloured symbol each, and
/// Delete on its own at the end (docs/ui.md, review 6; approved mockup).
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
    required this.onBackup,
    required this.lastBackup,
    required this.onChangeIdentity,
    required this.onOpenTrash,
    required this.onNewVault,
  });

  final String libraryDir;
  /// Read again after each action: the password may have just been set.
  final rust.VaultInfo Function() vault;
  final bool canBiometric;
  final bool Function() biometricOn;
  final Future<void> Function() onToggleBiometric;
  final Future<void> Function() onPassword;
  final Future<void> Function() onShowKit;
  final Future<void> Function() onBackup;
  final String Function() lastBackup;
  final Future<void> Function() onChangeIdentity;
  final Future<void> Function() onOpenTrash;
  final Future<void> Function() onNewVault;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _minutes = Settings.autoLockMinutes;
  bool _secure = Settings.blockScreenshots;
  final Map<String, BigInt> _byKind = {};
  int _count = 0;

  BigInt get _bytes => _byKind.values.fold(BigInt.zero, (a, b) => a + b);

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
        _byKind.clear();
        for (final i in all) {
          _byKind[i.kind] = (_byKind[i.kind] ?? BigInt.zero) + i.size;
        }
      });
    } catch (_) {}
  }

  String get _sizeText => AppLocalizations.of(context).storageUsed(fileSize(_bytes), _count);

  Future<void> _then(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }

  Future<void> _pickAutoLock() async {
    final l = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(l.autoLock, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              for (final m in Settings.autoLockChoices)
                ListTile(
                  title: Text(l.minutesLong(m)),
                  trailing: m == _minutes ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
                  onTap: () => Navigator.pop(context, m),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(l.autoLockNote, style: TextStyle(color: CsColors.of(context).muted, fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _minutes = picked);
    Settings.autoLockMinutes = picked;
  }

  Future<void> _showSecurity() {
    final l = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.securityTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(l.securityBody, style: TextStyle(color: CsColors.of(context).muted, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteVault() async {
    // The PIN confirms it; a vault opened with its password on this phone gets one first.
    if (!rust.pinEnabled()) {
      final set = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const SetPinScreen(skippable: true, forThisPhone: true)),
      );
      if (set != true || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeleteVaultScreen(libraryDir: widget.libraryDir, vault: widget.vault(), sizeText: _sizeText),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final vault = widget.vault();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final danger = Theme.of(context).colorScheme.error;

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _VaultCard(vault: vault, sizeText: _sizeText, lastBackup: widget.lastBackup(), byKind: _byKind),
          _Group(title: l.settingsThisVault, rows: [
            _Row(
              icon: Icons.palette_outlined,
              tint: const Color(0xFFFF6482),
              title: l.changeIdentity,
              onTap: () => _then(widget.onChangeIdentity),
            ),
            _Row(
              icon: Icons.delete_sweep_outlined,
              tint: const Color(0xFF8E8E93),
              title: l.recentlyDeleted,
              onTap: () => _then(widget.onOpenTrash),
            ),
          ]),
          _Group(title: l.settingsLock, rows: [
            if (widget.canBiometric)
              _Row(
                icon: Icons.face_retouching_natural,
                tint: const Color(0xFF34C759),
                title: l.biometricThisVault,
                trailing: _Switch(
                  value: widget.biometricOn(),
                  onChanged: (_) => _then(widget.onToggleBiometric),
                ),
              ),
            _Row(
              icon: Icons.dialpad,
              tint: const Color(0xFF5E5CE6),
              title: l.pinTitle,
              value: l.change,
              onTap: () => Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SetPinScreen())),
            ),
            _Row(
              icon: Icons.timer_outlined,
              tint: const Color(0xFFFF9F0A),
              title: l.autoLock,
              value: l.afterMinutes(_minutes),
              onTap: _pickAutoLock,
            ),
          ]),
          _Group(title: l.backup, rows: [
            _Row(
              icon: Icons.cloud_upload_outlined,
              tint: const Color(0xFF0A84FF),
              title: l.backupShort,
              subtitle: widget.lastBackup(),
              trailing: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                onPressed: () => _then(widget.onBackup),
                child: Text(l.backupNow),
              ),
            ),
            _Row(
              icon: Icons.key_outlined,
              tint: const Color(0xFFBF5AF2),
              title: l.backupPasswordLabel,
              value: vault.hasPassword ? l.isSet : l.notSet,
              onTap: () => _then(widget.onPassword),
            ),
            if (vault.hasPassword)
              _Row(
                icon: Icons.medical_services_outlined,
                tint: const Color(0xFFFF375F),
                title: l.showKit,
                onTap: widget.onShowKit,
              ),
          ]),
          _Group(title: l.settingsSecurity, rows: [
            _Row(
              icon: Icons.verified_user_outlined,
              tint: const Color(0xFF30B0A0),
              title: l.securityTitle,
              subtitle: l.securityShort,
              onTap: _showSecurity,
            ),
            if (Platform.isAndroid)
              _Row(
                icon: Icons.visibility_off_outlined,
                tint: const Color(0xFF8E8E93),
                title: l.blockScreenshots,
                subtitle: l.blockScreenshotsNote,
                trailing: _Switch(
                  value: _secure,
                  onChanged: (v) {
                    setState(() => _secure = v);
                    Settings.setBlockScreenshots(v);
                  },
                ),
              ),
          ]),
          _Group(title: l.settingsVaults, rows: [
            _Row(
              icon: Icons.add,
              tint: const Color(0xFF30B0C7),
              title: l.newVault,
              subtitle: l.newVaultNote,
              onTap: widget.onNewVault,
            ),
          ]),
          const SizedBox(height: 22),
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _deleteVault,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(l.deleteVault, style: TextStyle(color: danger, fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          // Version and build, to match a phone with its GitHub release run (build = 1000 + run).
          Center(
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Text(
                snap.hasData
                    // Android's version name already ends in the build (0.1.4.1009).
                    ? (snap.data!.version.endsWith('.${snap.data!.buildNumber}')
                        ? l.settingsVersionOnly(snap.data!.version)
                        : l.settingsVersion(snap.data!.version, snap.data!.buildNumber))
                    : l.settingsFooter,
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ),
          ),
          if (dark) const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// The vault itself: its icon, how much it holds (a bar split by kind) and the last
/// backup, on the vault's colour.
class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.vault, required this.sizeText, required this.lastBackup, required this.byKind});

  final rust.VaultInfo vault;
  final String sizeText;
  final String lastBackup;
  final Map<String, BigInt> byKind;

  static const _kinds = [
    ('photo', Color(0xFFFFD88A)),
    ('file', Color(0xFF9FD8FF)),
    ('note', Color(0xFFC8F0C0)),
  ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = colorById(vault.color).color;
    final bg = dark ? Color.lerp(deepForWhite(base), Colors.black, .25)! : deepForWhite(base);
    final total = byKind.values.fold(BigInt.zero, (a, b) => a + b);
    final names = {'photo': l.kindPhotos, 'file': l.kindFiles, 'note': l.kindNotes};
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0x2EFFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x59FFFFFF), width: 1.5),
                ),
                child: Icon(iconById(vault.icon).icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sizeText, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(lastBackup, style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              width: double.infinity,
              child: total == BigInt.zero
                  ? const ColoredBox(color: Color(0x33FFFFFF), child: SizedBox.expand())
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (k, col) in _kinds)
                          if ((byKind[k] ?? BigInt.zero) > BigInt.zero)
                            Expanded(
                              flex: ((byKind[k]! * BigInt.from(1000)) ~/ total).toInt().clamp(1, 1000),
                              child: ColoredBox(color: col),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            children: [
              for (final (k, col) in _kinds)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text(names[k]!, style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 12)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.rows});
  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final c = CsColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 7),
            child: Text(title, style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, indent: 56, color: c.border.withValues(alpha: .6)),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One setting: a white symbol on its own colour, the title (and a second line), then
/// a value with a chevron, a switch, or a button.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.tint,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15.5)),
                    if (subtitle != null)
                      Text(subtitle!, style: TextStyle(color: c.muted, fontSize: 12.5, height: 1.3)),
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(value!, style: TextStyle(color: c.muted, fontSize: 14)),
              ],
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (onTap != null && trailing == null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: c.muted, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The system-green switch, the same in every vault colour.
class _Switch extends StatelessWidget {
  const _Switch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: const Color(0xFF34C759),
        activeThumbColor: Colors.white,
      );
}
