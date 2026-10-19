import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import 'set_pin.dart';
import 'unlock.dart';

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
  int _cols = 3;
  double _scaleStart = 1;

  static final bool _desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  static const _idle = Duration(minutes: 2);
  bool _canBio = false;
  bool _bioOn = false;
  Timer? _idleTimer;
  DateTime? _awayAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _bioOn = rust.biometricEnabled();
    BiometricUnlock.available().then((k) {
      if (mounted) setState(() => _canBio = k != null);
    });
    LockGuard.onActivity = _touch;
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _touch();
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idle, () {
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
        _openCamera();
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

  Future<void> _openCamera() async {
    final saved = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const CameraScreen(), fullscreenDialog: true),
    );
    if (!_locked && (saved ?? 0) > 0) _reload();
  }

  Future<void> _openNote(rust.ItemInfo? item) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NoteScreen(item: item)));
    if (!_locked && changed == true) _reload();
  }

  Future<void> _import({required bool photos}) async {
    final l = AppLocalizations.of(context);
    LockGuard.allowAway();
    try {
      final files = photos ? await pickPhotos() : await pickFiles();
      if (files.isEmpty || !mounted) return;
      _snack(l.importing);
      final n = await importFiles(files, photos: photos);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _snack(l.imported(n));
        _reload();
      }
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
    final d = DateTime.now();
    final name = 'CozySafe-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.cozysafe';
    LockGuard.allowAway();
    try {
      if (_desktop) {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await rust.exportBackup(dir: widget.libraryDir, path: loc.path);
        if (mounted) _snack(l.backupDone);
        return;
      }
      final tmp = File('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$name');
      await rust.exportBackup(dir: widget.libraryDir, path: tmp.path);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(tmp.path, mimeType: 'application/octet-stream')],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      if (mounted) _snack(l.backupFailed);
    } finally {
      LockGuard.clear();
    }
  }

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

  Future<void> _changePin() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SetPinScreen()));
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
      if (mounted) setState(() => _vault = info);
    } on rust.VaultError catch (e) {
      if (mounted) _snack(vaultErrorText(AppLocalizations.of(context), e));
    }
  }

  /// Creating another vault locks this one first (one open at a time).
  void _newVault() {
    final avoid = (_vault.icon, _vault.color);
    _locked = true;
    _idleTimer?.cancel();
    rust.lock();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => NewVaultScreen(libraryDir: widget.libraryDir, first: false, avoid: avoid)),
      (_) => false,
    );
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ---------- content ----------

  Future<Uint8List> _thumb(String id) => _thumbs[id] ??= rust.itemThumbnail(id: id);

  Future<void> _openItem(rust.ItemInfo item, List<rust.ItemInfo> photos) async {
    if (item.kind == 'note') return _openNote(item);
    final String? deleted;
    if (item.kind == 'photo') {
      deleted = await Navigator.of(context).push<String>(
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (_, _, _) => PhotoViewerScreen(items: photos, initial: photos.indexOf(item)),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ),
      );
    } else {
      LockGuard.allowAway();
      deleted = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FileViewScreen(item: item)));
      LockGuard.clear();
    }
    if (!_locked && deleted != null) {
      _thumbs.remove(deleted);
      _reload();
    }
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

  List<Widget> _sections(BuildContext context, List<rust.ItemInfo> items) {
    final photos = items.where((i) => i.kind == 'photo').toList();
    final groups = <String, List<rust.ItemInfo>>{};
    for (final it in items) {
      groups.putIfAbsent(_dateGroup(context, it.createdMs), () => []).add(it);
    }
    return [
      for (final e in groups.entries) ...[
        SliverToBoxAdapter(child: _SectionTitle(e.key)),
        SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols, mainAxisSpacing: 2, crossAxisSpacing: 2),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final it = e.value.where((x) => x.kind == 'photo').elementAt(i);
              return _PhotoTile(key: ValueKey(it.id), thumb: _thumb(it.id), onTap: () => _openItem(it, photos));
            },
            childCount: e.value.where((x) => x.kind == 'photo').length,
          ),
        ),
        SliverList(
          delegate: SliverChildListDelegate([
            for (final it in e.value.where((x) => x.kind != 'photo')) _ItemRow(item: it, onTap: () => _openItem(it, photos)),
          ]),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final items = _items;

    Widget content;
    if (items == null) {
      content = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      content = const _Empty();
    } else {
      content = GestureDetector(
        // Pinch to fit more or fewer photos in a row, like Photos.
        onScaleStart: (_) => _scaleStart = 1,
        onScaleUpdate: (d) {
          if (d.pointerCount < 2) return;
          if (d.scale < _scaleStart * .8 && _cols < 5) {
            setState(() => _cols = 5);
            _scaleStart = d.scale;
          } else if (d.scale > _scaleStart * 1.25 && _cols > 3) {
            setState(() => _cols = 3);
            _scaleStart = d.scale;
          }
        },
        child: Scrollbar(
          child: CustomScrollView(slivers: [..._sections(context, items), const SliverToBoxAdapter(child: SizedBox(height: 12))]),
        ),
      );
    }

    return Scaffold(
        body: Column(
          children: [
            Expanded(
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 4, 10),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: _changeIdentity,
                            child: VaultBadge(icon: _vault.icon, color: _vault.color, size: 44),
                          ),
                          const Spacer(),
                          PopupMenuButton<void>(
                            tooltip: l.vaultMenu,
                            itemBuilder: (context) => [
                              PopupMenuItem<void>(onTap: _changeIdentity, child: Text(l.changeIdentity)),
                              PopupMenuItem<void>(onTap: _password, child: Text(_vault.hasPassword ? l.changePasswordTitle : l.backupPasswordTitle)),
                              PopupMenuItem<void>(onTap: _changePin, child: Text(l.changePin)),
                              if (_canBio)
                                CheckedPopupMenuItem<void>(checked: _bioOn, onTap: _toggleBiometric, child: Text(l.biometricSetting)),
                              PopupMenuItem<void>(onTap: _backup, child: Text(l.backup)),
                              if (_vault.hasPassword) PopupMenuItem<void>(onTap: _showKit, child: Text(l.showKit)),
                              PopupMenuItem<void>(onTap: _newVault, child: Text(l.newVault)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!_vault.hasPassword)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                        child: Material(
                          color: c.soft,
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                            child: Row(
                              children: [
                                Expanded(child: Text(l.passwordNudge, style: TextStyle(color: c.muted, fontSize: 13.5))),
                                TextButton(onPressed: _password, child: Text(l.passwordNudgeAction)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Expanded(child: content),
                  ],
                ),
              ),
            ),
            AddDock(
              modes: availableAddModes(),
              leading: DockSlot(glyph: const LockGlyph(size: 24, color: Colors.white), label: l.lockVault, onTap: _lock),
              // Search comes back here once it exists.
              trailing: const SizedBox(width: 46),
              onAction: _onAction,
            ),
          ],
        ),
    );
  }
}

