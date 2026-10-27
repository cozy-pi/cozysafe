import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../biometric.dart';
import '../lock_resume.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../sync/awake.dart';
import '../theme.dart';
import '../originals.dart';
import '../prefs.dart';
import '../privacy.dart';
import '../widgets/private_thumb.dart';
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import '../widgets/vault_bar.dart';
import 'backup_password.dart';
import 'camera.dart';
import 'common.dart';
import 'emergency_kit.dart';
import 'kit_password.dart';
import 'change_key.dart';
import 'file_view.dart';
import 'new_vault.dart';
import 'quick_look.dart';
import 'note.dart';
import 'recorder.dart';
import '../widgets/item_menu.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/drag_select.dart';
import '../widgets/selection_bar.dart';
import 'item_info.dart';
import '../widgets/native_bar.dart';
import 'overview.dart';
import 'search.dart';
import 'settings.dart';
import 'tour.dart';
import 'trash.dart';
import 'unlock.dart';
import 'video_view.dart';
import '../capture_name.dart';
import '../item_kind.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/selectable_row.dart';
import '../widgets/toast.dart';
import '../widgets/second_place.dart';
import '../sync/sync_screen.dart';
import 'history.dart';
import 'wide_home.dart';
import '../widgets/readable.dart';

/// Inside an open vault (docs/ui.md, vault bar): a large title, the tags as a row of
/// chips, the content edge to edge, and floating glass at the bottom: the lock, the four
/// sections, and the main action above the lock. Locks on leaving the
/// app, after 2 minutes without a touch, or with the lock button.
class VaultHomeScreen extends StatefulWidget {
  /// For the mockup renders: the vault's icon shows after opening (off for still shots).
  static bool debugReveal = true;


  const VaultHomeScreen({super.key, required this.libraryDir, required this.vault, this.tour});

  final String libraryDir;
  final rust.VaultInfo vault;
  /// Just made or restored here: the quick tour shows once the vault has opened.
  final TourKind? tour;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late rust.VaultInfo _vault = widget.vault;
  bool _locked = false;
  List<rust.ItemInfo>? _items;
  /// Decrypted previews, in memory only, dropped with this screen.
  final Map<String, Future<Uint8List>> _thumbnails = {};
  /// Thumbnails already read: a square scrolled back into view shows its picture on its
  /// first frame instead of an empty one (a flicker all over a fast scroll).
  final Map<String, Uint8List> _thumbReady = {};
  /// Photos per row; pinch to change, like Photos.
  /// Library columns (pinch), remembered across launches (owner 2026-10-22).
  int _cols = _colSteps.contains(int.tryParse(Prefs.read('library-columns') ?? ''))
      ? int.parse(Prefs.read('library-columns')!)
      : 4;
  void _setCols(int n) {
    Prefs.write('library-columns', '$n');
    setState(() => _cols = n);
  }
  static const _colSteps = [3, 4, 5, 7];
  double _scaleStart = 1;
  /// What the vault shows, picked in the bottom capsule.
  late VaultSection _section = startSection();
  /// A section opened from the add sheet stays offered while empty (a voice memo
  /// being recorded, a note being written), until another is picked.
  bool _keepSection = false;
  /// The vault's icon after unlocking: on unless turned off in Settings.
  late final bool _revealOn = VaultHomeScreen.debugReveal && revealIconOn();
  /// The + column is open; [_hover] is the way under a finger sliding up from +.
  bool _adding = false;
  /// The column stays on screen while it closes.
  bool _addShown = false;
  AddWhat? _hover;
  ScrollController _addScroll = ScrollController();
  final _actionKey = GlobalKey();
  /// What the quick tour points at (tour.dart).
  final _settingsKey = GlobalKey();
  final _tabsKey = GlobalKey();
  final _barKey = GlobalKey();
  final _lockKey = GlobalKey();
  final _contentKey = GlobalKey();
  final _tilesKey = GlobalKey();
  /// Settings → Quick tour was tapped: the tour runs here once Settings has closed.
  bool _tourAgain = false;
  final _recorder = GlobalKey<RecorderViewState>();
  bool _recordingNow = false;
  static const _tintApp = false;

  /// The tag open on top of the sections ("Hộ chiếu"): every section then shows only
  /// what carries it. None: everything.
  String? _tagId;
  /// A wide window (iPad, computer): three columns, and the item open beside the list.
  bool _wide = false;
  rust.ItemInfo? _focus;
  /// Library columns in a wide window: as many as fit.
  int _wideCols = 6;
  /// Long-press selection: ids picked for Delete / Send.
  final Set<String> _selected = {};
  /// Select mode, from the Select button: rows show their circles even with nothing
  /// chosen yet. A long press opens an item's menu instead (owner 2026-10-22).
  bool _selectMode = false;
  bool get _selecting => _selectMode || _selected.isNotEmpty;
  void _endSelect() {
    _selectMode = false;
    _selected.clear();
  }
  /// The items of the section on show, in their order, for a hold-and-drag selection.
  List<String> _dragOrder = const [];
  /// Hold an item, then drag across others: they are selected (lib/widgets/drag_select.dart).
  late final _drag = DragSelect(
    order: () => _dragOrder,
    selected: () => _selected,
    onBegin: () => setState(() => _selectMode = true),
    onChanged: (next) => setState(() => _selected
      ..clear()
      ..addAll(next)),
  );
  /// Note previews (second line on), decrypted on demand, in memory only.
  final Map<String, Future<String>> _previews = {};

