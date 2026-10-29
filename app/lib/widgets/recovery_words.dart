import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../temp_files.dart';
import '../screens/emergency_kit.dart' show WordGrid;
import '../theme.dart';
import '../words_export.dart';
import 'secret.dart';
import 'toast.dart';
import 'words_awake.dart';

/// Four positions (0-based, in order) to ask back. Fixed in tests and mockups.
List<int> pickFourWords({bool fixed = false}) {
  if (fixed && !kReleaseMode) return [2, 8, 14, 21];
  final r = Random.secure();
  final picked = <int>{};
  while (picked.length < 4) {
    picked.add(r.nextInt(24));
  }
  return picked.toList()..sort();
}

/// The 24 words to write down (new vault, Recovery Key change): masked until Show, then
/// the warning; the screen stays on while they are copied out by hand ([WordsAwake]).
/// Copy (wiped from the clipboard after 60 s and on lock) and Save only in a build with
/// [wordsExport]. The screen pins its own button at the bottom.
class RecoveryWordsPanel extends StatelessWidget {
  const RecoveryWordsPanel({super.key, required this.words});
  final List<String> words;

  Future<void> _copy(BuildContext context) async {
    if (!wordsExport) return;
    final l = AppLocalizations.of(context);
    final text = words.join(' ');
    await Clipboard.setData(ClipboardData(text: text));
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
          decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.border)),
          child: SecretText(
            text: words.join(' '),
            builder: (context, shown) => WordGrid(words: words, shown: shown),
            style: const TextStyle(fontSize: CsType.subhead),
          ),
        ),
        if (wordsExport) ...[
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                  onPressed: () => _copy(context), icon: const Icon(Icons.copy_rounded, size: 18), label: Text(l.kitCopy)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Builder(
                builder: (b) => OutlinedButton.icon(
                  key: const ValueKey('words-save'),
                  onPressed: () => _save(b),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(l.wordsSave),
                ),
              ),
            ),
          ],
        ),
        ],
        const SizedBox(height: 12),
        Material(
          color: c.warnBg,
          borderRadius: BorderRadius.circular(14),
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

/// Four of the 24 words typed back ([ask]: their positions). [onValid] hears whether all
/// four are right, for the screen's button pinned at the bottom; [onShowAgain] goes back
/// to the words.
class RecoveryWordsCheck extends StatefulWidget {
  const RecoveryWordsCheck({
    super.key,
    required this.words,
    required this.ask,
    required this.onValid,
    required this.onShowAgain,
  });
  final List<String> words;
  final List<int> ask;
  final ValueChanged<bool> onValid;
  final VoidCallback onShowAgain;

  @override
  State<RecoveryWordsCheck> createState() => _RecoveryWordsCheckState();
}

class _RecoveryWordsCheckState extends State<RecoveryWordsCheck> with VaultLockAware {
  final _answers = List.generate(4, (_) => TextEditingController());

  /// The words typed are not kept while the vault is locked.
  @override
  void vaultLocking() {
    setState(() {
      for (final c in _answers) {
        c.clear();
      }
    });
    widget.onValid(false);
  }

  @override
  void dispose() {
    for (final c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  /// Every BIP39 word is known by its first four letters.
  bool _ok(int i) {
    final want = widget.words[widget.ask[i]];
    final typed = _answers[i].text.trim().toLowerCase();
    return typed == want || (typed.length >= 4 && want.startsWith(typed));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 4; i++) ...[
          TextField(
            key: ValueKey('check-word-$i'),
            controller: _answers[i],
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            textInputAction: i < 3 ? TextInputAction.next : TextInputAction.done,
            decoration: InputDecoration(
              labelText: l.wordNumber(widget.ask[i] + 1),
              suffixIcon: _answers[i].text.isNotEmpty && _ok(i) ? const Icon(Icons.check_rounded) : null,
            ),
            onChanged: (_) {
              setState(() {});
              widget.onValid([for (var i = 0; i < 4; i++) _ok(i)].every((x) => x));
            },
          ),
          const SizedBox(height: 10),
        ],
        TextButton(onPressed: widget.onShowAgain, child: Text(l.wordsShowAgain)),
      ],
    );
  }
}

/// "Save to a file" writes a real .txt file (owner 2026-10-29: it used to share plain
/// text, which is not a file): on a computer through the Save dialog; on a phone a file
/// in the app's temporary folder, handed to the share sheet (Save to Files) and deleted
/// right after, so the words do not stay on the phone outside the vault.
Future<void> saveWordsFile(BuildContext button, List<String> words) async {
  if (!wordsExport) return;
  final l = AppLocalizations.of(button);
  // Where to keep it, first (owner 2026-10-29): no password of its own on the file (a
  // third secret to forget), a reminder instead.
  if (await _askBeforeSaving(button) != true || !button.mounted) return;
  final plain = [for (final (i, w) in words.indexed) '${i + 1}. $w'].join('\n');
  final text = '${l.kitTitle}\n\n$plain\n\n${l.kitShareNote}\n';
  final name = '${l.kitTitle} - Cozy Safe.txt'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
  final box = button.findRenderObject() as RenderBox?;
  LockGuard.allowAway();
  try {
    if (Device.desktop) {
      final loc = await getSaveLocation(suggestedName: name);
      if (loc != null) await File(loc.path).writeAsString(text);
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

Future<bool?> _askBeforeSaving(BuildContext context) {
  final l = AppLocalizations.of(context);
  return showModalBottomSheet<bool>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
        child: Column(
          key: const ValueKey('words-save-ask'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.wordsSaveAskTitle, style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(l.wordsSaveAskBody, style: TextStyle(color: CsColors.of(context).muted, height: 1.45)),
            const SizedBox(height: 16),
            FilledButton(
                key: const ValueKey('words-save-go'), onPressed: () => Navigator.pop(context, true), child: Text(l.wordsSaveAskGo)),
            const SizedBox(height: 6),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          ],
        ),
      ),
    ),
  );
}
