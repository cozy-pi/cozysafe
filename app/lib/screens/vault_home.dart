import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import 'backup_password.dart';
import 'camera.dart';
import 'common.dart';
import 'emergency_kit.dart';
import 'file_view.dart';
import 'new_vault.dart';
import 'note.dart';
import 'search.dart';
import 'settings.dart';
import 'trash.dart';
import 'unlock.dart';
import 'video_view.dart';

/// Inside an open vault: photos edge to edge, notes and files as a list, by date; the
/// same add dock as the lock screen. Locks on leaving the app, after 2 minutes without a
/// touch, or with the Lock button.
class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key, required this.libraryDir, required this.vault, this.initialAction});

  final String libraryDir;
  final rust.VaultInfo vault;
  /// An add action picked on the lock screen, run once the vault is open.
  final AddMode? initialAction;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> with WidgetsBindingObserver {
  late rust.VaultInfo _vault = widget.vault;
  bool _locked = false;
  List<rust.ItemInfo>? _items;
  /// Decrypted previews, in memory only, dropped with this screen.
  final Map<String, Future<Uint8List>> _thumbs = {};
  /// Photos per row; pinch to change, like Photos.
  int _cols = 4;
  static const _colSteps = [3, 4, 5, 7];
  double _scaleStart = 1;
  /// The dock's mode is also what the vault shows (docs/ui.md, vault content).
  late AddMode _mode = AddDock.startMode(availableAddModes());
  final _camera = GlobalKey<CameraViewState>();
  static const _tintApp = false;

  /// The folder open in Files mode; null at the top level.
  String? _folder;
  /// Long-press selection: ids picked for Delete / Send.
  final Set<String> _selected = {};
  /// Note previews (second line on), decrypted on demand, in memory only.
  final Map<String, Future<String>> _previews = {};

  static final bool _desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool _canBio = false;
  bool _bioOn = false;
  Timer? _idleTimer;
  DateTime? _awayAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // What has been in Recently deleted for 30 days goes for good, then list.
    rust.purgeExpired(nowMs: DateTime.now().millisecondsSinceEpoch).catchError((_) => 0).whenComplete(_reload);
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
    final first = widget.initialAction;
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onAction(first));
  }

  @override
  void dispose() {
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
      final save = LockGuard.beforeLock;
      if (save != null) {
        try {
          await save();
        } catch (_) {} // locking must not wait on a failed write
      }
      rust.lock();
      LockGuard.clearCopied();
      clearPlaybackCopies();
      _thumbs.clear();
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false),
        ),
        (_) => false,
      );
    }

    if (animate) {
      playVaultSpin(context, opening: false, onCovered: go, color: _color);
    } else {
      go();
    }
  }

  // ---------- adding ----------

  void _onAction(AddMode mode) {
    switch (mode) {
      case AddMode.camera:
        _camera.currentState?.shoot();
      case AddMode.note:
        _openNote(null);
      case AddMode.library:
        _import(photos: true);
      case AddMode.file:
        _import(photos: false);
      case _:
        break; // not offered: availableAddModes() lists only what works
    }
  }

  Future<void> _openNote(rust.ItemInfo? item) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NoteScreen(item: item)));
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
        }, cancelled: () => cancel);
      } finally {
        if (mounted) nav.pop();
        await sheet;
        done.dispose();
      }
      // Picked inside a folder: they go into that folder.
      final into = _mode == AddMode.file ? _folder : null;
      if (into != null && added.isNotEmpty) {
        await rust.moveItems(ids: [for (final a in added) a.id], folder: into);
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

  Future<void> _password() async {
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
    final key = await SecretKeyStore.read();
    if (key == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EmergencyKitScreen(keyText: rust.secretKeyText(key: key), confirm: false),
    ));
  }

  Future<void> _toggleBiometric() async {
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
    if (!_locked) _touch(); // the auto-lock time may have changed
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

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ---------- content ----------

  Future<Uint8List> _thumb(String id) => _thumbs[id] ??= rust.itemThumbnail(id: id);

  /// The note's text after its first line (the title), for the list's two-line preview.
  Future<String> _preview(String id) => _previews[id] ??= rust.itemContent(id: id).then((bytes) {
        final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
        final nl = text.indexOf('\n');
        return (nl < 0 ? '' : text.substring(nl + 1)).trim().replaceAll(RegExp(r'\s+'), ' ');
      });

  bool _isMedia(rust.ItemInfo i) => i.kind == 'photo' || i.kind == 'video';

  Future<void> _openItem(rust.ItemInfo item, List<rust.ItemInfo> media) async {
    if (_selected.isNotEmpty) return _toggle(item.id);
    if (item.kind == 'folder') {
      return setState(() {
        _mode = AddMode.file;
        _folder = item.id;
      });
    }
    if (item.kind == 'note') return _openNote(item);
    final String? deleted;
    if (item.kind == 'photo') {
      final photos = media.where((m) => m.kind == 'photo').toList();
      deleted = await Navigator.of(context).push<String>(
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, _, _) => PhotoViewerScreen(items: photos, initial: photos.indexOf(item)),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      );
    } else if (item.kind == 'video' && VideoViewScreen.supported) {
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

  /// "Moved to Recently deleted · Undo".
  void _trashed(List<String> ids) {
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ids.length == 1 ? l.movedToTrash : l.movedToTrashCount(ids.length)),
        action: SnackBarAction(
          label: l.undo,
          onPressed: () async {
            for (final id in ids) {
              try {
                await rust.restoreItem(id: id);
              } catch (_) {}
            }
            if (!_locked) _reload();
          },
        ),
      ));
  }

  // ---------- selection ----------

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  Future<void> _deleteSelected() async {
    final folders = {for (final i in _items ?? const <rust.ItemInfo>[]) if (i.kind == 'folder') i.id};
    final ids = _selected.where((id) => !folders.contains(id)).toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in _selected.where(folders.contains)) {
      try {
        await rust.deleteFolder(id: id); // what it holds moves up, nothing is deleted
      } catch (_) {}
    }
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
        (_items ?? const <rust.ItemInfo>[]).where((i) => _selected.contains(i.id) && i.kind != 'folder').toList();
    final dir = await Directory((await getTemporaryDirectory()).path).createTemp('send');
    LockGuard.allowAway();
    try {
      final files = <XFile>[];
      for (final (n, it) in items.indexed) {
        var name = it.name.isEmpty ? 'item-$n' : it.name.replaceAll(RegExp(r'[/\\:]'), '-');
        if (it.kind == 'note' && !name.endsWith('.txt')) name = '$name.txt';
        final path = '${dir.path}${Platform.pathSeparator}$name';
        await rust.exportItem(id: it.id, path: path);
        files.add(XFile(path, mimeType: it.kind == 'note' ? 'text/plain' : it.mime));
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
      MaterialPageRoute(builder: (_) => SearchScreen(items: items, thumb: _thumb)),
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

  /// Library: photos and videos only, by date, small squares like Photos.
  Widget _library(BuildContext context, List<rust.ItemInfo> items) {
    final l = AppLocalizations.of(context);
    final media = items.where(_isMedia).toList();
    if (media.isEmpty) {
      return _Empty(icon: Icons.photo_library_outlined, title: l.emptyPhotosTitle, body: l.emptyPhotosBody);
    }
    final groups = <String, List<rust.ItemInfo>>{};
    for (final it in media) {
      groups.putIfAbsent(_dateGroup(context, it.createdMs), () => []).add(it);
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
                mainAxisSpacing: 1,
                crossAxisSpacing: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final it = e.value[i];
                  return _MediaTile(
                    key: ValueKey(it.id),
                    item: it,
                    thumb: _thumb(it.id),
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
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ]),
      ),
    );
  }

  /// Notes or files: one neutral card of equal-height rows (title, two lines, date).
  Widget _list(BuildContext context, List<rust.ItemInfo> items, {required bool notes}) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final list = items.where((i) => notes ? i.kind == 'note' : i.kind == 'file').toList();
    if (list.isEmpty) {
      return notes
          ? _Empty(icon: Icons.sticky_note_2_outlined, title: l.emptyNotesTitle, body: l.emptyNotesBody)
          : _Empty(icon: Icons.description_outlined, title: l.emptyFilesTitle, body: l.emptyFilesBody);
    }
    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
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
                          selected: _selected.contains(it.id),
                          onTap: () => _openItem(it, const []),
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

  // ---------- folders (Files mode) ----------

  /// Folder colours: a short, distinct set of the vault colours.
  static const _folderColors = ['amber', 'blue', 'red', 'violet', 'leaf', 'teal', 'pink', 'grey'];

  Map<String, rust.ItemInfo> get _folders =>
      {for (final i in _items ?? const <rust.ItemInfo>[]) if (i.kind == 'folder') i.id: i};

  /// Where an item really sits: a folder that no longer exists counts as the top level.
  String? _parentOf(rust.ItemInfo i, Map<String, rust.ItemInfo> folders) =>
      i.folder != null && folders.containsKey(i.folder) ? i.folder : null;

  void _upFolder() {
    final f = _folders[_folder];
    setState(() {
      _folder = f == null ? null : _parentOf(f, _folders);
      _selected.clear();
    });
  }

  Future<(String, String)?> _askFolder({String name = '', String color = 'amber', required String title}) {
    final l = AppLocalizations.of(context);
    final text = TextEditingController(text: name);
    var picked = color;
    return showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: text,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(hintText: l.folderName),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in _folderColors)
                    Semantics(
                      button: true,
                      selected: c == picked,
                      label: colorById(c).label,
                      child: GestureDetector(
                        onTap: () => set(() => picked = c),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: colorById(c).color,
                            shape: BoxShape.circle,
                            border: c == picked ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            TextButton(
              onPressed: () {
                final n = text.text.trim();
                if (n.isNotEmpty) Navigator.pop(context, (n, picked));
              },
              child: Text(l.save),
            ),
          ],
        ),
      ),
    ).whenComplete(text.dispose);
  }

  Future<rust.ItemInfo?> _newFolder({String? parent}) async {
    final l = AppLocalizations.of(context);
    final r = await _askFolder(title: l.newFolder);
    if (r == null) return null;
    try {
      final f = await rust.createFolder(
          name: r.$1, color: r.$2, parent: parent, createdMs: DateTime.now().millisecondsSinceEpoch);
      await _reload();
      return f;
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
      return null;
    }
  }

  Future<void> _editFolder(rust.ItemInfo f) async {
    final l = AppLocalizations.of(context);
    final r = await _askFolder(title: l.renameFolder, name: f.name, color: f.color ?? 'amber');
    if (r == null) return;
    await rust.updateFolder(id: f.id, name: r.$1, color: r.$2);
    _reload();
  }

  Future<void> _removeFolder(rust.ItemInfo f) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deleteFolderTitle(f.name)),
        content: Text(l.deleteFolderBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true) return;
    final up = _parentOf(f, _folders);
    await rust.deleteFolder(id: f.id);
    setState(() => _folder = up);
    _reload();
  }

  /// Move the selection: pick a folder (the tree, indented), the top level, or a new one.
  Future<void> _moveSelected() async {
    final l = AppLocalizations.of(context);
    final folders = _folders;
    // Folders being moved, and everything under them, can't be targets.
    bool under(String? id, String root) {
      for (var at = id; at != null; at = folders[at] == null ? null : _parentOf(folders[at]!, folders)) {
        if (at == root) return true;
      }
      return false;
    }

    final moving = _selected.where(folders.containsKey).toList();
    final rows = <(rust.ItemInfo, int)>[];
    void walk(String? parent, int depth) {
      final kids = folders.values.where((f) => _parentOf(f, folders) == parent).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      for (final f in kids) {
        if (moving.any((m) => under(f.id, m))) continue;
        rows.add((f, depth));
        walk(f.id, depth + 1);
      }
    }

    walk(null, 0);
    const top = '';
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
                child: Text(l.moveTo(_selected.length), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(l.topLevel),
                onTap: () => Navigator.pop(context, top),
              ),
              for (final (f, depth) in rows)
                ListTile(
                  contentPadding: EdgeInsets.only(left: 16.0 + depth * 22, right: 16),
                  leading: Icon(Icons.folder, color: colorById(f.color ?? 'amber').color),
                  title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, f.id),
                ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(l.newFolderEllipsis),
                onTap: () => Navigator.pop(context, create),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    String? target = picked == top ? null : picked;
    if (picked == create) {
      final f = await _newFolder(parent: _mode == AddMode.file ? _folder : null);
      if (f == null) return;
      target = f.id;
    }
    try {
      await rust.moveItems(ids: _selected.toList(), folder: target);
      if (!mounted) return;
      final name = target == null ? l.topLevel : (_folders[target]?.name ?? '');
      setState(_selected.clear);
      await _reload();
      _snack(l.movedTo(name));
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(l, e));
    }
  }

  /// Files mode: the folders here (tiles, then "New folder"), then what else is here.
  /// At the top level that is the loose files; inside a folder, everything in it.
  Widget _files(BuildContext context, List<rust.ItemInfo> items) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final folders = _folders;
    final here = _folder != null && folders.containsKey(_folder) ? _folder : null;
    final subfolders = items.where((i) => i.kind == 'folder' && _parentOf(i, folders) == here).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final rest = items
        .where((i) => i.kind != 'folder' && _parentOf(i, folders) == here && (here != null || i.kind == 'file'))
        .toList();
    int count(String id) => items.where((i) => i.folder == id).length;

    // The path, top level first: Files › Papers › Passport.
    final path = <rust.ItemInfo>[];
    for (var at = here; at != null; at = _parentOf(folders[at]!, folders)) {
      path.insert(0, folders[at]!);
    }

    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          if (here != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  IconButton(tooltip: l.back, onPressed: _upFolder, icon: const Icon(Icons.arrow_back)),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${l.modeFile} › ', style: TextStyle(color: c.muted)),
                        for (final (i, f) in path.indexed)
                          TextSpan(
                            text: i == path.length - 1 ? f.name : '${f.name} › ',
                            style: i == path.length - 1
                                ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)
                                : TextStyle(color: c.muted),
                          ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PopupMenuButton<int>(
                    tooltip: l.folderOptions,
                    onSelected: (v) => v == 0 ? _editFolder(folders[here]!) : _removeFolder(folders[here]!),
                    itemBuilder: (context) => [
                      PopupMenuItem(value: 0, child: Text(l.renameFolder)),
                      PopupMenuItem(value: 1, child: Text(l.deleteFolder)),
                    ],
                  ),
                ],
              ),
            ),
          if (subfolders.isNotEmpty || here == null || rest.isEmpty) ...[
            if (here == null) _SectionTitle(l.folders),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.2,
              children: [
                for (final f in subfolders)
                  _FolderTile(
                    folder: f,
                    count: count(f.id),
                    selected: _selected.contains(f.id),
                    onTap: () => _openItem(f, const []),
                    onLongPress: () => _toggle(f.id),
                  ),
                _NewFolderTile(onTap: () => _newFolder(parent: here)),
              ],
            ),
          ],
          if (rest.isNotEmpty) ...[
            if (here == null) _SectionTitle(l.modeFile) else const SizedBox(height: 12),
            Material(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (i, it) in rest.indexed) ...[
                    if (i > 0) Divider(height: 1, indent: 70, color: c.border.withValues(alpha: .6)),
                    _FileRow(
                      item: it,
                      thumb: it.kind == 'photo' || it.kind == 'video' ? _thumb(it.id) : null,
                      selected: _selected.contains(it.id),
                      onTap: () => _openItem(it, rest.where(_isMedia).toList()),
                      onLongPress: () => _toggle(it.id),
                    ),
                  ],
                ],
              ),
            ),
          ] else if (here == null && subfolders.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _Empty(icon: Icons.description_outlined, title: l.emptyFilesTitle, body: l.emptyFilesBody),
            )
          else if (here != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(l.folderEmpty, textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
            ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final items = _items;
    if (_mode == AddMode.camera) {
      return CameraView(
        key: _camera,
        onSaved: (_) => _reload(),
        onOpenLast: (item) => _openItem(item, [item]),
      );
    }
    if (items == null) return const Center(child: CircularProgressIndicator());
    return switch (_mode) {
      AddMode.note => _list(context, items, notes: true),
      AddMode.file => _files(context, items),
      _ => _library(context, items),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final camera = _mode == AddMode.camera;
    final selecting = _selected.isNotEmpty;

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
        : Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 4, 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _changeIdentity,
                  child: VaultBadge(icon: _vault.icon, color: _vault.color, size: 44),
                ),
                const Spacer(),
                // Everything else about the vault lives in Settings, one tap away.
                IconButton(
                  key: const ValueKey('settings-button'),
                  tooltip: l.settings,
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          );

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

    final inFolder = _mode == AddMode.file && _folder != null;
    return PopScope(
      canPop: !selecting && !inFolder,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          setState(_selected.clear);
        } else if (inFolder) {
          _upFolder();
        }
      },
      child: Scaffold(
        // The dock is the Scaffold's bottom bar, so messages (Undo…) float above it
        // instead of covering its buttons.
        bottomNavigationBar: selecting
            ? _SelectionBar(onSend: _sendSelected, onMove: _moveSelected, onDelete: _deleteSelected)
            : AddDock(
                modes: availableAddModes(),
                leading: DockSlot(glyph: const LockGlyph(size: 24, color: Colors.white), label: l.lockVault, onTap: _lock),
                trailing: DockSlot(icon: Icons.search, label: l.search, onTap: _openSearch),
                onAction: _onAction,
                onModeChanged: (m) => setState(() {
                  _mode = m;
                  _selected.clear();
                }),
              ),
        body: camera
                  // The camera takes the whole area above the dock; the header steps
                  // aside so the frame is as large as it can be.
                  ? ColoredBox(color: Colors.black, child: SafeArea(bottom: false, child: _content(context)))
                  : SafeArea(
                      bottom: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          ?banner,
                          Expanded(child: _content(context)),
                        ],
                      ),
                    ),
      ),
    );
  }
}

