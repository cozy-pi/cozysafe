import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../theme.dart' show CsType;
import 'package:flutter/physics.dart';

import '../item_bytes.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../widgets/bottom_bar.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/toast.dart';
import 'common.dart';
import 'file_view.dart';
import 'glass.dart';
import 'quick_look.dart';
import 'video_view.dart';

/// Black space between two photos while swiping, as in Photos.
const _gap = 20.0;

/// Double tap zooms to this, at the tapped point.
const _doubleTapScale = 2.5;

/// Photos full screen, decrypted into memory only while shown. Swipe sideways for the
/// next one, drag down to close, pinch or double tap to zoom, tap to hide the bars.
/// Pops with the id of a deleted photo.
///
/// Smooth as Photos (owner 2026-10-28): a drag moves only what it moves (no rebuild of
/// the pages per frame), a photo let go springs back, the next photos are read once the
/// swipe has settled (not halfway through it), and the bars share one blur.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({super.key, required this.items, required this.initial, required this.vaultId});
  final String vaultId;

  final List<rust.ItemInfo> items;
  final int initial;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> with SingleTickerProviderStateMixin {
  late final _pages = PageController(initialPage: widget.initial);
  late final _index = ValueNotifier(widget.initial);
  final Map<String, Future<Uint8List>> _content = {};
  final Map<String, Future<Uint8List>> _thumbnails = {};
  final _bars = ValueNotifier(true);

  /// How far the photo has been dragged to put it away; zero at rest.
  final _drag = ValueNotifier(Offset.zero);
  Offset _dragStart = Offset.zero;

  /// Brings a photo let go back to its place.
  late final _back = AnimationController.unbounded(vsync: this)..addListener(_backTick);
  Offset _backFrom = Offset.zero;

  /// The photo shown is zoomed in: a drag pans it instead of turning the page or closing.
  final _zoomed = ValueNotifier(false);

  rust.ItemInfo get _item => widget.items[_index.value];

  Future<Uint8List> _load(String id) => _content[id] ??= photoBytes(id);
  Future<Uint8List> _thumbnail(String id) => _thumbnails[id] ??= rust.itemThumbnail(id: id);

  /// Width photos are decoded at: 1.5× the screen's (at most 3000 px, ~20 MB as a
  /// bitmap), sharp enough to zoom, without a very large photo's full bitmap in memory.
  int get _decodeWidth =>
      (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 1.5).round().clamp(1, 3000);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _around(_index.value));
  }

  /// The photos next to this one are decrypted and decoded before they slide in, and only
  /// the few around it stay in memory. Called once a swipe has settled: reading a photo
  /// copies megabytes on the UI thread, which halfway through a swipe drops frames.
  void _around(int i) {
    if (!mounted) return;
    final n = widget.items.length;
    final keep = {for (var j = i - 3; j <= i + 3; j++) if (j >= 0 && j < n) widget.items[j].id};
    _content.removeWhere((id, _) => !keep.contains(id));
    final w = _decodeWidth;
    for (final j in [i, i + 1, i - 1, i + 2, i - 2]) {
      if (j < 0 || j >= n || widget.items[j].kind != ItemKind.photo) continue;
      _load(widget.items[j].id).then((bytes) {
        // The same provider Image.memory(cacheWidth:) makes, so the page finds it decoded.
        if (mounted) precacheImage(ResizeImage(MemoryImage(bytes), width: w), context, onError: (_, _) {});
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _back.dispose();
    _index.dispose();
    _bars.dispose();
    _drag.dispose();
    _zoomed.dispose();
    super.dispose();
  }

  /// Asks first, then it goes to Recently deleted and the vault offers Undo.
  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    final item = _item;
    if (!await confirmTrash(context, count: 1, name: item.name) || !mounted) return;
    try {
      await rust.trashItem(id: item.id, nowMs: nowMs());
      if (mounted) Navigator.of(context).pop(item.id);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
    }
  }

  // ---------- drag down to close ----------

  void _dragBegin(DragStartDetails d) {
    _back.stop();
    _dragStart = d.globalPosition - _drag.value;
  }

  /// The photo follows the finger both ways, as in Photos; upwards it only gives a little.
  void _dragMove(DragUpdateDetails d) {
    final o = d.globalPosition - _dragStart;
    _drag.value = Offset(o.dx, o.dy < 0 ? o.dy * .25 : o.dy);
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    if (_drag.value.dy > 120 || (v.dy > 700 && _drag.value.dy > 0)) {
      // Fades out from where it is (the route is a fade).
      Navigator.of(context).pop();
      return;
    }
    _backFrom = _drag.value;
    final distance = _backFrom.distance;
    // The finger's speed towards home, so the spring picks up where the hand left off.
    final speed = distance == 0 ? 0.0 : -(v.dx * _backFrom.dx + v.dy * _backFrom.dy) / (distance * distance);
    _back
      ..value = 0
      ..animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 420, damping: 40), 0, 1, speed));
  }

  void _backTick() => _drag.value = _backFrom * (1 - _back.value);

  // ---------- pages ----------

  Widget _pageView(BuildContext context) => LayoutBuilder(
        // One page is the screen plus a gap, the photo centred in it: a black band
        // runs between two photos as they slide.
        builder: (context, box) => OverflowBox(
          minWidth: box.maxWidth + _gap,
          maxWidth: box.maxWidth + _gap,
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (_) {
              _around(_index.value);
              return false;
            },
            child: ValueListenableBuilder<bool>(
              valueListenable: _zoomed,
              builder: (context, zoomed, _) => PageView.builder(
                allowImplicitScrolling: true, // the pages beside this one are built (and decoded) ahead
                controller: _pages,
                physics: zoomed ? const NeverScrollableScrollPhysics() : const _PagePhysics(),
                itemCount: widget.items.length,
                onPageChanged: (i) => _index.value = i,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _gap / 2),
                  child: widget.items[i].kind == ItemKind.video
                      ? _videoPage(context, widget.items[i])
                      : _photoPage(context, widget.items[i]),
                ),
              ),
            ),
          ),
        ),
      );

  /// The thumbnail at once (no spinner between photos), the full photo over it as soon as
  /// it is decoded.
  Widget _photoPage(BuildContext context, rust.ItemInfo item) {
    final still = FutureBuilder<Uint8List>(
      future: _thumbnail(item.id),
      builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
          ? Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true, width: double.infinity, height: double.infinity)
          : const SizedBox.expand(),
    );
    return FutureBuilder<Uint8List>(
      future: _load(item.id),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text(AppLocalizations.of(context).errorStorage, style: const TextStyle(color: Colors.white70)));
        }
        final bytes = snap.data;
        if (bytes == null) return still;
        return _ZoomPhoto(
          onZoomed: (z) {
            if (_zoomed.value != z) _zoomed.value = z;
          },
          child: Center(
            child: Image.memory(bytes,
                gaplessPlayback: true,
                cacheWidth: _decodeWidth,
                frameBuilder: (context, child, frame, sync) => frame == null && !sync ? still : child),
          ),
        );
      },
    );
  }

  /// A video among the photos: its still and a play button; playing opens the video
  /// player (owner 2026-10-22: swiping goes through videos too).
  Widget _videoPage(BuildContext context, rust.ItemInfo item) => GestureDetector(
        onTap: () => _playVideo(item),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: FutureBuilder<Uint8List>(
                future: _thumbnail(item.id),
                builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
                    ? Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true)
                    : const SizedBox.expand(),
              ),
            ),
            Container(
              key: const ValueKey('viewer-play'),
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 46),
            ),
          ],
        ),
      );

  Future<void> _playVideo(rust.ItemInfo item) async {
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => VideoViewScreen(item: item, vaultId: widget.vaultId),
    ));
    if (result != null && mounted) Navigator.of(context).pop(result);
  }

  // ---------- the screen ----------

  @override
  Widget build(BuildContext context) {
    // Built once: the drag, the bars and the page number each rebuild only what they move.
    final pages = RepaintBoundary(child: _pageView(context));
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Black, lighter as the photo is dragged away, the page showing through.
          Positioned.fill(
            child: ValueListenableBuilder<Offset>(
              valueListenable: _drag,
              builder: (context, o, _) =>
                  ColoredBox(color: Colors.black.withValues(alpha: (1 - o.dy.abs() / 400).clamp(0.0, 1.0))),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _zoomed,
            builder: (context, zoomed, child) => GestureDetector(
              onTap: () => _bars.value = !_bars.value,
              // Zoomed in, a drag pans the photo instead.
              onVerticalDragStart: zoomed ? null : _dragBegin,
              onVerticalDragUpdate: zoomed ? null : _dragMove,
              onVerticalDragEnd: zoomed ? null : _dragEnd,
              child: child,
            ),
            child: ValueListenableBuilder<Offset>(
              valueListenable: _drag,
              child: pages,
              builder: (context, o, child) => Transform.translate(
                offset: o,
                child: Transform.scale(scale: (1 - o.dy.abs() / 1500).clamp(.7, 1.0), child: child),
              ),
            ),
          ),
          _barsLayer(context),
        ],
      ),
    );
  }

  Widget _barsLayer(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ml = MaterialLocalizations.of(context);
    final bars = Column(
      children: [
        // The date and size centred over the photo (owner 2026-10-27); no name, which can
        // be long. Exit is with the other buttons at the bottom, in the thumb's reach.
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ValueListenableBuilder<int>(
              valueListenable: _index,
              builder: (context, i, _) {
                final it = widget.items[i];
                final when = dateOf(it.createdMs);
                return GlassPill(
                  child: Padding(
                    key: const ValueKey('media-info'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Column(
                      children: [
                        Text(ml.formatMediumDate(when), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        Text('${ml.formatTimeOfDay(TimeOfDay.fromDateTime(when))} · ${fileSize(it.sizeBytes)}',
                            style: const TextStyle(color: Colors.white70, fontSize: CsType.caption1)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const Spacer(),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            // The same bar as every item (ActionBar), dark glass over the photo.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ActionBar(
                onMedia: true,
                inset: false,
                // Back to the quick look this full screen was opened from.
                leave: LeaveButton(Icons.fullscreen_exit_rounded, l.exitFullScreen, () => Navigator.of(context).pop(),
                    key: const ValueKey('media-exit-full')),
                actions: [
                  BarIcon(
                      key: const ValueKey('photo-send'),
                      icon: Icons.ios_share,
                      tooltip: l.sendOut,
                      onTap: (b) => shareItem(b, _item, widget.vaultId)),
                  BarIcon(
                      key: const ValueKey('photo-more'),
                      icon: Icons.more_horiz,
                      tooltip: l.more,
                      onTap: (_) => Navigator.of(context).pop(QuickLook.menuFor(_item.id))),
                ],
                end: BarIcon(
                      key: const ValueKey('photo-delete'),
                      icon: Icons.delete_rounded,
                      tooltip: l.delete,
                      onTap: (_) => _delete(),
                      color: const Color(0xFFFF453A)),
              ),
            ),
          ),
        ),
      ],
    );
    // The pills blur the photo moving under them every frame: one shared blur, not five.
    final grouped = BackdropGroup(child: bars);
    return ListenableBuilder(
      listenable: Listenable.merge([_bars, _drag]),
      builder: (context, child) {
        final shown = _bars.value && _drag.value == Offset.zero;
        return AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(ignoring: !_bars.value, child: child),
        );
      },
      child: grouped,
    );
  }
}

/// Paging that settles like Photos: quick, without the slow drift at the end.
class _PagePhysics extends PageScrollPhysics {
  const _PagePhysics({super.parent});

  @override
  _PagePhysics applyTo(ScrollPhysics? ancestor) => _PagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(mass: .5, stiffness: 220, ratio: 1);
}

/// One photo that pinches and double-taps to zoom. At its normal size it leaves drags to
/// the pages (sideways) and to closing (down); zoomed in, a drag pans it.
class _ZoomPhoto extends StatefulWidget {
  const _ZoomPhoto({required this.child, required this.onZoomed});
  final Widget child;
  final ValueChanged<bool> onZoomed;

  @override
  State<_ZoomPhoto> createState() => _ZoomPhotoState();
}

class _ZoomPhotoState extends State<_ZoomPhoto> with SingleTickerProviderStateMixin {
  final _matrix = TransformationController();
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  Animation<Matrix4>? _to;
  Offset _tap = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _matrix.addListener(_changed);
    _anim.addListener(() {
      final to = _to;
      if (to != null) _matrix.value = to.value;
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _matrix.dispose();
    // Turned away from while zoomed (it can't be, but a rebuild could drop it): the pages swipe again.
    if (_zoomed) widget.onZoomed(false);
    super.dispose();
  }

  void _changed() {
    final z = _matrix.value.getMaxScaleOnAxis() > 1.01;
    if (z == _zoomed) return;
    setState(() => _zoomed = z);
    widget.onZoomed(z);
  }

  /// Double tap: in to the tapped point, or back out.
  void _doubleTap() {
    final Matrix4 end;
    if (_zoomed) {
      end = Matrix4.identity();
    } else {
      const s = _doubleTapScale;
      end = Matrix4.identity()
        ..translateByDouble(-_tap.dx * (s - 1), -_tap.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    _to = Matrix4Tween(begin: _matrix.value, end: end).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onDoubleTapDown: (d) => _tap = d.localPosition,
        onDoubleTap: _doubleTap,
        child: MediaQuery(
          // At normal size a one-finger drag belongs to the pages and to closing: the zoom
          // only answers two fingers. Its pan slop is twice the touch slop, so a quick
          // flick's first move (often past both) went to the zoom and the page stayed put.
          data: _zoomed
              ? MediaQuery.of(context)
              : MediaQuery.of(context).copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: 1e6)),
          child: InteractiveViewer(
            transformationController: _matrix,
            maxScale: 6,
            panEnabled: _zoomed,
            onInteractionStart: (_) => _anim.stop(),
            child: widget.child,
          ),
        ),
      );
}
