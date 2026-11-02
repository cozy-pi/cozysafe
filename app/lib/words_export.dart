/// Whether the 24 words may leave the app: Copy, Save to a file, share, and Open file
/// where they are typed back. Chosen when the app is built, not in Settings:
///
///     flutter build … --dart-define=WORDS_EXPORT=false   # words on the screen only
///
/// On by default (owner 2026-11-02: copying 24 words by hand was too much; it was off
/// from 2026-10-30, "never written to disk"). The cost: the clipboard (Android keeps a
/// history on disk, iPhone hands it to a nearby Mac), the saved file and the share sheet
/// (Notes, Drive, a chat) put the words where the app cannot wipe them. The copy in the
/// iCloud Keychain / Google Block Store stays off either way ([KeyBackup]).
/// test/words_export_test.dart keeps every such path behind this switch.
const bool wordsExport = bool.fromEnvironment('WORDS_EXPORT', defaultValue: true);
