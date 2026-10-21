import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import 'file_view.dart';

/// A video, played inside the app. The player needs a file, so the video is decrypted
/// into the app's own temporary folder (never shared storage) and that copy is deleted
/// when the screen closes, when the vault locks, and at every app start
/// ([clearPlaybackCopies]). Pops with the id when the video was deleted.
class VideoViewScreen extends StatefulWidget {
  const VideoViewScreen({super.key, required this.item, required this.vaultId, this.player, this.copy});

  final rust.ItemInfo item;
  final String vaultId;
  /// Full screen from the quick look: its player (and decrypted copy) carry on here and
  /// stay the quick look's to dispose; the corner button goes back to it.
  final VideoPlayerController? player;
  final File? copy;

  /// The platforms with a video player; elsewhere videos open in another app.
  static bool get supported => Device.iOS || Device.android || Device.macOS;

  @override
  State<VideoViewScreen> createState() => _VideoViewScreenState();
}

const _playDir = 'play';

Future<Directory> _playbackDir() async =>
    Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$_playDir');

/// Decrypt an item into the private playback folder for a player that needs a file.
/// The caller deletes it when done; [clearPlaybackCopies] sweeps whatever is left.
Future<File> playbackCopy(rust.ItemInfo item, {String fallbackExt = '.mp4'}) async {
  final dir = await _playbackDir();
  await dir.create(recursive: true);
  final dot = item.name.lastIndexOf('.');
  final ext = dot < 0 ? fallbackExt : item.name.substring(dot);
  final copy = File('${dir.path}${Platform.pathSeparator}${item.id}$ext');
  await rust.exportItem(id: item.id, path: copy.path);
  return copy;
}

/// Recordings in progress live here until they are encrypted (then deleted).
Future<Directory> recordingDir() async {
  final d = Directory('${(await _playbackDir()).path}${Platform.pathSeparator}rec');
  await d.create(recursive: true);
  return d;
}

/// Remove every decrypted playback copy (app start, lock).
Future<void> clearPlaybackCopies() async {
  try {
    final d = await _playbackDir();
    if (d.existsSync()) d.deleteSync(recursive: true);
  } catch (_) {}
}

class _VideoViewScreenState extends State<VideoViewScreen> {
  VideoPlayerController? _player;
  File? _copy;
  bool _failed = false;
  bool _bars = true;

  @override
  void initState() {
    super.initState();
    final shared = widget.player;
    if (shared == null) {
      _open();
      return;
    }
    _player = shared;
    _copy = widget.copy;
    shared.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    try {
      final dir = await _playbackDir();
      await dir.create(recursive: true);
      final dot = widget.item.name.lastIndexOf('.');
      final ext = dot < 0 ? '.mp4' : widget.item.name.substring(dot);
      final copy = File('${dir.path}${Platform.pathSeparator}${widget.item.id}$ext');
      await rust.exportItem(id: widget.item.id, path: copy.path);
      _copy = copy;
      final p = VideoPlayerController.file(copy);
      await p.initialize();
      if (!mounted) {
        await p.dispose();
        return;
      }
      p.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _player = p);
      await p.play();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    if (widget.player != null) {
      widget.player!.removeListener(_tick);
      return super.dispose();
    }
    _player?.dispose();
    final copy = _copy;
    if (copy != null) {
      try {
        copy.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _delete() async {
    await rust.trashItem(id: widget.item.id, nowMs: nowMs());
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  Future<void> _send(BuildContext buttonContext) async {
    final copy = _copy;
    if (copy == null || !await confirmShareOut(context, widget.vaultId) || !buttonContext.mounted) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    LockGuard.allowAway();
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(copy.path, mimeType: widget.item.mime, name: widget.item.name)],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } finally {
      LockGuard.clear();
    }
  }

  static String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = _player;
    final v = p?.value;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _bars = !_bars),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(l.videoFailed, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    )
                  : p == null || v == null || !v.isInitialized
                      ? const CircularProgressIndicator(color: Colors.white)
                      : AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(p)),
            ),
            AnimatedOpacity(
              opacity: _bars ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_bars,
                child: SafeArea(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('media-exit-full'),
                            tooltip: widget.player != null ? l.exitFullScreen : l.close,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(widget.player != null ? Icons.fullscreen_exit_rounded : Icons.close, color: Colors.white),
                          ),
                          Expanded(
                            child: Text(widget.item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 12),
                        ],
                      ),
                      const Spacer(),
                      if (p != null && v != null && v.isInitialized)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: v.isPlaying ? l.pause : l.play,
                                onPressed: () => v.isPlaying ? p.pause() : p.play(),
                                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                              ),
                              Text(_time(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: VideoProgressIndicator(p, allowScrubbing: true),
                                ),
                              ),
                              Text(_time(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Builder(
                              builder: (b) => TextButton.icon(
                                onPressed: _copy == null ? null : () => _send(b),
                                style: TextButton.styleFrom(foregroundColor: Colors.white),
                                icon: const Icon(Icons.ios_share),
                                label: Text(l.sendOut),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _delete,
                              style: TextButton.styleFrom(foregroundColor: Colors.white),
                              icon: const Icon(Icons.delete_outline),
                              label: Text(l.delete),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
