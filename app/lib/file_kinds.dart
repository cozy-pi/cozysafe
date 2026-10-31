import 'package:flutter/material.dart';

import 'theme.dart' show CsType;

/// What kind of file a name is, for its icon and colour wherever files are listed (owner
/// 2026-10-31: Files showed grey extensions while Recent showed colour). Chosen by the
/// extension, then the MIME type; the extension is only a label, nothing is opened.
enum FileKind {
  pdf(Icons.picture_as_pdf_rounded, Color(0xFFFF453A)),
  image(Icons.image_rounded, Color(0xFF0A84FF)),
  video(Icons.movie_rounded, Color(0xFFBF5AF2)),
  audio(Icons.audiotrack_rounded, Color(0xFFFF375F)),
  document(Icons.description_rounded, Color(0xFF2F6FEB)),
  sheet(Icons.table_chart_rounded, Color(0xFF1E9E57)),
  slides(Icons.slideshow_rounded, Color(0xFFFF7A1A)),
  archive(Icons.folder_zip_rounded, Color(0xFFB7791F)),
  text(Icons.article_rounded, Color(0xFF64748B)),
  code(Icons.code_rounded, Color(0xFF14A3A3)),
  key(Icons.key_rounded, Color(0xFFE0A100)),
  contact(Icons.contact_page_rounded, Color(0xFF32ADE6)),
  calendar(Icons.event_rounded, Color(0xFFFF6B6B)),
  book(Icons.menu_book_rounded, Color(0xFF8D6E63)),
  app(Icons.apps_rounded, Color(0xFF34C759)),
  other(Icons.insert_drive_file_rounded, Color(0xFF8E8E93));

  const FileKind(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const _byExt = <String, FileKind>{
  'pdf': FileKind.pdf,
  // Pictures.
  'jpg': FileKind.image, 'jpeg': FileKind.image, 'png': FileKind.image, 'heic': FileKind.image,
  'heif': FileKind.image, 'webp': FileKind.image, 'gif': FileKind.image, 'bmp': FileKind.image,
  'tif': FileKind.image, 'tiff': FileKind.image, 'avif': FileKind.image, 'dng': FileKind.image,
  'raw': FileKind.image, 'cr2': FileKind.image, 'nef': FileKind.image, 'arw': FileKind.image,
  'svg': FileKind.image, 'ico': FileKind.image, 'psd': FileKind.image,
  // Video.
  'mp4': FileKind.video, 'mov': FileKind.video, 'm4v': FileKind.video, 'avi': FileKind.video,
  'mkv': FileKind.video, '3gp': FileKind.video, 'webm': FileKind.video, 'wmv': FileKind.video,
  'flv': FileKind.video, 'mpg': FileKind.video, 'mpeg': FileKind.video,
  // Sound.
  'mp3': FileKind.audio, 'm4a': FileKind.audio, 'aac': FileKind.audio, 'wav': FileKind.audio,
  'flac': FileKind.audio, 'ogg': FileKind.audio, 'opus': FileKind.audio, 'aiff': FileKind.audio,
  'wma': FileKind.audio, 'amr': FileKind.audio,
  // Documents, sheets, slides.
  'doc': FileKind.document, 'docx': FileKind.document, 'odt': FileKind.document,
  'rtf': FileKind.document, 'pages': FileKind.document,
  'xls': FileKind.sheet, 'xlsx': FileKind.sheet, 'ods': FileKind.sheet, 'numbers': FileKind.sheet,
  'csv': FileKind.sheet, 'tsv': FileKind.sheet,
  'ppt': FileKind.slides, 'pptx': FileKind.slides, 'odp': FileKind.slides, 'key': FileKind.slides,
  // Archives.
  'zip': FileKind.archive, 'rar': FileKind.archive, '7z': FileKind.archive, 'tar': FileKind.archive,
  'gz': FileKind.archive, 'tgz': FileKind.archive, 'bz2': FileKind.archive, 'xz': FileKind.archive,
  'dmg': FileKind.archive, 'iso': FileKind.archive,
  // Text.
  'txt': FileKind.text, 'text': FileKind.text, 'md': FileKind.text, 'markdown': FileKind.text,
  'log': FileKind.text, 'rst': FileKind.text, 'srt': FileKind.text, 'vtt': FileKind.text,
  // Data and code.
  'json': FileKind.code, 'xml': FileKind.code, 'yaml': FileKind.code, 'yml': FileKind.code,
  'toml': FileKind.code, 'ini': FileKind.code, 'conf': FileKind.code, 'cfg': FileKind.code,
  'env': FileKind.code, 'html': FileKind.code, 'htm': FileKind.code, 'css': FileKind.code,
  'js': FileKind.code, 'ts': FileKind.code, 'py': FileKind.code, 'sh': FileKind.code,
  'sql': FileKind.code, 'dart': FileKind.code, 'rs': FileKind.code, 'go': FileKind.code,
  'java': FileKind.code, 'kt': FileKind.code, 'swift': FileKind.code, 'c': FileKind.code,
  'cpp': FileKind.code, 'h': FileKind.code, 'cs': FileKind.code, 'php': FileKind.code,
  'rb': FileKind.code,
  // Keys and certificates.
  'pem': FileKind.key, 'crt': FileKind.key, 'cer': FileKind.key, 'csr': FileKind.key,
  'pub': FileKind.key, 'asc': FileKind.key, 'gpg': FileKind.key, 'p12': FileKind.key,
  'pfx': FileKind.key, 'der': FileKind.key, 'kdbx': FileKind.key, 'ovpn': FileKind.key,
  // Contacts, calendars, books, apps.
  'vcf': FileKind.contact, 'ics': FileKind.calendar,
  'epub': FileKind.book, 'mobi': FileKind.book, 'azw3': FileKind.book, 'djvu': FileKind.book,
  'apk': FileKind.app, 'aab': FileKind.app, 'ipa': FileKind.app, 'exe': FileKind.app, 'msi': FileKind.app,
};

/// The kind of the file [name] (its extension), else of [mime].
FileKind fileKindOf(String name, String mime) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  final byExt = _byExt[ext];
  if (byExt != null) return byExt;
  if (mime == 'application/pdf') return FileKind.pdf;
  if (mime.startsWith('image/')) return FileKind.image;
  if (mime.startsWith('video/')) return FileKind.video;
  if (mime.startsWith('audio/')) return FileKind.audio;
  if (mime.startsWith('text/')) return FileKind.text;
  if (mime.contains('zip') || mime.contains('compressed')) return FileKind.archive;
  return FileKind.other;
}

/// A file's mark in a list or grid: its kind's icon in its colour on a light wash of it,
/// with the extension under the icon when it is short ("PDF", "HEIC").
class FileKindBadge extends StatelessWidget {
  const FileKindBadge({super.key, required this.name, required this.mime, this.width = 42, this.height = 48, this.big = false});
  final String name;
  final String mime;
  final double width;
  final double height;
  /// The grid's tile: a bigger icon.
  final bool big;

  @override
  Widget build(BuildContext context) {
    final kind = fileKindOf(name, mime);
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: ValueKey('file-kind-${kind.name}'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: dark ? .22 : .14),
        borderRadius: BorderRadius.circular(big ? 10 : 8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(kind.icon, color: kind.color, size: big ? 34 : 20),
          if (ext.isNotEmpty && ext.length <= 4)
            Text(ext,
                maxLines: 1,
                style: TextStyle(color: kind.color, fontSize: big ? CsType.footnote : CsType.caption2, fontWeight: FontWeight.w800, height: 1.15)),
        ],
      ),
    );
  }
}
