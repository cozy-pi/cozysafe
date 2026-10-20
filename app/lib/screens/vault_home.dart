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
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../prefs.dart';
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import '../widgets/vault_bar.dart';
import 'backup_password.dart';
import 'camera.dart';
import 'common.dart';
import 'emergency_kit.dart';
import 'file_view.dart';
import 'new_vault.dart';
import 'note.dart';
import 'recorder.dart';
import 'search.dart';
import 'settings.dart';
import 'trash.dart';
import 'unlock.dart';
import 'video_view.dart';
import '../capture_name.dart';
import '../item_kind.dart';
import '../widgets/toast.dart';

/// Inside an open vault (docs/ui.md, vault bar): a large title, the tags as a row of
/// chips, the content edge to edge, and floating glass at the bottom: the lock, the four
/// sections, and the main action above the lock. Locks on leaving the
/// app, after 2 minutes without a touch, or with the lock button.
class VaultHomeScreen extends StatefulWidget {
  /// For the mockup renders: the vault's icon shows after opening (off for still shots).
  static bool debugReveal = true;

  const VaultHomeScreen({super.key, required this.libraryDir, required this.vault});

  final String libraryDir;
  final rust.VaultInfo vault;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late rust.VaultInfo _vault = widget.vault;
  bool _locked = false;
  List<rust.ItemInfo>? _items;
  /// Decrypted previews, in memory only, dropped with this screen.
  final Map<String, Future<Uint8List>> _thumbnails = {};
  /// Photos per row; pinch to change, like Photos.
  int _cols = 4;
  static const _colSteps = [3, 4, 5, 7];
  double _scaleStart = 1;
  /// What the vault shows, picked in the bottom capsule.
  late VaultSection _section = startSection();
  final _actionKey = GlobalKey();
  final _recorder = GlobalKey<RecorderViewState>();
  bool _recordingNow = false;
  static const _tintApp = false;

  /// The tag open on top of the sections ("Hộ chiếu"): every section then shows only
  /// what carries it. None: everything.
  String? _tagId;
  /// Long-press selection: ids picked for Delete / Send.
  final Set<String> _selected = {};
  /// Note previews (second line on), decrypted on demand, in memory only.
  final Map<String, Future<String>> _previews = {};

