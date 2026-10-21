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
import '../widgets/selectable_row.dart';
import '../theme.dart';
import 'video_view.dart';
import '../capture_name.dart';
import '../item_kind.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart';

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
    this.selected = const {},
    this.onToggleSelect,
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
  /// Selected recordings (long press, like photos and files: the selection bar sends,
  /// groups, renames and deletes); while any is selected a tap selects too.
  final Set<String> selected;
  final ValueChanged<String>? onToggleSelect;

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
  /// Play [id], e.g. when a search result is a recording.
  void openRow(String id) {
    final it = widget.items.where((i) => i.id == id).firstOrNull;
    if (it != null && _playingId != id) _togglePlay(it);
  }
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

  void _snack(String text) => showToast(context, text);

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
                          color: recordRed(context), borderRadius: BorderRadius.circular(2)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
              style: TextStyle(color: recordRed(context), fontSize: 44, fontWeight: FontWeight.w300, fontFeatures: const [FontFeature.tabularFigures()]),
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
    final selecting = widget.selected.isNotEmpty;
    final chosen = widget.selected.contains(it.id);
    // A tap plays (as a tap opens a photo); a long press selects (owner 2026-10-22: one
    // way for every kind of item).
    final select = widget.onToggleSelect;
    return SelectableRow(
      selected: chosen,
      selecting: selecting,
      highlight: playing ? primary.withValues(alpha: .08) : null,
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      onTap: selecting && select != null
          ? () => select(it.id)
          : () => _togglePlay(it),
      onLongPress: select == null
          ? null
          : () => select(it.id),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
          Row(
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
          ],
        ),
      ),
    );
  }
}

/// For the screenshots: the card without a player (tests have none).
bool debugRecordingStill = false;

/// A recording opened from anywhere but Voice (home, search): it plays in a card over
/// the page you are on, so a tap never moves you to another tab (owner 2026-10-21).
/// Returns the action picked (0 rename, 1 send, 2 delete), as the Voice rows do.
Future<int?> showRecording(BuildContext context, rust.ItemInfo item) => showCard<int>(
      context,
      title: item.name.replaceAll(RegExp(r'\.m4a$'), ''),
      builder: (_) => _RecordingCard(item: item),
    );

class _RecordingCard extends StatefulWidget {
  const _RecordingCard({required this.item});
  final rust.ItemInfo item;

  @override
  State<_RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<_RecordingCard> {
  VideoPlayerController? _player;
  File? _copy;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!debugRecordingStill) _start();
  }

  Future<void> _start() async {
    try {
      final copy = await playbackCopy(widget.item, fallbackExt: '.m4a');
      _copy = copy;
      final p = VideoPlayerController.file(copy);
      await p.initialize();
      if (!mounted) {
        await p.dispose();
        return _drop();
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

  void _drop() {
    try {
      _copy?.deleteSync();
    } catch (_) {}
    _copy = null;
  }

  @override
  void dispose() {
    _player?.dispose();
    _drop();
    super.dispose();
  }

  Future<void> _toggle() async {
    final p = _player;
    if (p == null) return;
    if (p.value.isPlaying) return p.pause();
    if (p.value.position >= p.value.duration) await p.seekTo(Duration.zero);
    await p.play();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final primary = Theme.of(context).colorScheme.primary;
    final p = _player;
    final ready = p != null && p.value.isInitialized;
    final total = ready ? p.value.duration : Duration(milliseconds: widget.item.durationMs?.toInt() ?? 0);
    final pos = ready ? p.value.position : Duration.zero;
    final playing = ready && p.value.isPlaying;
    Widget act(IconData icon, String label, int action, {Color? color}) => Expanded(
          child: TextButton.icon(
            key: ValueKey('card-audio-${['rename', 'send', 'delete'][action]}'),
            onPressed: () => Navigator.of(context).pop(action),
            style: TextButton.styleFrom(foregroundColor: color ?? ink, minimumSize: const Size(0, Ui.circle)),
            icon: Icon(icon, size: 22),
            label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton.filled(
                key: const ValueKey('card-play'),
                iconSize: 30,
                style: IconButton.styleFrom(minimumSize: const Size.square(Ui.bar)),
                tooltip: playing ? l.pause : l.play,
                onPressed: _failed ? null : _toggle,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ready)
                      VideoProgressIndicator(p, allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          colors: VideoProgressColors(playedColor: primary, backgroundColor: c.soft))
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(value: 0, minHeight: 4, color: primary, backgroundColor: c.soft),
                      ),
                    Text(_failed ? l.videoFailed : '${RecorderViewState._clock(pos)} / ${RecorderViewState._clock(total)}',
                        style: TextStyle(color: c.muted, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()])),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              act(Icons.ios_share, l.sendOut, 1),
              act(Icons.edit_outlined, l.rename, 0),
              act(Icons.delete_outline, l.delete, 2, color: recordRed(context)),
            ],
          ),
        ],
      ),
    );
  }
}
