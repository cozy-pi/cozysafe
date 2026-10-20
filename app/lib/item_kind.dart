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
}
