import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../debug_log.dart';
import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../appearance.dart';
import '../language.dart';
import '../links.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'common.dart' show fadeRoute;
import 'debug.dart';
import 'security_info.dart';
import '../widgets/toast.dart';
import '../build_info.dart';
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

  /// Keep the vault out of screenshots and recordings: Android FLAG_SECURE (and the
  /// recent-apps preview), iPhone a secure layer (AppDelegate.swift). On by default.
  static bool get blockScreenshots => Prefs.read(_secure) != '0';

  /// Mockups: show the iPhone row on any platform.
  static bool debugIOS = false;

  static const _privacy = MethodChannel('cozysafe/privacy');

  static Future<void> setBlockScreenshots(bool on) async {
    Prefs.write(_secure, on ? '1' : '0');
    await apply();
  }

  /// Called at start-up: the window starts protected, this turns it off if asked.
  static Future<void> apply() async {
    if (!Device.android && !Device.iOS) return;
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

  // Seven taps on the version turn on debug mode, after the owner check (docs/security.md).
  int _taps = 0;
  DateTime _tapAt = DateTime(0);

  Future<void> _versionTap() async {
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    _taps = now.difference(_tapAt) < const Duration(seconds: 2) ? _taps + 1 : 1;
    _tapAt = now;
    if (debugModeOn()) {
      if (_taps >= 3) showToast(context, l.debugAlready);
      return;
    }
    if (_taps >= 3 && _taps < 7) showToast(context, l.debugTapsLeft(7 - _taps));
    if (_taps < 7) return;
    _taps = 0;
    await _guarded(() async {
      Prefs.write(debugPref, '1');
      DebugLog.sync();
      if (!mounted) return;
      setState(() {});
      showToast(context, l.debugOn, icon: Icons.bug_report_outlined);
    });
  }

  Future<void> _then(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }



  String _appearanceName(AppLocalizations l, ThemeMode m) => switch (m) {
        ThemeMode.light => l.appearanceLight,
        ThemeMode.dark => l.appearanceDark,
        ThemeMode.system => l.appearanceAuto,
      };

  /// Automatic · Light · Dark: a menu at the row, like auto-lock.
  final _appearanceKey = GlobalKey();
  Future<void> _pickAppearance() async {
    final l = AppLocalizations.of(context);
    final box = _appearanceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset.zero) & box.size;
    final size = MediaQuery.sizeOf(context);
    final now = Appearance.mode.value;
    final picked = await showMenu<ThemeMode>(
      context: context,
      position: RelativeRect.fromLTRB(at.right - 220, at.bottom - 8, size.width - at.right + 12, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.radius)),
      items: [
        for (final m in Appearance.choices)
          PopupMenuItem(
            key: ValueKey('appearance-${m.name}'),
            value: m,
            height: Ui.circle,
            child: Row(children: [
              SizedBox(width: 26, child: m == now ? const Icon(Icons.check_rounded, size: 20) : null),
              Icon(
                switch (m) {
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.dark => Icons.dark_mode_outlined,
                  ThemeMode.system => Icons.brightness_auto_outlined,
                },
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(_appearanceName(l, m), style: TextStyle(fontWeight: m == now ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    Appearance.choose(picked);
    setState(() {});
  }

  /// A few choices: a menu right at the row, next to the value (no sheet at the bottom).
  final _autoLockKey = GlobalKey();
  Future<void> _pickAutoLock() async {
    final l = AppLocalizations.of(context);
    final box = _autoLockKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset.zero) & box.size;
    final size = MediaQuery.sizeOf(context);
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(at.right - 220, at.bottom - 8, size.width - at.right + 12, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.radius)),
      items: [
        for (final m in Settings.autoLockChoices)
          PopupMenuItem(
            value: m,
            height: Ui.circle,
            child: Row(children: [
              SizedBox(width: 26, child: m == _minutes ? const Icon(Icons.check_rounded, size: 20) : null),
              Text(l.minutesLong(m), style: TextStyle(fontWeight: m == _minutes ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
        PopupMenuItem(
          enabled: false,
          child: SizedBox(
            width: 200,
            child: Text(l.autoLockNote, style: TextStyle(color: CsColors.of(context).muted, fontSize: 12.5)),
          ),
        ),
      ],
    );
    if (picked == null) return;
    setState(() => _minutes = picked);
    Settings.autoLockMinutes = picked;
  }

  /// What protects the vault, explained with drawings: its own page (long content).
  Future<void> _showSecurity() =>
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const SecurityInfoScreen()));

  Future<void> _deleteVault() async {
    // The PIN confirms it; a vault opened with its password on this phone gets one first.
    if (!rust.pinEnabled()) {
      final set = await Navigator.of(context).push<bool>(
        fadeRoute((_) => const SetPinScreen(skippable: true, forThisPhone: true)),
      );
      if (set != true || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeleteVaultScreen(libraryDir: widget.libraryDir, vault: widget.vault(), sizeText: _sizeText),
    ));
  }

  Future<void> _pickLanguage() async {
    final l = AppLocalizations.of(context);
    final picked = await pushPage<String>(
      context,
      title: l.language,
      builder: (context) => _LanguageList(chosen: AppLanguage.chosen, system: l.languageSystem, systemNote: l.languageSystemNote),
    );
    if (picked == null || !mounted) return;
    await AppLanguage.choose(picked.isEmpty ? null : picked);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final vault = widget.vault();
    final dark = Theme.of(context).brightness == Brightness.dark;

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
            // The icon on a plain page after unlocking; only a look, so no owner check.
            _Row(
              key: const ValueKey('reveal-row'),
              icon: Icons.auto_awesome_outlined,
              color: _Mau.cham,
              title: l.revealIcon,
              trailing: _Switch(
                value: revealIconOn(),
                onChanged: (v) => setState(() => Prefs.write(revealIconPref, v ? '1' : '0')),
              ),
            ),
            _Row(
              icon: Icons.delete_sweep_outlined,
              color: _Mau.xam,
              title: l.recentlyDeleted,
              onTap: () => _then(widget.onOpenTrash),
            ),
          ]),
          // One Security group (owner 2026-10-21): how it opens every day, how it opens on
          // a new phone, and what keeps it private while open.
          _Group(title: l.settingsSecurity, rows: [
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
              onTap: () => _guarded(() => Navigator.of(context).push<bool>(fadeRoute((_) => const SetPinScreen()))),
            ),
            _Row(
              key: _autoLockKey,
              icon: Icons.timer_outlined,
              color: _Mau.cam,
              title: l.autoLock,
              value: l.afterMinutes(_minutes),
              onTap: () => _guarded(_pickAutoLock),
            ),

            if (vault.hasPassword)
              _Row(
                key: const ValueKey('kit-row'),
                icon: Icons.medical_services_outlined,
                color: _Mau.doTuoi,
                title: l.showKit,
                onTap: widget.onShowKit,
              ),
            _Row(
              icon: Icons.key_outlined,
              color: _Mau.vang,
              title: l.backupPasswordLabel,
              value: vault.hasPassword ? l.isSet : l.notSet,
              onTap: () => _then(widget.onPassword),
            ),
            _Row(
              icon: Icons.verified_user_outlined,
              color: _Mau.ngoc,
              title: l.securityTitle,
              onTap: _showSecurity,
            ),
          ]),
          // Only the backup here (owner 2026-10-21): the Recovery Key and the password,
          // which open it on a new phone, live under Security; the backup sheet names them.
          _Group(title: l.settingsBackupData, rows: [
            _Row(
              icon: Icons.cloud_upload_outlined,
              color: _Mau.xanh,
              title: l.backupShort,
              trailing: FilledButton(
                style: FilledButton.styleFrom(
                  // Settings may use colour (owner): a soft tint of the backup blue, low
                  // contrast in both modes, never a black or white slab.
                  backgroundColor: _Mau.xanh.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .22 : .12),
                  foregroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF64A8FF) : _Mau.xanh,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                onPressed: () => _then(widget.onBackup),
                child: Text(l.backupNow),
              ),
            ),
          ]),
          _Group(title: l.settingsDisplay, rows: [
            _Row(
              key: _appearanceKey,
              icon: Icons.contrast_rounded,
              color: _Mau.cham,
              title: l.appearance,
              value: _appearanceName(l, Appearance.mode.value),
              onTap: _pickAppearance,
            ),
            // Same list as Settings → Cozy Safe → Language on iPhone and Android 13+.
            _Row(
              key: const ValueKey('language-row'),
              icon: Icons.translate_rounded,
              color: _Mau.xanh,
              title: l.language,
              value: AppLanguage.chosen == null
                  ? l.languageSystem
                  : languages.firstWhere((x) => x.code == AppLanguage.chosen).name,
              onTap: _pickLanguage,
            ),
            // Left, middle or right right on the row: no sheet to open (owner 2026-10-24).
            _Row(
              key: const ValueKey('side-row'),
              icon: Icons.back_hand_outlined,
              color: _Mau.cam,
              title: l.actionSide,
              trailing: _SideSwitch(
                side: actionSide(),
                labels: (l.sideLeftShort, l.sideCenterShort, l.sideRightShort),
                onChanged: (v) => setState(() => Prefs.write(actionSidePref, v.name)),
              ),
            ),
            _Row(
              key: const ValueKey('hold-home-row'),
              icon: Icons.lock_outline_rounded,
              color: _Mau.tim,
              title: l.holdHomeTitle,
              trailing: _Switch(
                value: holdHomeLocks(),
                onChanged: (on) => setState(() => Prefs.write(holdHomePref, on ? '1' : '0')),
              ),
            ),
            _Row(
              icon: Icons.notes_rounded,
              color: _Mau.bacHa,
              // "Hide", on by default (owner 2026-10-21): the safe state is the on state,
              // like "Blur thumbnails". The pref keeps its old meaning (1 = show text).
              key: const ValueKey('hide-note-text-row'),
              title: l.hideNoteText,
              trailing: _Switch(
                value: !notePreviews(),
                // Showing more is weaker: turning "hide" off asks for the owner.
                onChanged: (hide) => hide
                    ? setState(() => Prefs.write(notePreviewsPref, '0'))
                    : _guarded(() async => setState(() => Prefs.write(notePreviewsPref, '1'))),
              ),
            ),
            _Row(
              key: const ValueKey('blur-row'),
              icon: Icons.blur_on_rounded,
              color: _Mau.ngoc,
              title: l.blurThumbs,
              trailing: _Switch(
                value: blurThumbnails(),
                // Turning it on protects more; turning it off asks for the owner.
                onChanged: (v) => v
                    ? setState(() => Prefs.write(blurThumbsPref, '1'))
                    : _guarded(() async => setState(() => Prefs.write(blurThumbsPref, '0'))),
              ),
            ),
            // With the other privacy-on-screen switches (owner 2026-10-21).
            if (Device.android || Device.iOS || Settings.debugIOS)
              _Row(
                icon: Icons.visibility_off_outlined,
              color: _Mau.hong,
                title: l.blockScreenshots,
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
                  // Destructive in the system red, like Delete elsewhere (docs/ui.md); the theme's
                  // error colour is ink in this black-and-white design.
                  child: Text(l.deleteVault, style: TextStyle(color: recordRed(context), fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            ),
          ),
          // About: version and build (to match a phone with its release run, build =
          // 1000 + run), when and from which commit it was built, the licence.
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              final p = snap.data;
              // Android's version name already ends in the build (0.1.4.1009).
              final version = p == null
                  ? '…'
                  : p.version.endsWith('.${p.buildNumber}')
                      ? p.version
                      : '${p.version} (${p.buildNumber})';
              DateTime? built = DateTime.tryParse(buildDate);
              final ml = MaterialLocalizations.of(context);
              return _Group(title: l.settingsAbout, rows: [
                _Row(
                  key: const ValueKey('about-version'),
                  icon: Icons.info_outline_rounded,
                  color: _Mau.xam,
                  title: l.aboutVersion,
                  value: version,
                  onTap: _versionTap,
                  chevron: false,
                ),
                _Row(
                  icon: Icons.schedule_rounded,
                  color: _Mau.xam,
                  title: l.aboutBuilt,
                  value: built == null
                      ? l.aboutLocal
                      : '${ml.formatShortDate(built.toLocal())} ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(built.toLocal()))}',
                ),
                _Row(
                  icon: Icons.code_rounded,
                  color: _Mau.xam,
                  title: l.aboutCommit,
                  value: buildCommit.isEmpty ? l.aboutLocal : buildCommitShort,
                ),
                _Row(icon: Icons.gavel_rounded, color: _Mau.xam, title: l.aboutLicense, value: 'GPL-3.0'),
                // Feedback lives on the website; the app only opens it (owner 2026-10-21).
                _Row(
                  key: const ValueKey('feedback-row'),
                  icon: Icons.chat_bubble_outline_rounded,
                  color: _Mau.xanh,
                  title: l.feedback,
                  onTap: Links.canOpen ? () => Links.open(Links.feedback(_langCode(context))) : null,
                ),
                if (debugModeOn())
                  _Row(
                    key: const ValueKey('debug-row'),
                    icon: Icons.bug_report_outlined,
                    color: _Mau.doTuoi,
                    title: l.debugMode,
                    onTap: () async {
                      await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const DebugScreen()));
                      if (mounted) setState(() {});
                    },
                  ),
              ]);
            },
          ),
          const SizedBox(height: 12),
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

  /// Every kind in the storage bar, each in its own iOS system colour (owner 2026-10-21:
  /// grey shades were hard to tell apart). Video and voice count too.
  static const _kinds = [
    (ItemKind.photo, Color(0xFF0A84FF)),
    (ItemKind.video, Color(0xFFBF5AF2)),
    (ItemKind.note, Color(0xFFFFD60A)),
    (ItemKind.audio, Color(0xFFFF9F0A)),
    (ItemKind.file, Color(0xFF30D158)),
  ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The same surface as the groups below, ink text: a black card in light mode and a
    // white one in dark mode were both too strong (owner 2026-10-21).
    final bg = Theme.of(context).cardColor;
    final fg = Theme.of(context).colorScheme.onSurface;
    final total = byKind.values.fold(BigInt.zero, (a, b) => a + b);
    final names = {
      ItemKind.photo: l.kindPhotos,
      ItemKind.video: l.cameraVideo,
      ItemKind.note: l.kindNotes,
      ItemKind.audio: l.modeAudio,
      ItemKind.file: l.kindFiles,
    };
    BigInt size(String k) => byKind[k] ?? BigInt.zero;
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
                        for (final (k, color) in _kinds)
                          if (size(k) > BigInt.zero)
                            Expanded(
                              flex: ((size(k) * BigInt.from(1000)) ~/ total).toInt().clamp(1, 1000),
                              child: Padding(
                                padding: const EdgeInsets.only(right: 2), // a hairline between kinds
                                child: ColoredBox(color: color),
                              ),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final (k, color) in _kinds)
                if (size(k) > BigInt.zero) Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text('${names[k]!} ${fileSize(size(k))}', style: TextStyle(color: fg.withValues(alpha: .9), fontSize: 12.5)),
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
    super.key,
    required this.icon,
    required this.color,
    this.glyph,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
    this.chevron = true,
  });

  /// False for a tap nobody should notice (the version's hidden debug taps).
  final bool chevron;

  final IconData icon;
  /// The tile's colour (white symbol on it).
  final Color color;
  /// A drawn symbol instead of [icon] (the real Face ID glyph).
  final Widget? glyph;
  final String title;
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
              // Just a name, no note under it (owner 2026-10-21): the name says enough.
              Expanded(child: Text(title, style: const TextStyle(fontSize: 15.5))),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(value!, style: TextStyle(color: c.muted, fontSize: 14)),
              ],
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (onTap != null && trailing == null && chevron) ...[
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
        // On is the iPhone's green with a white knob (settings may use colour; a black or
        // white track was too strong, owner 2026-10-21).
        activeTrackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF30D158) : _Mau.xanhLa,
        activeThumbColor: Colors.white,
      );
}

