import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart';
import 'vault_home.dart' show PhotoViewerScreen;
import 'video_view.dart';

/// Tapping a photo or video opens it as a card a little bigger than its thumbnail, over
/// the vault, which stays in view behind a light dim (owner 2026-10-21). A video plays
/// right in the card. Under it: Close (bottom left, as in the camera), Full screen, then
/// Send and Delete. A tap outside closes. Pops with the id when the item was deleted.
class QuickLook extends StatefulWidget {
  const QuickLook({super.key, required this.item, required this.photos, required this.vaultId});

  final rust.ItemInfo item;
  /// The photos around it, for swiping in full screen.
  final List<rust.ItemInfo> photos;
  final String vaultId;

  /// For the mockup renders: a still in place of the video player.
  static Widget? debugVideo;

  /// Opens over the current screen, the vault still visible behind.
  static Future<String?> show(BuildContext context, rust.ItemInfo item,
          {required List<rust.ItemInfo> photos, required String vaultId}) =>
      Navigator.of(context).push<String>(PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierLabel: AppLocalizations.of(context).close,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => QuickLook(item: item, photos: photos, vaultId: vaultId),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ));

  @override
  State<QuickLook> createState() => _QuickLookState();
}

class _QuickLookState extends State<QuickLook> {
  late final bool _video = widget.item.kind == ItemKind.video;
  Future<Uint8List>? _bytes;
  VideoPlayerController? _player;
  File? _copy;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!_video) {
      _bytes = rust.itemContent(id: widget.item.id);
    } else if (QuickLook.debugVideo == null) {
      _open();
    }
  }

  Future<void> _open() async {
    try {
      final copy = await playbackCopy(widget.item);
      _copy = copy;
      final p = VideoPlayerController.file(copy);
      await p.initialize();
      if (!mounted) {
        await p.dispose();
        return;
      }
      p.addListener(_tick);
      setState(() => _player = p);
      await p.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player?.dispose();
    try {
      _copy?.deleteSync();
    } catch (_) {}
    super.dispose();
  }

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    p.value.isPlaying ? p.pause() : p.play();
  }

  Future<void> _full() async {
    final String? deleted;
    if (_video) {
      deleted = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => VideoViewScreen(item: widget.item, vaultId: widget.vaultId, player: _player, copy: _copy),
      ));
    } else {
      final i = widget.photos.indexWhere((p) => p.id == widget.item.id);
      deleted = await Navigator.of(context).push<String>(PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, _, _) => PhotoViewerScreen(items: widget.photos, initial: i < 0 ? 0 : i),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ));
    }
    if (deleted != null && mounted) Navigator.of(context).pop(deleted);
  }

  Future<void> _delete() async {
    await rust.trashItem(id: widget.item.id, nowMs: nowMs());
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  Future<void> _send() async {
    final copy = _copy;
    if (copy == null || !await confirmShareOut(context, widget.vaultId) || !mounted) return;
    LockGuard.allowAway();
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(copy.path, mimeType: widget.item.mime, name: widget.item.name)]));
    } finally {
      LockGuard.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    // A little bigger than a thumbnail: most of the width, at most half the height.
    final box = BoxConstraints(maxWidth: (size.width - 64).clamp(0, 380), maxHeight: size.height * .5);
    final p = _player;
    final v = p?.value;
    final still = QuickLook.debugVideo;

    Widget media;
    if (!_video) {
      media = FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) => snap.hasData
            ? Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true)
            : const SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator())),
      );
    } else if (_failed) {
      media = SizedBox(
        width: 260,
        height: 160,
        child: Center(child: Text(l.videoFailed, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))),
      );
    } else {
      final playing = v?.isPlaying ?? false;
      final total = v?.duration.inMilliseconds ?? 0;
      final f = still != null ? .33 : total == 0 ? 0.0 : (v!.position.inMilliseconds / total).clamp(0.0, 1.0);
      media = GestureDetector(
        onTap: _togglePlay,
        child: Stack(
          alignment: Alignment.center,
          children: [
            still ??
                (v != null && v.isInitialized
                    ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(p!))
                    : const SizedBox(width: 260, height: 180, child: Center(child: CircularProgressIndicator(color: Colors.white)))),
            if (!playing)
              Container(
                key: const ValueKey('quick-play'),
                width: Ui.bar,
                height: Ui.bar,
                decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
              ),
            // Where the video is, a thin line along the bottom of the card.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(widthFactor: f, child: Container(height: 4, color: Colors.white)),
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        // The vault stays visible: a light dim and a little blur, tap to close.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: ColoredBox(color: page.withValues(alpha: .45)),
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: .88, end: 1),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (context, s, child) => Transform.scale(scale: s, child: child),
                child: Container(
                  key: const ValueKey('quick-look'),
                  constraints: box,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 30, offset: Offset(0, 12))],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: ColoredBox(color: Colors.black, child: media),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: box.maxWidth,
                child: Row(
                  children: [
                    GlassButton(
                      key: const ValueKey('quick-close'),
                      icon: Icons.close,
                      tooltip: l.close,
                      size: Ui.bar,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      key: const ValueKey('quick-full'),
                      icon: Icons.fullscreen_rounded,
                      tooltip: l.fullScreen,
                      size: Ui.bar,
                      onTap: _full,
                    ),
                    const Spacer(),
                    if (_video) ...[
                      GlassButton(
                        icon: Icons.ios_share,
                        tooltip: l.sendOut,
                        size: Ui.bar,
                        onTap: _copy == null ? null : _send,
                      ),
                      const SizedBox(width: 8),
                    ],
                    GlassButton(
                      key: const ValueKey('quick-delete'),
                      tooltip: l.delete,
                      size: Ui.bar,
                      icon: null,
                      onTap: _delete,
                      child: Icon(Icons.delete_outline, color: recordRed(context), size: 24),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
