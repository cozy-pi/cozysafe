import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'ask.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import '../entries/secure_clipboard.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../temp_files.dart';
import '../screens/emergency_kit.dart' show WordGrid;
import '../screens/top_secret_page.dart' show privateGreen;
import '../theme.dart';
import '../words_export.dart';
import 'secret.dart';
import 'toast.dart';
import 'words_awake.dart';
import 'words_input.dart';

/// The words as copied and saved: "1. word", one per line.
String numberedWords(List<String> words) => [for (final (i, w) in words.indexed) '${i + 1}. $w'].join('\n');

/// Four positions (0-based, in order) to ask back, never the same four as [not] (the
/// last check shown). Fixed in tests and mockups.
List<int> pickFourWords({bool fixed = false, List<int>? not}) {
  if (fixed && !kReleaseMode) return [2, 8, 14, 21];
  final r = Random.secure();
  while (true) {
    final picked = <int>{};
    while (picked.length < 4) {
      picked.add(r.nextInt(24));
    }
    final four = picked.toList()..sort();
    if (not == null || four.join(',') != not.join(',')) return four;
  }
}

/// The 24 words to write down (new vault, Recovery Key change): masked until Show, then
/// the warning; the screen stays on while they are copied out by hand ([WordsAwake]).
/// Copy (wiped from the clipboard after 60 s and on lock) and Save only in a build with
/// [wordsExport]. The screen pins its own button at the bottom.
/// How long the 24 words stay on the clipboard.
const wordsClipboardSeconds = 60;

class RecoveryWordsPanel extends StatelessWidget {
  const RecoveryWordsPanel({super.key, required this.words, this.cloud});
  final List<String> words;
  /// A third button beside Copy and Save to file: the copy in the iCloud Keychain /
  /// Google, on or off (making a vault; owner 2026-11-18: "one row of three").
  final Widget? cloud;

  Future<void> _copy(BuildContext context) async {
    if (!wordsExport) return;
    final l = AppLocalizations.of(context);
    // Numbered, one per line (owner 2026-11-03), as the file and the grid; Paste reads it back.
    final text = numberedWords(words);
    // As a password is copied (marked sensitive on Android: not in the preview, not kept
    // by keyboards; this device only and expiring by itself on iPhone and Mac), and for
    // 60 s whatever the setting. Wiped on lock as well.
    await SecureClipboard.copy(text, lasting: wordsClipboardSeconds);
    LockGuard.copied(text);
    if (context.mounted) showToast(context, l.kitCopied, icon: Icons.check_rounded);
  }

  Future<void> _save(BuildContext button) => saveWordsFile(button, words);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return WordsAwake(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(Ui.groupRadius), border: Border.all(color: c.border)),
          child: SecretText(
            text: words.join(' '),
            builder: (context, shown) => WordGrid(words: words, shown: shown),
            style: const TextStyle(fontSize: CsType.subhead),
          ),
        ),
        if (wordsExport || cloud != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              if (wordsExport) ...[
                Expanded(
                  child: WordsAction(icon: Icons.copy_rounded, label: l.kitCopy, onTap: () => _copy(context)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Builder(
                    builder: (b) => WordsAction(
                      key: const ValueKey('words-save'),
                      icon: Icons.ios_share,
                      label: l.wordsSave,
                      onTap: () => _save(b),
                    ),
                  ),
                ),
              ],
              if (cloud != null) ...[
                if (wordsExport) const SizedBox(width: 8),
                Expanded(child: cloud!),
              ],
            ],
          ),
        ],
        const SizedBox(height: 12),
        Material(
          color: c.warnBg,
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(l.kitWarning, style: TextStyle(color: c.warnInk, fontSize: CsType.subhead, height: 1.45)),
          ),
        ),
      ],
      ),
    );
  }
}

/// Four of the 24 words typed back ([ask]: their positions), in the same numbered grid
/// as the words were shown in, the other cells dots (owner 2026-10-30). [onValid] hears
/// whether all four are right, for the screen's button pinned at the bottom;
/// [onShowAgain] goes back to the words.
class RecoveryWordsCheck extends StatefulWidget {
  const RecoveryWordsCheck({
    super.key,
    required this.words,
    required this.ask,
    required this.onValid,
    this.onShowAgain,
  });
  final List<String> words;
  final List<int> ask;
  final ValueChanged<bool> onValid;
  final VoidCallback? onShowAgain;