class _SideSwitch extends StatelessWidget {
  const _SideSwitch({required this.side, required this.labels, required this.onChanged});
  final ActionSide side;
  final (String, String, String) labels;
  final ValueChanged<ActionSide> onChanged;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget part(String text, ActionSide value) {
      final on = side == value;
      return GestureDetector(
        key: ValueKey('side-${value.name}'),
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? (dark ? ink.withValues(alpha: .28) : Colors.white) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: on && !dark ? const [BoxShadow(color: Color(0x22000000), blurRadius: 4, offset: Offset(0, 1))] : null,
          ),
          child: Text(text, style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: ink.withValues(alpha: .08), borderRadius: BorderRadius.circular(19)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        part(labels.$1, ActionSide.left),
        part(labels.$2, ActionSide.center),
        part(labels.$3, ActionSide.right),
      ]),
    );
  }
}

/// "Same as device", then every language in its own name; a tick on the current one.
/// Pops the code ('' for the device's).
class _LanguageList extends StatelessWidget {
  const _LanguageList({required this.chosen, required this.system, required this.systemNote});
  final String? chosen;
  final String system;
  final String systemNote;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    Widget row(String code, String name, {String? note}) => ListTile(
          key: ValueKey('language-$code'),
          minTileHeight: 52,
          title: Text(name, style: const TextStyle(fontSize: 16)),
          subtitle: note == null ? null : Text(note, style: TextStyle(color: c.muted)),
          trailing: (code.isEmpty ? chosen == null : chosen == code)
              ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () => Navigator.of(context).pop(code),
        );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        row('', system, note: systemNote),
        const Divider(indent: 16, endIndent: 16),
        for (final x in languages) row(x.code, x.name),
      ],
    );
  }
}

/// The app's language as the arb code ("zh_Hant" for Traditional Chinese).
String _langCode(BuildContext context) {
  final l = Localizations.localeOf(context);
  return l.scriptCode == 'Hant' ? 'zh_Hant' : l.languageCode;
}
