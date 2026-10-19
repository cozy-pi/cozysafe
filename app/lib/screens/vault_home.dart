import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'camera.dart';
import 'common.dart';
import 'unlock.dart';

/// Inside an open vault. Locks the moment the app leaves the foreground.
class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key, required this.libraryDir, required this.vault});

  final String libraryDir;
  final rust.VaultInfo vault;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> with WidgetsBindingObserver {
  bool _locked = false;
  List<rust.ItemInfo>? _items;
  /// Decrypted previews, in memory only, dropped with this screen.
  final Map<String, Future<Uint8List>> _thumbs = {};

  static final bool _hasCamera = Platform.isIOS || Platform.isAndroid;
  bool _canBio = false;
  bool _bioOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
    _bioOn = rust.biometricEnabled();
    BiometricUnlock.available().then((k) {
      if (mounted) setState(() => _canBio = k != null);
    });
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _lock();
    }
  }

  Future<void> _reload() async {
    try {
      final items = await rust.listItems();
      if (mounted) setState(() => _items = items);
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      if (e == rust.VaultError.locked) return _lock();
      setState(() => _items = const []);
      _snack(vaultErrorText(AppLocalizations.of(context), e));
    }
  }

  void _lock() {
    if (_locked) return;
    _locked = true;
    rust.lock();
    _thumbs.clear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
      (_) => false,
    );
  }

  Future<void> _openCamera() async {
    final saved = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const CameraScreen(), fullscreenDialog: true),
    );
    if (!_locked && (saved ?? 0) > 0) _reload();
  }

  Future<void> _openItem(rust.ItemInfo item) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PhotoViewerScreen(item: item)),
    );
    if (!_locked && deleted == true) {
      _thumbs.remove(item.id);
      _reload();
    }
  }

  Future<Uint8List> _thumb(String id) => _thumbs[id] ??= rust.itemThumbnail(id: id);

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vault.name),
        actions: [
          if (_canBio)
            PopupMenuButton<void>(
              itemBuilder: (context) => [
                CheckedPopupMenuItem<void>(
                  checked: _bioOn,
                  onTap: _toggleBiometric,
                  child: Text(l.biometricSetting),
                ),
              ],
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _lock,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(l.lockVault),
            ),
          ),
        ],
      ),
      floatingActionButton: _hasCamera
          ? FloatingActionButton.extended(
              onPressed: _openCamera,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(l.takePhoto),
            )
          : null,
      body: SafeArea(
        child: items == null
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? const _Empty()
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 96),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      return _Tile(
                        key: ValueKey(item.id),
                        thumb: _thumb(item.id),
                        label: l.photo,
                        onTap: () => _openItem(item),
                      );
                    },
                  ),
      ),
    );
  }
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
              Text(
                l.emptyVaultTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                l.emptyVaultBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.thumb, required this.label, required this.onTap});

  final Future<Uint8List> thumb;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: c.soft,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: FutureBuilder<Uint8List>(
            future: thumb,
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null || bytes.isEmpty) {
                return Icon(Icons.image_outlined, color: c.muted);
              }
              return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
        ),
      ),
    );
  }
}

/// Full photo, decrypted into memory for as long as this screen is open.
/// Pops with `true` when the photo was deleted.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.item});

  final rust.ItemInfo item;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final Future<Uint8List> _content = rust.itemContent(id: widget.item.id);

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
      await rust.deleteItem(id: widget.item.id);
      if (mounted) Navigator.of(context).pop(true);
    } on rust.VaultError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(vaultErrorText(l, e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final when = DateTime.fromMillisecondsSinceEpoch(widget.item.createdMs);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          MaterialLocalizations.of(context).formatMediumDate(when),
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            tooltip: l.deletePhoto,
          ),
        ],
      ),
      body: FutureBuilder<Uint8List>(
        future: _content,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text(l.errorStorage, style: const TextStyle(color: Colors.white70)),
            );
          }
          final bytes = snap.data;
          if (bytes == null) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          return InteractiveViewer(
            maxScale: 6,
            child: Center(child: Image.memory(bytes, gaplessPlayback: true)),
          );
        },
      ),
    );
  }
}