  static final bool _desktop = Device.macOS || Device.windows || Device.linux;
  bool _canBio = false;
  bool _bioOn = false;
  Timer? _idleTimer;
  /// Out of the app with the vault still open: for a picker or the share sheet, or with
  /// "Lock as soon as I leave the app" off. Measured on [AwayClock].
  AwayClock? _away;
  /// Locks at the auto-lock time while away, if the app still runs then.
  Timer? _awayTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // What has been in Recently deleted for 30 days goes for good, then list.
    rust.purgeExpired(nowMs: nowMs()).catchError((_) => 0).whenComplete(_reload);
    _bioOn = rust.biometricEnabled();
    BiometricUnlock.available().then((k) {
      if (mounted) setState(() => _canBio = k != null);
    });
    LockGuard.onActivity = _touch;
    // A vault opening here: pages another vault kept under the lock are gone.
    vaultLock.reset();
    // iOS says when a screenshot was taken (it can't stop one): blocked, it came out black,
    // so say why and how to allow one; not blocked, it sits in Photos unencrypted. A card in
    // the middle that stays until closed (owner 2026-10-22: the toast was small and quick).
    PrivacyCover.onScreenshot = () {
      if (mounted) _screenshotNotice();
    };
    // Design B (the whole app in the vault's colour) is off since 2026-10-20: it often
    // looked wrong. The palette code stays in theme.dart; turn it back on here.
    if (_tintApp) WidgetsBinding.instance.addPostFrameCallback((_) => vaultTint.value = _color);
    // Touches anywhere count, also on the note editor or viewer pushed above this screen.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _touch();
    if (_revealOn) _reveal.forward();
    if (widget.tour case final kind?) {
      // After the vault's icon has come and gone, so the tour opens on the vault itself.
      Future<void>.delayed(Duration(milliseconds: _revealOn ? 1500 : 400), () => _showTour(kind));
    }
  }

  /// The quick tour: tips over this page, each pointing at the real thing (owner
  /// 2026-10-26). "Set up sync now" opens Settings, then Sync on top of it.
  Future<void> _showTour(TourKind kind) async {
    // The items first: an empty vault has the add tiles where the + would be.
    for (var i = 0; i < 20 && mounted && _items == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || _locked || _items == null) return;
    // Back on the vault's own page, out of whatever was open.
    if (_adding) _closeAdd();
    setState(() {
      _endSelect();
      _tagId = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final tips = _tourTips(AppLocalizations.of(context), kind);
    // The User guide goes on into Settings, counting on (6/9 there).
    final guide = kind == TourKind.guide;
    final end = await showCoachTour(context, tips, total: guide ? tips.length + SettingsScreen.guideTipCount : null);
    if (!mounted || _locked) return;
    if (end == TourEnd.action) _openSettings(focus: SettingsSpot.sync);
    if (end == TourEnd.done && guide) _openSettings(guideFrom: tips.length);
  }

  /// Where [key]'s widget is on screen, if it is.
  static Rect? _rectOf(GlobalKey key) => _boxRect(key.currentContext);

  static Rect? _boxRect(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The first item showing in the content (a row, a tile), for "tap, hold, drag".
  Rect? _firstItemRect() {
    final area = _rectOf(_contentKey);
    final root = _contentKey.currentContext;
    if (area == null || root == null) return null;
    Rect? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is OverviewRow || w is _MediaTile || w is _NoteRow || w is _FileRow || w is _FileTile) {
        final r = _boxRect(e);
        // Fully on screen and clear of the floating bar at the bottom.
        if (r != null && r.top >= area.top && r.bottom <= area.bottom - _bottomRoom) {
          found = r;
          return;
        }
      }
      e.visitChildren(visit);
    }
    root.visitChildElements(visit);
    return found;
  }

  /// The home tab in the bar, where holding locks.
  Rect? _homeTabRect() {
    Rect? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget.key == const ValueKey('home-tab')) {
        found = _boxRect(e);
        return;
      }
      e.visitChildren(visit);
    }
    _barKey.currentContext?.visitChildElements(visit);
    return found;
  }

  List<TourTip> _tourTips(AppLocalizations l, TourKind kind) {
    final empty = _empty;
    final sections = _sections;
    Rect? tilesOr(GlobalKey key) => empty ? _rectOf(_tilesKey) : _rectOf(key);
    // An empty vault's bar is just the lock: no tabs to show yet.
    final tabs = empty ? null : (_rectOf(_tabsKey) ?? (nativeBarOn() ? _rectOf(_barKey) : null));
    final lockButton = _rectOf(_lockKey);
    final holdHome = lockButton == null && _noLockButton(sections) && !nativeBarOn() ? _homeTabRect() : null;
    return [
      TourTip(
          id: 'add', target: () => tilesOr(_actionKey), title: l.tipAddTitle, body: l.tipAddBody),
      TourTip(
          id: 'items',
          target: () => empty ? _rectOf(_tilesKey) : (_firstItemRect() ?? _rectOf(_contentKey)),
          title: l.tipItemsTitle,
          body: empty ? l.tipItemsEmptyBody : l.tipItemsBody),
      if (tabs != null)
        TourTip(
            id: 'tabs',
            target: () => _rectOf(_tabsKey) ?? _rectOf(_barKey),
            title: l.tipBarTitle,
            body: l.tipBarBody),
      TourTip(
          id: 'settings', target: () => _rectOf(_settingsKey), title: l.settings, body: l.tipSettingsBody),
      if (kind != TourKind.restored) ...[
        // The lock: its button, else the home tab that locks when held, else Settings
        // (where Auto-lock is). With "Lock as soon as I leave" off, leaving does not lock
        // at once: that tip points at Settings and says so.
        if (!Settings.lockOnLeave)
          TourTip(id: 'lock', target: () => _rectOf(_settingsKey), title: l.tipLockTitle, body: l.tipLockAwayBody)
        else if (lockButton != null)
          TourTip(id: 'lock', target: () => _rectOf(_lockKey), title: l.tipLockTitle, body: l.tipLockButtonBody)
        else if (holdHome != null)
          TourTip(id: 'lock', target: _homeTabRect, title: l.tipLockTitle, body: l.tipLockHoldBody)
        else
          TourTip(id: 'lock', target: () => _rectOf(_settingsKey), title: l.tipLockTitle, body: l.tipLockBody),
        // In the User guide, Sync comes next in Settings: no button for it here.
        TourTip(
          id: 'copy',
          target: () => _rectOf(_settingsKey),
          title: l.tourCopyTitle,
          body: l.tourCopyBody,
          note: l.tourSafeKeys,
          action: kind == TourKind.guide ? null : l.tourCopyNow,
        ),
      ],
    ];
  }

  /// Settings → User guide: Settings closes, the guide runs over this page, then on into
  /// Settings.
  void _replayTour() => _tourAgain = true;

  /// Which vault just opened: on the plain page, its icon comes in as the unlock effect
  /// ends, holds, fades; only then does the content show (docs/ui.md). Vaults have no name.
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void dispose() {
    PrivacyCover.onScreenshot = null;
    _drag.dispose();
    _addScroll.dispose();
    _reveal.dispose();
    _idleTimer?.cancel();
    _awayTimer?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    if (LockGuard.onActivity == _touch) LockGuard.onActivity = null;
    final mine = _color;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (vaultTint.value == mine) vaultTint.value = null;
    });
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _touch();
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(minutes: Settings.autoLockMinutes), () {
      if (!mounted) return;
      // A sync waiting or running counts as use: nobody touches the phone while it works.
      if (Awake.busy) return _touch();
      if (!LockGuard.away) _lock();
    });
  }

  Duration get _awayLimit => Duration(minutes: Settings.autoLockMinutes);

  /// A computer's window hidden this long counts as leaving (see didChangeAppLifecycleState).
  static const _windowGrace = Duration(seconds: 3);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      if (_locked || _away != null) return;
      final leaveLocks = Settings.lockOnLeave;
      // Leaving locks at once (the default), unless the app itself sent the person out.
      // On a computer the window reports itself hidden for a moment while it is resized,
      // tiled or made full screen (owner 2026-10-28: every resize asked for the PIN): it
      // locks once hidden for [_windowGrace].
      if (leaveLocks && !LockGuard.away && !Device.desktop) return _lock(animate: false);
      _away = AwayClock.start();
      if (leaveLocks && !LockGuard.away) {
        _idleTimer?.cancel();
        _awayTimer?.cancel();
        _awayTimer = Timer(_windowGrace, () {
          if (mounted && _away != null) _lock(animate: false);
        });
        return;
      }
      // "Lock as soon as I leave" off: the auto-lock time runs from now, not from the
      // last touch. The app switcher still shows the cover, not the vault.
      if (!leaveLocks) {
        _idleTimer?.cancel();
        _awayTimer?.cancel();
        _awayTimer = Timer(_awayLimit, () {
          if (mounted && _away != null) _lock(animate: false);
        });
      }
    } else if (state == AppLifecycleState.resumed && _away != null) {
      final gone = _away!.elapsed;
      _away = null;
      _awayTimer?.cancel();
      LockGuard.clear();
      // Back in time: the vault shows again. Too late: it locks before anything shows.
      final tooLong = Settings.lockOnLeave
          ? gone > (Device.desktop ? _windowGrace : const Duration(seconds: 60))
          : gone >= _awayLimit;
      if (tooLong) {
        _lock(animate: false);
      } else {
        _touch();
      }
    }
  }

  Future<void> _reload() async {
    try {
      final items = await rust.listItems();
      if (mounted) setState(() => _items = items);
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      if (e == rust.VaultError.locked) return _lock(animate: false);
      setState(() => _items = const []);
      _snack(vaultErrorText(AppLocalizations.of(context), e));
    }
  }

  Color get _color => colorById(_vault.color).color;

  /// Lock from the dock (or idle) plays the closing moment; leaving the app locks at once.
  void _lock({bool animate = true}) {
    if (_locked) return;
    _locked = true;
    _idleTimer?.cancel();
    _awayTimer?.cancel();
    _away = null;
    final nav = Navigator.of(context);
    void go() async {
      // The pages kept under the lock let go first: players pause, typed passwords and
      // shown words go. A sync moving items goes on with its own hold on the vault, out of
      // the app's reach, and the lock screen shows how far it is.
      vaultLock.set(true);
      // Unsaved note text is written before the key is dropped.
      // A recording in progress is saved before the key goes.
      try {
        await _recorder.currentState?.stopAndSave();
      } catch (_) {}
      final save = LockGuard.beforeLock;
      if (save != null) {
        try {
          await save();
        } catch (_) {} // locking must not wait on a failed write
      }
      rust.lock();
      LockGuard.clearCopied();
      clearPlaybackCopies();
      _thumbnails.clear();
      _thumbReady.clear();
      // The lock covers the pages; what floats over them closes (as Cancel), and the item
      // names go until the vault opens again.
      nav.popUntil(keptOnLock);
      if (mounted) setState(() => _items = null);
      final opened = await nav.push<rust.VaultInfo>(
        PageRouteBuilder<rust.VaultInfo>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false, resumeVaultId: _vault.id),
        ),
      );
      // Another vault opened instead: this page is gone with the rest.
      if (opened == null || !mounted) return;
      setState(() {
        _vault = opened;
        _locked = false;
      });
      vaultLock.set(false);
      _reload();
      _touch();
    }

    if (animate) {
      playVaultSpin(context, opening: false, onCovered: go);
    } else {
      go();
    }
  }

  // ---------- adding ----------

  static bool get _hasCamera => Device.iOS || Device.android || debugCamera;

  /// The sections that hold something, in a fixed order (docs/ui.md, design language).
  List<VaultSection> get _sections {
    final items = _items ?? const <rust.ItemInfo>[];
    final kinds = [
      for (final s in vaultSections())
        if (s != VaultSection.home && ((s == _section && _keepSection) || items.any((i) => _inSection(s, i)))) s,
    ];
    // The overview comes first whenever the vault holds anything.
    return kinds.isEmpty ? kinds : [VaultSection.home, ...kinds];
  }

  /// Nothing in the vault yet (tags alone do not count): the welcome with the add tiles.
  bool get _empty => _items != null && _sections.isEmpty;

  /// The + in the middle (owner 2026-10-24): in notes, voice and files it does that
  /// section's one thing at once; in the library and on the overview it spreads a short
  /// row of ways. While recording it is the red stop (docs/ui.md, design language).
  Future<void> _mainAction() async {
    if (_recordingNow) return _recorder.currentState?.toggle();
    final direct = _directAdd;
    if (direct != null && !_adding) return _add(direct);
    setState(() {
      _adding = !_adding;
      if (_adding) _openAdd();
      _hover = null;
    });
  }

  /// Each opening starts with the nearest way by the button.
  void _openAdd() {
    if (!_addShown) {
      _addScroll.dispose();
      _addScroll = ScrollController();
    }
    _addShown = true;
  }

  void _closeAdd() => setState(() {
        _adding = false;
        _hover = null;
      });

  void _pickAdd(AddWhat what) {
    _closeAdd();
    _add(what);
  }

  /// One hand: keep the finger down from + and slide; the way level with it lights up.
  void _hoverAt(Offset at) {
    final found = AddColumn.wayAt(at);
    if (found != _hover) {
      if (found != null) HapticFeedback.selectionClick();
      setState(() => _hover = found);
    }
  }

  List<(AddWhat, IconData, String)> _addWays() => addRowWays(AppLocalizations.of(context), _section,
      camera: _hasCamera, voice: vaultSections().contains(VaultSection.audio));

  AddWhat? get _directAdd => addDirect(_section, camera: _hasCamera) ?? (_addWays().isEmpty ? AddWhat.photos : null);


  /// One way of adding, from the add column or the empty vault's tiles. The section it fills
  /// opens, and stays offered until something lands in it or another is picked.
  Future<void> _add(AddWhat what) async {
    final target = switch (what) {
      AddWhat.note => VaultSection.note,
      AddWhat.photo || AddWhat.video || AddWhat.photos => VaultSection.library,
      AddWhat.voice => VaultSection.audio,
      AddWhat.file => VaultSection.file,
    };
    setState(() {
      _section = target;
      _keepSection = true;
      _selected.clear();
    });
    switch (what) {
      case AddWhat.note:
        await _openNote(null);
      case AddWhat.photo:
        await _openCamera(video: false);
      case AddWhat.video:
        await _openCamera(video: true);
      case AddWhat.photos:
        await _import(photos: true);
      case AddWhat.file:
        await _import(photos: false);
      case AddWhat.voice:
        WidgetsBinding.instance.addPostFrameCallback((_) => _recorder.currentState?.toggle());
        return; // stays open while recording; picking another section lets it go
    }
    if (_locked || !mounted) return;
    await _reload();
    if (mounted) setState(() => _keepSection = false);
  }

  Future<void> _openCamera({required bool video}) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CameraScreen(
        video: video,
        tagId: _tagId,
        onOpenLast: (item) => _openItem(item, [item]),
      ),
    ));
    if (!_locked) _reload();
  }

  Future<void> _openNote(rust.ItemInfo? item) async {
    NoteScreen.lastSave = null;
    NoteScreen.lastDeleted = null;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => Readable(child: NoteScreen(item: item, tagId: item == null ? _tagId : null, vaultId: _vault.id))));
    // A swipe back pops null and saves behind the pop: wait for it, then reload.
    final pending = NoteScreen.lastSave;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        if (mounted) showToast(context, AppLocalizations.of(context).errorStorage, icon: Icons.error_outline_rounded);
      }
    }
    final gone = NoteScreen.lastDeleted;
    if (!_locked && gone != null) _trashed([gone]);
    if (!_locked && changed != false) {
      _previews.clear();
      _reload();
    }
  }

  Future<void> _import({required bool photos}) async {
    final l = AppLocalizations.of(context);
    LockGuard.allowAway();
    try {
      final picking = Stopwatch()..start();
      final batch = await Originals.pick(photos: photos);
      ImportStats.pickMs = picking.elapsedMilliseconds;
      if (batch.count == 0) return;
      if (!mounted) return await Originals.stopCopying();
      final done = ValueNotifier<int>(0);
      var cancel = false;
      final nav = Navigator.of(context);
      // The sheet's own route: locking closes it and puts the lock screen on top, and the
      // end of the import must not close that instead.
      Route<dynamic>? sheetRoute;
      final sheet = showModalBottomSheet<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (context) {
          sheetRoute ??= ModalRoute.of(context);
          return _ImportSheet(total: batch.count, done: done, onCancel: () {
            cancel = true;
            Originals.stopCopying(); // what is still being copied is not wanted any more
          });
        },
      );
      final List<(rust.ItemInfo, String?)> picked;
      try {
        picked = await importPicked(batch, photos: photos, progress: (d, _) {
          done.value = d;
          LockGuard.activity(); // a long import is not idleness
        }, cancelled: () => cancel, mediaName: (kind, ext) => captureName(l, kind, DateTime.now(), ext));
      } finally {
        final r = sheetRoute;
        if (r != null && r.isCurrent) {
          nav.pop();
        } else if (r != null && r.isActive) {
          nav.removeRoute(r);
        } else if (r == null && mounted && !_locked) {
          nav.pop(); // over before the sheet was even drawn
        }
        await sheet;
        done.dispose();
      }
      final added = [for (final p in picked) p.$1];
      // Added while a tag is open: they carry it.
      final tagId = _tagId;
      if (tagId != null && added.isNotEmpty) {
        await rust.setTag(itemIds: [for (final a in added) a.id], tagId: tagId, tagged: true);
      }
      // No "N added" message: the items appear at once, and the bar showed progress.
      if (mounted) _reload();
      // What went in (the first ones: a cancel only skips the rest) can be removed from
      // the phone, after asking here and then again by the system.
      final from = [for (final p in picked) ?p.$2];
      if (from.isNotEmpty && mounted) {
        await _offerDeleteOriginals(from, photos: photos);
      } else {
        await Originals.release();
      }
    } on rust.VaultError catch (e) {
      // Stopped by the lock: nothing to say over the lock screen.
      if (mounted && !_locked) _snack(vaultErrorText(l, e));
    } catch (_) {
      if (mounted && !_locked) _snack(l.errorStorage);
    } finally {
      LockGuard.clear();
    }
  }

  /// "Remove the originals from this phone?" after an import: the person decides here,
  /// then iOS or Android asks once more and does it.
  Future<void> _offerDeleteOriginals(List<String> ids, {required bool photos}) async {
    final l = AppLocalizations.of(context);
    final yes = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => DeleteOriginalsSheet(count: ids.length, photos: photos),
    );
    if (yes != true) return Originals.release();
    LockGuard.allowAway(); // the system's own question takes the screen for a moment
    try {
      final r = await Originals.delete(ids, photos: photos);
      if (!mounted || r.cancelled) return;
      if (r.failed > 0) {
        _snack(l.originalsFailed(r.failed));
      } else if (r.deleted > 0) {
        _snack(l.originalsDeleted(r.deleted));
      }
    } catch (_) {
      if (mounted) _snack(l.originalsFailed(ids.length));
    } finally {
      LockGuard.clear();
    }
  }

  // ---------- menu ----------

  /// The backup password is needed before the first backup: set it (with the
  /// Emergency Kit) right there, then carry on.
  Future<bool> _ensurePassword() async {
    if (_vault.hasPassword) return true;
    final info = await Navigator.of(context).push<rust.VaultInfo>(
      MaterialPageRoute(builder: (_) => Readable(child: BackupPasswordScreen(libraryDir: widget.libraryDir, change: false))),
    );
    if (info != null && mounted) setState(() => _vault = info);
    return info != null;
  }

  // Security settings (password, backup, Emergency Kit, biometrics) ask for the owner
  // first, wherever they are opened from (docs/security.md, security settings).
  Future<void> _password() async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    final info = await Navigator.of(context).push<rust.VaultInfo>(
      MaterialPageRoute(builder: (_) => Readable(child: BackupPasswordScreen(libraryDir: widget.libraryDir, change: _vault.hasPassword))),
    );
    if (info != null && mounted) setState(() => _vault = info);
  }

  /// One encrypted file with the vaults that have a password. Desktop: save where the
  /// user picks. Phone: hand it to the share sheet (Files, Drive, AirDrop…), then remove
  /// the temp copy.
  Future<void> _backup() async {
    final l = AppLocalizations.of(context);
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    if (!await _ensurePassword() || !mounted) return;
    if (await _confirmBackup(l) != true || !mounted) return;
    final d = DateTime.now();
    final name = 'CozySafe-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.cozysafe';
    LockGuard.allowAway();
    try {
      if (_desktop) {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await rust.exportBackup(dir: widget.libraryDir, path: loc.path);
        _backedUp();
        if (mounted) _snack(l.backupDone);
        return;
      }
      final tmp = File('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$name');
      await rust.exportBackup(dir: widget.libraryDir, path: tmp.path);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final shared = await SharePlus.instance.share(ShareParams(
        files: [XFile(tmp.path, mimeType: 'application/octet-stream')],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (tmp.existsSync()) tmp.deleteSync();
      // Android reports "unavailable" for most targets; count it, only a cancel is not a backup.
      if (shared.status != ShareResultStatus.dismissed) _backedUp();
    } catch (_) {
      if (mounted) _snack(l.backupFailed);
    } finally {
      LockGuard.clear();
    }
  }

  static const _lastBackupKey = 'last-backup';

  void _backedUp() {
    Prefs.write(_lastBackupKey, '${DateTime.now().millisecondsSinceEpoch}');
    if (mounted) setState(() {});
  }

  String _lastBackupText(AppLocalizations l) {
    final ms = int.tryParse(Prefs.read(_lastBackupKey) ?? '');
    if (ms == null) return l.lastBackupNever;
    final days = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms)).inDays;
    return days == 0 ? l.lastBackupToday : l.lastBackupDays(days);
  }

  /// Always the same words, whatever vaults exist: the sheet must not reveal how many.
  Future<bool?> _confirmBackup(AppLocalizations l) => showModalBottomSheet<bool>(
        context: context,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.backup, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(l.backupWhatsIn, style: TextStyle(color: CsColors.of(context).muted, height: 1.45)),
                const SizedBox(height: 6),
                Text(l.backupNeeds, style: TextStyle(color: CsColors.of(context).muted, height: 1.45)),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.backupSave)),
                const SizedBox(height: 6),
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
              ],
            ),
          ),
        ),
      );

  Future<void> _showKit() async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    // Face ID, then the vault password too: the 24 words are half of what opens the vault
    // anywhere (owner 2026-10-24).
    String? password = await KitPasswordScreen.ask(context, widget.libraryDir);
    if (password == null || !mounted) return;
    final key = await SecretKeyStore.read();
    if (key == null || !mounted) return;
    // The page stays under the lock, the password typed for it does not: a Recovery Key
    // change after that asks for it again.
    void drop() {
      if (vaultLock.locked) password = null;
    }
    vaultLock.addListener(drop);
    try {
      await _pushKit(key, () => password);
    } finally {
      vaultLock.removeListener(drop);
    }
  }

  Future<void> _pushKit(Uint8List key, String? Function() password) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (kit) => Readable(child: EmergencyKitScreen(
        keyText: rust.secretKeyText(key: key),
        confirm: false,
        // A new Recovery Key replaces this page (it would show the old one).
        onChange: () => Navigator.of(kit).pushReplacement(MaterialPageRoute<void>(
          builder: (_) => Readable(child: ChangeKeyScreen(libraryDir: widget.libraryDir, password: password(), onBackup: _backup)),
  )      )),
      ),
    ));
  }

  Future<void> _toggleBiometric() async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    final l = AppLocalizations.of(context);
    final store = BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel);
    if (_bioOn) {
      await turnOffBiometric(store);
    } else if (!await turnOnBiometric(store)) {
      if (mounted) _snack(l.biometricFailed);
    }
    if (mounted) setState(() => _bioOn = rust.biometricEnabled());
  }

  Future<void> _changeIdentity() async {
    var icon = vaultIcons.indexWhere((i) => i.id == _vault.icon);
    var color = vaultColors.indexWhere((c) => c.id == _vault.color);
    final picked = await showIdentityCard(context, icon: icon < 0 ? 0 : icon, color: color < 0 ? 0 : color);
    if (picked == null || !mounted) return;
    (icon, color) = picked;
    try {
      final info = await rust.setIdentity(icon: vaultIcons[icon].id, color: vaultColors[color].id);
      if (mounted) {
        setState(() => _vault = info);
        if (_tintApp) vaultTint.value = _color;
      }
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(AppLocalizations.of(context), e));
    }
  }

  Future<void> _openTrash() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => Readable(child: const TrashScreen())));
    // A swipe back returns null: reload then too.
    if (!_locked && changed != false) _reload();
  }

  /// [guideFrom]: the User guide goes on in Settings after that many tips here.
  Future<void> _openSettings({SettingsSpot? focus, int? guideFrom}) async {
    final l = AppLocalizations.of(context);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Readable(child: SettingsScreen(
        libraryDir: widget.libraryDir,
        vault: () => _vault,
        canBiometric: _canBio,
        biometricOn: () => _bioOn,
        onToggleBiometric: _toggleBiometric,
        onPassword: _password,
        onShowKit: _showKit,
        onBackup: _backup,
        lastBackup: () => _lastBackupText(l),
        onChangeIdentity: _changeIdentity,
        onOpenTrash: _openTrash,
        onNewVault: _newVault,
        onShowKind: (kind) => _pickSection(switch (kind) {
          ItemKind.note => VaultSection.note,
          ItemKind.audio => VaultSection.audio,
          ItemKind.file => VaultSection.file,
          _ => VaultSection.library,
        }),
        onSynced: _reload,
        focus: focus,
        guideFrom: guideFrom,
        onTour: _replayTour,
      )),
    ));
    if (!_locked) {
      _touch(); // the auto-lock time may have changed
      setState(() {}); // and the side of the main action
      if (_tourAgain) {
        _tourAgain = false;
        _showTour(TourKind.guide);
      }
    }
  }

  /// Creating another vault locks this one first (one open at a time). Only the phone's
  /// owner may: knowing this vault's PIN is not enough.
  Future<void> _newVault() async {
    if (!await confirmOwner(AppLocalizations.of(context).ownerCheckReason) || !mounted) return;
    final avoid = (_vault.icon, _vault.color);
    _locked = true;
    _idleTimer?.cancel();
    rust.lock();
    // The new vault fades in over this page; once it covers the screen, the lock screen
    // takes the place of everything under it, so Cancel goes back there. (Swapping to the
    // lock screen first flashed it for a moment.)
    final nav = Navigator.of(context);
    final libraryDir = widget.libraryDir;
    final route = fadeRoute<void>((_) => Readable(child: NewVaultScreen(libraryDir: libraryDir, first: false, avoid: avoid)));
    nav.push(route);
    void swap(AnimationStatus s) {
      if (s != AnimationStatus.completed) return;
      route.animation?.removeStatusListener(swap);
      if (!route.isActive) return;
      final unlock = PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => UnlockScreen(libraryDir: libraryDir, askBiometricNow: false),
      );
      nav.replaceRouteBelow(anchorRoute: route, newRoute: unlock);
      while (!unlock.isFirst) {
        nav.removeRouteBelow(unlock);
      }
    }
    route.animation?.addStatusListener(swap);
  }

  void _snack(String text) => showToast(context, text, besideAction: _selected.isEmpty);

  // ---------- content ----------

  Future<Uint8List> _thumbnail(String id) => _thumbnails[id] ??= rust.itemThumbnail(id: id)
    ..then((b) => _thumbReady[id] = b, onError: (_) => Uint8List(0));

  /// The note's text after its first line (the title), for the list's two-line preview.
  Future<String> _preview(String id) => _previews[id] ??= rust.itemContent(id: id).then((bytes) {
        final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
        final nl = text.indexOf('\n');
        return (nl < 0 ? '' : text.substring(nl + 1)).trim().replaceAll(RegExp(r'\s+'), ' ');
      });

  bool _isMedia(rust.ItemInfo i) => i.kind == ItemKind.photo || i.kind == ItemKind.video;

  Future<void> _openItem(rust.ItemInfo item, List<rust.ItemInfo> media) async {
    if (_selecting) return _toggle(item.id);
    if (item.kind == ItemKind.tag) return setState(() => _tagId = item.id);
    // A wide window opens it in the pane beside the list, not over the page.
    if (_wide && hasPane(context)) return setState(() => _focus = item);
    // Every kind opens the same way: big, over the page you are on, never a jump to
    // another tab (owner 2026-10-21, one design 2026-10-25). Open in its bar goes further:
    // full screen, the note's editor, the file's own page.
    final result = await QuickLook.show(context, item,
        // Photos and videos: the full-screen view swipes through both.
        photos: media.where((m) => m.kind == ItemKind.photo || VideoViewScreen.supported).toList(),
        vaultId: _vault.id);
    if (!mounted || _locked) return;
    // A box ticked in the preview: its write ends first (Edit reads the note), then the
    // list and the note's line under its title catch up.
    if (QuickLook.edited.remove(item.id)) {
      await QuickLook.lastSave?.catchError((Object _) {});
      if (!mounted || _locked) return;
      _previews.remove(item.id);
      _reload();
    }
    if (result == QuickLook.editRequest) return _openNote(item);
    // ⋯ in a viewer: that item's menu (it may be another photo, swiped to).
    final target = QuickLook.menuTarget(result);
    if (target != null) {
      final it = (_items ?? const <rust.ItemInfo>[]).where((i) => i.id == target).firstOrNull;
      if (it != null) await _itemMenu(it, media);
      return;
    }
    if (result != null) {
      _reload();
      _trashed([result]);
    }
  }

  /// The pane's viewer is done with [item]: the same answers as when it is popped.
  Future<void> _paneResult(rust.ItemInfo item, String? result) async {
    if (QuickLook.edited.remove(item.id)) {
      await QuickLook.lastSave?.catchError((Object _) {});
      if (!mounted || _locked) return;
      _previews.remove(item.id);
      _reload();
    }
    if (result == null) return;
    if (result == QuickLook.editRequest) return _openNote(item);
    final target = QuickLook.menuTarget(result);
    if (target != null) {
      final it = (_items ?? const <rust.ItemInfo>[]).where((i) => i.id == target).firstOrNull;
      if (it != null) await _itemMenu(it, const []);
      return;
    }
    setState(() => _focus = null);
    _reload();
    _trashed([result]);
  }

  /// Rename a photo, video, recording or file: the name is edited, its extension kept
  /// (owner 2026-10-22: the same Rename everywhere, from a long press). A note has no
  /// name of its own: its first line is its title.
  Future<void> _rename(rust.ItemInfo item) async {
    final l = AppLocalizations.of(context);
    final dot = item.name.lastIndexOf('.');
    final ext = dot > 0 && item.name.length - dot <= 6 ? item.name.substring(dot) : '';
    final text = TextEditingController(text: ext.isEmpty ? item.name : item.name.substring(0, dot));
    text.selection = TextSelection(baseOffset: 0, extentOffset: text.text.length);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.rename),
        content: TextField(
          key: const ValueKey('rename-field'),
          controller: text,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: Text(l.save)),
        ],
      ),
    );
    text.dispose();
    if (name == null || name.isEmpty || '$name$ext' == item.name) return;
    await rust.renameItem(id: item.id, name: '$name$ext');
    _reload();
  }

  /// The one selected item, when it can be renamed (not a note, not a group).
  rust.ItemInfo? get _renamable {
    if (_selected.length != 1) return null;
    final it = (_items ?? const <rust.ItemInfo>[]).where((i) => i.id == _selected.first).firstOrNull;
    return it == null || it.kind == ItemKind.note || it.kind == ItemKind.tag ? null : it;
  }

  Future<void> _renameSelected() async {
    final it = _renamable;
    if (it == null) return;
    await _rename(it);
    if (mounted) setState(_endSelect);
  }

  /// "Moved to Recently deleted · Undo".
  void _trashed(List<String> ids) {
    final l = AppLocalizations.of(context);
    showToast(
      context,
      ids.length == 1 ? l.movedToTrash : l.movedToTrashCount(ids.length),
      icon: Icons.delete_outline_rounded,
      actionLabel: l.undo,
      besideAction: _selected.isEmpty,
      onAction: () async {
        for (final id in ids) {
          try {
            await rust.restoreItem(id: id);
          } catch (_) {}
        }
        if (!_locked) _reload();
      },
    );
  }

  // ---------- selection ----------

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final one = ids.length == 1 ? (_items ?? const <rust.ItemInfo>[]).where((i) => i.id == ids.first).firstOrNull : null;
    final l = AppLocalizations.of(context);
    if (!await confirmTrash(context, count: ids.length, name: one == null ? null : _shownName(l, one)) || !mounted) return;
    final now = nowMs();
    for (final id in ids) {
      try {
        await rust.trashItem(id: id, nowMs: now);
      } catch (_) {}
    }
    setState(_endSelect);
    _reload();
    if (ids.isNotEmpty) _trashed(ids);
  }

  /// Decrypted copies of the selection go to the share sheet, then the copies are wiped.
  Future<void> _sendSelected() async {
    final l = AppLocalizations.of(context);
    if (!await confirmShareOut(context, _vault.id) || !mounted) return;
    final items =
        (_items ?? const <rust.ItemInfo>[]).where((i) => _selected.contains(i.id) && i.kind != ItemKind.tag).toList();
    final dir = await Directory((await getTemporaryDirectory()).path).createTemp('send');
    LockGuard.allowAway();
    try {
      final files = <XFile>[];
      for (final (n, it) in items.indexed) {
        var name = it.name.isEmpty ? 'item-$n' : it.name.replaceAll(RegExp(r'[/\\:]'), '-');
        if (it.kind == ItemKind.note && !name.endsWith('.txt')) name = '$name.txt';
        final path = '${dir.path}${Platform.pathSeparator}$name';
        await rust.exportItem(id: it.id, path: path);
        files.add(XFile(path, mimeType: it.kind == ItemKind.note ? 'text/plain' : it.mime));
      }
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: files,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (mounted) setState(_endSelect);
    } catch (_) {
      if (mounted) _snack(l.errorStorage);
    } finally {
      LockGuard.clear();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  bool _shotCardOpen = false;

  Future<void> _screenshotNotice() async {
    if (_shotCardOpen) return; // a burst of screenshots: one card
    _shotCardOpen = true;
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final blocked = Settings.blockScreenshots;
    final go = await showCard<bool>(
      context,
      title: blocked ? l.shotBlockedTitle : l.shotSavedTitle,
      builder: (context) => Padding(
        key: const ValueKey('shot-card'),
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(blocked ? Icons.visibility_off_outlined : Icons.warning_amber_rounded,
                size: 40, color: blocked ? c.muted : recordRed(context)),
            const SizedBox(height: 12),
            Text(blocked ? l.shotBlockedBody : l.screenshotWarning, style: const TextStyle(fontSize: 16, height: 1.45)),
            if (blocked) ...[
              const SizedBox(height: 10),
              Text(l.shotBlockedHow, style: TextStyle(fontSize: 15, height: 1.45, color: c.muted)),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                if (blocked)
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('shot-settings'),
                      onPressed: () => Navigator.of(context).pop(true),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                      child: Text(l.settings),
                    ),
                  ),
                if (blocked) const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('shot-ok'),
                    onPressed: () => Navigator.of(context).pop(false),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                    child: Text(l.gotIt),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    _shotCardOpen = false;
    if (go == true && mounted && !_locked) _openSettings();
  }

  // ---------- one item's menu (long press) ----------

  /// Run [act] on [item] alone, as if it were the selection, then leave it unselected.
  Future<void> _onlyThis(rust.ItemInfo item, Future<void> Function() act) async {
    setState(() => _selected
      ..clear()
      ..add(item.id));
    await act();
    if (mounted) setState(_endSelect);
  }

  /// The actions for one item, at the finger (owner 2026-10-22, the iPhone's Files app):
  /// Open, Select, Rename, Group, Info, Send, Delete.
  Future<void> _itemMenu(rust.ItemInfo item, List<rust.ItemInfo> media, {bool open = true}) async {
    if (_selecting) return _toggle(item.id);
    final l = AppLocalizations.of(context);
    await showItemMenu(context, title: _shownName(l, item), entries: [
      if (open) MenuEntry(Icons.open_in_new_rounded, l.openItem, () => _openItem(item, media), key: const ValueKey('menu-open')),
      MenuEntry(Icons.check_circle_outline, l.select, () => setState(() {
            _selectMode = true;
            _selected.add(item.id);
          }), key: const ValueKey('menu-select')),
      if (item.kind != ItemKind.note)
        MenuEntry(Icons.edit_outlined, l.rename, () => _rename(item), key: const ValueKey('menu-rename')),
      MenuEntry(item.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded, item.isFavorite ? l.unfavorite : l.favorite,
          () => _toggleFavorite(item), key: const ValueKey('menu-favorite')),
      MenuEntry(Icons.sell_outlined, l.tagAction, () => _onlyThis(item, _tagSelected), key: const ValueKey('menu-group')),
      MenuEntry(Icons.info_outline, l.info, () => _info(item), key: const ValueKey('menu-info')),
      // Older versions of it, to look at or bring back (owner 2026-10-27).
      MenuEntry(Icons.history_rounded, l.versionHistory, () => _history(item), key: const ValueKey('menu-history')),
      MenuEntry(Icons.ios_share, l.sendOut, () => _onlyThis(item, _sendSelected), key: const ValueKey('menu-send')),
      MenuEntry(Icons.delete_outline, l.delete, () async {
        if (!await confirmTrash(context, count: 1, name: _shownName(l, item)) || !mounted) return;
        await rust.trashItem(id: item.id, nowMs: nowMs());
        _reload();
        _trashed([item.id]);
      }, danger: true, key: const ValueKey('menu-delete')),
    ]);
  }

  /// A group's menu (long press on its chip): Open, Rename, Delete.
  Future<void> _tagMenu(rust.ItemInfo tag) async {
    final l = AppLocalizations.of(context);
    await showItemMenu(context, title: tag.name, entries: [
      MenuEntry(Icons.open_in_new_rounded, l.openItem, () => setState(() => _tagId = tag.id)),
      MenuEntry(Icons.edit_outlined, l.renameTag, () => _renameTag(tag), key: const ValueKey('menu-rename-tag')),
      MenuEntry(Icons.delete_outline, l.deleteTag, () => _deleteTag(tag), danger: true),
    ]);
  }

  String _shownName(AppLocalizations l, rust.ItemInfo it) => shownName(l, it);

  Future<void> _history(rust.ItemInfo item) => pushPage<void>(context,
      title: AppLocalizations.of(context).versionHistory,
      builder: (_) => HistoryScreen(item: item, onRestored: (_) => _reload()));

  /// What an item is: name, kind, size, when it was added, its length, its groups.
  Future<void> _info(rust.ItemInfo item) =>
      showItemInfo(context, item, groups: [for (final id in item.tagIds) ?_tags[id]?.name]..sort());

  // ---------- search ----------

  Future<void> _openSearch() async {
    final items = _items;
    if (items == null) return;
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
          builder: (_) => Readable(child: SearchScreen(items: items, thumbnail: _thumbnail))),
    );
    if (result == null || !mounted || _locked) return;
    // A long press on a result: its menu, over the vault.
    if (result is SearchMenu) {
      final it = result.item;
      return it.kind == ItemKind.tag ? _tagMenu(it) : _itemMenu(it, items.where(_isMedia).toList());
    }
    final picked = result as rust.ItemInfo;
    // A group found by its name opens like a chip in the vault.
    if (picked.kind == ItemKind.tag) return setState(() => _tagId = picked.id);
    _openItem(picked, items.where(_isMedia).toList());
  }

  String _dateGroup(BuildContext context, int ms) {
    final l = AppLocalizations.of(context);
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff <= 0) return l.today;
    if (diff == 1) return l.yesterday;
    if (diff < 7) return l.thisWeek;
    final m = MaterialLocalizations.of(context).formatMonthYear(d);
    return m.isEmpty ? m : m[0].toUpperCase() + m.substring(1); // "tháng 9" → "Tháng 9"
  }

  /// Room under the content for the floating bar and the button above the lock, so
  /// neither ever hides the last row.
  double get _bottomRoom => MediaQuery.paddingOf(context).bottom + 150;

  /// Library: photos and videos, by date, small squares like Photos.
  Widget _library(BuildContext context, List<rust.ItemInfo> media) {
    final l = AppLocalizations.of(context);
    if (media.isEmpty) {
      return _tagId != null
          ? _tagEmpty(context)
          : _Empty(icon: Icons.photo_library_outlined, title: l.emptyPhotosTitle, body: l.emptyPhotosBody);
    }
    final groups = <String, List<rust.ItemInfo>>{};
    // By size: one grid, no date titles.
    final bySize = _sort == ItemSort.size || _sort == ItemSort.smallest;
    for (final it in media) {
      groups.putIfAbsent(bySize ? '' : _dateGroup(context, it.createdMs.toInt()), () => []).add(it);
    }
    _dragOrder = [for (final g in groups.values) for (final it in g) it.id];
    return GestureDetector(
      // Pinch to fit more or fewer per row: 3, 4, 5 or 7.
      onScaleStart: (_) => _scaleStart = 1,
      onScaleUpdate: (d) {
        if (d.pointerCount < 2) return;
        final at = _colSteps.indexOf(_cols);
        if (d.scale < _scaleStart * .8 && at < _colSteps.length - 1) {
          _setCols(_colSteps[at + 1]);
          _scaleStart = d.scale;
        } else if (d.scale > _scaleStart * 1.25 && at > 0) {
          _setCols(_colSteps[at - 1]);
          _scaleStart = d.scale;
        }
      },
      child: Scrollbar(
        child: CustomScrollView(slivers: [
          for (final e in groups.entries) ...[
            if (e.key.isNotEmpty) SliverToBoxAdapter(child: _SectionTitle(e.key)),
            SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _wide ? _wideCols : _cols,
                mainAxisSpacing: 1.5,
                crossAxisSpacing: 1.5,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final it = e.value[i];
                  return DragSelectItem(
                    key: ValueKey(it.id),
                    id: it.id,
                    drag: _drag,
                    onMenu: () => _itemMenu(it, media),
                    child: _MediaTile(
                      item: it,
                      thumbnail: _thumbnail(it.id),
                      ready: _thumbReady[it.id],
                      selected: _selected.contains(it.id),
                      selecting: _selecting,
                      onTap: () => _openItem(it, media),
                    ),
                  );
                },
                childCount: e.value.length,
              ),
            ),
          ],
          SliverToBoxAdapter(child: SizedBox(height: _bottomRoom)),
        ]),
      ),
    );
  }

  /// The open group has nothing in this section: say so, and offer the sections where
  /// it does have something, with their counts, one tap away.
  Widget _tagEmpty(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final items = _items ?? const <rust.ItemInfo>[];
    final elsewhere = [
      for (final s in vaultSections())
        if (s != _section) (s, items.where((i) => _inSection(s, i) && i.tagIds.contains(_tagId)).length),
    ].where((e) => e.$2 > 0).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      children: [
        Icon(Icons.sell_outlined, size: 44, color: c.muted),
        const SizedBox(height: 12),
        Text(l.tagEmpty, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 16)),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (s, n) in elsewhere)
              ActionChip(
                key: ValueKey('tag-goto-${s.name}'),
                label: Text('${sectionLabel(l, s)} · $n', style: const TextStyle(fontWeight: FontWeight.w600)),
                avatar: const Icon(Icons.arrow_forward_rounded, size: 18),
                shape: const StadiumBorder(),
                onPressed: () => setState(() {
                  _section = s;
                  _keepSection = false;
                }),
              ),
          ],
        ),
      ],
    );
  }

  /// Notes or files: one neutral card of rows.
  Widget _list(BuildContext context, List<rust.ItemInfo> list, {required bool notes}) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    if (list.isEmpty) {
      if (_tagId != null) return _tagEmpty(context);
      return notes
          ? _Empty(icon: Icons.edit_note_rounded, title: l.emptyNotesTitle, body: l.emptyNotesBody)
          : _Empty(icon: Icons.folder_outlined, title: l.emptyFilesTitle, body: l.emptyFilesBody);
    }
    _dragOrder = [for (final it in list) it.id];
    if (!notes && _filesAsGrid) {
      return Scrollbar(
        child: GridView.builder(
          key: const ValueKey('files-grid'),
          padding: EdgeInsets.fromLTRB(12, 4, 12, _bottomRoom),
          // Three a row on a phone, as many as fit on a computer (owner 2026-10-28: three
          // tiles across a MacBook were each the size of a page).
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .78),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final it = list[i];
            return DragSelectItem(
              id: it.id,
              drag: _drag,
              onMenu: () => _itemMenu(it, list.where(_isMedia).toList()),
              child: _FileTile(
                item: it,
                selected: _selected.contains(it.id),
                selecting: _selecting,
                onTap: () => _openItem(it, list.where(_isMedia).toList()),
              ),
            );
          },
        ),
      );
    }
    return Scrollbar(
      child: ListView(
        padding: EdgeInsets.fromLTRB(12, 4, 12, _bottomRoom),
        children: [
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, it) in list.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: notes ? 16 : 70, color: c.border.withValues(alpha: .6)),
                  DragSelectItem(
                    id: it.id,
                    drag: _drag,
                    onMenu: () => _itemMenu(it, notes ? const [] : list.where(_isMedia).toList()),
                    child: notes
                        ? _NoteRow(
                            item: it,
                            preview: notePreviews() ? _preview(it.id) : null,
                            selected: _selected.contains(it.id),
                            selecting: _selecting,
                            onTap: () => _openItem(it, const []),
                          )
                        : _FileRow(
                            item: it,
                            thumbnail: _isMedia(it) ? _thumbnail(it.id) : null,
                            selected: _selected.contains(it.id),
                            selecting: _selecting,
                            onTap: () => _openItem(it, list.where(_isMedia).toList()),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- tags ("nhóm", docs/naming.md) ----------

  /// Every tag, by id.
  Map<String, rust.ItemInfo> get _tags =>
      {for (final i in _items ?? const <rust.ItemInfo>[]) if (i.kind == ItemKind.tag) i.id: i};

  rust.ItemInfo? get _openTag => _tagId == null ? null : _tags[_tagId];

  /// Item kinds each section shows.
  static bool _inSection(VaultSection s, rust.ItemInfo i) => switch (s) {
        VaultSection.home => false,
        VaultSection.note => i.kind == ItemKind.note,
        VaultSection.library => i.kind == ItemKind.photo || i.kind == ItemKind.video,
        VaultSection.audio => i.kind == ItemKind.audio,
        VaultSection.file => i.kind == ItemKind.file,
      };

  /// What the section on show holds, narrowed to the open tag.
  /// The open section's items in the chosen order, favourites first (the library keeps
  /// its date groups, so there they only carry a star).
  List<rust.ItemInfo> _shown(List<rust.ItemInfo> items) {
    final out = items
        .where((i) => _inSection(_section, i) && (_tagId == null || i.tagIds.contains(_tagId)))
        .toList();
    final sort = _sort;
    int by(rust.ItemInfo a, rust.ItemInfo b) => switch (sort) {
          ItemSort.newest => b.createdMs.compareTo(a.createdMs),
          ItemSort.oldest => a.createdMs.compareTo(b.createdMs),
          ItemSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ItemSort.size => b.sizeBytes.compareTo(a.sizeBytes),
          ItemSort.smallest => a.sizeBytes.compareTo(b.sizeBytes),
          ItemSort.edited => b.modifiedMs.compareTo(a.modifiedMs),
        };
    final pinFirst = _section != VaultSection.library;
    out.sort((a, b) {
      if (pinFirst && a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
      final c = by(a, b);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return out;
  }

  /// This section's order (Prefs `sort-<section>`): newest first unless changed.
  ItemSort get _sort {
    final saved = Prefs.read('sort-${_section.name}');
    final sort = ItemSort.values.where((v) => v.name == saved).firstOrNull ?? ItemSort.newest;
    // The library is grouped by date, or one grid by size (owner 2026-10-28): name and
    // last edit mean nothing there.
    if (_section == VaultSection.library && (sort == ItemSort.name || sort == ItemSort.edited)) return ItemSort.newest;
    return sort;
  }

  /// Files as a grid of tiles instead of rows (Prefs `files-view`).
  bool get _filesAsGrid => Prefs.read('files-view') == 'grid';

  /// Sort and view, from the ⇅ button in the header.
  Future<void> _sortMenu() async {
    final l = AppLocalizations.of(context);
    final now = _sort;
    final options = switch (_section) {
      VaultSection.library => [ItemSort.newest, ItemSort.oldest, ItemSort.size, ItemSort.smallest],
      VaultSection.note => ItemSort.values,
      _ => [ItemSort.newest, ItemSort.oldest, ItemSort.name, ItemSort.size, ItemSort.smallest],
    };
    String label(ItemSort s) => switch (s) {
          ItemSort.newest => l.sortNewest,
          ItemSort.oldest => l.sortOldest,
          ItemSort.name => l.sortName,
          ItemSort.size => l.sortSize,
          ItemSort.smallest => l.sortSmallest,
          ItemSort.edited => l.sortEdited,
        };
    await showItemMenu(context, title: l.sortBy, entries: [
      for (final o in options)
        MenuEntry(o == now ? Icons.check_rounded : null, label(o), () {
          Prefs.write('sort-${_section.name}', o.name);
          setState(() {});
        }, key: ValueKey('sort-${o.name}')),
      if (_section == VaultSection.file)
        MenuEntry(_filesAsGrid ? Icons.view_list_rounded : Icons.grid_view_rounded, _filesAsGrid ? l.viewList : l.viewGrid, () {
          Prefs.write('files-view', _filesAsGrid ? 'list' : 'grid');
          setState(() {});
        }, key: const ValueKey('files-view')),
    ]);
  }

  Future<void> _toggleFavorite(rust.ItemInfo item) async {
    try {
      await rust.setItemFavorite(id: item.id, isFavorite: !item.isFavorite);
      await _reload();
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(AppLocalizations.of(context), e));
    }
  }

  Future<String?> _askTagName({required String title, String name = ''}) {
    final l = AppLocalizations.of(context);
    final text = TextEditingController(text: name);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: l.tagName),
          onSubmitted: (v) => v.trim().isEmpty ? null : Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          TextButton(
            onPressed: () {
              final n = text.text.trim();
              if (n.isNotEmpty) Navigator.pop(context, n);
            },
            child: Text(l.save),
          ),
        ],
      ),
    ).whenComplete(text.dispose);
  }

  Future<rust.ItemInfo?> _newTag() async {
    final l = AppLocalizations.of(context);
    final name = await _askTagName(title: l.newTag);
    if (name == null) return null;
    try {
      final tag = await rust.createTag(name: name, createdMs: nowMs());
      await _reload();
      return tag;
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
      return null;
    }
  }

  Future<void> _renameTag(rust.ItemInfo tag) async {
    final l = AppLocalizations.of(context);
    final name = await _askTagName(title: l.renameTag, name: tag.name);
    if (name == null) return;
    await rust.renameTag(tagId: tag.id, name: name);
    _reload();
  }

  Future<void> _deleteTag(rust.ItemInfo tag) async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDelete(context,
        title: l.deleteTagTitle(tag.name), body: l.deleteTagBody, action: l.deleteTag, icon: Icons.sell_outlined);
    if (!ok || !mounted) return;
    await rust.deleteTag(tagId: tag.id);
    if (_tagId == tag.id) setState(() => _tagId = null);
    _reload();
  }

  /// Every tag in a sheet: open one, or make a new one.
  Future<void> _allTags() async {
    final l = AppLocalizations.of(context);
    final items = _items ?? const <rust.ItemInfo>[];
    final tags = _tags.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    const create = '+', menu = '?';
    final picked = await pushPage<String>(
      context,
      title: l.allTags,
      builder: (context) => ListView(
            children: [
              for (final t in tags)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text('${items.where((i) => i.tagIds.contains(t.id)).length}'),
                  onTap: () => Navigator.pop(context, t.id),
                  onLongPress: () => Navigator.pop(context, '$menu${t.id}'),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(l.newTag),
                onTap: () => Navigator.pop(context, create),
              ),
            ],
          ),
    );
    if (picked == null || !mounted) return;
    if (picked == create) {
      final t = await _newTag();
      if (t != null) setState(() => _tagId = t.id);
    } else if (picked.startsWith(menu)) {
      final t = _tags[picked.substring(menu.length)];
      if (t != null) await _tagMenu(t);
    } else {
      setState(() => _tagId = picked);
    }
  }

  /// Put the selection into tags, or take it out: one switch per tag, on when every
  /// selected item carries it.
  Future<void> _tagSelected() async {
    final l = AppLocalizations.of(context);
    final items = {for (final i in _items ?? const <rust.ItemInfo>[]) i.id: i};
    final ids = _selected.toList();
    final count = ids.length;
    final result = await pushPage<Map<String, bool>>(
      context,
      title: l.tagSelected(count),
      builder: (context) => _TagSheet(
        tags: _tags.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
        carried: (tagId) => ids.where((id) => items[id]?.tagIds.contains(tagId) ?? false).length,
        total: count,
        onNewTag: _newTag,
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    try {
      for (final e in result.entries) {
        await rust.setTag(itemIds: ids, tagId: e.key, tagged: e.value);
      }
      setState(_endSelect);
      await _reload();
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
    }
  }

  Widget _content(BuildContext context) {
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (_empty) {
      return _Welcome(
        vault: _vault,
        bottomPad: _bottomRoom,
        tiles: AddTiles(key: _tilesKey, camera: _hasCamera, voice: vaultSections().contains(VaultSection.audio), onPick: _add),
      );
    }
    final shown = _shown(items);
    return switch (_section) {
      VaultSection.home => _home(context, items),
      VaultSection.note => _list(context, shown, notes: true),
      VaultSection.file => _list(context, shown, notes: false),
      VaultSection.audio when _tagId != null && shown.isEmpty && !_recordingNow => _tagEmpty(context),
      VaultSection.audio => RecorderView(
          key: _recorder,
          items: shown,
          tagId: _tagId,
          bottomPad: _bottomRoom,
          onSaved: _reload,
          onRecordingChanged: (v) => setState(() => _recordingNow = v),
          selected: _selected,
          selecting: _selecting,
          onToggleSelect: _toggle,
          onOpen: (it) => _openItem(it, const []),
          onMenu: (it) => _itemMenu(it, const []),
          drag: _drag,
          onOrder: (ids) => _dragOrder = ids,
        ),
      VaultSection.library => _library(context, shown),
    };
  }

  /// The home tab: a search field, how much the vault holds, then the overview (the
  /// sections, the groups, what was added last), each a tap away.
  Widget _home(BuildContext context, List<rust.ItemInfo> items) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final things = items.where((i) => i.kind != ItemKind.tag).toList();
    final bytes = things.fold<BigInt>(BigInt.zero, (a, i) => a + i.sizeBytes);
    return VaultOverview(
      items: items,
      thumbnail: _thumbnail,
      bottomPad: _bottomRoom,
      recentCount: 6,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          Material(
            key: const ValueKey('home-search'),
            color: ink.withValues(alpha: .07),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: _openSearch,
              child: SizedBox(
                height: Ui.circle,
                child: Row(children: [
                  const SizedBox(width: 14),
                  Icon(Icons.search, color: ink.withValues(alpha: .6)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(l.searchHint,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, color: ink.withValues(alpha: .5))),
                  ),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 0),
            child: Text(l.storageUsed(fileSize(bytes), things.length), style: TextStyle(color: c.muted, fontSize: 13.5)),
          ),
          if (things.isNotEmpty)
            SecondPlaceNudge(
              onAdd: () => pushPage<void>(context,
                  title: l.syncTitle, builder: (_) => SyncScreen(libraryDir: widget.libraryDir, onSynced: _reload)),
            ),
        ],
      ),
      onKind: (s) => setState(() {
        _section = s;
        _keepSection = false;
        Prefs.write('vault-section', s.name);
      }),
      onGroup: (g) => setState(() {
        _tagId = g.id;
        // A group opens on the first section where it has something.
        _section = vaultSections().firstWhere(
          (s) => s != VaultSection.home && things.any((i) => _inSection(s, i) && i.tagIds.contains(g.id)),
          orElse: () => VaultSection.library,
        );
      }),
      onOpen: (it) => _openItem(it, things.where(_isMedia).toList()),
      onMenu: (it) => _itemMenu(it, things.where(_isMedia).toList()),
      onGroupMenu: _tagMenu,
    );
  }

  /// Large title (the section, or the open tag with Back and a ⋯ menu); Search and
  /// Settings are glass circles on the right.
  Widget _header(BuildContext context) {
    final l = AppLocalizations.of(context);
    final open = _openTag;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          // No vault icon here: it shows once when the vault opens; change it in Settings.
          if (open != null) ...[
            GlassButton(icon: Icons.arrow_back_ios_new, tooltip: l.back, size: Ui.circle, onTap: () => setState(() => _tagId = null)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Inside a group, say so above its name: the page is narrowed to it.
                if (open != null)
                  Text('${l.tagAction} · ${sectionLabel(l, _section)}',
                      key: const ValueKey('group-label'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CsColors.of(context).muted)),
                Text(
                  open?.name ?? (_empty ? '' : sectionLabel(l, _section)),
                  key: const ValueKey('vault-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: open != null ? 26 : 28, fontWeight: FontWeight.w800, letterSpacing: -.5),
                ),
              ],
            ),
          ),
          if (open != null) ...[
            PopupMenuButton<int>(
              tooltip: l.tagOptions,
              onSelected: (v) => v == 0 ? _renameTag(open) : _deleteTag(open),
              itemBuilder: (context) => [
                PopupMenuItem(value: 0, child: Text(l.renameTag)),
                PopupMenuItem(value: 1, child: Text(l.deleteTag)),
              ],
              child: const IgnorePointer(child: GlassButton(icon: Icons.more_horiz, tooltip: '', size: Ui.circle, onTap: null)),
            ),
            const SizedBox(width: 8),
          ],
          // Select, as in Files: choose many, then act on them in the bar.
          if (_items != null && !_empty && _shown(_items!).isNotEmpty) ...[
            SizedBox(
              height: Ui.circle,
              child: Glass(
                radius: Ui.circle / 2,
                child: InkWell(
                  key: const ValueKey('select-button'),
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() => _selectMode = true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(child: Text(l.select, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          // Sort (and, for files, grid or list), as in Files.
          if (_section != VaultSection.home && _items != null && !_empty && _shown(_items!).length > 1) ...[
            GlassButton(
                key: const ValueKey('sort-button'), icon: Icons.swap_vert_rounded, tooltip: l.sortBy, size: Ui.circle, onTap: _sortMenu),
            const SizedBox(width: 8),
          ],
          // The home tab has its own search field.
          if (_section != VaultSection.home || _tagId != null)
            GlassButton(icon: Icons.search, tooltip: l.search, size: Ui.circle, onTap: _openSearch),
          // Inside a group the header is crowded; Settings is one Back away. A wide window
          // has it in the sidebar.
          if (open == null && !_wide) ...[
            const SizedBox(width: 8),
            KeyedSubtree(
              key: _settingsKey,
              child: GlassButton(
                key: const ValueKey('settings-button'),
                icon: Icons.settings_outlined,
                tooltip: l.settings,
                size: Ui.circle,
                onTap: _openSettings,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Three columns (owner 2026-10-27, iPad and computer): the sidebar, the list, and the
  /// open item. No bar at the bottom: the sidebar holds the sections, Add and Lock.
  Widget _wideLayout(BuildContext context, Widget header, Widget? banner, List<VaultSection> sections, bool empty) {
    final selecting = _selecting;
    final width = MediaQuery.sizeOf(context).width;
    final focus = hasPane(context) && _focus != null && (_items ?? const <rust.ItemInfo>[]).any((i) => i.id == _focus!.id) ? _focus : null;
    final listWidth = width - sidebarWidth - 1 - (focus != null ? paneWidth + 1 : 0);
    _wideCols = (listWidth / 130).floor().clamp(3, 10);
    final items = _items ?? const <rust.ItemInfo>[];
    int count(String tagId) => items.where((i) => i.kind != ItemKind.tag && i.tagIds.contains(tagId)).length;
    final groups = [for (final t in _tags.values) (t, count(t.id))]
      ..sort((a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()));
    final divider = VerticalDivider(width: 1, thickness: 1, color: CsColors.of(context).border);
    return MenuPointer(
      child: Scaffold(
        bottomNavigationBar: selecting
            ? _SelectionBar(
                enabled: _selected.isNotEmpty,
                onDone: () => setState(_endSelect),
                allSelected: _allShownSelected,
                onSelectAll: _toggleSelectAll,
                onSend: _sendSelected,
                onTag: _tagSelected,
                onRename: _renamable == null ? null : _renameSelected,
                onDelete: _deleteSelected)
            : null,
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: sidebarWidth,
                child: WideSidebar(
                  vault: _vault,
                  sections: sections.isEmpty ? const [VaultSection.home] : sections,
                  section: _section,
                  groups: groups,
                  groupId: _tagId,
                  onSection: (s) => setState(() {
                    _tagId = null;
                    _pickSection(s);
                  }),
                  onGroup: (id) => setState(() => _tagId = id),
                  onAdd: () => setState(() {
                    _adding = true;
                    _openAdd();
                  }),
                  onSync: () => pushPage<void>(context,
                      title: AppLocalizations.of(context).syncTitle,
                      builder: (_) => SyncScreen(libraryDir: widget.libraryDir, onSynced: _reload)),
                  onTrash: _openTrash,
                  onSettings: _openSettings,
                  onLock: _lock,
                ),
              ),
              divider,
              Expanded(
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        ?banner,
                        Expanded(
                          child: DragSelectArea(
                            key: _contentKey,
                            drag: _drag,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 150),
                              child: KeyedSubtree(
                                key: ValueKey('${_section.name}/$_tagId'),
                                // The overview reads as a page, not stretched across the window.
                                child: _section == VaultSection.home && _tagId == null
                                    ? Align(
                                        alignment: Alignment.topCenter,
                                        child: ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 760), child: _content(context)),
                                      )
                                    : _content(context),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_addShown)
                      Positioned.fill(
                        child: AddCardOverlay(
                          open: _adding,
                          onGone: () => setState(() => _addShown = false),
                          ways: addWays(AppLocalizations.of(context),
                              camera: _hasCamera, voice: vaultSections().contains(VaultSection.audio)),
                          bottom: 24,
                          hovered: _hover,
                          onPick: _pickAdd,
                          onClose: _closeAdd,
                        ),
                      ),
                  ],
                ),
              ),
              if (focus != null) ...[
                divider,
                SizedBox(
                  width: paneWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          key: const ValueKey('wide-pane-close'),
                          tooltip: AppLocalizations.of(context).close,
                          onPressed: () => setState(() => _focus = null),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      Expanded(
                        child: QuickLook(
                          key: ValueKey('pane-${focus.id}'),
                          item: focus,
                          vaultId: _vault.id,
                          onResult: (r) => _paneResult(focus, r),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// A button for every group, then the groups that hold anything as chips (with their
  /// whole count; the open one first and marked), then "New group".
  Widget _tagChips(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = _items ?? const <rust.ItemInfo>[];
    // The whole group's count, the same in every section and in All groups (owner
    // 2026-10-21); a group with nothing in this section still shows, and opening it
    // offers the sections where it has something.
    int count(String tagId) => items.where((i) => i.kind != ItemKind.tag && i.tagIds.contains(tagId)).length;
    final all = _tags.values.toList();
    // The open tag first, then the others by name.
    final here = all.where((t) => t.id == _tagId || count(t.id) > 0).toList()
      ..sort((a, b) => a.id == _tagId
          ? -1
          : b.id == _tagId
              ? 1
              : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final primary = Theme.of(context).colorScheme.primary;
    Widget link(Key key, IconData icon, String text, VoidCallback onTap) => Semantics(
          button: true,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(13),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 19, color: primary),
                  const SizedBox(width: 6),
                  Text(text, style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 13.5)),
                ],
              ),
            ),
          ),
        );
    return SizedBox(
      height: Ui.chip + 14,
      child: ListView(
        // A new list per open tag: the row starts at the beginning again.
        key: ValueKey('tags-$_tagId'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
        children: [
          // Every group, always in reach at the start of the row (the sheet also makes new ones).
          if (all.isNotEmpty) ...[
            Tooltip(
              message: l.allTags,
              child: Semantics(
                button: true,
                label: l.allTags,
                child: Material(
                  key: const ValueKey('all-tags'),
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(13),
                  elevation: .5,
                  shadowColor: Colors.black26,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(13),
                    onTap: _allTags,
                    child: SizedBox(width: Ui.chip + 8, child: Icon(Icons.sell_outlined, size: 20, color: primary)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          for (final t in here) ...[
            _TagChip(
              tag: t,
              count: count(t.id),
              open: t.id == _tagId,
              onTap: () => setState(() => _tagId = t.id == _tagId ? null : t.id),
              onLongPress: () => _tagMenu(t),
            ),
            const SizedBox(width: 8),
          ],
          link(const ValueKey('new-tag'), Icons.add, l.newTag, () async {
            final t = await _newTag();
            if (t != null && mounted) setState(() => _tagId = t.id);
          }),
        ],
      ),
    );
  }

  /// After the unlock spin (it ends ~0.45 s after this screen appears): fade in, hold,
  /// fade out. Taps go through; nothing waits for it.
  Widget _revealOverlay() => Positioned.fill(
        child: AnimatedBuilder(
          animation: _reveal,
          builder: (context, _) {
            // Off for still shots, and gone once it has played.
            if (!_revealOn || _reveal.isCompleted) return const SizedBox.shrink();
            final t = _reveal.value;
            double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
            // The vault's content stays hidden under the page colour until the icon has come
            // and gone: icon in, hold, icon out, then the content shows (docs/ui.md).
            // The icon arrives sharp from the unlock (the dial left it there): hold it,
            // fade it, then the content.
            final icon = 1 - Curves.easeIn.transform(seg(.22, .55));
            final cover = 1 - Curves.easeOut.transform(seg(.5, 1));
            const scale = 1.0;
            // Nothing under the cover can be tapped while it is up.
            return AbsorbPointer(
              absorbing: cover > .5,
              child: Opacity(
                opacity: cover,
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Center(
                    child: Opacity(
                      opacity: icon,
                      child: Transform.scale(
                        scale: scale,
                        child: VaultBadge(icon: _vault.icon, color: _vault.color, size: 120),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

  void _pickSection(VaultSection k) {
    if (_recordingNow) return;
    setState(() {
      _section = k;
      _keepSection = false;
      _selected.clear();
    });
  }

  /// Holding the home tab locks (on by default, Settings): no lock button, as long as
  /// the bar has a home tab to hold.
  bool _noLockButton(List<VaultSection> sections) =>
      holdHomeLocks() && sections.length >= 2 && sections.contains(VaultSection.home);
  void _holdHome() {
    if (_recordingNow) return;
    _lock();
  }

  Widget _actionButton(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Where + does one thing at once, it shows that thing (owner's testers 2026-10-24: in
    // Voice a plain + that starts the microphone was a surprise).
    final (icon, tip) = _recordingNow
        ? (Icons.stop_rounded, l.stopRecording)
        : switch (_adding ? null : _directAdd) {
            AddWhat.note => (Icons.edit_note_rounded, l.newNote),
            AddWhat.voice => (Icons.mic_rounded, l.startRecording),
            AddWhat.file => (Icons.folder_outlined, l.addFiles),
            AddWhat.photos => (Icons.add_photo_alternate_outlined, l.addFromDevice),
            _ => (Icons.add, _adding ? l.close : l.addToVault),
          };
    return ActionButton(
        key: _actionKey,
        icon: icon,
        tooltip: tip,
        onTap: _mainAction,
        turns: _adding && icon == Icons.add ? .125 : 0,
        solid: actionSide() == ActionSide.center,
        size: actionSide() == ActionSide.center ? centrePlusSize : Ui.primary,
        // Red where it records: the stop while recording, the microphone in Voice.
        color: _recordingNow || (!_adding && _directAdd == AddWhat.voice) ? recordRed(context) : null);
  }

  /// Everything on show is selected (Select all then reads Deselect all).
  bool get _allShownSelected {
    final items = _items;
    if (items == null) return false;
    final ids = _shown(items).map((i) => i.id).toSet();
    return ids.isNotEmpty && _selected.containsAll(ids);
  }

  void _toggleSelectAll() {
    final items = _items;
    if (items == null) return;
    final ids = _shown(items).map((i) => i.id).toSet();
    setState(() => _allShownSelected ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final selecting = _selecting;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final page = Theme.of(context).scaffoldBackgroundColor;
    // The section on show is always one that is offered (it may have just emptied).
    final sections = _sections;
    if (sections.isNotEmpty && !sections.contains(_section)) _section = sections.first;
    final empty = _empty;
    // The + inside the bar's middle (Settings → Middle); the bar's centre, left of which a
    // lock button may sit.
    final centreMode = actionSide() == ActionSide.center;
    final lockShown = !_noLockButton(sections) && !nativeBarOn();
    // Left of the bar: a lock button, and the vault's badge (the overview tab).
    final leftOfBar = (lockShown ? Ui.bar + 4 : 0);
    final barW = MediaQuery.sizeOf(context).width - 20 - leftOfBar;
    final centreX = 10 + leftOfBar + barW * centrePlusShare(barSections(sections).length < 2 ? const [] : barSections(sections));

    // Selecting: only the count on top; Done and Select all sit in the bar at the bottom
    // with the actions (owner 2026-10-25: every button within the thumb's reach).
    final header = selecting
        ? Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
            child: SizedBox(
              height: Ui.tap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_selected.isEmpty ? l.selectItems : l.selectedCount(_selected.length),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
          )
        : _header(context);

    final banner = !_vault.hasPassword && !selecting
        ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            // Says what is at stake, not how it works (docs/ui.md, review 1).
            child: Material(
              color: c.warnBg,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.passwordNudgeTitle, style: TextStyle(color: c.warnInk, fontSize: 13.5, fontWeight: FontWeight.w700)),
                    Text(l.passwordNudge, style: TextStyle(color: c.warnInk, fontSize: 13.5)),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _password,
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      child: Text(l.backupPasswordTitle),
                    ),
                  ],
                ),
              ),
            ),
          )
        : null;

    final inTag = _tagId != null;
    _wide = isWide(context);
    if (_wide) return _wideLayout(context, header, banner, sections, empty);
    return MenuPointer(child: PopScope(
      canPop: !selecting && !inTag && !_recordingNow && !_adding,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_adding) {
          _closeAdd();
        } else if (selecting) {
          setState(_endSelect);
        } else if (inTag) {
          setState(() => _tagId = null);
        }
      },
      // Inside a group the header's Back has no route to pop: a swipe from the left edge
      // does the same (docs/ui.md). The bottom of the edge stays free for the add column.
      child: EdgeSwipeBack(
      enabled: inTag && !selecting && !_adding && !_recordingNow,
      bottomGap: 220,
      onBack: () => setState(() => _tagId = null),
      child: Scaffold(
        // While selecting, the bar gives way to what can be done with the selection
        // (a real bottom bar, so messages float above it).
        bottomNavigationBar: selecting
            ? _SelectionBar(
                enabled: _selected.isNotEmpty,
                onDone: () => setState(_endSelect),
                allSelected: _allShownSelected,
                onSelectAll: _toggleSelectAll,
                onSend: _sendSelected,
                onTag: _tagSelected,
                onRename: _renamable == null ? null : _renameSelected,
                onDelete: _deleteSelected)
            : null,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  // The home tab lists the groups itself.
                  if (!_recordingNow && !empty && (_section != VaultSection.home || _tagId != null)) _tagChips(context),
                  ?banner,
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      // A short fade when the section or the open group changes.
                      child: DragSelectArea(
                        key: _contentKey,
                        drag: _drag,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: KeyedSubtree(key: ValueKey('${_section.name}/$_tagId'), child: _content(context)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!selecting) ...[
              // The content fades out under the floating bar.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: bottom + 96,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [page.withValues(alpha: 0), page.withValues(alpha: .85)],
                      ),
                    ),
                  ),
                ),
              ),
              // iOS 26: the system's own bar (Liquid Glass), centred on the same line.
              if (nativeBarOn())
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottom + Ui.edge - 4 - NativeVaultBar.marginBottom,
                  child: NativeVaultBar(
                    key: _barKey,
                    section: _section,
                    sections: barSections(sections),
                    onSection: _pickSection,
                    onLock: _lock,
                    showLock: !_noLockButton(sections),
                    onHoldHome: _noLockButton(sections) ? _holdHome : null,
                  ),
                )
              else
              Positioned(
                left: 10,
                right: 10,
                bottom: bottom + Ui.edge,
                child: VaultBar(
                  key: _barKey,
                  tabsKey: _tabsKey,
                  section: _section,
                  sections: barSections(sections),
                  home: VaultBadge(icon: _vault.icon, color: _vault.color, size: 32),
                  centre: centreMode && !empty ? const SizedBox(width: centrePlusSize, height: centrePlusSize) : null,
                  onSection: _pickSection,
                  // Just the lock, big: no vault icon, which would hint that the phone
                  // holds other vaults (owner 2026-10-21, after user testing).
                  // Holding the home tab locks: no lock button, the sections run the
                  // full width (owner 2026-10-22).
                  onHoldHome: _noLockButton(sections) ? _holdHome : null,
                  lock: _noLockButton(sections)
                      ? null
                      : KeyedSubtree(
                          key: _lockKey,
                          child: GlassButton(
                            key: const ValueKey('lock-button'),
                            tooltip: l.lockVault,
                            size: Ui.bar,
                            icon: null,
                            onTap: _lock,
                            child: LockGlyph(size: 26, color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ),
                ),
              ),
              if (_addShown)
                Positioned.fill(
                  child: actionSide() == ActionSide.center
                      // In the middle: the ways side by side just above the + (owner
                      // 2026-10-24: the fan put them too far apart).
                      ? AddRow(
                          open: _adding,
                          onGone: () => setState(() => _addShown = false),
                          ways: _addWays(),
                          bottom: bottom + actionLift() + Ui.primary + 10,
                          centreX: centreX,
                          hovered: _hover,
                          onPick: _pickAdd,
                          onClose: _closeAdd,
                        )
                      // On an edge: the card alone just above + (owner 2026-10-27: a column
                      // beside the card looked broken); its lines are the quick buttons.
                      : AddCardOverlay(
                          open: _adding,
                          onGone: () => setState(() => _addShown = false),
                          ways: addWays(l, camera: _hasCamera, voice: vaultSections().contains(VaultSection.audio)),
                          bottom: bottom + actionLift() + Ui.primary + 10,
                          hovered: _hover,
                          onPick: _pickAdd,
                          onClose: _closeAdd,
                        ),
                ),
              // In the middle, above the quick buttons: every way with a line on what it
              // does (owner 2026-10-27).
              if (_addShown && actionSide() == ActionSide.center)
                Positioned(
                  left: 16,
                  right: 16,
                  top: MediaQuery.paddingOf(context).top + 12,
                  bottom: bottom + actionLift() + Ui.primary + 10 + Ui.bar + 40,
                  child: AddCard(
                    open: _adding,
                    ways: addWays(l, camera: _hasCamera, voice: vaultSections().contains(VaultSection.audio)),
                    onPick: _pickAdd,
                  ),
                ),
              // Above the lock (left thumb), on the right, or in the middle above the bar
              // (Settings). An empty vault has the add tiles on screen instead.
              if (!empty) Positioned(
                // Keyed: the column appearing above must not rebuild the button mid-slide
                // (it would drop the finger's gesture). In the middle it floats exactly over
                // the gap the bar leaves for it, so it stays one widget throughout.
                key: const ValueKey('action-slot'),
                left: centreMode ? centreX - centrePlusSize / 2 : actionLeft(context),
                bottom: bottom + actionLift(),
                // Tap: open or close the column. Finger down and slide up: pick on release.
                // Only a tap, or a finger sliding UP from +, opens the ways: a sideways
                // swipe over the button belongs to the page (owner 2026-10-24: swiping the
                // library from the edge kept opening the column).
                child: GestureDetector(
                  onVerticalDragStart: _recordingNow || _directAdd != null
                      ? null
                      : (_) {
                          if (!_adding) {
                            HapticFeedback.mediumImpact();
                            setState(() {
                              _adding = true;
                              _openAdd();
                            });
                          }
                        },
                  onVerticalDragUpdate: _recordingNow ? null : (d) => _hoverAt(d.globalPosition),
                  onVerticalDragEnd: _recordingNow
                      ? null
                      : (_) {
                          final h = _hover;
                          if (h != null) _pickAdd(h);
                        },
                  child: _actionButton(context),
                ),
              ),
            ],
            _revealOverlay(),
          ],
        ),
      ),
      ),
    ));
  }
}

/// A tag in the chip row: its name and how much of this section carries it.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.count, required this.open, required this.onTap, this.onLongPress});
  final rust.ItemInfo tag;
  final int count;
  final bool open;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    // The open group stands out: filled (ink in light mode, a soft grey in dark mode,
    // never a white slab), a check before its name and × to leave it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final fill = dark ? Color.alphaBlend(Colors.white.withValues(alpha: .3), page) : ink;
    final onFill = dark ? Colors.white : page;
    final primary = open ? onFill : Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: open,
      label: '${tag.name}, $count',
      child: Material(
        color: open ? fill : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(13),
        elevation: open ? 0 : .5,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(open ? Icons.check_rounded : Icons.sell_outlined, size: 17, color: open ? primary : c.muted),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(tag.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: open ? primary : null)),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Text('$count', style: TextStyle(color: open ? onFill.withValues(alpha: .75) : c.muted, fontSize: 12.5)),
                ],
                if (open) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.close_rounded, size: 16, color: onFill.withValues(alpha: .85)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tags for the selection: a switch per tag (on, off, or "some" when only part of the
/// selection carries it), and "New group". Returns the switches that changed.
class _TagSheet extends StatefulWidget {
  const _TagSheet({
    required this.tags,
    required this.carried,
    required this.total,
    required this.onNewTag,
  });
  final List<rust.ItemInfo> tags;
  final int Function(String tagId) carried;
  final int total;
  final Future<rust.ItemInfo?> Function() onNewTag;

  @override
  State<_TagSheet> createState() => _TagSheetState();
}

class _TagSheetState extends State<_TagSheet> {
  late final List<rust.ItemInfo> _tags = [...widget.tags];
  final Map<String, bool> _changed = {};

  bool? _state(String tagId) {
    final set = _changed[tagId];
    if (set != null) return set;
    final n = widget.carried(tagId);
    return n == 0 ? false : (n == widget.total ? true : null);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // A page now (its title in the app bar): the list, and Done at the bottom.
    return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                children: [
                  for (final t in _tags)
                    CheckboxListTile(
                      tristate: true,
                      value: _state(t.id),
                      title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      secondary: const Icon(Icons.sell_outlined),
                      // From "some", a tap puts it on all of them.
                      onChanged: (_) => setState(() => _changed[t.id] = _state(t.id) != true),
                    ),
                  ListTile(
                    key: const ValueKey('sheet-new-tag'),
                    leading: const Icon(Icons.add),
                    title: Text(l.newTag),
                    onTap: () async {
                      final t = await widget.onNewTag();
                      if (t == null || !mounted) return;
                      setState(() {
                        _tags.add(t);
                        _changed[t.id] = true;
                      });
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton(
                key: const ValueKey('sheet-done'),
                onPressed: () => Navigator.pop(context, _changed),
                child: Text(l.done),
              ),
            ),
          ],
        );
  }
}

/// While items are selected the dock gives way to what can be done with them.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.onDone,
    required this.onSelectAll,
    required this.allSelected,
    required this.onSend,
    required this.onTag,
    required this.onDelete,
    this.onRename,
    this.enabled = true,
  });
  /// Leaves Select mode; first, on the left, where the back arrow would be.
  final VoidCallback onDone;
  final VoidCallback onSelectAll;
  /// Everything shown is selected: the button reads Deselect all.
  final bool allSelected;
  /// Nothing chosen yet (Select mode just opened): the actions wait, dimmed.
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onTag;
  /// Only with one item selected that has a name of its own.
  final VoidCallback? onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SelectionBar(
      onDone: onDone,
      onSelectAll: onSelectAll,
      allSelected: allSelected,
      enabled: enabled,
      actions: [
        SelectionAction(Icons.ios_share, l.sendOut, onSend),
        SelectionAction(Icons.sell_outlined, l.tagAction, onTag),
        if (onRename case final rename?) SelectionAction(Icons.edit_outlined, l.rename, rename),
        SelectionAction(Icons.delete_outline, l.delete, onDelete, color: recordRed(context), key: const ValueKey('select-delete')),
      ],
    );
  }
}

/// When a note was made, short: the time today, the weekday this week, else the date.
String _shortWhen(BuildContext context, DateTime d) {
  final ml = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return ml.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);
  if (days < 7) return DateFormat.EEEE(Localizations.localeOf(context).toLanguageTag()).format(d);
  return ml.formatShortDate(d);
}

/// A note: title, then the date and the first words on one line.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.item,
    required this.preview,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });
  final rust.ItemInfo item;
  /// null: the text stays hidden (Settings → Display).
  final Future<String>? preview;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final when = _shortWhen(context, dateOf(item.createdMs));
    return SelectableRow(
      selected: selected,
      selecting: selecting,
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name.isEmpty ? l.untitledNote : item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (item.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                    ],
                  ),
                  const SizedBox(height: 3),
                  // One line, as in iPhone Notes: when, then the first words. Every row
                  // the same height, with no gap under a short note.
                  FutureBuilder<String>(
                    future: preview,
                    builder: (context, snap) => Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: when,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .75)),
                        ),
                        if ((snap.data ?? '').isNotEmpty) TextSpan(text: '   ${snap.data}'),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }
}

