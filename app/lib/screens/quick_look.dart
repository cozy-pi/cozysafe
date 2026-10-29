import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:video_player/video_player.dart';

import '../widgets/confirm_delete.dart';
import '../item_bytes.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../note_format.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/link_card.dart';
import '../widgets/text_styles.dart';
import '../widgets/toast.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/vault_bar.dart';
import 'common.dart';
import 'file_view.dart';
import 'item_info.dart';
import 'note.dart' show noteTitle;
import 'photo_viewer.dart';
import 'video_view.dart';

/// What the preview shows inside its box, and what its Open button does.
enum _Look { photo, video, note, audio, pdf, text, image, file }

/// An item opened from Recently deleted: the preview offers Restore, Info and Delete for
/// good (asked first) instead of the vault's buttons, as its long-press menu does.
class TrashLook {
  const TrashLook({required this.daysLeft, this.held = false});

  /// Days before it goes for good.
  final int daysLeft;

  /// Deleted on another device and held here (sync).
  final bool held;
}

/// The vault's menu for one item (Rename, Favourite, Group, Info, Version history), opened
/// over the viewer itself (owner 2026-10-29: ⋯ used to close the viewer and open the long
/// press menu on the grid, somewhere else). Gives back the item as it is afterwards
/// (renamed, starred), or null when it is gone. The menu opens beside [button].
typedef ViewerMenu = Future<rust.ItemInfo?> Function(BuildContext button, rust.ItemInfo item);

/// Tapping any item opens it big, over the page, which goes dark and soft behind (owner
/// 2026-10-22, one design for every kind 2026-10-25): a photo, a video that plays right
/// there, a note's first lines on a page, a recording with its player, a PDF's first page,
/// a text file's first lines, or any other file's icon and size. Above it, its date and
/// size in a small tag; under it, its name (not for a photo or a video); and the buttons in the vault bar's place: Close, Open (full screen, Edit, the
/// file's own page or another app; none for a recording), Send, More and Delete. A tap outside or a swipe
/// down closes. Pops with the id when the item was deleted, or with one of the requests
/// below.
class QuickLook extends StatefulWidget {
  const QuickLook(
      {super.key, required this.item, this.photos = const [], required this.vaultId, this.trash, this.onResult, this.menu});

  final rust.ItemInfo item;
  /// The photos and videos around it, for swiping in full screen.
  final List<rust.ItemInfo> photos;
  final String vaultId;
  /// Set when the item is in Recently deleted: the bar is Close, Restore, Info, Delete for good.
  final TrashLook? trash;
  /// Shown in a pane of a wide window (iPad, computer), not over the page: what a popped
  /// viewer would return goes here instead, and there is no Close and no dimmed page.
  final ValueChanged<String?>? onResult;
  /// What ⋯ opens over the viewer; none: ⋯ pops [menuFor] as before.
  final ViewerMenu? menu;

  /// Popped by ⋯ in any viewer, with the item's id: the vault shows that item's menu
  /// (Rename, Group, Info…) over itself. The full-screen viewers return it through here.
  static const menuRequest = '\u0000menu';
  static String menuFor(String id) => '$menuRequest:$id';
  /// The item whose menu a viewer asked for, if [result] is such a request.
  static String? menuTarget(String? result) =>
      result != null && result.startsWith('$menuRequest:') ? result.substring(menuRequest.length + 1) : null;

  /// Popped by Edit on a note: the vault opens it in the editor.
  static const editRequest = '\u0000edit';

  /// Popped from Recently deleted.
  static const restoreRequest = '\u0000restore';
  static const purgeRequest = '\u0000purge';

  /// Notes whose checklist boxes were ticked here: the vault reloads them after.
  static final Set<String> edited = {};
  /// The last of those writes, for whoever reads the note next.
  static Future<void>? lastSave;

  /// For the mockup renders: a still in place of the video player.
  static Widget? debugVideo;
  /// For the mockup renders: a recording without a player (tests have none).
  static bool debugStillAudio = false;
  /// For the mockup renders: a PDF's first page (tests have no PDF engine).
  static Widget? debugPdfPage;

