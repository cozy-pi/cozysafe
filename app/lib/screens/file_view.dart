import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import 'common.dart';

/// Icon for an item kind / type.
IconData fileIcon(rust.ItemInfo item) {
  if (item.kind == 'note') return Icons.sticky_note_2_outlined;
  if (item.kind == 'video') return Icons.movie_outlined;
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

String mimeOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? 'application/octet-stream' : (_mimeByExt[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream');
}

/// A small preview for an image, made with the platform's own decoders (so HEIC from
/// an iPhone works too). null when the file is not an image this device can read.
Future<Uint8List?> imageThumbnail(String path) async {
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
  if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) return null;
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

/// Bring files from outside into the open vault. Copies that pickers left in this app's
/// temp folder are deleted once encrypted; files picked in place (desktop) are left alone.
Future<List<rust.ItemInfo>> importFiles(
  List<XFile> files, {
  required bool photos,
  void Function(int done, int total)? progress,
  bool Function()? cancelled,
}) async {
  final tmp = (await getTemporaryDirectory()).path;
  final added = <rust.ItemInfo>[];
  for (final f in files) {
    // Cancel keeps what is finished; the current file is never half added.
    if (cancelled?.call() ?? false) {
      if (f.path.startsWith(tmp)) {
        try {
          File(f.path).deleteSync();
        } catch (_) {}
      }
      continue;
    }
    final name = f.name;
    final mime = (f.mimeType?.isNotEmpty ?? false) ? f.mimeType! : mimeOf(name);
    final isImage = mime.startsWith('image/');
    final isVideo = mime.startsWith('video/');
    final thumb = isImage ? await imageThumbnail(f.path) : (isVideo ? await videoThumbnail(f.path) : null);
    final item = await rust.addFile(
      path: f.path,
      kind: isVideo ? 'video' : (isImage && (photos || thumb != null) ? 'photo' : 'file'),
      name: name,
      mime: mime,
      createdMs: DateTime.now().millisecondsSinceEpoch,
      thumbnail: thumb,
    );
    if (isVideo) {
      final ms = await videoLength(f.path);
      if (ms != null) await rust.setItemDuration(id: item.id, durationMs: ms);
    }
    added.add(item);
    progress?.call(added.length, files.length);
    if (f.path.startsWith(tmp)) {
      try {
        File(f.path).deleteSync();
      } catch (_) {}
    }
  }
  return added;
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
    final l = AppLocalizations.of(context);
    if (!await confirmShareOut(context, widget.vaultId) || !mounted) return;
    setState(() => _busy = true);
    final dir = await Directory((await getTemporaryDirectory()).path).createTemp('open');
    final path = '${dir.path}${Platform.pathSeparator}${widget.item.name.isEmpty ? 'file' : widget.item.name}';
    try {
      await rust.exportItem(id: widget.item.id, path: path);
      if (!buttonContext.mounted) return;
      final box = buttonContext.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: widget.item.mime)],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } on rust.VaultError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(vaultErrorText(l, e))));
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  /// No question: it goes to Recently deleted and the vault offers Undo.
  Future<void> _delete() async {
    await rust.trashItem(id: widget.item.id, nowMs: DateTime.now().millisecondsSinceEpoch);
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  bool get _pdf => widget.item.mime == 'application/pdf';

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
          ],
        ),
        body: FutureBuilder<Uint8List>(
          future: _bytes ??= rust.itemContent(id: widget.item.id),
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text(l.errorStorage));
            final data = snap.data;
            if (data == null) return const Center(child: CircularProgressIndicator());
            return PdfViewer.data(data, sourceName: widget.item.id);
          },
        ),
      );

  Future<Uint8List>? _bytes;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (_pdf) return _pdfView(l);
    final c = CsColors.of(context);
    final when = DateTime.fromMillisecondsSinceEpoch(widget.item.createdMs);
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: l.delete),
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
                Text('${fileSize(widget.item.size)} · ${MaterialLocalizations.of(context).formatMediumDate(when)}',
                    style: TextStyle(color: c.muted)),
                const SizedBox(height: 24),
                Builder(
                  builder: (b) => FilledButton.icon(
                    onPressed: _busy ? null : () => _open(b),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(l.openWith),
                  ),
                ),
                const SizedBox(height: 8),
                Text(l.openWithNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
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