/// A file: its kind, name, size and date.
class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.item,
    this.thumbnail,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });
  final rust.ItemInfo item;
  /// A photo's or video's preview, when one shows up among files.
  final Future<Uint8List>? thumbnail;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final when = MaterialLocalizations.of(context).formatShortDate(dateOf(item.createdMs));
    final dot = item.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : item.name.substring(dot + 1).toUpperCase();
    return SelectableRow(
      selected: selected,
      selecting: selecting,
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 48,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(8)),
              child: thumbnail != null
                  ? FutureBuilder<Uint8List>(
                      future: thumbnail,
                      builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                          ? PrivateThumb(snap.data!)
                          : const SizedBox.expand(),
                    )
                  : Center(
                child: item.kind == ItemKind.note || ext.isEmpty || ext.length > 4
                    ? Icon(fileIcon(item), color: Theme.of(context).colorScheme.primary)
                    : Text(ext,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15))),
                      if (item.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('${fileSize(item.sizeBytes)} · $when', style: TextStyle(color: c.muted, fontSize: 12.5)),
                ],
              ),
            ),
          ],
        ),
    );
  }
}

/// A file as a tile in the grid view (⇅ → Grid): its type, then its name.
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.item,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });
  final rust.ItemInfo item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final dot = item.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : item.name.substring(dot + 1).toUpperCase();
    return InkWell(
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: .12) : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(10)),
                    alignment: Alignment.center,
                    child: ext.isEmpty || ext.length > 4
                        ? Icon(fileIcon(item), color: primary, size: 30)
                        : Text(ext, style: TextStyle(color: primary, fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.25)),
                const SizedBox(height: 2),
                Text(fileSize(item.sizeBytes), style: TextStyle(color: c.muted, fontSize: 11.5)),
              ],
            ),
            if (item.isFavorite) const Positioned(left: 4, top: 4, child: FavoriteStar(size: 16)),
            if (selecting) Positioned(right: 2, top: 2, child: SelectCircle(selected: selected)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

/// What a mode looks like before it holds anything, and how to add the first one.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: c.muted),
              const SizedBox(height: 14),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A square in the library: no corner radius, 1 px apart, like Photos. Videos show
/// their length; selected ones a tick.
class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.item,
    required this.thumbnail,
    this.ready,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });

  final rust.ItemInfo item;
  final Future<Uint8List> thumbnail;
  /// [thumbnail]'s bytes when already read.
  final Uint8List? ready;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  static String _length(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final duration = item.durationMs;
    return GestureDetector(
      onTap: onTap,
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      child: ColoredBox(
        color: c.soft,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: thumbnail,
              initialData: ready,
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null || bytes.isEmpty) {
                  return item.kind == ItemKind.video
                      ? const ColoredBox(color: Color(0xFF2A3133))
                      : const SizedBox.expand();
                }
                return PrivateThumb(bytes);
              },
            ),
            if (item.kind == ItemKind.video)
              Positioned(
                right: 5,
                bottom: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 15, shadows: [Shadow(blurRadius: 4)]),
                    if (duration != null)
                      Text(
                        _length(duration.toInt()),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4)]),
                      ),
                  ],
                ),
              ),
            if (item.isFavorite) const Positioned(left: 5, bottom: 4, child: FavoriteStar(size: 17, onPhoto: true)),
            if (selecting)
              Positioned(
                right: 5,
                top: 5,
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: Colors.white,
                  size: 22,
                  shadows: const [Shadow(blurRadius: 4)],
                ),
              ),
            if (selected) const ColoredBox(color: Color(0x33FFFFFF)),
          ],
        ),
      ),
    );
  }
}

