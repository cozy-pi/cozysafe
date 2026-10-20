import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'video_view.dart';
import '../capture_name.dart';
import '../item_kind.dart';

/// Voice memos (docs/ui.md, voice memos): the list of recordings, each playable in
/// place, or, while recording, a live level meter and a timer. The red mic button
/// above the lock starts and stops ([toggle]). The sound goes to a file in the app's
/// private temp directory while recording and is encrypted into the vault and deleted as soon as it
/// stops.
class RecorderView extends StatefulWidget {
  const RecorderView({
    super.key,
    required this.items,
    required this.onSaved,
    required this.onRecordingChanged,
    required this.onOpen,
    this.tagId,
    this.bottomPad = 16,
  });

  /// New recordings carry this tag (the one open in the vault).
  final String? tagId;
  final double bottomPad;

  /// The recordings to list (narrowed to the open tag, if any).
  final List<rust.ItemInfo> items;
  final VoidCallback onSaved;
  final ValueChanged<bool> onRecordingChanged;
  /// A recording's row was tapped (rename, send, delete).
  final void Function(rust.ItemInfo item) onOpen;

  static bool get supported => Device.iOS || Device.android;

  @override
  State<RecorderView> createState() => RecorderViewState();
}

class RecorderViewState extends State<RecorderView> {
  /// Made on the first recording, so the microphone isn't touched before then.
  AudioRecorder? _recorder;
  AudioRecorder get _rec => _recorder ??= AudioRecorder();
  StreamSubscription<Amplitude>? _levels;
  final List<double> _bars = [];
  DateTime? _started;
  Timer? _tick;
  String? _path;
  /// Set when recording starts (the context may be gone when it is saved on lock).
  String? _name;
  bool _saving = false;

  // In-place playback of one recording.
  String? _playingId;
  VideoPlayerController? _player;
  File? _copy;

  bool get recording => _started != null;

  @override
  void dispose() {
    _tick?.cancel();
    _levels?.cancel();
    _stopPlaying();
    // Leaving mid-recording keeps what was recorded.
    if (recording) unawaited(stopAndSave());
    _recorder?.dispose();
    super.dispose();
  }

  /// The dock's button: start, or stop and save.
  Future<void> toggle() => recording ? stopAndSave() : _start();

  Future<void> _start() async {
    final l = AppLocalizations.of(context);
    if (_saving) return;
    await _stopPlaying();
    try {
      if (!await _rec.hasPermission()) {
        if (mounted) _snack(l.micDenied);
        return;
      }
      final dir = await recordingDir();
      final path = '${dir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1), path: path);
      HapticFeedback.mediumImpact();
      _path = path;
      _name = captureName(l, ItemKind.audio, DateTime.now(), '.m4a');
      _bars.clear();
      _levels = _rec.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((a) {
        // dBFS (about -60 quiet … 0 loud) to 0..1.
        final v = ((a.current + 60) / 60).clamp(.04, 1.0);
        setState(() {
          _bars.add(v);
          if (_bars.length > 60) _bars.removeAt(0);
        });
        LockGuard.activity(); // recording is not idleness
      });
      setState(() => _started = DateTime.now());
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
      widget.onRecordingChanged(true);
    } catch (_) {
      if (mounted) _snack(l.recordFailed);
    }
  }

