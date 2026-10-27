import 'quick_look.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../theme.dart' show CsType;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../widgets/confirm_delete.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import 'file_view.dart';
import 'glass.dart';

/// A video, played inside the app. The player needs a file, so the video is decrypted
/// into the app's own temporary folder (never shared storage) and that copy is deleted
/// when the screen closes, when the vault locks, and at every app start
/// ([clearPlaybackCopies]). Pops with the id when the video was deleted.
class VideoViewScreen extends StatefulWidget {
  const VideoViewScreen({super.key, required this.item, required this.vaultId, this.playback});

  final rust.ItemInfo item;
  final String vaultId;

  /// Full screen from the quick look: its player (and decrypted copy) carry on here and
  /// stay the quick look's to dispose; the corner button goes back to it.
  final Playback? playback;

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

/// How many bytes of decrypted playback copies are on disk now (Debug).
Future<int> playbackBytes() async {
  try {
    final d = await _playbackDir();
    if (!d.existsSync()) return 0;
    var n = 0;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      n += f.lengthSync();
    }
    return n;
  } catch (_) {
    return 0;
  }
}

/// Remove every decrypted playback copy (app start, lock).
Future<void> clearPlaybackCopies() async {
  try {
    final d = await _playbackDir();
    if (d.existsSync()) d.deleteSync(recursive: true);
  } catch (_) {}
}

/// A video (or a recording) decrypted into the playback folder and its player. When the
/// vault locks, the player stops and the copy is deleted (the page stays under the lock);
/// when the same vault opens again, it is decrypted again and carries on from where it was.
class Playback extends ChangeNotifier {
  Playback(this.item, {this.fallbackExt = '.mp4'}) {
    vaultLock.addListener(_lockChanged);
    _open(_round);
  }

  final rust.ItemInfo item;
  /// The copy's extension when the name has none (players go by it).
  final String fallbackExt;
  VideoPlayerController? _player;
  File? _copy;
  bool _failed = false;
  bool _disposed = false;
  /// Each lock starts a new round: an opening from before it is thrown away.
  int _round = 0;
  Duration _at = Duration.zero;
  bool _playing = true;

  VideoPlayerController? get player => _player;
  File? get copy => _copy;
  bool get failed => _failed;

  Future<void> _open(int round) async {
    File? copy;
    VideoPlayerController? p;
    try {
      copy = await playbackCopy(item, fallbackExt: fallbackExt);
      p = VideoPlayerController.file(copy);
      await p.initialize();
      if (_at > Duration.zero) await p.seekTo(_at);
      if (round != _round) {
        await p.dispose();
        _delete(copy);
        return;
      }
      _copy = copy;
      _player = p..addListener(notifyListeners);
      notifyListeners();
      if (_playing) await p.play();
    } catch (_) {
      if (round != _round) {
        await p?.dispose();
        _delete(copy);
        return;
      }
      _failed = true;
      notifyListeners();
    }
  }

  void _lockChanged() {
    if (_disposed) return;
    if (!vaultLock.locked) {
      if (_player == null && !_failed) _open(_round);
      return;
    }
    _round++;
    final p = _player;
    if (p != null) {
      _at = p.value.position;
      _playing = p.value.isPlaying;
      p.removeListener(notifyListeners);
    }
    _player = null;
    _failed = false;
    _delete(_copy);
    _copy = null;
    notifyListeners();
    p?.dispose();
  }

  static void _delete(File? f) {
    try {
      f?.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _round++;
    vaultLock.removeListener(_lockChanged);
    _player?.removeListener(notifyListeners);
    _player?.dispose();
    _delete(_copy);
    super.dispose();
  }
}

class _VideoViewScreenState extends State<VideoViewScreen> {
  late final Playback _playback = widget.playback ?? Playback(widget.item);
  bool _bars = true;

  VideoPlayerController? get _player => _playback.player;
  File? get _copy => _playback.copy;
  bool get _failed => _playback.failed;

  @override
  void initState() {
    super.initState();
    _playback.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _playback.removeListener(_tick);
    if (widget.playback == null) _playback.dispose();
    super.dispose();
  }

  /// Asks first, then it goes to Recently deleted and the vault offers Undo.
  Future<void> _delete() async {
    if (!await confirmTrash(context, count: 1, name: widget.item.name) || !mounted) return;
    await rust.trashItem(id: widget.item.id, nowMs: nowMs());
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  Future<void> _send(BuildContext buttonContext) async {
    final copy = _copy;
    if (copy == null || !await confirmShareOut(context, widget.vaultId) || !buttonContext.mounted) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    LockGuard.allowAway();
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(copy.path, mimeType: widget.item.mime, name: widget.item.name)],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } finally {
      LockGuard.clear();
    }
  }

  static String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

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
                      child: Text(
                        l.videoFailed,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
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
                          const SizedBox(width: 8),
                          GlassPill(
                            child: IconButton(
                              key: const ValueKey('media-exit-full'),
                              tooltip: widget.playback != null ? l.exitFullScreen : l.close,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: Icon(
                                widget.playback != null ? Icons.fullscreen_exit_rounded : Icons.close,
                                color: Colors.white,
                                size: 26,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: GlassPill(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                                child: Text(
                                  widget.item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                      ),
                      const Spacer(),
                      if (p != null && v != null && v.isInitialized)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: GlassPill(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: v.isPlaying ? l.pause : l.play,
                                    onPressed: () => v.isPlaying ? p.pause() : p.play(),
                                    icon: Icon(
                                      v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                  Text(_time(v.position), style: const TextStyle(color: Colors.white, fontSize: CsType.caption1)),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      child: VideoProgressIndicator(p, allowScrubbing: true),
                                    ),
                                  ),
                                  Text(_time(v.duration), style: const TextStyle(color: Colors.white, fontSize: CsType.caption1)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Builder(
                              builder: (b) => GlassPill(
                                child: TextButton.icon(
                                  onPressed: _copy == null ? null : () => _send(b),
                                  style: glassButton,
                                  icon: const Icon(Icons.ios_share),
                                  label: glassLabel(l.sendOut),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            GlassPill(
                              child: TextButton.icon(
                                key: const ValueKey('video-delete'),
                                onPressed: _delete,
                                style: glassDelete,
                                icon: const Icon(Icons.delete_rounded),
                                label: glassLabel(l.delete),
                              ),
                            ),
                            const SizedBox(width: 16),
                            GlassPill(
                              child: IconButton(
                                key: const ValueKey('video-more'),
                                tooltip: l.more,
                                color: Colors.white,
                                onPressed: () => Navigator.of(context).pop(QuickLook.menuFor(widget.item.id)),
                                icon: const Icon(Icons.more_horiz),
                              ),
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
