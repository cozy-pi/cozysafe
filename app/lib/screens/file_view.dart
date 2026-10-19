import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'common.dart';

/// Icon for an item kind / type.
IconData fileIcon(rust.ItemInfo item) {
  if (item.kind == 'note') return Icons.sticky_note_2_outlined;
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

/// Bring files from outside into the open vault. Copies that pickers left in this app's
/// temp folder are deleted once encrypted; files picked in place (desktop) are left alone.
Future<int> importFiles(List<XFile> files, {required bool photos}) async {
  final tmp = (await getTemporaryDirectory()).path;
  var n = 0;
  for (final f in files) {
    final name = f.name;
    final mime = (f.mimeType?.isNotEmpty ?? false) ? f.mimeType! : mimeOf(name);
    final isImage = mime.startsWith('image/');
    final thumb = isImage ? await imageThumbnail(f.path) : null;
    await rust.addFile(
      path: f.path,
      kind: photos || (isImage && thumb != null) ? 'photo' : 'file',
      name: name,
      mime: mime,
      createdMs: DateTime.now().millisecondsSinceEpoch,
      thumbnail: thumb,
    );
    n++;
    if (f.path.startsWith(tmp)) {
      try {
        File(f.path).deleteSync();
      } catch (_) {}
    }
  }
  return n;
}

Future<List<XFile>> pickPhotos() => ImagePicker().pickMultipleMedia(requestFullMetadata: false);

Future<List<XFile>> pickFiles() => openFiles();

/// A file in the vault: what it is, open it in another app, delete it.
class FileViewScreen extends StatefulWidget {
  const FileViewScreen({super.key, required this.item});

  final rust.ItemInfo item;

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  bool _busy = false;

  /// Decrypt to a private temp file, hand it to the system (open with / save to), then
  /// delete the decrypted copy.
  Future<void> _open(BuildContext buttonContext) async {
    final l = AppLocalizations.of(context);
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

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deleteItem),
        content: Text(l.deletePhotoBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await rust.deleteItem(id: widget.item.id);
    if (mounted) Navigator.of(context).pop(widget.item.id);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
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