  /// Opens over the current screen, the page still visible behind.
  static Future<String?> show(BuildContext context, rust.ItemInfo item,
      {List<rust.ItemInfo> photos = const [], required String vaultId, TrashLook? trash, ViewerMenu? menu}) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Navigator.of(context).push<String>(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context).close,
      barrierColor: Colors.transparent,
      transitionDuration: Duration(milliseconds: still ? 0 : 260),
      reverseTransitionDuration: Duration(milliseconds: still ? 0 : 180),
      pageBuilder: (_, _, _) => QuickLook(item: item, photos: photos, vaultId: vaultId, trash: trash, menu: menu),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  State<QuickLook> createState() => _QuickLookState();
}

/// Pictures up to this size are decrypted into memory and shown (as in [FileViewScreen]).
const _imageInMemory = 60 << 20;
/// A PDF's first page is drawn up to this size; a bigger one shows its icon.
const _pdfPreviewMax = 20 << 20;
/// A note's or a text file's first lines.
const _maxLines = 30;

class _QuickLookState extends State<QuickLook> {
  /// The item as the menu left it (a new name, a star).
  rust.ItemInfo? _fresh;
  rust.ItemInfo get _item => _fresh ?? widget.item;
  late final _Look _look = _lookOf(widget.item);
  bool get _trash => widget.trash != null;

  Future<Uint8List>? _thumb;
  Future<Uint8List>? _bytes;

  /// A note's whole text once read (null while reading); a ticked box changes it here
  /// first, then on disk.
  String? _noteText;
  bool _noteFailed = false;

  /// "Hide note text" is on and the person tapped the note: its text shows until the
  /// preview closes (next time it is hidden again).
  Future<ui.Image?>? _pdfPage;
  ui.Image? _pdfImage;

  /// The video's or recording's player; it pauses through a lock and carries on after
  /// (video_view.dart). From Recently deleted it starts on a tap, not at once.
  Playback? _playback;

  VideoPlayerController? get _player => _playback?.player;
  bool get _failed => _playback?.failed ?? false;
  bool _busy = false;

  static _Look _lookOf(rust.ItemInfo it) {
    switch (it.kind) {
      case ItemKind.photo:
        return _Look.photo;
      case ItemKind.video:
        return _Look.video;
      case ItemKind.note:
        return _Look.note;
      case ItemKind.audio:
        return _Look.audio;
    }
    // A file: the same order FileViewScreen opens it in.
    final m = it.mime;
    if (m == 'application/pdf') return _Look.pdf;
    if (textKindOf(it.name) != null || m.startsWith('text/')) return _Look.text;
    if (m.startsWith('image/') && it.sizeBytes < BigInt.from(_imageInMemory)) return _Look.image;
    // Music or a recording added from Files plays here too.
    if (m.startsWith('audio/')) return _Look.audio;
    return _Look.file;
  }

  bool get _canPlayVideo => VideoViewScreen.supported;

  @override
  void initState() {
    super.initState();
    final id = _item.id;
    switch (_look) {
      case _Look.photo || _Look.image:
        _thumb = rust.itemThumbnail(id: id);
        _bytes = photoBytes(id);
      case _Look.video:
        _thumb = rust.itemThumbnail(id: id);
        if (!_trash && _canPlayVideo && QuickLook.debugVideo == null) _startPlayer();
      case _Look.audio:
        if (!_trash && !QuickLook.debugStillAudio) _startPlayer();
      case _Look.note:
        itemBytes(id).then((b) {
          if (mounted) setState(() => _noteText = utf8.decode(b, allowMalformed: true));
        }, onError: (Object _) {
          if (mounted) setState(() => _noteFailed = true);
        });
      case _Look.text:
        // Only the start is decrypted: a 1 GB log never sits in memory.
        _bytes = readThroughLock(() => rust.itemContentHead(id: id, max: 16 << 10));
      case _Look.pdf:
        if (QuickLook.debugPdfPage == null && _item.sizeBytes <= BigInt.from(_pdfPreviewMax)) {
          _pdfPage = _renderPdf();
        }
      case _Look.file:
        break;
    }
  }

