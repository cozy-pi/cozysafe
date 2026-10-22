import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart';
import 'vault_home.dart' show PhotoViewerScreen;
import 'video_view.dart';

/// Tapping a photo or video opens it big, over the vault, which goes dark and soft
/// behind (owner 2026-10-22: the first card was small and the page behind looked messy).
/// A video plays right there. Under it: its name and date, then one glass bar with Close,
/// Full screen, Send and Delete. A tap outside or a swipe down closes. Pops with the id
/// when the item was deleted.
class QuickLook extends StatefulWidget {
  const QuickLook({super.key, required this.item, required this.photos, required this.vaultId});

  final rust.ItemInfo item;
  /// The photos around it, for swiping in full screen.
  final List<rust.ItemInfo> photos;
  final String vaultId;

  /// Popped by ⋯ in any viewer, with the item's id: the vault shows that item's menu
  /// (Rename, Group, Info…) over itself. The full-screen viewers return it through here.
  static const menuRequest = '\u0000menu';
  static String menuFor(String id) => '$menuRequest:$id';
  /// The item whose menu a viewer asked for, if [result] is such a request.
  static String? menuTarget(String? result) =>
      result != null && result.startsWith('$menuRequest:') ? result.substring(menuRequest.length + 1) : null;

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
        pageBuilder: (_, _, _) => PhotoViewerScreen(items: widget.photos, initial: i < 0 ? 0 : i, vaultId: widget.vaultId),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ));
    }
    if (deleted != null && mounted) Navigator.of(context).pop(deleted);
  }

  Future<void> _delete() async {
    await rust.trashItem(id: widget.item.id, nowMs: nowMs());
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  Future<void> _send() => shareItem(context, widget.item, widget.vaultId);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    // Big: the width less a margin, up to about two thirds of the height.
    final box = BoxConstraints(maxWidth: (size.width - 32).clamp(0, 520), maxHeight: size.height * .62);
    final c = CsColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = _player;
    final v = p?.value;
    final still = QuickLook.debugVideo;

    Widget media;
    if (!_video) {
      media = FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snap) => snap.hasData
            // Decoded at the card's size, not the photo's (a 48 MP photo would take ~190 MB).
            ? Image.memory(snap.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // A tiny scale makes the natural size huge, so the card's limits shrink it
                // to the most room it can have, keeping its shape.
                scale: .05,
                cacheWidth: (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).round())
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

    Widget tool(Key key, IconData icon, String tip, VoidCallback onTap, {Color? color}) => IconButton(
          key: key,
          tooltip: tip,
          onPressed: onTap,
          iconSize: 24,
          style: IconButton.styleFrom(minimumSize: const Size(Ui.tap, Ui.tap)),
          icon: Icon(icon, color: color ?? Theme.of(context).colorScheme.onSurface),
        );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
      children: [
        // The vault goes dark and soft behind, so only the photo speaks; tap to close.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: ColoredBox(color: page.withValues(alpha: dark ? .82 : .72)),
            ),
          ),
        ),
        Center(
          child: GestureDetector(
            // Swipe down to put it away, as in Photos.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).pop();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: .92, end: 1),
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  builder: (context, s, child) => Transform.scale(scale: s, child: child),
                  child: Container(
                    key: const ValueKey('quick-look'),
                    constraints: box,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 16))],
                    ),
                    child: ClipRRect(borderRadius: BorderRadius.circular(20), child: media),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: box.maxWidth,
                  child: Column(
                    children: [
                      Text(widget.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(MaterialLocalizations.of(context).formatShortDate(dateOf(widget.item.createdMs)),
                          style: TextStyle(fontSize: 13, color: c.muted)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // One small glass bar, not four big circles.
                Glass(
                  radius: 28,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        tool(const ValueKey('quick-close'), Icons.close_rounded, l.close, () => Navigator.of(context).pop()),
                        const SizedBox(width: 10),
                        tool(const ValueKey('quick-full'), Icons.fullscreen_rounded, l.fullScreen, _full),
                        const SizedBox(width: 10),
                        tool(const ValueKey('quick-send'), Icons.ios_share, l.sendOut, _send),
                        const SizedBox(width: 10),
                        tool(const ValueKey('quick-more'), Icons.more_horiz, l.more,
                            () => Navigator.of(context).pop(QuickLook.menuFor(widget.item.id))),
                        const SizedBox(width: 10),
                        tool(const ValueKey('quick-delete'), Icons.delete_outline, l.delete, _delete, color: recordRed(context)),
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
