import 'dart:math';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../screens/emergency_kit.dart' show WordGrid;
import '../theme.dart';
import 'secret.dart';
import 'toast.dart';

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

/// The 24 words to write down (new vault, Recovery Key change): masked until Show, Copy
/// (wiped from the clipboard after 60 s and on lock) and Save, the warning, then [action].
class RecoveryWordsPanel extends StatelessWidget {
  const RecoveryWordsPanel({super.key, required this.words, required this.action});
  final List<String> words;
  final Widget action;

  Future<void> _copy(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final text = words.join(' ');
    await Clipboard.setData(ClipboardData(text: text));
    LockGuard.copied(text);
    if (context.mounted) showToast(context, l.kitCopied, icon: Icons.check_rounded);
  }

  Future<void> _save(BuildContext button) async {
    final l = AppLocalizations.of(button);
    final box = button.findRenderObject() as RenderBox?;
    final plain = [for (final (i, w) in words.indexed) '${i + 1}. $w'].join('\n');
    await SharePlus.instance.share(ShareParams(
      subject: l.kitTitle,
      text: '${l.kitTitle}\n\n$plain\n\n${l.kitShareNote}',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.border)),
          child: SecretText(
            text: words.join(' '),
            builder: (context, shown) => WordGrid(words: words, shown: shown),
            style: const TextStyle(fontSize: 15),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                  onPressed: () => _copy(context), icon: const Icon(Icons.copy_outlined, size: 18), label: Text(l.kitCopy)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Builder(
                builder: (b) => OutlinedButton.icon(
                  onPressed: () => _save(b),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(l.wordsSave),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Material(
          color: c.warnBg,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(l.kitWarning, style: TextStyle(color: c.warnInk, fontSize: 14, height: 1.45)),
          ),
        ),
        const SizedBox(height: 18),
        action,
      ],
    );
  }
}

/// Four of the 24 words typed back ([ask]: their positions). [action] gets whether all
/// four are right; [onShowAgain] goes back to the words.
class RecoveryWordsCheck extends StatefulWidget {
  const RecoveryWordsCheck({
    super.key,
    required this.words,
    required this.ask,
    required this.action,
    required this.onShowAgain,
  });
  final List<String> words;
  final List<int> ask;
  final Widget Function(bool ok) action;
  final VoidCallback onShowAgain;

  @override
  State<RecoveryWordsCheck> createState() => _RecoveryWordsCheckState();
}

class _RecoveryWordsCheckState extends State<RecoveryWordsCheck> {
  final _answers = List.generate(4, (_) => TextEditingController());

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
            textInputAction: i < 3 ? TextInputAction.next : TextInputAction.done,
            decoration: InputDecoration(
              labelText: l.wordNumber(widget.ask[i] + 1),
              suffixIcon: _answers[i].text.isNotEmpty && _ok(i) ? const Icon(Icons.check_rounded) : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        widget.action([for (var i = 0; i < 4; i++) _ok(i)].every((x) => x)),
        const SizedBox(height: 4),
        TextButton(onPressed: widget.onShowAgain, child: Text(l.wordsShowAgain)),
      ],
    );
  }
}