/// While items are selected the dock gives way to what can be done with them.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onSend, required this.onMove, required this.onDelete});
  final VoidCallback onSend;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(height: 4),
                  Text(label, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
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
            action(Icons.drive_file_move_outline, l.move, onMove),
            action(Icons.delete_outline, l.delete, onDelete),
          ],
        ),
      ),
    );
  }
}

/// A note: title, two lines of what follows, and the date. Every row the same height.
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
    final when = MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(item.createdMs));
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
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 38,
                    child: FutureBuilder<String>(
                      future: preview,
                      builder: (context, snap) => Text(
                        snap.data ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 13.5, height: 1.4),
                      ),
                    ),
                  ),
                  Text(when, style: TextStyle(color: c.muted, fontSize: 12)),
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
  const _FileRow({required this.item, this.thumb, required this.selected, required this.onTap, required this.onLongPress});
  final rust.ItemInfo item;
  /// A photo's or video's preview, inside folders.
  final Future<Uint8List>? thumb;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final when = MaterialLocalizations.of(context).formatShortDate(DateTime.fromMillisecondsSinceEpoch(item.createdMs));
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
              child: thumb != null
                  ? FutureBuilder<Uint8List>(
                      future: thumb,
                      builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                          ? Image.memory(snap.data!, fit: BoxFit.cover)
                          : const SizedBox.expand(),
                    )
                  : Center(
                child: item.kind == 'note' || ext.isEmpty || ext.length > 4
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
                  Text('${fileSize(item.size)} · $when', style: TextStyle(color: c.muted, fontSize: 12.5)),
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
    required this.thumb,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final rust.ItemInfo item;
  final Future<Uint8List> thumb;
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
              future: thumb,
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null || bytes.isEmpty) {
                  return item.kind == 'video'
                      ? const ColoredBox(color: Color(0xFF2A3133))
                      : const SizedBox.expand();
                }
                return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
              },
            ),
            if (item.kind == 'video')
              Positioned(
                right: 5,
                bottom: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 15, shadows: [Shadow(blurRadius: 4)]),
                    if (duration != null)
                      Text(
                        _length(duration),
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
      await rust.trashItem(id: _item.id, nowMs: DateTime.now().millisecondsSinceEpoch);
      if (mounted) Navigator.of(context).pop(_item.id);
    } on rust.VaultError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(vaultErrorText(l, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final when = DateTime.fromMillisecondsSinceEpoch(_item.createdMs);
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

/// A folder in Files mode: its colour, name and how many things are directly in it.
class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final rust.ItemInfo folder;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Material(
      color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: .18) : Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Icon(Icons.folder, size: 34, color: colorById(folder.color ?? 'amber').color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(folder.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(l.itemsCount(count), style: TextStyle(color: c.muted, fontSize: 12)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewFolderTile extends StatelessWidget {
  const _NewFolderTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: DottedBox(
        color: c.muted,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.create_new_folder_outlined, color: c.muted),
              const SizedBox(width: 8),
              Text(l.newFolder, style: TextStyle(color: c.muted, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded box with a dashed outline ("add one here").
class DottedBox extends StatelessWidget {
  const DottedBox({super.key, required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _Dashes(color.withValues(alpha: .6)), child: child);
}

class _Dashes extends CustomPainter {
  _Dashes(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14)).deflate(1);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in (Path()..addRRect(rrect)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}
