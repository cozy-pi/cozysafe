import 'package:flutter/material.dart';

import '../theme.dart' show CsType;

/// A file's name on one line that always keeps its extension (owner 2026-10-31): a long
/// name is cut with "…" before the extension, "Ket qua xet nghiem mau….pdf", never at it.
/// A name without a short extension is cut at the end as before.
class FileNameText extends StatelessWidget {
  const FileNameText(this.name, {super.key, this.style});
  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || name.length - dot > 8) {
      return Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(name.substring(0, dot), maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style)),
        Text(name.substring(dot), maxLines: 1, softWrap: false, style: style),
      ],
    );
  }
}

/// [name] without its short extension, for a grid tile whose mark already shows it
/// (owner 2026-10-31).
String nameWithoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || name.length - dot > 8 ? name : name.substring(0, dot);
}

/// A small extension label ("HEIC", "MOV") on a picture's corner in a grid tile, where
/// the photo stands in place of the kind's mark.
class ExtensionTag extends StatelessWidget {
  const ExtensionTag(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || name.length - dot > 6) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), borderRadius: BorderRadius.circular(6)),
      child: Text(name.substring(dot + 1).toUpperCase(),
          style: const TextStyle(color: Colors.white, fontSize: CsType.caption2, fontWeight: FontWeight.w800, height: 1.15)),
    );
  }
}