  @override
  State<RecoveryWordsCheck> createState() => _RecoveryWordsCheckState();
}

class _RecoveryWordsCheckState extends State<RecoveryWordsCheck> {
  /// Every BIP39 word is known by its first four letters.
  bool _ok(int i, String typed) {
    final want = widget.words[i];
    return typed == want || (typed.length >= 4 && want.startsWith(typed));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WordsInput(
          key: const ValueKey('words-check'),
          only: widget.ask,
          paste: false,
          accept: _ok,
          onCells: (cells) => widget.onValid([for (final i in widget.ask) _ok(i, cells[i])].every((x) => x)),
        ),
        if (widget.onShowAgain != null) ...[
          const SizedBox(height: 6),
          TextButton(onPressed: widget.onShowAgain, child: Text(l.wordsShowAgain)),
        ],
      ],
    );
  }
}

/// The file name "Save to a file" suggests: ASCII, lower case, no spaces, the same in
/// every language (owner 2026-11-03: a technical name — no accents, no spaces, so it
/// survives USB sticks, old Windows and mail), dated so a later save does not clash.
String wordsFileName(DateTime day) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'cozysafe-recovery-key-${day.year}-${two(day.month)}-${two(day.day)}.txt';
}

/// "Save to a file" writes a real .txt file (owner 2026-10-29: it used to share plain
/// text, which is not a file): on a computer and on Android through the system's Save
/// dialog (Android's share sheet cannot save to the phone itself: a tester, 2026-11-17);
/// on iPhone a file in the app's temporary folder, handed to the share sheet (Save to
/// Files) and deleted right after, so the words do not stay on the phone outside the vault.
Future<void> saveWordsFile(BuildContext button, List<String> words) async {
  if (!wordsExport) return;
  final l = AppLocalizations.of(button);
  // Where to keep it, first (owner 2026-10-29): no password of its own on the file (a
  // third secret to forget), a reminder instead.
  if (await _askBeforeSaving(button) != true || !button.mounted) return;
  final plain = numberedWords(words);
  final text = '${l.kitTitle}\n\n$plain\n\n${l.kitShareNote}\n';
  final name = wordsFileName(DateTime.now());
  final box = button.findRenderObject() as RenderBox?;
  LockGuard.allowAway();
  try {
    if (Device.desktop) {
      final loc = await getSaveLocation(suggestedName: name);
      if (loc != null) await File(loc.path).writeAsString(text);
      return;
    }
    if (Device.android) {
      await _saveFile.invokeMethod<bool>('saveText', {'name': name, 'text': text});
      return;
    }
    final tmp = File('${(await privateTemp()).path}${Platform.pathSeparator}$name');
    await tmp.writeAsString(text);
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(tmp.path, mimeType: 'text/plain', name: name)],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  } finally {
    LockGuard.clear();
  }
}

const _saveFile = MethodChannel('cozysafe/savefile'); // MainActivity.kt

Future<bool?> _askBeforeSaving(BuildContext context) {
  final l = AppLocalizations.of(context);
  return askSheet<bool>(
    context,
    boxKey: const ValueKey('words-save-ask'),
    title: l.wordsSaveAskTitle,
    body: [l.wordsSaveAskBody],
    actions: [
      AskAction.main(l.wordsSaveAskGo, true, key: const ValueKey('words-save-go')),
      AskAction.quiet(l.cancel, false),
    ],
  );
}

/// One of the buttons under the 24 words: the icon over a short word, so three fit in a
/// row. [on]: a switch that is on (the cloud copy), filled.
class WordsAction extends StatelessWidget {
  const WordsAction({super.key, required this.icon, required this.label, required this.onTap, this.on});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool? on;

  @override
  Widget build(BuildContext context) {
    // On: the same outlined button, its icon and ring in the private green, a check on
    // the icon. A filled green slab outshone the main button (owner 2026-11-18).
    final lit = on == true;
    final child = Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 22, color: lit ? privateGreen : null),
      const SizedBox(height: 4),
      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
    ]);
    final button = OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.groupRadius)),
        minimumSize: const Size(0, 64),
        side: lit ? const BorderSide(color: privateGreen, width: 1.6) : null,
      ),
      child: child,
    );
    return on == null ? button : Semantics(toggled: on, child: button);
  }
}
