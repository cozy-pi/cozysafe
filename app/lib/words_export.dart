/// Whether the 24 words (and an earlier `CS1-` key) may leave the app: Copy, Save to a
/// file, share, and Open file when restoring. Chosen when the app is built, not in
/// Settings (owner 2026-10-30: "never written to disk, absolutely"):
///
///     flutter build … --dart-define=WORDS_EXPORT=true   # the earlier behaviour
///
/// Off by default: the words are only ever on the screen, to be written down by hand.
/// The clipboard (Android keeps a history on disk, iPhone hands it to a nearby Mac), a
/// file in the temporary folder and the share sheet (Notes, Drive, a chat) all put the
/// words where the app cannot wipe them. test/words_export_test.dart keeps every such
/// path behind this switch.
const bool wordsExport = bool.fromEnvironment('WORDS_EXPORT');