/// A note or file in the list: icon, name, kind and date.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onTap});
  final rust.ItemInfo item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final l = AppLocalizations.of(context);
    final when = DateTime.fromMillisecondsSinceEpoch(item.createdMs);
    final ml = MaterialLocalizations.of(context);
    final sub = item.kind == 'note'
        ? '${l.note} · ${ml.formatShortDate(when)}'
        : '${fileSize(item.size)} · ${ml.formatShortDate(when)}';
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(10)),
        child: Icon(fileIcon(item), color: Theme.of(context).colorScheme.primary),
      ),
      title: Text(item.name.isEmpty ? l.untitledNote : item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
        child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined, size: 48, color: c.muted),
              const SizedBox(height: 16),
              Text(l.emptyVaultTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(l.emptyVaultBody, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo square: no corner radius and a 2 px gap, like Photos.
class _PhotoTile extends StatelessWidget {
  const _PhotoTile({super.key, required this.thumb, this.onTap});

  final Future<Uint8List> thumb;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: c.soft,
        child: FutureBuilder<Uint8List>(
          future: thumb,
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null || bytes.isEmpty) return const SizedBox.expand();
            return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, width: double.infinity, height: double.infinity);
          },
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

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deletePhoto),
        content: Text(l.deletePhotoBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await rust.deleteItem(id: _item.id);
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
