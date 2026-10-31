import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../debug_log.dart';
import '../biometric.dart';
import '../key_backup.dart';
import '../l10n/app_localizations.dart';
import '../appearance.dart';
import '../language.dart';
import '../links.dart';
import '../platform.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../secret_key_store.dart';
import '../theme.dart';
import '../sync/sync_status.dart';
import 'debug.dart';
import 'security_info.dart';
import '../widgets/toast.dart';
import '../build_info.dart';
import '../item_kind.dart';
import '../prefs.dart';
import '../widgets/identity.dart';
import '../widgets/vault_bar.dart';
import 'delete_vault.dart';
import 'history.dart';
import 'storage.dart';
import '../src/rust/api/history.dart' as hist;
import 'file_view.dart';
import 'error_report.dart';
import 'key_check.dart';
import 'tour.dart';
import '../sync/sync_screen.dart';
import '../widgets/readable.dart';
import '../top_secret_mode.dart';
import 'top_secret_page.dart';
import 'vault_manager.dart';
import '../widgets/edge_swipe_back.dart';

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
  sync(Icons.sync_rounded, SettingsHue.xanhLa),
  autoLock(Icons.timer_rounded, SettingsHue.cam),
  blurThumbs(Icons.blur_on_rounded, SettingsHue.ngoc),
  hideNoteText(Icons.notes_rounded, SettingsHue.bacHa),
  appearance(Icons.contrast_rounded, SettingsHue.cham),
  language(Icons.translate_rounded, SettingsHue.xanh);

  const SettingsSpot(this.icon, this.color);
  final IconData icon;
  final Color color;
}

