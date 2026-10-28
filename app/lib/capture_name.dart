/// The name of a photo, video or recording made in the vault, or picked without a real
/// name: only the moment, e.g. "20-10-2026 21.40.12.jpg" (owner 2026-10-28: no "Photo",
/// "Video", "Recording" before it; the icon and the section already say what it is). No
/// "/" or ":", so the name also works as a file name when the item is sent out.
String captureName(DateTime at, String extension) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.day)}-${two(at.month)}-${at.year} ${two(at.hour)}.${two(at.minute)}.${two(at.second)}$extension';
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
