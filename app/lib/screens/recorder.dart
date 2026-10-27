import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../widgets/drag_select.dart';
import '../widgets/selectable_row.dart';
import '../theme.dart';
import 'video_view.dart';
import '../capture_name.dart';
import '../item_kind.dart';
import '../widgets/toast.dart';

/// Voice memos (docs/ui.md, voice memos): the list of recordings, each opening in the
/// item preview where it plays, or, while recording, a live level meter and a timer. The red mic button
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
    this.selecting = false,
    this.onToggleSelect,
    this.onOpen,
    this.onMenu,
    this.drag,
    this.onOrder,
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
  /// Selected recordings (the Select button, as for photos and files: the selection bar
  /// sends, groups, renames and deletes); while selecting a tap selects.
  final Set<String> selected;
  /// Select mode is on (the Select button), even with nothing chosen yet.
  final bool selecting;
  final ValueChanged<String>? onToggleSelect;
  /// A tap: the recording opens in the item preview and plays there, as anywhere else
  /// (owner 2026-10-25: one way of opening every kind of item).
  final ValueChanged<rust.ItemInfo>? onOpen;
  /// A long press: the recording's menu (Open, Rename, Group, Info…).
  final ValueChanged<rust.ItemInfo>? onMenu;
  /// Hold a recording, then drag across others to select them (lib/widgets/drag_select.dart).
  final DragSelect? drag;
  /// The listed recordings' ids, in order, for [drag].
  final ValueChanged<List<String>>? onOrder;

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

  bool get recording => _started != null;

  @override
  void dispose() {
    _tick?.cancel();
    _levels?.cancel();
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
    widget.onOrder?.call([for (final it in list) it.id]);
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mic_rounded, size: 48, color: c.muted),
              const SizedBox(height: 14),
              Text(l.emptyAudioTitle, style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700)),
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
                DragSelectItem(
                  id: it.id,
                  drag: widget.drag,
                  onMenu: widget.onMenu == null ? null : () => widget.onMenu!(it),
                  child: _row(context, it),
                ),
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
    final total = Duration(milliseconds: it.durationMs?.toInt() ?? 0);
    final selecting = widget.selecting || widget.selected.isNotEmpty;
    final chosen = widget.selected.contains(it.id);
    // A tap opens it (as a tap opens a photo) and it plays there; a long press opens the
    // menu (owner 2026-10-22: one way for every kind of item).
    final select = widget.onToggleSelect;
    final open = widget.onOpen;
    return SelectableRow(
      selected: chosen,
      selecting: selecting,
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      onTap: selecting && select != null
          ? () => select(it.id)
          : () => open?.call(it),
      // The long press is the [DragSelectItem]'s around it (menu, or drag to select).
      onLongPress: null,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          children: [
          Row(
          children: [
            IconButton.filledTonal(
              tooltip: l.play,
              onPressed: open == null ? null : () => open(it),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(it.name.replaceAll(RegExp(r'\.m4a$'), ''),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600)),
                      ),
                      if (it.isFavorite) ...[const SizedBox(width: 5), const FavoriteStar()],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(MaterialLocalizations.of(context).formatShortDate(dateOf(it.createdMs)),
                      style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _clock(total),
              style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()]),
            ),

          ],
        ),
          ],
        ),
      ),
    );
  }
}
