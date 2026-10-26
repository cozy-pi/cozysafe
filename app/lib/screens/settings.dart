import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../debug_log.dart';
import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../appearance.dart';
import '../language.dart';
import '../links.dart';
import '../platform.dart';
import '../src/rust/api/sync.dart' as sync;
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
import 'error_report.dart';
import 'set_pin.dart';
import 'tour.dart';
import '../sync/sync_screen.dart';

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

  static const _lockOnLeave = 'lock-on-leave';

  /// Leaving the app locks the vault at once (on by default). Off, the vault locks once
  /// the app has been away for [autoLockMinutes] (vault_home.dart, AwayClock); turning it
  /// off asks for the owner (docs/security.md).
  static bool get lockOnLeave => Prefs.read(_lockOnLeave) != '0';
  static set lockOnLeave(bool on) => Prefs.write(_lockOnLeave, on ? '1' : '0');

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

/// A setting Settings can open at (the quick tour's "Set up sync now" opens Sync), with
/// its row's symbol and colour.
enum SettingsSpot {
  sync(Icons.sync_rounded, _Mau.xanhLa),
  autoLock(Icons.timer_outlined, _Mau.cam),
  blurThumbs(Icons.blur_on_rounded, _Mau.ngoc),
  hideNoteText(Icons.notes_rounded, _Mau.bacHa),
  appearance(Icons.contrast_rounded, _Mau.cham),
  language(Icons.translate_rounded, _Mau.xanh);

  const SettingsSpot(this.icon, this.color);
  final IconData icon;
  final Color color;
}