  static final bool _desktop = Device.macOS || Device.windows || Device.linux;
  bool _canBio = false;
  bool _bioOn = false;
  Timer? _idleTimer;
  DateTime? _awayAt;

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
    // Design B (the whole app in the vault's colour) is off since 2026-10-20: it often
    // looked wrong. The palette code stays in theme.dart; turn it back on here.
    if (_tintApp) WidgetsBinding.instance.addPostFrameCallback((_) => vaultTint.value = _color);
    // Touches anywhere count, also on the note editor or viewer pushed above this screen.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _touch();
    if (VaultHomeScreen.debugReveal) _reveal.forward();
  }

  /// Which vault just opened: on the plain page, its icon comes in as the unlock effect
  /// ends, holds, fades; only then does the content show (docs/ui.md). Vaults have no name.
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));

  @override
  void dispose() {
    _reveal.dispose();
    _idleTimer?.cancel();
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
      if (mounted && !LockGuard.away) _lock();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      if (LockGuard.away) {
        _awayAt ??= DateTime.now();
      } else {
        _lock(animate: false);
      }
    } else if (state == AppLifecycleState.resumed && _awayAt != null) {
      final gone = DateTime.now().difference(_awayAt!);
      _awayAt = null;
      LockGuard.clear();
      if (gone > const Duration(seconds: 60)) _lock(animate: false);
      _touch();
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
    final nav = Navigator.of(context);
    void go() async {
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
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false),
        ),
        (_) => false,
      );
    }

    if (animate) {
      playVaultSpin(context, opening: false, onCovered: go);
    } else {
      go();
    }
  }

  // ---------- adding ----------

  static bool get _hasCamera => Device.iOS || Device.android || debugCamera;

  /// The button above the lock: compose, record, or a short menu of ways to add.
  Future<void> _mainAction() async {
    switch (_section) {
      case VaultSection.note:
        return _openNote(null);
      case VaultSection.audio:
        return _recorder.currentState?.toggle();
      case VaultSection.file:
        return _import(photos: false);
      case VaultSection.library:
        if (!_hasCamera) return _import(photos: true);
        final l = AppLocalizations.of(context);
        final box = _actionKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return;
        final at = box.localToGlobal(Offset.zero);
        final size = MediaQuery.sizeOf(context);
        PopupMenuItem<int> item(int v, IconData icon, String text) => PopupMenuItem(
              value: v,
              height: 48,
              child: Row(children: [
                Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Text(text, style: const TextStyle(fontSize: 15)),
              ]),
            );
        final v = await showMenu<int>(
          context: context,
          position: RelativeRect.fromLTRB(at.dx, at.dy - 172, size.width - at.dx - 240, size.height - at.dy + 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          items: [
            item(0, Icons.add_photo_alternate_outlined, l.addFromDevice),
            item(1, Icons.photo_camera_outlined, l.takePhoto),
            item(2, Icons.videocam_outlined, l.recordVideo),
          ],
        );
        if (v == 0) _import(photos: true);
        if (v == 1) _openCamera(video: false);
        if (v == 2) _openCamera(video: true);
    }
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
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => NoteScreen(item: item, tagId: item == null ? _tagId : null)));
    if (!_locked && changed == true) {
      _previews.clear();
      _reload();
    }
  }

  Future<void> _import({required bool photos}) async {
    final l = AppLocalizations.of(context);
    LockGuard.allowAway();
    try {
      final files = photos ? await pickPhotos() : await pickFiles();
      if (files.isEmpty || !mounted) return;
      final done = ValueNotifier<int>(0);
      var cancel = false;
      final nav = Navigator.of(context);
      final sheet = showModalBottomSheet<void>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (context) => _ImportSheet(total: files.length, done: done, onCancel: () => cancel = true),
      );
      final List<rust.ItemInfo> added;
      try {
        added = await importFiles(files, photos: photos, progress: (d, _) {
          done.value = d;
          LockGuard.activity(); // a long import is not idleness
        }, cancelled: () => cancel, mediaName: (kind, ext) => captureName(l, kind, DateTime.now(), ext));
      } finally {
        if (mounted) nav.pop();
        await sheet;
        done.dispose();
      }
      // Added while a tag is open: they carry it.
      final tagId = _tagId;
      if (tagId != null && added.isNotEmpty) {
        await rust.setTag(itemIds: [for (final a in added) a.id], tagId: tagId, tagged: true);
      }
      // No "N added" message: the items appear at once, and the bar showed progress.
      if (mounted) _reload();
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
    } catch (_) {
      if (mounted) _snack(l.errorStorage);
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
      MaterialPageRoute(builder: (_) => BackupPasswordScreen(libraryDir: widget.libraryDir, change: false)),
    );
    if (info != null && mounted) setState(() => _vault = info);
    return info != null;
  }

  // Security settings (password, backup, Emergency Kit, biometrics) ask for the owner
  // first, wherever they are opened from (docs/security.md, security settings).
  Future<void> _password() async {
    if (!await confirmOwnerForSetting(AppLocalizations.of(context).ownerCheckSettings) || !mounted) return;
    final info = await Navigator.of(context).push<rust.VaultInfo>(
      MaterialPageRoute(builder: (_) => BackupPasswordScreen(libraryDir: widget.libraryDir, change: _vault.hasPassword)),
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
    final key = await SecretKeyStore.read();
    if (key == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EmergencyKitScreen(keyText: rust.secretKeyText(key: key), confirm: false),
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
    final i = await showAllIcons(context, icon < 0 ? 0 : icon);
    if (i == null || !mounted) return;
    icon = i;
    final c = await showAllColors(context, color < 0 ? 0 : color);
    if (c == null || !mounted) return;
    color = c;
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
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const TrashScreen()));
    if (!_locked && changed == true) _reload();
  }

  Future<void> _openSettings() async {
    final l = AppLocalizations.of(context);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
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
      ),
    ));
    if (!_locked) {
      _touch(); // the auto-lock time may have changed
      setState(() {}); // and the side of the main action
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
    // Under it, the lock screen: Cancel on the new vault goes back there.
    final nav = Navigator.of(context);
    nav.pushAndRemoveUntil(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false),
      ),
      (_) => false,
    );
    nav.push(MaterialPageRoute<void>(
      builder: (_) => NewVaultScreen(libraryDir: widget.libraryDir, first: false, avoid: avoid),
    ));
  }

  void _snack(String text) => showToast(context, text, besideAction: _selected.isEmpty);

  // ---------- content ----------

  Future<Uint8List> _thumbnail(String id) => _thumbnails[id] ??= rust.itemThumbnail(id: id);

  /// The note's text after its first line (the title), for the list's two-line preview.
  Future<String> _preview(String id) => _previews[id] ??= rust.itemContent(id: id).then((bytes) {
        final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
        final nl = text.indexOf('\n');
        return (nl < 0 ? '' : text.substring(nl + 1)).trim().replaceAll(RegExp(r'\s+'), ' ');
      });

  bool _isMedia(rust.ItemInfo i) => i.kind == ItemKind.photo || i.kind == ItemKind.video;

  Future<void> _openItem(rust.ItemInfo item, List<rust.ItemInfo> media) async {
    if (_selected.isNotEmpty) return _toggle(item.id);
    if (item.kind == ItemKind.tag) return setState(() => _tagId = item.id);
    if (item.kind == ItemKind.note) return _openNote(item);
    if (item.kind == ItemKind.audio) return _audioActions(item);
    final String? deleted;
    if (item.kind == ItemKind.photo) {
      final photos = media.where((m) => m.kind == ItemKind.photo).toList();
      deleted = await Navigator.of(context).push<String>(
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, _, _) => PhotoViewerScreen(items: photos, initial: photos.indexOf(item)),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      );
    } else if (item.kind == ItemKind.video && VideoViewScreen.supported) {
      deleted = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => VideoViewScreen(item: item, vaultId: _vault.id)),
      );
    } else {
      LockGuard.allowAway();
      deleted = await Navigator.of(context)
          .push<String>(MaterialPageRoute(builder: (_) => FileViewScreen(item: item, vaultId: _vault.id)));
      LockGuard.clear();
    }
    if (!_locked && deleted != null) {
      _reload();
      _trashed([deleted]);
    }
  }

  /// A recording: rename it, send it, or delete it (play is right in the list).
  Future<void> _audioActions(rust.ItemInfo item) async {
    final l = AppLocalizations.of(context);
    final pick = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.edit_outlined), title: Text(l.rename), onTap: () => Navigator.pop(context, 0)),
            ListTile(leading: const Icon(Icons.ios_share), title: Text(l.sendOut), onTap: () => Navigator.pop(context, 1)),
            ListTile(leading: const Icon(Icons.delete_outline), title: Text(l.delete), onTap: () => Navigator.pop(context, 2)),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick == 0) {
      final text = TextEditingController(text: item.name.replaceAll(RegExp(r'\.m4a$'), ''));
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.rename),
          content: TextField(controller: text, autofocus: true, textCapitalization: TextCapitalization.sentences),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: Text(l.save)),
          ],
        ),
      );
      text.dispose();
      if (name != null && name.isNotEmpty) {
        await rust.renameItem(id: item.id, name: '$name.m4a');
        _reload();
      }
    } else if (pick == 1) {
      setState(() => _selected
        ..clear()
        ..add(item.id));
      await _sendSelected();
      if (mounted) setState(_selected.clear);
    } else {
      await rust.trashItem(id: item.id, nowMs: nowMs());
      _reload();
      _trashed([item.id]);
    }
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
    final now = nowMs();
    for (final id in ids) {
      try {
        await rust.trashItem(id: id, nowMs: now);
      } catch (_) {}
    }
    setState(_selected.clear);
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
      if (mounted) setState(_selected.clear);
    } catch (_) {
      if (mounted) _snack(l.errorStorage);
    } finally {
      LockGuard.clear();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  // ---------- search ----------

  Future<void> _openSearch() async {
    final items = _items;
    if (items == null) return;
    final picked = await Navigator.of(context).push<rust.ItemInfo>(
      MaterialPageRoute(
          builder: (_) => SearchScreen(items: items.where((i) => i.kind != ItemKind.tag).toList(), thumbnail: _thumbnail)),
    );
    if (picked != null && mounted && !_locked) _openItem(picked, items.where(_isMedia).toList());
  }

  String _dateGroup(BuildContext context, int ms) {
    final l = AppLocalizations.of(context);
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff <= 0) return l.today;
    if (diff == 1) return l.yesterday;
    if (diff < 7) return l.thisWeek;
    return MaterialLocalizations.of(context).formatMonthYear(d);
  }

  /// Room under the content for the floating bar and the button above the lock, so
  /// neither ever hides the last row.
  double get _bottomRoom => MediaQuery.paddingOf(context).bottom + 150;

  /// Library: photos and videos, by date, small squares like Photos.
  Widget _library(BuildContext context, List<rust.ItemInfo> media) {
    final l = AppLocalizations.of(context);
    if (media.isEmpty) {
      return _tagId != null
          ? _TagEmpty(text: l.tagEmpty)
          : _Empty(icon: Icons.photo_library_outlined, title: l.emptyPhotosTitle, body: l.emptyPhotosBody);
    }
    final groups = <String, List<rust.ItemInfo>>{};
    for (final it in media) {
      groups.putIfAbsent(_dateGroup(context, it.createdMs.toInt()), () => []).add(it);
    }
    return GestureDetector(
      // Pinch to fit more or fewer per row: 3, 4, 5 or 7.
      onScaleStart: (_) => _scaleStart = 1,
      onScaleUpdate: (d) {
        if (d.pointerCount < 2) return;
        final at = _colSteps.indexOf(_cols);
        if (d.scale < _scaleStart * .8 && at < _colSteps.length - 1) {
          setState(() => _cols = _colSteps[at + 1]);
          _scaleStart = d.scale;
        } else if (d.scale > _scaleStart * 1.25 && at > 0) {
          setState(() => _cols = _colSteps[at - 1]);
          _scaleStart = d.scale;
        }
      },
      child: Scrollbar(
        child: CustomScrollView(slivers: [
          for (final e in groups.entries) ...[
            SliverToBoxAdapter(child: _SectionTitle(e.key)),
            SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _cols,
                mainAxisSpacing: 1.5,
                crossAxisSpacing: 1.5,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final it = e.value[i];
                  return _MediaTile(
                    key: ValueKey(it.id),
                    item: it,
                    thumbnail: _thumbnail(it.id),
                    selected: _selected.contains(it.id),
                    selecting: _selected.isNotEmpty,
                    onTap: () => _openItem(it, media),
                    onLongPress: () => _toggle(it.id),
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

  /// Notes or files: one neutral card of rows.
  Widget _list(BuildContext context, List<rust.ItemInfo> list, {required bool notes}) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    if (list.isEmpty) {
      if (_tagId != null) return _TagEmpty(text: l.tagEmpty);
      return notes
          ? _Empty(icon: Icons.sticky_note_2_outlined, title: l.emptyNotesTitle, body: l.emptyNotesBody)
          : _Empty(icon: Icons.description_outlined, title: l.emptyFilesTitle, body: l.emptyFilesBody);
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
                  notes
                      ? _NoteRow(
                          item: it,
                          preview: _preview(it.id),
                          selected: _selected.contains(it.id),
                          onTap: () => _openItem(it, const []),
                          onLongPress: () => _toggle(it.id),
                        )
                      : _FileRow(
                          item: it,
                          thumbnail: _isMedia(it) ? _thumbnail(it.id) : null,
                          selected: _selected.contains(it.id),
                          onTap: () => _openItem(it, list.where(_isMedia).toList()),
                          onLongPress: () => _toggle(it.id),
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
        VaultSection.note => i.kind == ItemKind.note,
        VaultSection.library => i.kind == ItemKind.photo || i.kind == ItemKind.video,
        VaultSection.audio => i.kind == ItemKind.audio,
        VaultSection.file => i.kind == ItemKind.file,
      };

  /// What the section on show holds, narrowed to the open tag.
  List<rust.ItemInfo> _shown(List<rust.ItemInfo> items) => items
      .where((i) => _inSection(_section, i) && (_tagId == null || i.tagIds.contains(_tagId)))
      .toList();

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deleteTagTitle(tag.name)),
        content: Text(l.deleteTagBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true) return;
    await rust.deleteTag(tagId: tag.id);
    setState(() => _tagId = null);
    _reload();
  }

  /// Every tag in a sheet: open one, or make a new one.
  Future<void> _allTags() async {
    final l = AppLocalizations.of(context);
    final items = _items ?? const <rust.ItemInfo>[];
    final tags = _tags.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    const create = '+';
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(l.allTags, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              for (final t in tags)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text('${items.where((i) => i.tagIds.contains(t.id)).length}'),
                  onTap: () => Navigator.pop(context, t.id),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(l.newTag),
                onTap: () => Navigator.pop(context, create),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == create) {
      final t = await _newTag();
      if (t != null) setState(() => _tagId = t.id);
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
    final result = await showModalBottomSheet<Map<String, bool>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _TagSheet(
        title: l.tagSelected(count),
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
      setState(_selected.clear);
      await _reload();
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
    }
  }

  Widget _content(BuildContext context) {
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    final shown = _shown(items);
    return switch (_section) {
      VaultSection.note => _list(context, shown, notes: true),
      VaultSection.file => _list(context, shown, notes: false),
      VaultSection.audio => RecorderView(
          key: _recorder,
          items: shown,
          tagId: _tagId,
          bottomPad: _bottomRoom,
          onSaved: _reload,
          onRecordingChanged: (v) => setState(() => _recordingNow = v),
          onOpen: (it) => _openItem(it, const []),
        ),
      VaultSection.library => _library(context, shown),
    };
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
            GlassButton(icon: Icons.arrow_back_ios_new, tooltip: l.back, size: 38, onTap: () => setState(() => _tagId = null)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              open?.name ?? sectionLabel(l, _section),
              key: const ValueKey('vault-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -.5),
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
              child: const IgnorePointer(child: GlassButton(icon: Icons.more_horiz, tooltip: '', size: 38, onTap: null)),
            ),
            const SizedBox(width: 8),
          ],
          GlassButton(icon: Icons.search, tooltip: l.search, size: 38, onTap: _openSearch),
          const SizedBox(width: 8),
          GlassButton(
            key: const ValueKey('settings-button'),
            icon: Icons.settings_outlined,
            tooltip: l.settings,
            size: 38,
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  /// A button for every group, then the tags with something in this section as chips
  /// (the open one first and marked), then "New group".
  Widget _tagChips(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = _items ?? const <rust.ItemInfo>[];
    int count(String tagId) => items.where((i) => _inSection(_section, i) && i.tagIds.contains(tagId)).length;
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
      height: 48,
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
                    child: SizedBox(width: 40, child: Icon(Icons.sell_outlined, size: 18, color: primary)),
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
            if (!VaultHomeScreen.debugReveal || _reveal.isCompleted) return const SizedBox.shrink();
            final t = _reveal.value;
            double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
            // The vault's content stays hidden under the page colour until the icon has come
            // and gone: icon in, hold, icon out, then the content shows (docs/ui.md).
            final icon = t < .4 ? Curves.easeOut.transform(seg(.22, .32)) : 1 - Curves.easeIn.transform(seg(.58, .74));
            final cover = 1 - Curves.easeOut.transform(seg(.76, 1));
            final scale = .9 + .1 * Curves.easeOut.transform(seg(.22, .38));
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
                        child: VaultBadge(icon: _vault.icon, color: _vault.color, size: 112, ring: true),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _actionButton(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (icon, tip) = switch (_section) {
      VaultSection.note => (Icons.edit_square, l.newNote),
      VaultSection.library => (Icons.add, l.addToLibrary),
      VaultSection.audio => (_recordingNow ? Icons.stop_rounded : Icons.mic, _recordingNow ? l.stopRecording : l.startRecording),
      VaultSection.file => (Icons.add, l.addFiles),
    };
    return ActionButton(
        key: _actionKey, icon: icon, tooltip: tip, onTap: _mainAction,
        color: _section == VaultSection.audio ? recordRed(context) : null);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final selecting = _selected.isNotEmpty;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final page = Theme.of(context).scaffoldBackgroundColor;

    final header = selecting
        ? Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
            child: Row(
              children: [
                Text(l.selectedCount(_selected.length), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(onPressed: () => setState(_selected.clear), child: Text(l.cancel)),
              ],
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
    return PopScope(
      canPop: !selecting && !inTag && !_recordingNow,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          setState(_selected.clear);
        } else if (inTag) {
          setState(() => _tagId = null);
        }
      },
      child: Scaffold(
        // While selecting, the bar gives way to what can be done with the selection
        // (a real bottom bar, so messages float above it).
        bottomNavigationBar: selecting
            ? _SelectionBar(onSend: _sendSelected, onTag: _tagSelected, onDelete: _deleteSelected)
            : null,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  if (!_recordingNow) _tagChips(context),
                  ?banner,
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      // A short fade when the section or the open group changes.
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: KeyedSubtree(key: ValueKey('${_section.name}/$_tagId'), child: _content(context)),
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
              Positioned(
                left: 10,
                right: 10,
                bottom: bottom + 10,
                child: VaultBar(
                  section: _section,
                  onSection: (k) {
                    if (_recordingNow) return;
                    setState(() {
                      _section = k;
                      _selected.clear();
                    });
                  },
                  lock: GlassButton(
                    key: const ValueKey('lock-button'),
                    tooltip: l.lockVault,
                    size: 50,
                    icon: null,
                    onTap: _lock,
                    child: LockGlyph(size: 22, color: Theme.of(context).colorScheme.onSurface),
                  ),
                ),
              ),
              // Above the lock (left thumb), or on the right if chosen in Settings.
              Positioned(
                left: actionOnRight() ? null : 7,
                right: actionOnRight() ? 7 : null,
                bottom: bottom + 10 + 50 + 14,
                child: _actionButton(context),
              ),
            ],
            _revealOverlay(),
          ],
        ),
      ),
    );
  }
}

/// A tag in the chip row: its name and how much of this section carries it.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.count, required this.open, required this.onTap});
  final rust.ItemInfo tag;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: open,
      label: '${tag.name}, $count',
      child: Material(
        color: open ? primary.withValues(alpha: .14) : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(13),
        elevation: open ? 0 : .5,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sell_outlined, size: 17, color: open ? primary : c.muted),
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
                  Text('$count', style: TextStyle(color: c.muted, fontSize: 12.5)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tag with nothing in this section.
class _TagEmpty extends StatelessWidget {
  const _TagEmpty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 48, left: 24, right: 24),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: CsColors.of(context).muted)),
      );
}

/// Tags for the selection: a switch per tag (on, off, or "some" when only part of the
/// selection carries it), and "New group". Returns the switches that changed.
class _TagSheet extends StatefulWidget {
  const _TagSheet({
    required this.title,
    required this.tags,
    required this.carried,
    required this.total,
    required this.onNewTag,
  });
  final String title;
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
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
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
        ),
      ),
    );
  }
}

