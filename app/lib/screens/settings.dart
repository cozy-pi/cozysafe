import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../item_kind.dart';
import '../prefs.dart';
import '../widgets/identity.dart';
import '../widgets/vault_bar.dart';
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
    if (!Device.android) return;
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
    if (widget.canBiometric) {
      BiometricUnlock.available().then((k) {
        if (mounted && k != null) setState(() => _bioKind = k);
      });
    }
  }

  /// Which biometric symbol to show: iPhones have Face ID, until the device says otherwise.
  BiometricKind _bioKind = Device.iOS ? BiometricKind.face : BiometricKind.fingerprint;

  Future<void> _measure() async {
    try {
      // Tags are names only: not counted as things kept.
      final all = [...await rust.listItems(), ...await rust.listTrash()].where((i) => i.kind != ItemKind.tag);
      if (!mounted) return;
      setState(() {
        _count = all.length;
        _byKind.clear();
        for (final i in all) {
          _byKind[i.kind] = (_byKind[i.kind] ?? BigInt.zero) + i.sizeBytes;
        }
      });
    } catch (_) {}
  }

  String get _sizeText => AppLocalizations.of(context).storageUsed(fileSize(_bytes), _count);

  /// Security settings changed here ask for the owner first (docs/security.md); the ones
  /// that live in the vault screen (password, backup, kit, biometrics) ask there.
  Future<void> _guarded(Future<void> Function() action) async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    await action();
  }

  Future<void> _then(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }

  /// The main action floats on the left (under the left thumb) or the right.
  Future<void> _pickActionSide() async {
    final l = AppLocalizations.of(context);
    final right = actionOnRight();
    final picked = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (r, label) in [(false, l.sideLeft), (true, l.sideRight)])
              ListTile(
                title: Text(label),
                trailing: r == right ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.pop(context, r),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    Prefs.write(actionSidePref, picked ? 'right' : 'left');
    setState(() {});
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
              color: _Mau.tim,
              title: l.changeIdentity,
              onTap: () => _then(widget.onChangeIdentity),
            ),
            _Row(
              icon: Icons.delete_sweep_outlined,
              color: _Mau.xam,
              title: l.recentlyDeleted,
              onTap: () => _then(widget.onOpenTrash),
            ),
          ]),
          _Group(title: l.settingsLock, rows: [
            if (widget.canBiometric)
              _Row(
                icon: Icons.face_retouching_natural,
                color: _Mau.xanhLa,
                // The device's own symbol: the Face ID glyph, or a fingerprint (biometric.dart).
                glyph: BiometricGlyph(kind: _bioKind, size: 19, color: Colors.white),
                title: _bioKind == BiometricKind.face ? l.biometricThisVault : l.fingerprintThisVault,
                trailing: _Switch(
                  value: widget.biometricOn(),
                  onChanged: (_) => _then(widget.onToggleBiometric),
                ),
              ),
            _Row(
              icon: Icons.dialpad,
              color: _Mau.cham,
              title: l.pinTitle,
              value: l.change,
              onTap: () => _guarded(() => Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SetPinScreen()))),
            ),
            _Row(
              icon: Icons.timer_outlined,
              color: _Mau.cam,
              title: l.autoLock,
              value: l.afterMinutes(_minutes),
              onTap: () => _guarded(_pickAutoLock),
            ),
          ]),
          _Group(title: l.backup, rows: [
            _Row(
              icon: Icons.cloud_upload_outlined,
              color: _Mau.xanh,
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
              color: _Mau.vang,
              title: l.backupPasswordLabel,
              value: vault.hasPassword ? l.isSet : l.notSet,
              onTap: () => _then(widget.onPassword),
            ),
            if (vault.hasPassword)
              _Row(
                icon: Icons.medical_services_outlined,
              color: _Mau.doTuoi,
                title: l.showKit,
                onTap: widget.onShowKit,
              ),
          ]),
          _Group(title: l.settingsDisplay, rows: [
            _Row(
              icon: Icons.back_hand_outlined,
              color: _Mau.cam,
              title: l.actionSide,
              value: actionOnRight() ? l.sideRight : l.sideLeft,
              onTap: _pickActionSide,
            ),
            _Row(
              icon: Icons.notes_rounded,
              color: _Mau.bacHa,
              title: l.notePreviews,
              subtitle: l.notePreviewsNote,
              trailing: _Switch(
                value: notePreviews(),
                // Showing more is weaker: on asks for the owner, off never does.
                onChanged: (v) => v
                    ? _guarded(() async => setState(() => Prefs.write(notePreviewsPref, '1')))
                    : setState(() => Prefs.write(notePreviewsPref, '0')),
              ),
            ),
          ]),
          _Group(title: l.settingsSecurity, rows: [
            _Row(
              icon: Icons.verified_user_outlined,
              color: _Mau.ngoc,
              title: l.securityTitle,
              subtitle: l.securityShort,
              onTap: _showSecurity,
            ),
            if (Device.android)
              _Row(
                icon: Icons.visibility_off_outlined,
              color: _Mau.hong,
                title: l.blockScreenshots,
                subtitle: l.blockScreenshotsNote,
                trailing: _Switch(
                  value: _secure,
                  onChanged: (v) => _guarded(() async {
                    setState(() => _secure = v);
                    Settings.setBlockScreenshots(v);
                  }),
                ),
              ),
          ]),
          _Group(title: l.settingsVaults, rows: [
            _Row(
              icon: Icons.add,
              color: _Mau.troi,
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
              onTap: () => _guarded(_deleteVault),
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

  /// Kinds in the storage bar, told apart by how strong the page colour is on the ink.
  static const _kinds = [(ItemKind.photo, 1.0), (ItemKind.file, .62), (ItemKind.note, .34)];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Black and white: the card in ink, its text in the page colour.
    final bg = Theme.of(context).colorScheme.onSurface;
    final fg = Theme.of(context).scaffoldBackgroundColor;
    final total = byKind.values.fold(BigInt.zero, (a, b) => a + b);
    final names = {ItemKind.photo: l.kindPhotos, ItemKind.file: l.kindFiles, ItemKind.note: l.kindNotes};
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              VaultBadge(icon: vault.icon, color: vault.color, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sizeText, style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(lastBackup, style: TextStyle(color: fg.withValues(alpha: .85), fontSize: 13)),
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
                  ? ColoredBox(color: fg.withValues(alpha: .2), child: const SizedBox.expand())
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (k, strength) in _kinds)
                          if ((byKind[k] ?? BigInt.zero) > BigInt.zero)
                            Expanded(
                              flex: ((byKind[k]! * BigInt.from(1000)) ~/ total).toInt().clamp(1, 1000),
                              child: ColoredBox(color: fg.withValues(alpha: strength)),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            children: [
              for (final (k, strength) in _kinds)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: fg.withValues(alpha: strength), shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text(names[k]!, style: TextStyle(color: fg.withValues(alpha: .9), fontSize: 12)),
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

/// One setting: a white symbol on its own colour (iOS Settings palette — owner 2026-10-20:
/// "the icons inside Settings may have colour", an exception to black and white), the title
/// (and a second line), then a value with a chevron, a switch, or a button.
/// iOS system colours for the setting tiles.
abstract final class _Mau {
  static const tim = Color(0xFFAF52DE), xam = Color(0xFF8E8E93), xanhLa = Color(0xFF34C759),
      cham = Color(0xFF5856D6), cam = Color(0xFFFF9500), xanh = Color(0xFF007AFF),
      doTuoi = Color(0xFFFF3B30), ngoc = Color(0xFF30B0C7), hong = Color(0xFFFF2D55), troi = Color(0xFF32ADE6),
      vang = Color(0xFFFFB300), bacHa = Color(0xFF00C7BE); // brown (nau) dropped: owner found it ugly
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    this.glyph,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  /// The tile's colour (white symbol on it).
  final Color color;
  /// A drawn symbol instead of [icon] (the real Face ID glyph).
  final Widget? glyph;
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
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
                child: Center(child: glyph ?? Icon(icon, color: Colors.white, size: 18)),
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

/// A switch in ink: on is solid ink with a page-coloured thumb.
class _Switch extends StatelessWidget {
  const _Switch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: Theme.of(context).colorScheme.onSurface,
        activeThumbColor: Theme.of(context).scaffoldBackgroundColor,
      );
}