  void _startPlayer() {
    if (_playback != null) return;
    _playback = Playback(_item, fallbackExt: _look == _Look.audio ? '.m4a' : '.mp4')..addListener(_tick);
    setState(() {});
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  /// The first page as a picture, at most ~1200 px on its longer side.
  Future<ui.Image?> _renderPdf() async {
    try {
      final data = await itemBytes(_item.id);
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openData(data, sourceName: _item.id);
      try {
        if (doc.pages.isEmpty) return null;
        final page = doc.pages.first;
        final k = 1200 / (page.width > page.height ? page.width : page.height);
        final w = (page.width * k).round(), h = (page.height * k).round();
        final img = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xFFFFFFFF);
        if (img == null) return null;
        try {
          final out = await img.createImage();
          if (!mounted) {
            out.dispose();
            return null;
          }
          return _pdfImage = out;
        } finally {
          img.dispose();
        }
      } finally {
        await doc.dispose();
      }
    } catch (_) {
      return null; // a damaged or locked PDF: its icon
    }
  }

  @override
  void dispose() {
    _playback?.dispose();
    _pdfImage?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playback == null) {
      if (_look == _Look.video ? _canPlayVideo && QuickLook.debugVideo == null : !QuickLook.debugStillAudio) {
        _startPlayer();
      }
      return;
    }
    final p = _player;
    if (p == null) return;
    if (p.value.isPlaying) return p.pause();
    if (p.value.position >= p.value.duration) await p.seekTo(Duration.zero);
    await p.play();
  }

  /// Open: what it means for this kind of item.
  Future<void> _open(BuildContext button) async {
    final String? result;
    switch (_look) {
      case _Look.note:
        _done(QuickLook.editRequest);
        return;
      case _Look.video when !_canPlayVideo:
      case _Look.file:
      case _Look.audio:
        return _send(button);
      case _Look.video:
        result = await Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => VideoViewScreen(item: _item, vaultId: widget.vaultId, playback: _playback, menu: widget.menu),
        ));
      case _Look.photo:
        final list = widget.photos.isEmpty ? [_item] : widget.photos;
        final i = list.indexWhere((p) => p.id == _item.id);
        result = await Navigator.of(context).push<String>(PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, _, _) => PhotoViewerScreen(items: list, initial: i < 0 ? 0 : i, vaultId: widget.vaultId, menu: widget.menu),
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ));
      case _Look.pdf || _Look.text || _Look.image:
        LockGuard.allowAway();
        try {
          result = await Navigator.of(context)
              .push<String>(MaterialPageRoute(builder: (_) => FileViewScreen(item: _item, vaultId: widget.vaultId, menu: widget.menu)));
        } finally {
          LockGuard.clear();
        }
    }
    if (result != null && mounted) _done(result);
  }

  /// A box ticked or cleared in the preview: that line's "[ ]" and "[x]" swap in the
  /// note's text, which is saved as the editor saves it (through a lock, once it opens).
  Future<void> _toggle(int line) async {
    final before = _noteText;
    final after = before == null ? null : toggleChecklist(before, line);
    if (after == null) return;
    setState(() => _noteText = after);
    final id = _item.id;
    final write = (QuickLook.lastSave ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => readThroughLock(() => rust.updateNote(id: id, title: noteTitle(after), text: after)));
    QuickLook.lastSave = write;
    QuickLook.edited.add(id);
    try {
      await write;
    } catch (_) {
      if (!mounted) return;
      if (_noteText == after) setState(() => _noteText = before);
      showToast(context, AppLocalizations.of(context).errorStorage, icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    if (!await confirmTrash(context, count: 1, name: _title) || !mounted) return;
    try {
      await rust.trashItem(id: _item.id, nowMs: nowMs());
      if (mounted) _done(_item.id);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _send(BuildContext button) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await shareItem(context, _item, widget.vaultId, from: button);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _clock(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
  }

  String get _title {
    final it = _item;
    if (it.kind == ItemKind.note && it.name.isEmpty) return AppLocalizations.of(context).untitledNote;
    return it.kind == ItemKind.audio ? it.name.replaceAll(RegExp(r'\.m4a$'), '') : it.name;
  }


  /// Date · size, and the length of a video or a recording when known. A note's size
  /// says nothing to anyone, so a note has its date only.
  String get _info {
    final it = _item;
    final parts = [MaterialLocalizations.of(context).formatShortDate(dateOf(it.createdMs))];
    if (it.kind != ItemKind.note) parts.add(fileSize(it.sizeBytes));
    final ms = it.durationMs?.toInt() ?? 0;
    if ((_look == _Look.video || _look == _Look.audio) && ms > 0) parts.add(_clock(Duration(milliseconds: ms)));
    return parts.join(' · ');
  }

  // ---------- what the box shows ----------

  /// The thumbnail at once, softly blurred, then the full photo fading in over it.
  Widget _photo(BoxConstraints box, Duration fade) {
    final width = (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).round();
    return FutureBuilder<Uint8List>(
      future: _thumb,
      builder: (context, t) {
        final thumb = t.data;
        final hasThumb = thumb != null && thumb.isNotEmpty;
        return FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, f) {
            // A picture this device can't read: its icon, kind and size.
            final failed = _fileCard(box);
            final full = f.data == null || f.data!.isEmpty ? null : f.data;
            // Decoded at the box's size, not the photo's (a 48 MP photo would take ~190 MB).
            // A tiny scale makes the natural size huge, so the box's limits shrink it to the
            // most room it can have, keeping its shape.
            final big = full == null
                ? null
                : Image.memory(full,
                    key: const ValueKey('quick-full-image'),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    scale: .05,
                    cacheWidth: width,
                    frameBuilder: (context, child, frame, sync) =>
                        AnimatedOpacity(opacity: frame == null && !sync ? 0 : 1, duration: fade, child: child),
                    errorBuilder: (_, _, _) => hasThumb ? const SizedBox.shrink() : failed);
            if (!hasThumb) {
              return big ??
                  (f.hasError || f.data != null
                      ? failed
                      : const SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator())));
            }
            final small = ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Image.memory(thumb, fit: BoxFit.contain, gaplessPlayback: true, scale: .05),
            );
            // Still reading: a spinner over the blurred thumbnail (owner 2026-10-30).
            final waiting = f.connectionState != ConnectionState.done;
            return Stack(alignment: Alignment.center, children: [
              small,
              if (big != null) Positioned.fill(child: big),
              if (waiting) const Positioned.fill(child: LoadingSpinner()),
            ]);
          },
        );
      },
    );
  }

  Widget _video() {
    final l = AppLocalizations.of(context);
    final p = _player;
    final v = p?.value;
    final debug = QuickLook.debugVideo;
    if (_failed) {
      return SizedBox(
        width: 260,
        height: 160,
        child: Center(child: Text(l.videoFailed, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white))),
      );
    }
    final still = debug ??
        FutureBuilder<Uint8List>(
          future: _thumb,
          builder: (context, snap) => snap.hasData && snap.data!.isNotEmpty
              ? Image.memory(snap.data!, fit: BoxFit.contain, gaplessPlayback: true, scale: .05)
              : const SizedBox(width: 260, height: 180, child: ColoredBox(color: Colors.black)),
        );
    final ready = v != null && v.isInitialized;
    final playing = v?.isPlaying ?? false;
    // Being decrypted for the player: the still, with a ring (the copy has no progress).
    final opening = _playback != null && !ready;
    final total = v?.duration.inMilliseconds ?? 0;
    final f = debug != null ? .33 : total == 0 ? 0.0 : (v!.position.inMilliseconds / total).clamp(0.0, 1.0);
    return GestureDetector(
      onTap: _canPlayVideo ? _togglePlay : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ready ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(p!)) : still,
          if (opening)
            Container(
              key: const ValueKey('quick-opening'),
              width: Ui.bar,
              height: Ui.bar,
              padding: const EdgeInsets.all(14),
              decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
              child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          else if (!playing && _canPlayVideo)
            Container(
              key: const ValueKey('quick-play'),
              width: Ui.bar,
              height: Ui.bar,
              decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34, semanticLabel: l.play),
            ),
          // Where the video is, a thin line along the bottom of the box.
          if (ready || debug != null)
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

  /// A card the width of the box: notes and text on paper, the rest on the card colour.
  Widget _card(BoxConstraints box, Widget child, {bool paper = false, EdgeInsets? padding}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = paper ? (dark ? const Color(0xFF232220) : const Color(0xFFFFFDF7)) : Theme.of(context).cardColor;
    return Container(
      width: box.maxWidth,
      color: color,
      padding: padding ?? const EdgeInsets.fromLTRB(22, 20, 22, 0),
      child: child,
    );
  }

  /// The first lines, cut by the box and fading out at its bottom; not selectable here
  /// (Open shows the whole text). A note's boxes and links take taps ([interactive]).
  Widget _lines(BoxConstraints box, Widget text, {bool interactive = false}) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: 200, maxHeight: box.maxHeight - 20),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.white, Colors.white, Colors.transparent],
            stops: [0, r.height <= 40 ? 0 : (r.height - 40) / r.height, 1],
          ).createShader(r),
          child: IgnorePointer(
            ignoring: !interactive,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 36),
              child: text,
            ),
          ),
        ),
      );

  static String _head(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final cut = lines.length > _maxLines ? lines.sublist(0, _maxLines).join('\n') : text;
    return cut.length > 4000 ? cut.substring(0, 4000) : cut;
  }

  Widget _note(BoxConstraints box) {
    final full = _noteText;
    if (full == null) {
      return _card(
          box,
          paper: true,
          SizedBox(
              height: 200,
              child: Center(
                  child: _noteFailed ? Text(AppLocalizations.of(context).errorStorage) : const CircularProgressIndicator())));
    }
    // The title is the first line with something on it; the lines after it are drawn
    // as Markdown, and a box's line is counted in the whole text so a tick lands on it.
    final lines = full.split('\n');
    final first = lines.indexWhere((x) => x.trim().isNotEmpty);
    final head = first < 0 ? '' : lines[first].trim().replaceFirst(RegExp(r'^#{1,6} '), '');
    final after = first < 0 ? const <String>[] : lines.skip(first + 1).take(_maxLines - 1).toList();
    var rest = after.join('\n').trimRight();
    if (rest.length > 4000) rest = rest.substring(0, 4000);
    final ink = Theme.of(context).colorScheme.onSurface;
    final card = _card(
      box,
      paper: true,
      _lines(
        box,
        interactive: true,
        Column(
          key: const ValueKey('quick-note'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(head.isEmpty ? AppLocalizations.of(context).untitledNote : head,
                style: NoteTextController.title.copyWith(fontSize: CsType.title3, color: ink)),
            const SizedBox(height: 8),
            MarkdownLite(
                text: rest,
                fontSize: CsType.callout,
                selectable: false,
                // From Recently deleted the note is only read.
                onToggle: _trash ? null : (i) => _toggle(first + 1 + i),
                onLink: (url) => confirmOpenLink(context, url),
              )
          ],
        ),
      ),
    );
    return card;
  }

  Widget _text(BoxConstraints box) => _card(
        box,
        paper: true,
        FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, snap) {
            if (snap.hasError) return SizedBox(height: 200, child: Center(child: Text(AppLocalizations.of(context).errorStorage)));
            if (!snap.hasData) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            final text = _head(utf8.decode(snap.data!, allowMalformed: true));
            final kind = textKindOf(_item.name) ?? TextKind.prose;
            return _lines(
              box,
              MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                // The file's own reader, a little smaller, as a page seen from afar.
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: (box.maxWidth - 44) / .86,
                    child: switch (kind) {
                      TextKind.markdown => MarkdownLite(text: text),
                      TextKind.prose => ProseText(text: text),
                      TextKind.json => CodeCard(text: text),
                      TextKind.code => CodeCard(text: text),
                    },
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _audio(BoxConstraints box) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final p = _player;
    final ready = p != null && p.value.isInitialized;
    final total = ready ? p.value.duration : Duration(milliseconds: _item.durationMs?.toInt() ?? 0);
    final pos = ready ? p.value.position : Duration.zero;
    final playing = ready && p.value.isPlaying;
    final opening = _playback != null && !ready && !_failed;
    return _card(
      box,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 84,
            child: Stack(
              alignment: Alignment.center,
              children: [
                IconButton.filled(
                  key: const ValueKey('quick-audio-play'),
                  iconSize: 44,
                  style: IconButton.styleFrom(fixedSize: const Size.square(84)),
                  tooltip: playing ? l.pause : l.play,
                  onPressed: _failed ? null : _togglePlay,
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                if (opening)
                  const SizedBox.square(dimension: 84, child: CircularProgressIndicator(strokeWidth: 3)),
              ],
            ),
          ),
          const SizedBox(height: 22),
          if (ready)
            VideoProgressIndicator(p, allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                colors: VideoProgressColors(playedColor: primary, backgroundColor: c.soft))
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(value: 0, minHeight: 4, color: primary, backgroundColor: c.soft),
            ),
          const SizedBox(height: 4),
          if (_failed)
            Text(l.videoFailed, style: TextStyle(color: c.muted, fontSize: CsType.footnote))
          else
            Row(
              children: [
                Text(_clock(pos), style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()])),
                const Spacer(),
                Text(_clock(total), style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
        ],
      ),
    );
  }

  /// A file the app does not draw: its icon, its kind and its size.
  Widget _fileCard(BoxConstraints box) {
    final c = CsColors.of(context);
    final name = _item.name;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 6 ? name.substring(dot + 1).toUpperCase() : null;
    return _card(
      box,
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 28),
      Column(
        key: const ValueKey('quick-file'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(24)),
            child: Icon(fileIcon(_item), size: 54, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(height: 16),
          if (ext != null) Text(ext, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w800, letterSpacing: .5)),
          const SizedBox(height: 2),
          Text(fileSize(_item.sizeBytes), style: TextStyle(color: c.muted, fontSize: CsType.subhead)),
        ],
      ),
    );
  }

  Widget _pdf(BoxConstraints box) {
    final debug = QuickLook.debugPdfPage;
    if (debug != null) return debug;
    return FutureBuilder<ui.Image?>(
      future: _pdfPage,
      builder: (context, snap) {
        final img = snap.data;
        if (img == null) {
          return snap.connectionState == ConnectionState.waiting && _pdfPage != null
              ? SizedBox(width: box.maxWidth, height: 260, child: const Center(child: CircularProgressIndicator()))
              : _fileCard(box);
        }
        return AspectRatio(
          aspectRatio: img.width / img.height,
          child: RawImage(key: const ValueKey('quick-pdf'), image: img, fit: BoxFit.contain),
        );
      },
    );
  }

  bool get embedded => widget.onResult != null;

  /// Close with [result]: back to the page that opened it, or to the wide window's pane.
  void _done([String? result]) {
    final onResult = widget.onResult;
    if (onResult != null) {
      onResult(result);
    } else {
      Navigator.of(context).pop(result);
    }
  }

  /// ⋯: the item's menu over this view, which stays open.
  Future<void> _more(BuildContext button) async {
    final menu = widget.menu;
    if (menu == null) return _done(QuickLook.menuFor(_item.id));
    final fresh = await menu(button, _item);
    if (fresh != null && mounted) setState(() => _fresh = fresh);
  }

  @override
  Widget build(BuildContext context) => embedded
      ? LayoutBuilder(builder: (context, c) => _body(context, Size(c.maxWidth, c.maxHeight)))
      : _body(context, MediaQuery.sizeOf(context));

  Widget _body(BuildContext context, Size size) {
    final l = AppLocalizations.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final still = MediaQuery.disableAnimationsOf(context);
    final fade = Duration(milliseconds: still ? 0 : 220);
    // Big: the width less a margin, up to about two thirds of the height.
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    // The buttons take the vault bar's place and size exactly (owner 2026-10-25: a second
    // bar stacked over the vault's looked cluttered); the vault bar is taller with the +
    // in its middle.
    final barHeight = actionSide() == ActionSide.center ? Ui.bar + 8 : Ui.bar;
    final barBottom = safeBottom + Ui.edge;
    final bottomRoom = barBottom + barHeight;
    // Under the top bar (ViewerTopBar: 4 above a circle), with a little air.
    final topRoom = MediaQuery.paddingOf(context).top + 4 + Ui.action + 12;
    final box = embedded
        ? BoxConstraints(maxWidth: (size.width - 32).clamp(0, 720), maxHeight: (size.height - Ui.bar - 120).clamp(0, double.infinity))
        : BoxConstraints(maxWidth: (size.width - 32).clamp(0, 520), maxHeight: (size.height - bottomRoom) * .78);
    final c = CsColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final trash = widget.trash;

    final media = switch (_look) {
      _Look.photo || _Look.image => _photo(box, fade),
      _Look.video => _video(),
      _Look.note => _note(box),
      _Look.audio => _audio(box),
      _Look.pdf => _pdf(box),
      _Look.text => _text(box),
      _Look.file => _fileCard(box),
    };

    // Send and Open with wait while a copy is being handed out; Close never does.
    Widget tool(Key key, IconData icon, String tip, void Function(BuildContext) onTap, {Color? color, bool waits = false}) =>
        Builder(
          builder: (b) => IconButton(
            key: key,
            tooltip: tip,
            onPressed: waits && _busy ? null : () => onTap(b),
            iconSize: 28,
            style: IconButton.styleFrom(minimumSize: const Size(Ui.bar, Ui.bar)),
            icon: Icon(icon, color: color ?? Theme.of(context).colorScheme.onSurface),
          ),
        );

    final red = recordRed(context);
    // No ×: a tap beside the item or a swipe down puts it away (owner 2026-10-29).
    final tools = trash != null
        ? [
            // The same actions, icons and order as the long-press menu in Recently deleted.
            tool(const ValueKey('preview-restore'), Icons.restore_from_trash_rounded, l.restore, (_) async {
              if (await confirmRestore(context, count: 1, name: _title, held: trash.held)) {
                _done(QuickLook.restoreRequest);
              }
            }, color: restoreBlue),
            tool(const ValueKey('preview-info'), Icons.info_rounded, l.info,
                (_) => showItemInfo(context, _item, held: trash.held)),
            tool(const ValueKey('preview-purge'), Icons.delete_forever_rounded, l.deleteForGoodShort, (_) async {
              if (await confirmDeleteForGood(context, count: 1, name: _title, othersKeep: !trash.held)) {
                _done(QuickLook.purgeRequest);
              }
            }, color: red),
          ]
        : [
            // Share on the left, Info in the middle, Delete on the right, as in Photos
            // (owner 2026-10-29); the item opens by a tap on it.
            tool(const ValueKey('quick-send'), Icons.ios_share, l.sendOut, _send, waits: true),
            tool(const ValueKey('quick-item-info'), Icons.info_rounded, l.info, (_) => showItemInfo(context, _item)),
            tool(const ValueKey('quick-delete'), Icons.delete_rounded, l.delete, (_) => _delete(), color: red),
          ];

    final boxed = Container(
      key: const ValueKey('quick-look'),
      constraints: box,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 16))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(20), child: media),
    );
    // A tap on the item opens it (full screen, the editor, the file page); a video plays
    // and pauses here instead. Recently deleted only looks.
    final opens = trash == null && _look != _Look.video && !(_look == _Look.audio && _item.kind == ItemKind.audio);
    final shown = opens
        ? Builder(builder: (b) => GestureDetector(key: const ValueKey('quick-tap-open'), onTap: _busy ? null : () => _open(b), child: boxed))
        : boxed;

    final Widget titleBlock = SizedBox(
                  width: box.maxWidth,
                  child: Column(
                    children: [
                      // The name under every kind, photos and videos too, on one line
                      // ending in … when long (owner 2026-10-29); the date and size are in
                      // the tag above.
                      // Not under a note: its card starts with the same title.
                      if (_look != _Look.note)
                        Text(_title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600)),
                      if (trash != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          key: const ValueKey('preview-days'),
                          trash.held ? '${l.trashHeldLabel} · ${l.daysLeft(trash.daysLeft)}' : l.daysLeft(trash.daysLeft),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: CsType.footnote, color: c.muted),
                        ),
                      ],
                    ],
                  ),
                );
    // The date and size in a quiet tag centred above the item, the same for every kind
    // (owner 2026-10-27/28).
    final Widget infoTag = Container(
      key: const ValueKey('quick-info'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: dark ? .14 : .07),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(_info,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: CsType.footnote, color: c.muted, fontWeight: FontWeight.w500)),
    );
    // Below: the name (and in Recently deleted, the days left).
    final Widget below = titleBlock;
    // In a pane: the item, its name, and its buttons under it; nothing over the page.
    if (embedded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          children: [
            infoTag,
            const SizedBox(height: 12),
            Expanded(child: Center(child: shown)),
            const SizedBox(height: 14),
            titleBlock,
            const SizedBox(height: 10),
            ActionBar(inset: false, barKey: const ValueKey('quick-bar'), start: tools.first, actions: [tools[1]], end: tools.last),
          ],
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Stack(
      children: [
        // The page goes dark and soft behind, so only the item speaks; tap to close.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => _done(),
            // Light enough to see the page under it (owner 2026-10-25: it was nearly opaque).
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: ColoredBox(color: page.withValues(alpha: dark ? .55 : .45)),
            ),
          ),
        ),
        // The item in the middle of the room between the status bar and the buttons, as
        // much space above as below (owner 2026-10-25: centred on the whole screen it
        // looked high; resting on the buttons left a hole on top).
        Positioned(
          left: 0,
          right: 0,
          top: topRoom,
          bottom: bottomRoom,
          child: Center(
          child: GestureDetector(
            // Swipe down to put it away, as in Photos.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 300) _done();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: still
                      ? shown
                      : TweenAnimationBuilder<double>(
                          tween: Tween(begin: .92, end: 1),
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          builder: (context, s, child) => Transform.scale(scale: s, child: child),
                          child: shown,
                        ),
                ),
                const SizedBox(height: 14),
                below,
              ],
            ),
          ),
          ),
        ),
        // Back, the date and ⋯ on top, as over a photo (owner 2026-10-29: every preview
        // looks the same).
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: SafeArea(
            bottom: false,
            child: ViewerTopBar(
              back: BarIcon(
                  key: const ValueKey('quick-back'),
                  icon: Icons.arrow_back_ios_new_rounded,
                  tooltip: l.back,
                  onTap: (_) => _done()),
              more: trash != null ? null : BarIcon(key: const ValueKey('quick-more'), icon: Icons.more_horiz, tooltip: l.more, onTap: _more),
              center: infoTag,
            ),
          ),
        ),
        // The buttons where the vault bar is, the same glass, width and height, spread
        // evenly; the same for every kind of item.
        Positioned(
          left: 10,
          right: 10,
          bottom: barBottom,
          height: barHeight,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ActionBar(inset: false, barKey: const ValueKey('quick-bar'), start: tools.first, actions: [tools[1]], end: tools.last),
          ),
        ),
      ],
      ),
    );
  }
}