/// "Encrypting 3 of 12", a bar and Cancel (docs/ui.md, review 12).
class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.total, required this.done, required this.onCancel});
  final int total;
  final ValueNotifier<int> done;
  final VoidCallback onCancel;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
          child: ValueListenableBuilder<int>(
            valueListenable: widget.done,
            builder: (context, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.encryptingCount(done + (done < widget.total ? 1 : 0), widget.total),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: widget.total == 0 ? null : done / widget.total, minHeight: 6,
                    borderRadius: BorderRadius.circular(3)),
                const SizedBox(height: 12),
                Text(l.importNote, style: TextStyle(color: CsColors.of(context).muted, fontSize: 13)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _cancelling
                      ? null
                      : () {
                          setState(() => _cancelling = true);
                          widget.onCancel();
                        },
                  child: Text(l.cancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An empty vault: its badge, a line on what happens to what is added, and the ways to
/// add as big tiles (docs/ui.md, design language).
class _Welcome extends StatelessWidget {
  const _Welcome({required this.vault, required this.bottomPad, required this.tiles});
  final rust.VaultInfo vault;
  final double bottomPad;
  final Widget tiles;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 24, 16, bottomPad - 60),
      children: [
        Center(child: VaultBadge(icon: vault.icon, color: vault.color, size: 84)),
        const SizedBox(height: 18),
        Text(l.emptyVaultTitle, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.3)),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(l.emptyVaultBody, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: c.muted, height: 1.35)),
        ),
        const SizedBox(height: 28),
        tiles,
      ],
    );
  }
}

/// After an import: remove the originals from the phone? (owner 2026-10-21: always ask).
class DeleteOriginalsSheet extends StatelessWidget {
  const DeleteOriginalsSheet({super.key, required this.count, required this.photos});
  final int count;
  final bool photos;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(photos ? Icons.photo_library_outlined : Icons.folder_outlined, size: 36, color: c.muted),
            const SizedBox(height: 10),
            Text(l.originalsTitle, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.2)),
            const SizedBox(height: 8),
            Text(photos ? l.originalsBodyPhotos(count) : l.originalsBodyFiles(count),
                textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.45)),
            const SizedBox(height: 18),
            FilledButton(
              key: const ValueKey('originals-delete'),
              style: FilledButton.styleFrom(backgroundColor: recordRed(context), foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.originalsDelete),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const ValueKey('originals-keep'),
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.originalsKeep),
            ),
          ],
        ),
      ),
    );
  }
}

/// How a section is ordered (the ⇅ menu). Saved per section.
enum ItemSort { newest, oldest, name, size, smallest, edited }