/// A setting's symbol: white on its own colour, as at the start of each row.
class SettingTile extends StatelessWidget {
  const SettingTile({super.key, required this.icon, required this.color, this.glyph});
  final IconData icon;
  final Color color;
  final Widget? glyph;

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Center(child: glyph ?? Icon(icon, color: Colors.white, size: 18)),
      );
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
    this.onSynced,
    this.focus,
    this.guideFrom,
    this.onTour,
  });

  /// User guide: its first tips are on the vault's page, so Settings closes and the
  /// vault's page runs it; it comes back here for the rest ([guideFrom]).
  final VoidCallback? onTour;

  /// The User guide goes on here after this many tips on the vault's page.
  final int? guideFrom;

  /// How many User guide tips are in Settings ([_SettingsScreenState._guideTips]).
  static int get guideTipCount => kIsWeb ? 3 : 4;

  /// Opened from the quick tour: scroll to this setting and light it up (Sync: open it).
  final SettingsSpot? focus;

  final String libraryDir;
  /// Items came in from another device: the vault screen reloads.
  final VoidCallback? onSynced;
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

  /// For the mockup renders: the connection log without a vault.
  static List<String>? debugSyncLog;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _minutes = Settings.autoLockMinutes;
  bool _secure = Settings.blockScreenshots;
  bool _lockOnLeave = Settings.lockOnLeave;
  final Map<String, BigInt> _byKind = {};
  int _count = 0;
  /// The last figures per vault, in memory only (sizes and counts are about the vault, so
  /// never written out): Settings shows them at once while it measures again
  /// (owner 2026-10-27: the storage line came late).
  static final _lastSizes = <String, (Map<String, BigInt>, int)>{};

  BigInt get _bytes => _byKind.values.fold(BigInt.zero, (a, b) => a + b);

  @override
  void initState() {
    super.initState();
    if (_lastSizes[widget.vault().id] case (final kinds, final count)) {
      _byKind.addAll(kinds);
      _count = count;
    }
    _measure();
    _loadLastSync();
    if (widget.focus case final spot?) WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(spot));
    if (widget.guideFrom case final from?) WidgetsBinding.instance.addPostFrameCallback((_) => _guide(from));
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
      _lastSizes[widget.vault().id] = (Map.of(_byKind), _count);
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
  final _debugRowKey = GlobalKey(debugLabel: 'debug-row');

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
      // No toast: it covered the Debug row that had just appeared (owner 2026-10-24).
      // The row itself, scrolled into view with a tick, says debug mode is on.
      HapticFeedback.mediumImpact();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final row = _debugRowKey.currentContext;
        if (row != null) Scrollable.ensureVisible(row, alignment: .5, duration: const Duration(milliseconds: 300));
      });
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
      builder: (context) => _LanguageList(chosen: AppLanguage.chosen, system: l.languageSystem),
    );
    if (picked == null || !mounted) return;
    await AppLanguage.choose(picked.isEmpty ? null : picked);
    if (mounted) setState(() {});
  }

  /// When this vault last synced fully, anywhere (from the connection log).
  DateTime? _lastSync;

  Future<void> _loadLastSync() async {
    if (kIsWeb) return;
    try {
      final log = SettingsScreen.debugSyncLog ?? await sync.connectionLog();
      int? newest;
      for (final line in log) {
        final p = line.split('|');
        final ms = p.isNotEmpty ? int.tryParse(p[0]) : null;
        if (p.length > 3 && p[3] == 'ok' && ms != null && (newest == null || ms > newest)) newest = ms;
      }
      if (mounted) setState(() => _lastSync = newest == null ? null : DateTime.fromMillisecondsSinceEpoch(newest));
    } catch (_) {}
  }

  String _lastSyncText(AppLocalizations l) {
    final at = _lastSync;
    if (at == null) return l.syncLastNever;
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return l.syncLastJustNow;
    if (ago.inHours < 1) return l.syncLastMinutes(ago.inMinutes);
    if (ago.inDays < 1) return l.syncLastHours(ago.inHours);
    return l.syncLastDays(ago.inDays);
  }

  Future<void> _openSync() async {
    final l = AppLocalizations.of(context);
    await pushPage<void>(context,
        title: l.syncTitle,
        builder: (_) => SyncScreen(
            libraryDir: widget.libraryDir,
            onSynced: () {
              widget.onSynced?.call();
              _measure(); // the storage line follows what came in
            }));
    _loadLastSync();
  }

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Rows the quick tour points at, found to scroll to them.
  late final _spotKeys = {
    for (final s in SettingsSpot.values)
      s: switch (s) {
        SettingsSpot.autoLock => _autoLockKey,
        SettingsSpot.appearance => _appearanceKey,
        _ => GlobalKey(debugLabel: 'spot-${s.name}'),
      },
  };
  /// The row just reached from the tour, lit up for a moment.
  SettingsSpot? _lit;

  /// Takes the person to [spot]: Sync opens; any other row scrolls into the middle and
  /// lights up, so it is easy to see which one to change.
  Future<void> _goTo(SettingsSpot spot) async {
    if (!mounted) return;
    if (spot == SettingsSpot.sync) return _openSync();
    final row = await _build(_spotKeys[spot]!);
    if (row == null || !row.mounted || !mounted) return;
    setState(() => _lit = spot);
    await Scrollable.ensureVisible(row, alignment: .4, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && _lit == spot) setState(() => _lit = null);
  }

  /// [key]'s widget, built: rows far down are not built yet, so the list moves down a
  /// screen at a time until it is.
  Future<BuildContext?> _build(GlobalKey key) async {
    var row = key.currentContext;
    for (var i = 0; row == null && i < 12 && _scroll.hasClients; i++) {
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent) break;
      _scroll.jumpTo((p.pixels + p.viewportDimension).clamp(0, p.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return null;
      row = key.currentContext;
    }
    return row != null && row.mounted ? row : null;
  }

  /// What the User guide points at in Settings.
  final _syncRowKey = GlobalKey(debugLabel: 'sync-row');
  final _securityGroupKey = GlobalKey(debugLabel: 'security-group');
  final _shieldGroupKey = GlobalKey(debugLabel: 'shield-group');
  final _backupRowKey = GlobalKey(debugLabel: 'backup-row');
  final _guideRowKey = GlobalKey(debugLabel: 'guide-row');

  /// Brings [key]'s widget into view with its top a third of the way down the list,
  /// so the tip's bubble fits above it (a tall group runs on below the screen).
  Future<void> _bringUp(GlobalKey key) async {
    final row = await _build(key);
    final box = row?.findRenderObject();
    if (box is! RenderBox || !_scroll.hasClients) return;
    final p = _scroll.position;
    final top = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
    _scroll.jumpTo((top - p.viewportDimension * .3).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  /// Where [key]'s widget is on screen, cut to the list's own window.
  Rect? _visibleRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    final list = _scroll.hasClients ? _scroll.position.context.notificationContext?.findRenderObject() : null;
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (list is! RenderBox || !list.hasSize) return r;
    final shown = r.intersect(list.localToGlobal(Offset.zero) & list.size);
    return shown.isEmpty ? null : shown;
  }

  /// The User guide's tips here, after those on the vault's page (owner 2026-10-26).
  List<TourTip> _guideTips(AppLocalizations l) {
    TourTip tip(String id, GlobalKey key, String title, String body) =>
        TourTip(id: id, target: () => _visibleRect(key), prepare: () => _bringUp(key), title: title, body: body);
    return [
      if (!kIsWeb) tip('sync', _syncRowKey, l.syncTitle, l.tipSyncBody),
      tip('security', _securityGroupKey, l.settingsSecurity, l.tipSecurityBody),
      tip('backup', _backupRowKey, l.backupToFile, l.tipBackupBody),
      tip('guide', _guideRowKey, l.userGuide, l.tipGuideBody),
    ];
  }

  /// Runs the rest of the User guide once Settings has slid in.
  Future<void> _guide(int from) async {
    final route = ModalRoute.of(context)?.animation;
    if (route != null && !route.isCompleted) {
      final done = Completer<void>();
      void listen(AnimationStatus s) {
        if (s == AnimationStatus.completed && !done.isCompleted) done.complete();
      }
      route.addStatusListener(listen);
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      route.removeStatusListener(listen);
    }
    if (!mounted) return;
    final tips = _guideTips(AppLocalizations.of(context));
    await showCoachTour(context, tips, first: from, total: from + tips.length);
  }

  /// A row the tour can reach: keyed to be found, lit while [_lit].
  Widget _spot(SettingsSpot spot, Widget row) => AnimatedContainer(
        key: spot == SettingsSpot.autoLock || spot == SettingsSpot.appearance ? null : _spotKeys[spot],
        duration: const Duration(milliseconds: 250),
        color: _lit == spot ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .12) : Colors.transparent,
        child: row,
      );

  void _tour() {
    widget.onTour?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final vault = widget.vault();
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _VaultCard(vault: vault, sizeText: _sizeText, lastBackup: widget.lastBackup(), byKind: _byKind),
          // First (owner 2026-10-25): syncing is done often and keeps a copy elsewhere. The
          // backup to a file sits with it (owner 2026-10-26: one "Backup & Sync" group); the
          // Recovery Key and the password, which open a backup, live under Security.
          _Group(rows: [
            if (!kIsWeb)
              KeyedSubtree(
                key: _syncRowKey,
                child: _Row(
                  key: const ValueKey('sync-row'),
                  icon: SettingsSpot.sync.icon,
                  color: SettingsSpot.sync.color,
                  title: l.syncTitle,
                  value: _lastSyncText(l),
                  onTap: _openSync,
                ),
              ),
            _Row(
              key: _backupRowKey,
              icon: Icons.cloud_upload_outlined,
              color: _Mau.xanh,
              title: l.backupToFile,
              trailing: FilledButton(
                key: const ValueKey('backup-now'),
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
          // Help near the top, where people look for it (owner 2026-10-26), not under About.
          _Group(rows: [
            // The guide again: tips on the vault's page, then here.
            if (widget.onTour != null)
              KeyedSubtree(
                key: _guideRowKey,
                child: _Row(
                  key: const ValueKey('guide-row'),
                  icon: Icons.school_outlined,
                  color: _Mau.vang,
                  title: l.userGuide,
                  onTap: _tour,
                ),
              ),
            // Feedback lives on the website; the app only opens it (owner 2026-10-21).
            _Row(
              key: const ValueKey('feedback-row'),
              icon: Icons.chat_bubble_outline_rounded,
              color: _Mau.xanh,
              title: l.feedback,
              onTap: Links.canOpen ? () => Links.open(Links.feedback(_langCode(context))) : null,
            ),
            // What went wrong, as codes to copy (owner 2026-10-26).
            _Row(
              key: const ValueKey('report-row'),
              icon: Icons.bug_report_outlined,
              color: _Mau.cam,
              title: l.reportProblem,
              onTap: () => pushPage<void>(context, title: l.reportProblem, builder: (_) => const ErrorReportScreen()),
            ),
          ]),
          _Group(rows: [
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
          // The keys (owner 2026-10-26): how the vault opens here and on a new phone. The
          // next group shields the screen. Turning any of them weaker asks for the owner
          // first (docs/security.md).
          _Group(boxKey: _securityGroupKey, rows: [
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
          // What shows on screen and when it locks (owner 2026-10-26: apart from the keys above).
          _Group(boxKey: _shieldGroupKey, rows: [
            _spot(
              SettingsSpot.autoLock,
              _Row(
                key: _autoLockKey,
                icon: SettingsSpot.autoLock.icon,
                color: SettingsSpot.autoLock.color,
                title: l.autoLock,
                value: l.afterMinutes(_minutes),
                onTap: () => _guarded(_pickAutoLock),
              ),
            ),
            // On: leaving the app locks at once. Off: away counts towards the time above.
            _Row(
              key: const ValueKey('lock-on-leave-row'),
              icon: Icons.exit_to_app_rounded,
              color: _Mau.troi,
              title: l.lockOnLeave,
              trailing: _Switch(
                value: _lockOnLeave,
                onChanged: (on) {
                  void apply() {
                    setState(() => _lockOnLeave = on);
                    Settings.lockOnLeave = on;
                  }

                  on ? apply() : _guarded(() async => apply());
                },
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
            if (Device.android || Device.iOS || Settings.debugIOS)
              _Row(
                key: const ValueKey('screenshots-row'),
                icon: Icons.visibility_off_outlined,
                color: _Mau.hong,
                title: l.blockScreenshots,
                trailing: _Switch(
                  value: _secure,
                  // Turning it on only makes the vault safer: no Face ID for that
                  // (owner 2026-10-24). Turning it off still asks.
                  onChanged: (v) {
                    void apply() {
                      setState(() => _secure = v);
                      Settings.setBlockScreenshots(v);
                    }

                    v ? apply() : _guarded(() async => apply());
                  },
                ),
              ),
            _spot(
              SettingsSpot.blurThumbs,
              _Row(
                key: const ValueKey('blur-row'),
                icon: SettingsSpot.blurThumbs.icon,
                color: SettingsSpot.blurThumbs.color,
                title: l.blurThumbs,
                trailing: _Switch(
                  value: blurThumbnails(),
                  // Turning it on protects more; turning it off asks for the owner.
                  onChanged: (v) => v
                      ? setState(() => Prefs.write(blurThumbsPref, '1'))
                      : _guarded(() async => setState(() => Prefs.write(blurThumbsPref, '0'))),
                ),
              ),
            ),
            _spot(
              SettingsSpot.hideNoteText,
              _Row(
                icon: SettingsSpot.hideNoteText.icon,
                color: SettingsSpot.hideNoteText.color,
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
            ),
          ]),
          // How it looks and where things are: nothing here protects the vault.
          _Group(rows: [
            _spot(
              SettingsSpot.appearance,
              _Row(
                key: _appearanceKey,
                icon: SettingsSpot.appearance.icon,
                color: SettingsSpot.appearance.color,
                title: l.appearance,
                value: _appearanceName(l, Appearance.mode.value),
                onTap: _pickAppearance,
              ),
            ),
            // Same list as Settings → Cozy Safe → Language on iPhone and Android 13+.
            _spot(
              SettingsSpot.language,
              _Row(
                key: const ValueKey('language-row'),
                icon: SettingsSpot.language.icon,
                color: SettingsSpot.language.color,
                title: l.language,
                value: AppLanguage.chosen == null
                    ? l.languageSystem
                    : languages.firstWhere((x) => x.code == AppLanguage.chosen).name,
                onTap: _pickLanguage,
              ),
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
          ]),
          // One vault in the app (decisions 2026-10-24); another one only in debug mode, for
          // testing (the core keeps several).
          if (debugModeOn())
            _Group(rows: [
              _Row(
                key: const ValueKey('debug-new-vault'),
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
              return _Group(rows: [
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
                if (debugModeOn())
                  _Row(
                    key: _debugRowKey,
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
                    // The name only, as in the iPhone's Storage (owner 2026-10-26): the
                    // bar shows how much, the total is above.
                    Text(names[k]!, style: TextStyle(color: fg.withValues(alpha: .9), fontSize: 12.5)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Groups have no names, as in the iPhone's Settings (owner 2026-10-26): a gap sets them
/// apart and the rows say what they are.
class _Group extends StatelessWidget {
  const _Group({required this.rows, this.boxKey});
  final List<Widget> rows;
  /// On the rows (not the space above): what the User guide lights up.
  final Key? boxKey;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final c = CsColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        key: boxKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              SettingTile(icon: icon, color: color, glyph: glyph),
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
  const _LanguageList({required this.chosen, required this.system});
  final String? chosen;
  final String system;

  @override
  Widget build(BuildContext context) {
    Widget row(String code, String name) => ListTile(
          key: ValueKey('language-$code'),
          minTileHeight: 52,
          title: Text(name, style: const TextStyle(fontSize: 16)),
          trailing: (code.isEmpty ? chosen == null : chosen == code)
              ? Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () => Navigator.of(context).pop(code),
        );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        row('', system),
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