/// Settings' sub-pages (owner 2026-10-31: too many settings on one page). The main page
/// shows the vault's card and one row per sub-page; each row opens its page in place, so
/// the rows' switches, the User guide and the jumps to a setting keep working.
/// The main page, or About (version, build, source, licence) on a page of its own.
enum _Page { main, help }

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
    this.onShowKind,
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
  static int get guideTipCount => kIsWeb ? 4 : 5;

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
  /// Storage → a kind of item: Settings closes on that section of the vault.
  final void Function(String kind)? onShowKind;

  /// For the mockup renders: the connection log without a vault.
  static List<String>? debugSyncLog;
  /// For the mockup renders: space version history takes.
  static BigInt? debugHistoryBytes;
  /// Mockups: open on a sub-page (`syncBackup`, `security`, `history`, `look`, `help`).
  static String? debugPage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _minutes = Settings.autoLockMinutes;
  bool _secure = Settings.blockScreenshots;
  bool _lockOnLeave = Settings.lockOnLeave;
  /// What the vault takes, part by part; the card and the Storage page follow it.
  final _figures = ValueNotifier(const StorageFigures());
  /// The last figures per vault, in memory only (sizes and counts are about the vault, so
  /// never written out): Settings shows them at once while it measures again
  /// (owner 2026-10-27: the storage line came late).
  static final _lastSizes = <String, StorageFigures>{};

  @override
  void initState() {
    super.initState();
    if (_lastSizes[widget.vault().id] case final last?) _figures.value = last;
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
      final items = (await rust.listItems()).where((i) => i.kind != ItemKind.tag);
      // Recently deleted takes room until it is emptied, held items (deleted for good on
      // another device, kept here) too: a part of its own (owner 2026-10-28).
      final trash = [...await rust.listTrash(), ...await rust.listHeld()].where((i) => i.kind != ItemKind.tag).toList();
      final history = SettingsScreen.debugHistoryBytes ?? await _historyBytes();
      if (!mounted) return;
      final bytes = <String, BigInt>{};
      final counts = <String, int>{};
      for (final i in items) {
        bytes[i.kind] = (bytes[i.kind] ?? BigInt.zero) + i.sizeBytes;
        counts[i.kind] = (counts[i.kind] ?? 0) + 1;
      }
      bytes[storageTrash] = trash.fold(BigInt.zero, (a, i) => a + i.sizeBytes);
      counts[storageTrash] = trash.length;
      // Older versions take room too: their own line (owner 2026-10-27).
      bytes[storageHistory] = history;
      final f = StorageFigures(bytes: bytes, counts: counts);
      _figures.value = f;
      _lastSizes[widget.vault().id] = f;
      setState(() {});
    } catch (_) {}
  }

  /// Recently deleted, then the figures again at once: emptied items leave the total
  /// as soon as the page closes (owner 2026-10-28).
  Future<void> _openTrash() async {
    await widget.onOpenTrash();
    await _measure();
  }

  /// Storage, part by part; each part leads where it is managed.
  void _openStorage() {
    final l = AppLocalizations.of(context);
    pushPage<void>(
      context,
      title: l.storage,
      builder: (page) => StorageScreen(
        figures: _figures,
        onOpen: (part) {
          switch (part) {
            case storageTrash:
              _openTrash();
            case storageHistory:
              _openHistory();
            default:
              if (widget.onShowKind == null) return;
              widget.onShowKind!(part);
              Navigator.of(page).pop();
              Navigator.of(context).pop();
          }
        },
      ),
    );
  }

  Future<BigInt> _historyBytes() async {
    try {
      final s = await hist.historySettings();
      _historyDays = s.days;
      _historyMax = s.maxBytes;
      return await hist.historyBytes();
    } catch (_) {
      return BigInt.zero;
    }
  }

  /// This device's history setting, for its row.
  int _historyDays = 30;
  BigInt _historyMax = BigInt.from(1 << 30);

  Future<void> _openHistory() async {
    final l = AppLocalizations.of(context);
    await pushPage<void>(context, title: l.versionHistory, grouped: true, builder: (_) => HistorySettingsScreen(onChanged: _measure));
    _measure();
  }

  String get _sizeText => AppLocalizations.of(context).storageUsed(fileSize(_figures.value.total), _figures.value.count);

  /// Security settings changed here ask for the owner first (docs/security.md); the ones
  /// that live in the vault screen (password, backup, kit, biometrics) ask there.
  Future<void> _guarded(Future<void> Function() action) async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    await action();
  }

  Future<void> _keyBackupOn() async {
    final l = AppLocalizations.of(context);
    final google = KeyBackup.google;
    final yes = await showCard<bool>(context, title: google ? l.keyBackupTitleGoogle : l.keyBackupTitle, builder: (context) {
      final c = CsColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(google ? l.keyBackupBodyGoogle : l.keyBackupBody, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l.cancel))),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                key: const ValueKey('key-backup-yes'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l.keyBackupOn),
              ),
            ),
          ]),
        ]),
      );
    });
    if (yes != true || !mounted) return;
    final key = await SecretKeyStore.read();
    final ok = key != null && await KeyBackup.turnOn(key);
    if (!mounted) return;
    // Block Store keeps nothing without a screen lock (end to end encryption) or Google.
    if (!ok && google) showToast(context, l.keyBackupGoogleFailed);
    setState(() {});
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
                  ThemeMode.light => Icons.light_mode_rounded,
                  ThemeMode.dark => Icons.dark_mode_rounded,
                  ThemeMode.system => Icons.brightness_auto_rounded,
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
      Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => Readable(child: const SecurityInfoScreen())));

  Future<void> _deleteVault() async {
    // The vault's password confirms it; a vault without one (made with a PIN before)
    // gets one first.
    if (!widget.vault().hasPassword) {
      await widget.onPassword();
      if (!mounted || !widget.vault().hasPassword) return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Readable(child: DeleteVaultScreen(libraryDir: widget.libraryDir, vault: widget.vault(), sizeText: _sizeText)),
    ));
  }

  Future<void> _openVaults() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Readable(
        child: VaultManagerScreen(
          libraryDir: widget.libraryDir,
          onDeleteOpen: () => _guarded(_deleteVault),
          onNewVault: widget.onNewVault,
        ),
      ),
    ));
    if (mounted) setState(() {});
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
        title: l.syncTitle, grouped: true,
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
    _rev.dispose();
    _scroll.dispose();
    _figures.dispose();
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

  /// The page drawn by this screen: the main page, or (mockups only, [SettingsScreen.debugPage])
  /// a sub-page in place.
  _Page _page = SettingsScreen.debugPage == _Page.help.name ? _Page.help : _Page.main;

  /// Bumped on every [setState], so a sub-page pushed over this screen redraws too.
  final _rev = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _rev.value++;
  }

  /// The list of the sub-page on show over this screen.
  ScrollController? _subScroll;

  /// [key] while [page] is the one this screen draws; null on a pushed sub-page, whose
  /// main page stays built underneath with the same keys (the User guide's targets).
  GlobalKey? _here(GlobalKey key, _Page page) => page == _page ? key : null;

  /// A sub-page slides in as a page of its own, like Top Secret Mode (owner 2026-10-31:
  /// the in-place pages felt poor); Back and the edge swipe come with the route.
  Future<void> _show(_Page page) async {
    if (page == _Page.main) {
      if (_page != _Page.main) setState(() => _page = _Page.main);
      return;
    }
    final scroll = ScrollController();
    _subScroll = scroll;
    await pushPage<void>(
      context,
      title: _pageTitle(AppLocalizations.of(context), page),
      grouped: true,
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: _rev,
        builder: (context, _, _) => ListView(
          key: ValueKey('settings-page-${page.name}'),
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: _children(AppLocalizations.of(context), page),
        ),
      ),
    );
    if (_subScroll == scroll) _subScroll = null;
    scroll.dispose();
    if (mounted) setState(() {});
  }

  String _pageTitle(AppLocalizations l, _Page page) => switch (page) {
        _Page.main => l.settings,
        _Page.help => l.aboutTitle,
      };

  /// Where each setting the tour points at lives.
  static _Page _pageOf(SettingsSpot spot) => _Page.main;

  /// Takes the person to [spot]: Sync opens; any other row scrolls into the middle and
  /// lights up, so it is easy to see which one to change.
  Future<void> _goTo(SettingsSpot spot) async {
    if (!mounted) return;
    if (spot == SettingsSpot.sync) return _openSync();
    if (_pageOf(spot) != _Page.main) {
      unawaited(_show(_pageOf(spot)));
      // The page slides in first.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } else {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    final row = await _build(_spotKeys[spot]!, _subScroll ?? _scroll);
    if (row == null || !row.mounted || !mounted) return;
    setState(() => _lit = spot);
    await Scrollable.ensureVisible(row, alignment: .4, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && _lit == spot) setState(() => _lit = null);
  }

  /// [key]'s widget, built: rows far down are not built yet, so the list moves down a
  /// screen at a time until it is.
  Future<BuildContext?> _build(GlobalKey key, [ScrollController? list]) async {
    final scroll = list ?? _scroll;
    var row = key.currentContext;
    for (var i = 0; row == null && i < 12 && scroll.hasClients; i++) {
      final p = scroll.position;
      if (p.pixels >= p.maxScrollExtent) break;
      scroll.jumpTo((p.pixels + p.viewportDimension).clamp(0, p.maxScrollExtent));
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
      // Security in two stops (owner 2026-10-29: every security setting shown): the keys,
      // then locking and what stays hidden.
      tip('security', _securityGroupKey, l.settingsSecurity, l.tipKeysBody),
      tip('shield', _shieldGroupKey, l.tipShieldTitle, l.tipShieldBody),
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

  Future<void> _openTopSecret() async {
    final l = AppLocalizations.of(context);
    await pushPage<void>(
      context,
      title: l.topSecretMode,
      grouped: true,
      builder: (_) => TopSecretModePage(verify: () => confirmOwnerForSetting(l.ownerCheckSettings)),
    );
  }

  void _tour() {
    widget.onTour?.call();
    // Help is a page of its own over Settings: both close.
    final me = ModalRoute.of(context);
    final nav = Navigator.of(context);
    nav.popUntil((r) => r == me);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final main = _page == _Page.main;
    return PopScope(
      // A sub-page goes back to the main page first.
      canPop: main,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _show(_Page.main);
      },
      // Sub-pages are shown in place, so the system swipe has nothing to pop: an edge
      // swipe goes back to the main page (iPhone).
      child: EdgeSwipeBack(
      enabled: !main,
      onBack: () => _show(_Page.main),
      child: groupedPage(context, Builder(builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(main ? l.settings : _pageTitle(l, _page)),
        centerTitle: !main,
        titleTextStyle: main ? largeTitle(context) : null,
        leading: main
            ? null
            : IconButton(
                key: const ValueKey('settings-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
                onPressed: () => _show(_Page.main),
              ),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          ..._children(l, _page),
        ],
      ),
    )))));
  }

  /// What [page] shows: the main page, or one sub-page (pushed as a page of its own, or
  /// in place for mockups).
  List<Widget> _children(AppLocalizations l, _Page page) {
    final vault = widget.vault();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return [
          // One page, every setting on it in groups (owner 2026-10-31: the main page was
          // empty and the sub-pages long); only About opens a page of its own.
          if (page == _Page.main) ...[
            _VaultCard(vault: vault, sizeText: _sizeText, lastBackup: widget.lastBackup(), figures: _figures.value, onTap: _openStorage),
            // Top Secret Mode in a card of its own, near the top (owner 2026-10-31: people
            // must know the feature exists).
            _TopSecretCard(onTap: _openTopSecret),
          ],
          // Most important first, like with like (owner 2026-10-27). Groups still have no
          // names (owner 2026-10-26): the gaps set them apart.
          // 1. A copy elsewhere: syncing is done often (owner 2026-10-25), the backup file with it.
          if (page == _Page.main) SettingsGroup(rows: [
            if (!kIsWeb)
              KeyedSubtree(
                key: _here(_syncRowKey, page),
                child: SettingsRow(
                  key: const ValueKey('sync-row'),
                  icon: SettingsSpot.sync.icon,
                  color: SettingsSpot.sync.color,
                  title: l.syncTitle,
                  value: _lastSyncText(l),
                  alert: true,
                  onTap: _openSync,
                ),
              ),
            SettingsRow(
              key: _here(_backupRowKey, page) ?? const ValueKey('backup-row'),
              icon: Icons.cloud_upload_rounded,
              color: SettingsHue.xanh,
              title: l.backupToFile,
              trailing: FilledButton(
                key: const ValueKey('backup-now'),
                style: FilledButton.styleFrom(
                  // Settings may use colour (owner): a soft tint of the backup blue, low
                  // contrast in both modes, never a black or white slab.
                  backgroundColor: SettingsHue.xanh.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? .22 : .12),
                  foregroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF64A8FF) : SettingsHue.xanh,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: CsType.footnote, fontWeight: FontWeight.w600),
                ),
                onPressed: () => _then(widget.onBackup),
                child: Text(l.backupNow),
              ),
            ),
          ]),
          // 2. The keys: how the vault opens here and on a new phone. Turning any of them
          // weaker asks for the owner first (docs/security.md).
          if (page == _Page.main) SettingsGroup(boxKey: _here(_securityGroupKey, page), rows: [
            if (widget.canBiometric)
              SettingsRow(
                icon: Icons.face_retouching_natural_rounded,
                color: SettingsHue.xanhLa,
                // The device's own symbol: the Face ID glyph, or a fingerprint (biometric.dart).
                glyph: BiometricGlyph(kind: _bioKind, size: 19, color: Colors.white),
                title: opensThisVaultLabel(l, _bioKind),
                trailing: SettingsSwitch(
                  value: widget.biometricOn(),
                  onChanged: (_) => _then(widget.onToggleBiometric),
                ),
              ),
            SettingsRow(
              icon: Icons.key_rounded,
              color: SettingsHue.vang,
              title: l.backupPasswordLabel,
              value: vault.hasPassword ? l.isSet : l.notSet,
              onTap: () => _then(widget.onPassword),
            ),
            if (vault.hasPassword)
              SettingsRow(
                key: const ValueKey('kit-row'),
                icon: Icons.medical_services_rounded,
                color: SettingsHue.doTuoi,
                title: l.showKit,
                onTap: widget.onShowKit,
              ),
            // Type them back to know they still open this vault (owner 2026-10-26).
            SettingsRow(
              key: const ValueKey('key-check-row'),
              icon: Icons.fact_check_rounded,
              color: SettingsHue.xanhLa,
              title: l.keyCheckRow,
              onTap: () => pushPage<void>(context,
                  title: l.keyCheckRow,
                  builder: (_) => KeyCheckScreen(libraryDir: widget.libraryDir, hasPassword: vault.hasPassword)),
            ),
            // Off unless turned on; turning it on is weaker, so it asks for the owner and
            // says the trade (owner 2026-10-26).
            if (KeyBackup.supported)
              SettingsRow(
                key: const ValueKey('key-backup-row'),
                icon: Icons.cloud_rounded,
                color: SettingsHue.troi,
                title: KeyBackup.google ? l.keyBackupRowGoogle : l.keyBackupRow,
                trailing: SettingsSwitch(
                  value: KeyBackup.on,
                  onChanged: (on) => on
                      ? _guarded(_keyBackupOn)
                      : KeyBackup.turnOff().then((_) {
                          if (mounted) setState(() {});
                        }),
                ),
              ),
          ]),
          // 3. What shows on screen and when it locks.
          if (page == _Page.main) SettingsGroup(boxKey: _here(_shieldGroupKey, page), rows: [
            _spot(
              SettingsSpot.autoLock,
              SettingsRow(
                key: _autoLockKey,
                icon: SettingsSpot.autoLock.icon,
                color: SettingsSpot.autoLock.color,
                title: l.autoLock,
                value: l.afterMinutes(_minutes),
                onTap: () => _guarded(_pickAutoLock),
              ),
            ),
            // On: leaving the app locks at once. Off: away counts towards the time above.
            SettingsRow(
              key: const ValueKey('lock-on-leave-row'),
              icon: Icons.exit_to_app_rounded,
              color: SettingsHue.troi,
              title: l.lockOnLeave,
              trailing: SettingsSwitch(
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
            SettingsRow(
              key: const ValueKey('hold-home-row'),
              icon: Icons.lock_rounded,
              color: SettingsHue.tim,
              title: l.holdHomeTitle,
              trailing: SettingsSwitch(
                value: holdHomeLocks(),
                onChanged: (on) => setState(() => Prefs.write(holdHomePref, on ? '1' : '0')),
              ),
            ),
            if (Device.android || Device.iOS || Settings.debugIOS)
              SettingsRow(
                key: const ValueKey('screenshots-row'),
                icon: Icons.visibility_off_rounded,
                color: SettingsHue.hong,
                title: l.blockScreenshots,
                trailing: SettingsSwitch(
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
              SettingsRow(
                key: const ValueKey('blur-row'),
                icon: SettingsSpot.blurThumbs.icon,
                color: SettingsSpot.blurThumbs.color,
                title: l.blurThumbs,
                trailing: SettingsSwitch(
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
              SettingsRow(
                icon: SettingsSpot.hideNoteText.icon,
                color: SettingsSpot.hideNoteText.color,
                // "Hide", on by default (owner 2026-10-21): the safe state is the on state,
                // like "Blur thumbnails". The pref keeps its old meaning (1 = show text).
                key: const ValueKey('hide-note-text-row'),
                title: l.hideNoteText,
                trailing: SettingsSwitch(
                  value: !notePreviews(),
                  // Showing more is weaker: turning "hide" off asks for the owner.
                  onChanged: (hide) => hide
                      ? setState(() => Prefs.write(notePreviewsPref, '0'))
                      : _guarded(() async => setState(() => Prefs.write(notePreviewsPref, '1'))),
                ),
              ),
            ),
          ]),
          // 4. This vault and the others: its look, getting things back, the vaults here
          // (making and deleting a vault live there).
          if (page == _Page.main) SettingsGroup(rows: [
            SettingsRow(
              key: const ValueKey('identity-row'),
              icon: Icons.palette_rounded,
              color: SettingsHue.tim,
              title: l.changeIdentity,
              onTap: () => _then(widget.onChangeIdentity),
            ),
            SettingsRow(
              icon: Icons.delete_sweep_rounded,
              color: SettingsHue.xam,
              title: l.recentlyDeleted,
              onTap: () => _then(_openTrash),
            ),
            // Older versions of every item, kept on this device (owner 2026-10-27).
            SettingsRow(
              key: const ValueKey('history-row'),
              icon: Icons.history_rounded,
              color: SettingsHue.ngoc,
              title: l.versionHistory,
              value: _historyDays == 0 ? l.historyOff : historySizeText(l, _historyMax),
              onTap: _openHistory,
            ),
            SettingsRow(
              key: const ValueKey('vaults-row'),
              icon: Icons.inventory_2_rounded,
              color: SettingsHue.cam,
              title: l.vaultManagerTitle,
              onTap: _openVaults,
            ),
          ]),
          // 5. How it looks and where things are: nothing here protects the vault.
          if (page == _Page.main) SettingsGroup(rows: [
            _spot(
              SettingsSpot.appearance,
              SettingsRow(
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
              SettingsRow(
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
            SettingsRow(
              key: const ValueKey('side-row'),
              icon: Icons.back_hand_rounded,
              color: SettingsHue.cam,
              title: l.actionSide,
              trailing: _SideSwitch(
                side: actionSide(),
                labels: (l.sideLeftShort, l.sideCenterShort, l.sideRightShort),
                onChanged: (v) => setState(() => Prefs.write(actionSidePref, v.name)),
              ),
            ),
            // The icon on a plain page after unlocking; only a look, so no owner check.
            SettingsRow(
              key: const ValueKey('reveal-row'),
              icon: Icons.auto_awesome_rounded,
              color: SettingsHue.cham,
              title: l.revealIcon,
              trailing: SettingsSwitch(
                value: revealIconOn(),
                onChanged: (v) => setState(() => Prefs.write(revealIconPref, v ? '1' : '0')),
              ),
            ),
          ]),
          // 6. Help: the guide, how the vault is protected, feedback, what went wrong.
          if (page == _Page.main) SettingsGroup(rows: [
            // The guide again: tips on the vault's page, then here.
            if (widget.onTour != null)
              KeyedSubtree(
                key: _here(_guideRowKey, page),
                child: SettingsRow(
                  key: const ValueKey('guide-row'),
                  icon: Icons.school_rounded,
                  color: SettingsHue.vang,
                  title: l.userGuide,
                  onTap: _tour,
                ),
              ),
            SettingsRow(
              icon: Icons.verified_user_rounded,
              color: SettingsHue.ngoc,
              title: l.securityTitle,
              onTap: _showSecurity,
            ),
            // Feedback lives on the website; the app only opens it (owner 2026-10-21).
            SettingsRow(
              key: const ValueKey('feedback-row'),
              icon: Icons.chat_bubble_rounded,
              color: SettingsHue.xanh,
              title: l.feedback,
              onTap: Links.canOpen ? () => Links.open(Links.feedback(_langCode(context))) : null,
            ),
            // What went wrong, as codes to copy (owner 2026-10-26).
            SettingsRow(
              key: const ValueKey('report-row'),
              icon: Icons.bug_report_rounded,
              color: SettingsHue.cam,
              title: l.reportProblem,
              onTap: () => pushPage<void>(context, title: l.reportProblem, builder: (_) => const ErrorReportScreen()),
            ),
            // Version, build, source, licence (and Debug) on a page of their own.
            SettingsRow(
              key: const ValueKey('settings-help'),
              icon: Icons.info_rounded,
              color: SettingsHue.xam,
              title: l.aboutTitle,
              onTap: () => _show(_Page.help),
            ),
          ]),
          // About: version and build (to match a phone with its release run, build =
          // 1000 + run), when and from which commit it was built, the licence.
          if (page == _Page.help) FutureBuilder<PackageInfo>(
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
              return SettingsGroup(rows: [
                SettingsRow(
                  key: const ValueKey('about-version'),
                  icon: Icons.info_rounded,
                  color: SettingsHue.xam,
                  title: l.aboutVersion,
                  value: version,
                  onTap: _versionTap,
                  chevron: false,
                ),
                SettingsRow(
                  icon: Icons.schedule_rounded,
                  color: SettingsHue.xam,
                  title: l.aboutBuilt,
                  value: built == null
                      ? l.aboutLocal
                      : '${ml.formatShortDate(built.toLocal())} ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(built.toLocal()))}',
                ),
                SettingsRow(
                  icon: Icons.code_rounded,
                  color: SettingsHue.xam,
                  title: l.aboutCommit,
                  value: buildCommit.isEmpty ? l.aboutLocal : buildCommitShort,
                ),
                SettingsRow(icon: Icons.gavel_rounded, color: SettingsHue.xam, title: l.aboutLicense, value: 'GPL-3.0'),
                if (debugModeOn())
                  SettingsRow(
                    key: _debugRowKey,
                    icon: Icons.bug_report_rounded,
                    color: SettingsHue.doTuoi,
                    title: l.debugMode,
                    onTap: () async {
                      await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => Readable(child: const DebugScreen())));
                      if (mounted) setState(() {});
                    },
                  ),
              ]);
            },
          ),
          const SizedBox(height: 12),
          if (dark) const SizedBox(height: 4),
    ];
  }
}

/// Top Secret Mode on the main page: its mark, its name, whether it is on, one line on
/// what it does. A tap opens its page.
class _TopSecretCard extends StatelessWidget {
  const _TopSecretCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final on = TopSecretMode.on;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('top-secret-row'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(children: [
              const TopSecretMark(size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(l.topSecretMode,
                          style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      on ? l.statusOn : l.statusOff,
                      style: TextStyle(
                        fontSize: CsType.footnote,
                        fontWeight: FontWeight.w700,
                        color: on ? topSecretRed : c.muted,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(l.topSecretCardNote,
                      style: TextStyle(fontSize: CsType.footnote, height: 1.3, color: c.muted)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: c.muted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The vault itself: its icon, how much it holds (a bar split by part) and the last
/// backup, on the vault's colour. A tap opens Storage, part by part (owner 2026-10-28).
class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.vault, required this.sizeText, required this.lastBackup, required this.figures, required this.onTap});

  final rust.VaultInfo vault;
  final String sizeText;
  final String lastBackup;
  final StorageFigures figures;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The same surface as the groups below, ink text: a black card in light mode and a
    // white one in dark mode were both too strong (owner 2026-10-21).
    final bg = Theme.of(context).cardColor;
    final fg = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('storage-card'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                        Text(sizeText, style: TextStyle(color: fg, fontSize: CsType.body, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(lastBackup, style: TextStyle(color: fg.withValues(alpha: .85), fontSize: CsType.footnote)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: fg.withValues(alpha: .5), size: 22),
                ],
              ),
              const SizedBox(height: 14),
              StorageBar(figures: figures),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  for (final (k, color) in storageParts)
                    if (figures.size(k) > BigInt.zero) Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        // The name only, as in the iPhone's Storage (owner 2026-10-26): the
                        // bar shows how much, the total is above; the sizes are one tap away.
                        Text(storagePartName(l, k), style: TextStyle(color: fg.withValues(alpha: .9), fontSize: CsType.footnote)),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Groups have no names, as in the iPhone's Settings (owner 2026-10-26): a gap sets them
/// apart and the rows say what they are.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.rows, this.boxKey});
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
abstract final class SettingsHue {
  static const tim = Color(0xFFAF52DE), xam = Color(0xFF8E8E93), xanhLa = Color(0xFF34C759),
      cham = Color(0xFF5856D6), cam = Color(0xFFFF9500), xanh = Color(0xFF007AFF),
      doTuoi = Color(0xFFFF3B30), ngoc = Color(0xFF30B0C7), hong = Color(0xFFFF2D55), troi = Color(0xFF32ADE6),
      vang = Color(0xFFFFB300), bacHa = Color(0xFF00C7BE); // brown (nau) dropped: owner found it ugly
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.color,
    this.glyph,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.alert = false,
  });

  /// False for a tap nobody should notice (the version's hidden debug taps).
  final bool chevron;
  /// The red dot of a failed automatic sync before the value (the Sync row).
  final bool alert;

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
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          child: Row(
            children: [
              SettingTile(icon: icon, color: color, glyph: glyph),
              const SizedBox(width: 12),
              // Just a name, no note under it (owner 2026-10-21): the name says enough.
              Expanded(flex: 3, child: Text(title, style: const TextStyle(fontSize: CsType.body))),
              if (alert) const SyncAlertDot(),
              if (value != null) ...[
                const SizedBox(width: 8),
                // At 17 pt a long value (a language name, a time) shortens with "…" as on
                // the iPhone, instead of pushing the row wider; it sits against the ›.
                Expanded(
                  flex: 2,
                  child: Text(value!,
                      textAlign: TextAlign.end,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: CsType.body)),
                ),
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
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Switch.adaptive(
        value: value,
        onChanged: onChanged,
        // On is the iPhone's green with a white knob (settings may use colour; a black or
        // white track was too strong, owner 2026-10-21).
        activeTrackColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF30D158) : SettingsHue.xanhLa,
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
          child: Text(text, style: TextStyle(fontSize: CsType.subhead, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
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
          title: Text(name, style: const TextStyle(fontSize: CsType.callout)),
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

