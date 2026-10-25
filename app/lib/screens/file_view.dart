import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../item_bytes.dart';
import '../l10n/app_localizations.dart';
import '../debug_log.dart';
import '../lock_guard.dart';
import '../originals.dart' show PickedBatch, PickedCopy;
import '../widgets/vault_bar.dart';
import 'quick_look.dart';
import 'recorder.dart';
import 'video_view.dart';
import '../widgets/text_styles.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../prefs.dart';
import 'common.dart';
import '../capture_name.dart';
import '../item_kind.dart';
import '../widgets/toast.dart';

/// Icon for an item kind / type.
IconData fileIcon(rust.ItemInfo item) {
  if (item.kind == ItemKind.note) return Icons.edit_note_rounded;
  if (item.kind == ItemKind.video) return Icons.movie_outlined;
  final m = item.mime;
  if (m == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (m.startsWith('image/')) return Icons.image_outlined;
  if (m.startsWith('video/')) return Icons.movie_outlined;
  if (m.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (m.contains('zip') || m.contains('compressed')) return Icons.folder_zip_outlined;
  return Icons.insert_drive_file_outlined;
}

String fileSize(BigInt bytes) {
  final b = bytes.toDouble();
  if (b < 1024) return '$bytes B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

const _mimeByExt = {
  'pdf': 'application/pdf', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'heic': 'image/heic',
  'heif': 'image/heif', 'webp': 'image/webp', 'gif': 'image/gif', 'mp4': 'video/mp4', 'mov': 'video/quicktime',
  'm4v': 'video/mp4', 'avi': 'video/x-msvideo', 'mkv': 'video/x-matroska', '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'txt': 'text/plain', 'zip': 'application/zip',
  'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
};

/// How a text file is shown in the app (docs/ui.md, design language).
enum TextKind { prose, markdown, json, code }

/// Text files the app reads itself, by extension (reviewed 2026-10-21). Keys and
/// certificates (pem, key, pub, crt, asc) are here on purpose: people keep them in a
/// vault, and they are plain text. Binary look-alikes (rtf, docx, plist) are not.
const _textKinds = <String, TextKind>{
  // Prose: like a page.
  'txt': TextKind.prose, 'text': TextKind.prose, 'log': TextKind.prose, 'nfo': TextKind.prose,
  'srt': TextKind.prose, 'vtt': TextKind.prose, 'rst': TextKind.prose, 'adoc': TextKind.prose,
  'org': TextKind.prose, 'tex': TextKind.prose, 'eml': TextKind.prose,
  // Markdown: drawn.
  'md': TextKind.markdown, 'markdown': TextKind.markdown,
  // JSON: laid out and highlighted.
  'json': TextKind.json, 'geojson': TextKind.json, 'webmanifest': TextKind.json,
  // Data, config, keys and code: fixed width in a card.
  'jsonl': TextKind.code, 'ndjson': TextKind.code, 'csv': TextKind.code, 'tsv': TextKind.code,
  'xml': TextKind.code, 'svg': TextKind.code, 'yaml': TextKind.code, 'yml': TextKind.code,
  'toml': TextKind.code, 'ini': TextKind.code, 'conf': TextKind.code, 'cfg': TextKind.code,
  'env': TextKind.code, 'properties': TextKind.code, 'gitignore': TextKind.code, 'editorconfig': TextKind.code,
  'ics': TextKind.code, 'vcf': TextKind.code, 'diff': TextKind.code, 'patch': TextKind.code,
  'pem': TextKind.code, 'key': TextKind.code, 'pub': TextKind.code, 'crt': TextKind.code,
  'cer': TextKind.code, 'csr': TextKind.code, 'asc': TextKind.code, 'gpg': TextKind.code,
  'html': TextKind.code, 'htm': TextKind.code, 'xhtml': TextKind.code, 'css': TextKind.code,
  'scss': TextKind.code, 'less': TextKind.code, 'js': TextKind.code, 'mjs': TextKind.code,
  'cjs': TextKind.code, 'jsx': TextKind.code, 'ts': TextKind.code, 'tsx': TextKind.code,
  'vue': TextKind.code, 'svelte': TextKind.code, 'py': TextKind.code, 'rb': TextKind.code,
  'php': TextKind.code, 'pl': TextKind.code, 'lua': TextKind.code, 'r': TextKind.code,
  'sh': TextKind.code, 'bash': TextKind.code, 'zsh': TextKind.code, 'fish': TextKind.code,
  'bat': TextKind.code, 'ps1': TextKind.code, 'sql': TextKind.code, 'graphql': TextKind.code,
  'proto': TextKind.code, 'dart': TextKind.code, 'rs': TextKind.code, 'go': TextKind.code,
  'java': TextKind.code, 'kt': TextKind.code, 'kts': TextKind.code, 'gradle': TextKind.code,
  'scala': TextKind.code, 'swift': TextKind.code, 'm': TextKind.code, 'mm': TextKind.code,
  'c': TextKind.code, 'h': TextKind.code, 'cc': TextKind.code, 'cpp': TextKind.code,
  'hpp': TextKind.code, 'cs': TextKind.code,
};

/// Files with no extension that are text by name.
const _textNames = {'readme', 'license', 'licence', 'changelog', 'makefile', 'dockerfile', 'authors', 'notice'};

/// How [name] is read as text inside the app; null when it is not a text file the app
/// knows (it can still be opened as text by choice, see [FileViewScreen]).
TextKind? textKindOf(String name) {
  final base = name.toLowerCase();
  final dot = base.lastIndexOf('.');
  if (dot < 0) return _textNames.contains(base) ? TextKind.prose : null;
  // ".gitignore", ".env": the part after the dot is the name.
  return _textKinds[base.substring(dot + 1)];
}

/// The extension in upper case for the header ("JSON"), or "TXT" for a name without one.
String textLabelOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? 'TXT' : name.substring(dot + 1).toUpperCase();
}

String mimeOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? 'application/octet-stream' : (_mimeByExt[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream');
}

/// A small preview for an image, made with the platform's own decoders (so HEIC from
/// an iPhone works too). null when the file is not an image this device can read.
const _media = MethodChannel('cozysafe/media');

/// A photo's thumbnail (shorter side 320 px). On phones the platform makes it: it reads
/// only what it needs of the picture and writes a JPEG, ~10× faster than decoding the
/// whole photo here (owner 2026-10-22: 191 photos took 30 s). Elsewhere, or if that fails,
/// Flutter's decoder.
Future<Uint8List?> imageThumbnail(String path, {void Function(String way)? way}) async {
  if (Device.iOS || Device.android) {
    try {
      final jpeg = await _media.invokeMethod<Uint8List>('thumbnail', {'path': path, 'shortSide': 320});
      if (jpeg != null && jpeg.isNotEmpty) {
        way?.call('system');
        return jpeg;
      }
    } catch (_) {}
  }
  way?.call('flutter');
  try {
    final codec = await ui.instantiateImageCodecFromBuffer(
      await ui.ImmutableBuffer.fromFilePath(path),
      targetWidth: 320,
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    return png?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// A still from a video for the library square, made by the platform. Null when the
/// platform can't (some desktops): the square then shows a plain dark tile.
Future<Uint8List?> videoThumbnail(String path) async {
  try {
    return await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: path,
      width: 320,
      height: 320,
      format: 'jpeg',
      quality: 80,
    );
  } catch (_) {
    return null;
  }
}

/// A video's length in milliseconds, read by the platform player.
Future<int?> videoLength(String path) async {
  if (!(Device.iOS || Device.android || Device.macOS)) return null;
  final p = VideoPlayerController.file(File(path));
  try {
    await p.initialize();
    return p.value.duration.inMilliseconds;
  } catch (_) {
    return null;
  } finally {
    await p.dispose();
  }
}

/// Timings of the last import, for the Debug page (owner 2026-10-22: measure on the
/// phone before making it faster). Numbers only, in memory only: no names, nothing kept.
abstract final class ImportStats {
  static int? items;
  static int pickMs = 0;
  /// Sum of the platform's copy times, and when the first file was ready.
  static int copyMs = 0;
  static int? firstMs;
  static int thumbnailMs = 0;
  static int vaultMs = 0;
  static int totalMs = 0;
}

/// Bring files from outside into the open vault. Copies that pickers left in this app's
/// temp folder are deleted once encrypted; files picked in place (desktop) are left alone.
Future<List<rust.ItemInfo>> importFiles(
  List<XFile> files, {
  required bool photos,
  void Function(int done, int total)? progress,
  bool Function()? cancelled,
  /// Name for a photo or video whose picked name is made up ([isMadeUpName]).
  String Function(String kind, String extension)? mediaName,
}) async {
  final added = await importPicked(
    PickedBatch(files.length, Stream.fromIterable([for (final f in files) PickedCopy(f, null, 0)])),
    photos: photos,
    progress: progress,
    cancelled: cancelled,
    mediaName: mediaName,
  );
  return [for (final a in added) a.$1];
}

/// [importFiles] for a pick whose files arrive one by one: each is encrypted as soon as
/// it is there, while the platform is still copying the next ones. Gives each added item
/// with where it came from.
Future<List<(rust.ItemInfo, String?)>> importPicked(
  PickedBatch batch, {
  required bool photos,
  void Function(int done, int total)? progress,
  bool Function()? cancelled,
  String Function(String kind, String extension)? mediaName,
}) async {
  final tmp = (await getTemporaryDirectory()).path;
  final added = <(rust.ItemInfo, String?)>[];
  final total = Stopwatch()..start();
  ImportStats.items = batch.count;
  ImportStats.copyMs = 0;
  ImportStats.thumbnailMs = 0;
  ImportStats.vaultMs = 0;
  ImportStats.firstMs = null;
  DebugLog.add('import ${batch.count} files: picker closed after ${ImportStats.pickMs} ms');
  final inbox = _Inbox(batch.files);
  // Three at a time: while one is being encrypted (the vault takes one at a time) the
  // next ones get their thumbnails made on other cores.
  var n = 0;
  Future<void> worker(int w) async {
    for (PickedCopy? p; (p = await inbox.next()) != null;) {
      final i = ++n;
      ImportStats.firstMs ??= total.elapsedMilliseconds;
      ImportStats.copyMs += p!.copyMs;
      final items = <rust.ItemInfo>[];
      await importOne(p.file, tmp, photos: photos, cancelled: cancelled, mediaName: mediaName, added: items,
          tag: '#$i w$w copy ${p.copyMs} ms ·');
      for (final it in items) {
        added.add((it, p.origin));
      }
      progress?.call(added.length, batch.count);
    }
  }

  await Future.wait([for (var w = 1; w <= 3; w++) worker(w)]);
  ImportStats.totalMs = total.elapsedMilliseconds;
  DebugLog.add('import done: ${added.length}/${batch.count} in ${ImportStats.totalMs} ms · '
      'first file after ${ImportStats.firstMs ?? 0} ms · copy ${ImportStats.copyMs} ms (sum) · '
      'thumbnails ${ImportStats.thumbnailMs} ms (sum) · vault ${ImportStats.vaultMs} ms (sum, waits included)');
  return added;
}

/// Files from a stream, handed to whichever worker asks first.
class _Inbox {
  _Inbox(Stream<PickedCopy> files) {
    files.listen((f) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(f);
      } else {
        _ready.add(f);
      }
    }, onDone: () {
      _done = true;
      for (final w in _waiting) {
        w.complete(null);
      }
      _waiting.clear();
    });
  }

  final _ready = <PickedCopy>[];
  final _waiting = <Completer<PickedCopy?>>[];
  var _done = false;

  Future<PickedCopy?> next() {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    if (_done) return Future.value(null);
    final c = Completer<PickedCopy?>();
    _waiting.add(c);
    return c.future;
  }
}

/// One file of [importFiles]: thumbnail, encrypt, add; the picker's copy is deleted.
Future<void> importOne(
  XFile f,
  String tmp, {
  required bool photos,
  required bool Function()? cancelled,
  required String Function(String kind, String extension)? mediaName,
  required List<rust.ItemInfo> added,
  String tag = '',
}) async {
  // Cancel keeps what is finished; the current file is never half added.
  if (cancelled?.call() ?? false) {
    if (f.path.startsWith(tmp)) {
      try {
        File(f.path).deleteSync();
      } catch (_) {}
    }
    return;
  }
  final mime = (f.mimeType?.isNotEmpty ?? false) ? f.mimeType! : mimeOf(f.name);
  final isImage = mime.startsWith('image/');
  final isVideo = mime.startsWith('video/');
  final dot = f.name.lastIndexOf('.');
  final name = (isImage || isVideo) && mediaName != null && isMadeUpName(f.name)
      ? mediaName(isVideo ? ItemKind.video : ItemKind.photo, dot < 0 ? '' : f.name.substring(dot).toLowerCase())
      : f.name;
  final watch = Stopwatch()..start();
  var way = isVideo ? 'video' : '';
  final thumbnail =
      isImage ? await imageThumbnail(f.path, way: (w) => way = w) : (isVideo ? await videoThumbnail(f.path) : null);
  final thumbMs = watch.elapsedMilliseconds;
  ImportStats.thumbnailMs += thumbMs;
  watch.reset();
  final item = await rust.addFile(
    path: f.path,
    kind: isVideo ? ItemKind.video : (isImage && (photos || thumbnail != null) ? ItemKind.photo : ItemKind.file),
    name: name,
    mime: mime,
    createdMs: nowMs(),
    thumbnail: thumbnail,
  );
  ImportStats.vaultMs += watch.elapsedMilliseconds;
  DebugLog.add('import $tag ${isVideo ? 'video' : isImage ? 'image' : 'file'} ${(item.sizeBytes ~/ BigInt.from(1024))} KB: '
      'thumbnail $way $thumbMs ms (${thumbnail == null ? 'none' : '${thumbnail.length ~/ 1024} KB'}) · vault ${watch.elapsedMilliseconds} ms');
  if (isVideo) {
    final ms = await videoLength(f.path);
    if (ms != null) await rust.setItemDuration(id: item.id, durationMs: i64(ms));
  }
  added.add(item);
  if (f.path.startsWith(tmp)) {
    try {
      File(f.path).deleteSync();
    } catch (_) {}
  }
}

Future<List<XFile>> pickPhotos() => ImagePicker().pickMultipleMedia(requestFullMetadata: false);

Future<List<XFile>> pickFiles() => openFiles();

/// A file in the vault: what it is, open it in another app, delete it.
class FileViewScreen extends StatefulWidget {
  const FileViewScreen({super.key, required this.item, required this.vaultId});

  final rust.ItemInfo item;
  /// The first share out of each vault asks once (docs/ui.md, review 5).
  final String vaultId;

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  bool _busy = false;

  /// Decrypt to a private temp file, hand it to the system (open with / save to), then
  /// delete the decrypted copy.
  Future<void> _open(BuildContext buttonContext) async {
    setState(() => _busy = true);
    await shareItem(context, widget.item, widget.vaultId, from: buttonContext);
    if (mounted) setState(() => _busy = false);
  }

  /// No question: it goes to Recently deleted and the vault offers Undo.
  Future<void> _delete() async {
    await rust.trashItem(id: widget.item.id, nowMs: nowMs());
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  bool get _pdf => widget.item.mime == 'application/pdf';

  /// ⋯: back to the vault, which shows this item's menu (Rename, Group, Info…).
  Widget _more(AppLocalizations l) => IconButton(
        key: const ValueKey('file-more'),
        tooltip: l.more,
        onPressed: _busy ? null : () => Navigator.of(context).pop(QuickLook.menuFor(widget.item.id)),
        icon: const Icon(Icons.more_horiz),
      );

  /// The same player card as a recording opened from the home page.
  Future<void> _play() async {
    final pick = await showRecording(context, widget.item);
    if (!mounted || pick == null) return;
    if (pick == 2) return _delete();
    if (pick == 1) setState(() => _busy = true);
    if (pick == 1) await shareItem(context, widget.item, widget.vaultId);
    if (mounted) setState(() => _busy = false);
  }

  /// Pictures up to this size are decrypted into memory and shown here.
  static const _imageInMemory = 60 << 20;
  Future<Uint8List>? _imageBytes;

  Widget _imageView(AppLocalizations l) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          actions: [
            Builder(
              builder: (b) => IconButton(
                  onPressed: _busy ? null : () => _open(b), icon: const Icon(Icons.ios_share), tooltip: l.sendOut),
            ),
            IconButton(onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: l.delete),
            _more(l),
          ],
        ),
        body: FutureBuilder<Uint8List>(
          future: _imageBytes ??= photoBytes(widget.item.id),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(l.videoFailed, style: const TextStyle(color: Colors.white)));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Colors.white));
            return InteractiveViewer(
              key: const ValueKey('file-image'),
              maxScale: 6,
              child: Center(
                child: Image.memory(snap.data!,
                    fit: BoxFit.contain,
                    cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 2).round(),
                    errorBuilder: (_, _, _) =>
                        Text(l.videoFailed, style: const TextStyle(color: Colors.white))),
              ),
            );
          },
        ),
      );

  /// "Open as text" on a file the app does not know: only the first part is decrypted.
  bool _asText = false;

  /// Shown at most this much; the rest goes out with Send.
  static const _textLimit = 1 << 20;

  /// Text files are read inside the app from the decrypted bytes in memory, like PDFs:
  /// no file is written. Markdown is drawn, JSON laid out and highlighted, code in a card,
  /// plain text like a page (docs/ui.md, design language).
  Widget _textView(AppLocalizations l) {
    final kind = textKindOf(widget.item.name) ?? TextKind.prose;
    final c = CsColors.of(context);
    final when = dateOf(widget.item.createdMs);
    final label = textLabelOf(widget.item.name);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.3)),
                  const SizedBox(height: 2),
                  Text('$label · ${fileSize(widget.item.sizeBytes)} · ${MaterialLocalizations.of(context).formatMediumDate(when)}',
                      style: TextStyle(color: c.muted, fontSize: 13.5)),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<Uint8List>(
                // Only the first part is decrypted: a 1 GB log never sits in memory.
                future: _bytes ??= rust.itemContentHead(id: widget.item.id, max: _textLimit + 1),
                builder: (context, snap) {
                  if (snap.hasError) return Center(child: Text(l.errorStorage));
                  final data = snap.data;
                  if (data == null) return const Center(child: CircularProgressIndicator());
                  final cut = data.length > _textLimit;
                  var text = utf8.decode(cut ? data.sublist(0, _textLimit) : data, allowMalformed: true);
                  if (kind == TextKind.json && !cut) {
                    try {
                      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
                    } catch (_) {} // not valid JSON: shown as it is
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
                    children: [
                      if (cut)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(l.textTruncated, style: TextStyle(color: c.muted, fontSize: 13)),
                        ),
                      switch (kind) {
                        TextKind.markdown => MarkdownLite(text: text),
                        TextKind.prose => ProseText(text: text),
                        TextKind.json => CodeCard(text: text, json: true),
                        TextKind.code => CodeCard(text: text),
                      },
                    ],
                  );
                },
              ),
            ),
            // Close where the camera's is, then the actions in glass.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, Ui.edge),
              child: Row(
                children: [
                  GlassButton(icon: Icons.close, tooltip: l.close, size: Ui.bar, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Glass(
                      radius: Ui.bar / 2,
                      child: SizedBox(
                        height: Ui.bar,
                        child: Row(
                          children: [
                            Expanded(
                              child: Builder(
                                builder: (b) => TextButton.icon(
                                  onPressed: _busy ? null : () => _open(b),
                                  style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                                  icon: const Icon(Icons.ios_share, size: 22),
                                  label: Text(l.sendOut, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextButton.icon(
                                onPressed: _busy ? null : _delete,
                                style: TextButton.styleFrom(foregroundColor: recordRed(context)),
                                icon: const Icon(Icons.delete_outline, size: 22),
                                label: Text(l.delete, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                              ),
                            ),
                            _more(l),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// PDFs are shown inside the app from the decrypted bytes in memory; no file is
  /// written. "Send out" stays available as the secondary action.
  Widget _pdfView(AppLocalizations l) => Scaffold(
        appBar: AppBar(
          title: Text(widget.item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            Builder(
              builder: (b) => IconButton(
                tooltip: l.sendOut,
                onPressed: _busy ? null : () => _open(b),
                icon: const Icon(Icons.ios_share),
              ),
            ),
            IconButton(tooltip: l.delete, onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline)),
            _more(l),
          ],
        ),
        // Up to [_pdfInMemory] the PDF is decrypted into memory only. A bigger one would not
        // fit on a small phone, so it is decrypted (in 64 KB chunks) to the app's private
        // playback folder, read from there, and deleted when this screen closes, on lock
        // and at every start, like videos.
        body: widget.item.sizeBytes > BigInt.from(_pdfInMemory)
            ? FutureBuilder<File>(
                future: _pdfCopy ??= readThroughLock(() => playbackCopy(widget.item, fallbackExt: '.pdf')),
                builder: (context, snap) {
                  if (snap.hasError) return Center(child: Text(l.errorStorage));
                  final f = snap.data;
                  if (f == null) return const Center(child: CircularProgressIndicator());
                  return PdfViewer.file(f.path);
                },
              )
            : FutureBuilder<Uint8List>(
                future: _bytes ??= itemBytes(widget.item.id),
                builder: (context, snap) {
                  if (snap.hasError) return Center(child: Text(l.errorStorage));
                  final data = snap.data;
                  if (data == null) return const Center(child: CircularProgressIndicator());
                  return PdfViewer.data(data, sourceName: widget.item.id);
                },
              ),
      );

  Future<Uint8List>? _bytes;
  Future<File>? _pdfCopy;
  static const _pdfInMemory = 40 << 20;

  @override
  void dispose() {
    _pdfCopy?.then((f) {
      try {
        f.deleteSync();
      } catch (_) {}
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_pdf) return _pdfView(l);
    if (_asText || textKindOf(widget.item.name) != null || widget.item.mime.startsWith('text/')) return _textView(l);
    // A picture added from Files (not through the photo picker) is a file, but it opens
    // as a picture (owner 2026-10-22). Very large ones go to "Open with".
    if (widget.item.mime.startsWith('image/') && widget.item.sizeBytes < BigInt.from(_imageInMemory)) {
      return _imageView(l);
    }
    final c = CsColors.of(context);
    final when = dateOf(widget.item.createdMs);
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: l.delete),
        _more(l),
      ]),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(22)),
                  child: Icon(fileIcon(widget.item), size: 48, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(height: 16),
                Text(widget.item.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${fileSize(widget.item.sizeBytes)} · ${MaterialLocalizations.of(context).formatMediumDate(when)}',
                    style: TextStyle(color: c.muted)),
                const SizedBox(height: 24),
                // Music or a recording added from Files plays right here.
                if (widget.item.mime.startsWith('audio/')) ...[
                  FilledButton.icon(
                    key: const ValueKey('file-play'),
                    onPressed: _busy ? null : _play,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(l.play),
                  ),
                  const SizedBox(height: 8),
                ],
                Builder(
                  builder: (b) => (widget.item.mime.startsWith('audio/') ? OutlinedButton.icon : FilledButton.icon)(
                    onPressed: _busy ? null : () => _open(b),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(l.openWith),
                  ),
                ),
                const SizedBox(height: 8),
                Text(l.openWithNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 13)),
                const SizedBox(height: 12),
                // Any file can be looked at as text inside the app, without leaving it.
                TextButton.icon(
                  key: const ValueKey('open-as-text'),
                  onPressed: () => setState(() => _asText = true),
                  icon: const Icon(Icons.notes_rounded),
                  label: Text(l.openAsText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Send any item out (owner 2026-10-21: every opened item can be shared): ask once per
/// vault (confirmShareOut), decrypt a copy into a private temporary folder in 64 KB
/// chunks, hand it to the share sheet, then delete the copy. The vault stays open while
/// the person is in the share sheet. [name] overrides the file name (a note: "Title.txt").
Future<void> shareItem(BuildContext context, rust.ItemInfo item, String vaultId, {String? name, BuildContext? from}) =>
    shareById(context, item.id, item.mime, name ?? item.name, vaultId, from: from);

/// [shareItem] by id, for an item whose details are not at hand (a note just saved).
Future<void> shareById(BuildContext context, String id, String mime, String name, String vaultId, {BuildContext? from}) async {
  final l = AppLocalizations.of(context);
  if (!await confirmShareOut(context, vaultId) || !context.mounted) return;
  final dir = await Directory((await getTemporaryDirectory()).path).createTemp('send');
  final file = name.replaceAll(RegExp(r'[/\\:]'), '-');
  final path = '${dir.path}${Platform.pathSeparator}${file.isEmpty ? 'file' : file}';
  LockGuard.allowAway();
  try {
    await rust.exportItem(id: id, path: path);
    final box = (from ?? context).findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: mime, name: file)],
      sharePositionOrigin: box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } on rust.VaultError catch (e) {
    if (context.mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
  } finally {
    LockGuard.clear();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Before the first decrypted copy leaves a vault: say what that means, once per
/// vault unless the person ticks "Don't ask again".
Future<bool> confirmShareOut(BuildContext context, String vaultId) async {
  final key = 'share-ok-$vaultId';
  if (Prefs.read(key) == '1') return true;
  final l = AppLocalizations.of(context);
  var again = false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.shareOutTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(l.shareOutBody, style: TextStyle(color: CsColors.of(context).muted, height: 1.45)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.dontAskAgain),
                value: again,
                onChanged: (v) => set(() => again = v),
              ),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.continueAction)),
              const SizedBox(height: 6),
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            ],
          ),
        ),
      ),
    ),
  );
  if (ok == true && again) Prefs.write(key, '1');
  return ok == true;
}
