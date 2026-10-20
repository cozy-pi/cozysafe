import 'item_kind.dart';
import 'l10n/app_localizations.dart';

/// The name of a photo, video or recording made in the vault, or picked without a real
/// name: the kind and the moment, e.g. "Ảnh 20-10-2026 21.40.12.jpg". No "/" or ":", so
/// the name also works as a file name when the item is sent out.
String captureName(AppLocalizations l, String kind, DateTime at, String extension) {
  String two(int n) => n.toString().padLeft(2, '0');
  final when = '${two(at.day)}-${two(at.month)}-${at.year} ${two(at.hour)}.${two(at.minute)}.${two(at.second)}';
  final label = switch (kind) {
    ItemKind.video => l.captureVideo(when),
    ItemKind.audio => l.captureAudio(when),
    _ => l.capturePhoto(when),
  };
  return '$label$extension';
}

/// Names that pickers make up (temporary copies, UUIDs, bare numbers) say nothing; a name
/// a person or a camera gave ("IMG_4810.HEIC", "Hop-dong.pdf") is kept.
bool isMadeUpName(String name) {
  final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  return base.isEmpty ||
      base.startsWith('image_picker') ||
      base.startsWith('scaled_') ||
      RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-').hasMatch(base) ||
      RegExp(r'^[0-9]+$').hasMatch(base);
}