/// While items are selected the dock gives way to what can be done with them.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onSend, required this.onTag, required this.onDelete});
  final VoidCallback onSend;
  final VoidCallback onTag;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    // The bar is ink; its icons and words are the page colour.
    final page = Theme.of(context).scaffoldBackgroundColor;
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: page),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(color: page, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
    return Material(
      color: CsColors.of(context).dock,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 10 + bottom),
        child: Row(
          children: [
            action(Icons.ios_share, l.sendOut, onSend),
            action(Icons.sell_outlined, l.tagAction, onTag),
            action(Icons.delete_outline, l.delete, onDelete),
          ],
        ),
      ),
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
    required this.onTap,
    required this.onLongPress,
  });
  final rust.ItemInfo item;
  final Future<String> preview;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final when = _shortWhen(context, dateOf(item.createdMs));
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: .12) : null,
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name.isEmpty ? l.untitledNote : item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
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
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}

/// A file: its kind, name, size and date.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.item, this.thumbnail, required this.selected, required this.onTap, required this.onLongPress});
  final rust.ItemInfo item;
  /// A photo's or video's preview, when one shows up among files.
  final Future<Uint8List>? thumbnail;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final when = MaterialLocalizations.of(context).formatShortDate(dateOf(item.createdMs));
    final dot = item.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : item.name.substring(dot + 1).toUpperCase();
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: .12) : null,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
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
                          ? Image.memory(snap.data!, fit: BoxFit.cover)
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
                  Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 2),
                  Text('${fileSize(item.sizeBytes)} · $when', style: TextStyle(color: c.muted, fontSize: 12.5)),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
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
    super.key,
    required this.item,
    required this.thumbnail,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final rust.ItemInfo item;
  final Future<Uint8List> thumbnail;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

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
      onLongPress: onLongPress,
      child: ColoredBox(
        color: c.soft,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: thumbnail,
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null || bytes.isEmpty) {
                  return item.kind == ItemKind.video
                      ? const ColoredBox(color: Color(0xFF2A3133))
                      : const SizedBox.expand();
                }
                return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
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

