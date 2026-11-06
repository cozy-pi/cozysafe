/// What an item is (docs/naming.md). Same values as `cs_vault::items::kind` in Rust;
/// compare against these, never against string literals.
abstract final class ItemKind {
  static const photo = 'photo';
  static const video = 'video';
  static const note = 'note';
  static const audio = 'audio';
  static const file = 'file';

  /// A group of items ("nhóm"): an item with a name and no content.
  static const tag = 'tag';

  /// Secure items (docs/adr/0009-secure-items.md): a login, a one-time code (2FA) on
  /// its own, a service's recovery codes. Their content is a JSON document.
  static const login = 'login';
  static const otp = 'otp';
  static const codes = 'codes';
  static const entries = [login, otp, codes];
  static bool isEntry(String kind) => entries.contains(kind);

  /// Every kind this version knows. Anything else comes from a newer version: it is
  /// listed (among the files) but opens nothing and offers only Delete.
  static const known = [photo, video, note, audio, file, tag, ...entries];
  static bool isKnown(String kind) => known.contains(kind);
}