  /// Stop and encrypt into the vault. Also called before the vault locks.
  Future<void> stopAndSave() async {
    final started = _started;
    if (started == null || _saving) return;
    _saving = true;
    _tick?.cancel();
    await _levels?.cancel();
    _levels = null;
    final length = DateTime.now().difference(started);
    if (mounted) setState(() => _started = null);
    widget.onRecordingChanged(false);
    String? path;
    try {
      path = await _rec.stop() ?? _path;
      if (path != null && File(path).existsSync()) {
        final when = started;
        final item = await rust.addFile(
          path: path,
          kind: ItemKind.audio,
          name: _name ?? 'Recording.m4a',
          mime: 'audio/mp4',
          createdMs: i64(when.millisecondsSinceEpoch),
          thumbnail: null,
        );
        await rust.setItemDuration(id: item.id, durationMs: i64(length.inMilliseconds));
        final tagId = widget.tagId;
        if (tagId != null) await rust.setTag(itemIds: [item.id], tagId: tagId, tagged: true);
        widget.onSaved();
      }
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).recordFailed);
    } finally {
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      _saving = false;
    }
  }

  Future<void> _togglePlay(rust.ItemInfo item) async {
    if (_playingId == item.id) {
      final p = _player;
      if (p == null) return;
      p.value.isPlaying ? await p.pause() : await p.play();
      return;
    }
    await _stopPlaying();
    setState(() => _playingId = item.id);
    try {
      final copy = await playbackCopy(item, fallbackExt: '.m4a');
      _copy = copy;
      final p = VideoPlayerController.file(copy);
      await p.initialize();
      if (!mounted || _playingId != item.id) {
        await p.dispose();
        return;
      }
      p.addListener(() {
        if (!mounted) return;
        if (p.value.isInitialized && !p.value.isPlaying && p.value.position >= p.value.duration) {
          _stopPlaying();
        } else {
          setState(() {});
        }
      });
      setState(() => _player = p);
      await p.play();
    } catch (_) {
      if (mounted) {
        setState(() => _playingId = null);
        _snack(AppLocalizations.of(context).videoFailed);
      }
    }
  }

  Future<void> _stopPlaying() async {
    final p = _player;
    final copy = _copy;
    _player = null;
    _copy = null;
    if (mounted && _playingId != null) setState(() => _playingId = null);
    _playingId = null;
    await p?.dispose();
    if (copy != null) {
      try {
        copy.deleteSync();
      } catch (_) {}
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static String _clock(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final started = _started;
    if (started != null) {
      final d = DateTime.now().difference(started);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 120,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final v in _bars)
                    Container(
                      width: 4,
                      height: 8 + v * 104,
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface, borderRadius: BorderRadius.circular(2)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 4),
            Text(l.recordingHint, style: TextStyle(color: c.muted)),
          ],
        ),
      );
    }
    final list = widget.items.where((i) => i.kind == ItemKind.audio).toList();
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_none, size: 48, color: c.muted),
              const SizedBox(height: 14),
              Text(l.emptyAudioTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(l.emptyAudioBody, textAlign: TextAlign.center, style: TextStyle(color: c.muted, height: 1.5)),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 4, 12, widget.bottomPad),
      children: [
        Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, it) in list.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 62, color: c.border.withValues(alpha: .6)),
                _row(context, it),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, rust.ItemInfo it) {
    final c = CsColors.of(context);
    final l = AppLocalizations.of(context);
    final playing = _playingId == it.id;
    final p = playing ? _player : null;
    final total = Duration(milliseconds: it.durationMs?.toInt() ?? 0);
    final pos = p?.value.position ?? Duration.zero;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => widget.onOpen(it),
      child: Container(
        color: playing ? primary.withValues(alpha: .08) : null,
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            IconButton.filledTonal(
              tooltip: playing && (p?.value.isPlaying ?? false) ? l.pause : l.play,
              onPressed: () => _togglePlay(it),
              icon: Icon(playing && (p?.value.isPlaying ?? true) ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.name.replaceAll(RegExp(r'\.m4a$'), ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  if (playing && p != null && p.value.isInitialized)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: VideoProgressIndicator(p, allowScrubbing: true,
                          colors: VideoProgressColors(playedColor: primary, backgroundColor: c.soft)),
                    )
                  else
                    Text(MaterialLocalizations.of(context).formatShortDate(dateOf(it.createdMs)),
                        style: TextStyle(color: c.muted, fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              playing ? '${_clock(pos)} / ${_clock(total)}' : _clock(total),
              style: TextStyle(color: c.muted, fontSize: 12.5, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ),
    );
  }
}