/// Photos full screen, decrypted into memory only while shown. Swipe sideways for the
/// next one, swipe down to close, tap to hide the bars. Pops with the id of a deleted photo.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.items, required this.initial});

  final List<rust.ItemInfo> items;
  final int initial;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  final Map<String, Future<Uint8List>> _content = {};
  bool _bars = true;
  double _drag = 0;

  rust.ItemInfo get _item => widget.items[_index];

  Future<Uint8List> _load(String id) => _content[id] ??= rust.itemContent(id: id);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// No question: it goes to Recently deleted and the vault offers Undo.
  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    try {
      await rust.trashItem(id: _item.id, nowMs: nowMs());
      if (mounted) Navigator.of(context).pop(_item.id);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final when = dateOf(_item.createdMs);
    final ml = MaterialLocalizations.of(context);
    final fade = (1 - (_drag.abs() / 400)).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: fade),
      body: Stack(
        children: [
          GestureDetector(
            onTap: () => setState(() => _bars = !_bars),
            onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
            onVerticalDragEnd: (d) {
              if (_drag > 120 || d.velocity.pixelsPerSecond.dy > 900) {
                Navigator.of(context).pop();
              } else {
                setState(() => _drag = 0);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _drag),
              child: Transform.scale(
                scale: (1 - _drag.abs() / 1500).clamp(.7, 1.0),
                child: PageView.builder(
                  controller: _pages,
                  itemCount: widget.items.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => FutureBuilder<Uint8List>(
                    future: _load(widget.items[i].id),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(child: Text(l.errorStorage, style: const TextStyle(color: Colors.white70)));
                      }
                      final bytes = snap.data;
                      if (bytes == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
                      return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes, gaplessPlayback: true)));
                    },
                  ),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _bars && _drag == 0 ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !_bars,
              child: Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
                          tooltip: l.close,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ml.formatMediumDate(when), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                              Text(ml.formatTimeOfDay(TimeOfDay.fromDateTime(when)), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: _delete,
                            style: TextButton.styleFrom(foregroundColor: Colors.white),
                            icon: const Icon(Icons.delete_outline),
                            label: Text(l.delete),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
