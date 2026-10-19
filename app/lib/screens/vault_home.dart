import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/brand.dart';
import 'camera.dart';
import 'common.dart';
import 'emergency_kit.dart';
import 'set_pin.dart';
import 'unlock.dart';

/// Inside an open vault (mockup "Cozy Safe Add Strip", v3): Library by date or
/// Collections by kind, photos edge to edge, documents and notes as a list, and the
/// same add dock as the lock screen. Locks the moment the app leaves the foreground.
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
  bool _locked = false;
  List<rust.ItemInfo>? _items;
  /// Decrypted previews, in memory only, dropped with this screen.
  final Map<String, Future<Uint8List>> _thumbs = {};
  bool _collections = false;
  String? _collection;
  int _cols = 3;
  double _scaleStart = 1;

  static final bool _phone = Platform.isIOS || Platform.isAndroid;
  static final bool _desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool _canBio = false;
  bool _bioOn = false;
  bool _pinOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _bioOn = rust.biometricEnabled();
    _pinOn = rust.pinEnabled();
    BiometricUnlock.available().then((k) {
      if (mounted) setState(() => _canBio = k != null);
    });
    final first = widget.initialAction;
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onAction(first));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _lock(animate: false);
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

  /// Lock from the dock plays the closing moment; leaving the app locks at once.
  void _lock({bool animate = true}) {
    if (_locked) return;
    _locked = true;
    final nav = Navigator.of(context);
    void go() {
      rust.lock();
      _thumbs.clear();
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, __, ___) => UnlockScreen(libraryDir: widget.libraryDir),
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

  void _onAction(AddMode mode) {
    final l = AppLocalizations.of(context);
    switch (mode) {
      case AddMode.camera:
        if (_phone) {
          _openCamera();
        } else {
          _snack(l.cameraPhoneOnly);
        }
      case _:
        _snack(l.comingSoon);
    }
  }

  Future<void> _openCamera() async {
    final saved = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const CameraScreen(), fullscreenDialog: true),
    );
    if (!_locked && (saved ?? 0) > 0) _reload();
  }

  // ---------- menu ----------

  /// One encrypted file with the whole library. Desktop: save where the user picks.
  /// Phone: write it to the app's temp folder and hand it to the share sheet (Files,
  /// Drive, AirDrop…), then remove the temp copy.
  Future<void> _backup() async {
    final l = AppLocalizations.of(context);
    final d = DateTime.now();
    final name = 'CozySafe-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.cozysafe';
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

  Future<void> _togglePin() async {
    if (_pinOn) {
      try {
        await rust.disablePin();
      } catch (_) {}
      await PinStore.clear();
    } else {
      await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const SetPinScreen()));
    }
    if (mounted) setState(() => _pinOn = rust.pinEnabled());
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ---------- content ----------

  Future<Uint8List> _thumb(String id) => _thumbs[id] ??= rust.itemThumbnail(id: id);

  Future<void> _openItem(rust.ItemInfo item, List<rust.ItemInfo> list) async {
    final deleted = await Navigator.of(context).push<String>(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => PhotoViewerScreen(items: list, initial: list.indexOf(item)),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
    if (!_locked && deleted != null) {
      _thumbs.remove(deleted);
      _reload();
    }
  }

  String _dateGroup(BuildContext context, int ms) {
    final l = AppLocalizations.of(context);
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
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
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _cols,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final it = e.value.where((x) => x.kind == 'photo').elementAt(i);
              return _PhotoTile(key: ValueKey(it.id), thumb: _thumb(it.id), onTap: () => _openItem(it, photos));
            },
            childCount: e.value.where((x) => x.kind == 'photo').length,
          ),
        ),
      ],
    ];
  }

  Widget _collectionsView(BuildContext context, List<rust.ItemInfo> items) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final photos = items.where((i) => i.kind == 'photo').toList();
    if (_collection != null) {
      return CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 18, 6),
            child: TextButton.icon(
              onPressed: () => setState(() => _collection = null),
              icon: const Icon(Icons.chevron_left),
              label: Text(_collection!),
            ),
          ),
        ),
        if (_collection == l.collPhotos)
          SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols, mainAxisSpacing: 2, crossAxisSpacing: 2),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _PhotoTile(key: ValueKey(photos[i].id), thumb: _thumb(photos[i].id), onTap: () => _openItem(photos[i], photos)),
              childCount: photos.length,
            ),
          )
        else
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text(l.collectionEmpty, style: TextStyle(color: c.muted))),
          ),
      ]);
    }
    final tiles = [
      (l.collPhotos, Icons.photo_outlined, photos),
      (l.collDocuments, Icons.description_outlined, const <rust.ItemInfo>[]),
      (l.collNotes, Icons.sticky_note_2_outlined, const <rust.ItemInfo>[]),
      (l.collDeleted, Icons.delete_outline, const <rust.ItemInfo>[]),
    ];
    return GridView.count(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      crossAxisCount: 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 12,
      childAspectRatio: .82,
      children: [
        for (final (name, icon, list) in tiles)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _collection = name),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: ColoredBox(
                      color: c.soft,
                      child: list.isEmpty
                          ? Center(child: Icon(icon, color: c.muted, size: 34))
                          : GridView.count(
                              physics: const NeverScrollableScrollPhysics(),
                              crossAxisCount: 2,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                              children: [for (final it in list.take(4)) _PhotoTile(thumb: _thumb(it.id))],
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final items = _items;

    Widget content;
    if (items == null) {
      content = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty && !_collections) {
      content = _Empty(onCamera: _phone ? _openCamera : null);
    } else if (_collections) {
      content = _collectionsView(context, items);
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
                    padding: const EdgeInsets.fromLTRB(18, 8, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.vault.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -.5),
                          ),
                        ),
                        PopupMenuButton<void>(
                          tooltip: l.vaultMenu,
                          itemBuilder: (context) => [
                            CheckedPopupMenuItem<void>(checked: _pinOn, onTap: _togglePin, child: Text(l.pinSetting)),
                            if (_canBio)
                              CheckedPopupMenuItem<void>(checked: _bioOn, onTap: _toggleBiometric, child: Text(l.biometricSetting)),
                            PopupMenuItem<void>(onTap: _backup, child: Text(l.backup)),
                            PopupMenuItem<void>(onTap: _showKit, child: Text(l.showKit)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: false, label: Text(l.tabLibrary)),
                        ButtonSegment(value: true, label: Text(l.tabCollections)),
                      ],
                      selected: {_collections},
                      onSelectionChanged: (s) => setState(() {
                        _collections = s.first;
                        _collection = null;
                      }),
                      style: ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
                      ),
                    ),
                  ),
                  Expanded(child: content),
                ],
              ),
            ),
          ),
          AddDock(
            leading: DockSlot(icon: Icons.lock_outline, label: l.lockVault, onTap: _lock),
            trailing: DockSlot(icon: Icons.search, label: l.search, onTap: () => _snack(l.comingSoon)),
            onAction: _onAction,
          ),
        ],
      ),
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
  const _Empty({this.onCamera});
  final VoidCallback? onCamera;

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
