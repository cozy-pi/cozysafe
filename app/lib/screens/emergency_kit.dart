import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../theme.dart';
import '../widgets/recovery_words.dart' show saveWordsFile;
import '../widgets/secret.dart';
import '../widgets/words_awake.dart';
import '../words_export.dart';
import 'common.dart';
import '../widgets/toast.dart';

/// The Secret Key, written for people. Shown once after the first vault (and later from
/// the vault menu). With `confirm`, the user must type its last 4 characters to go on,
/// so it has really been written down somewhere.
class EmergencyKitScreen extends StatefulWidget {
  const EmergencyKitScreen({super.key, required this.keyText, required this.confirm, this.onDone, this.onChange});

  final String keyText;
  final bool confirm;
  final VoidCallback? onDone;
  /// Settings only: change to a new Recovery Key (24 words; from an earlier key too).
  final VoidCallback? onChange;

  @override
  State<EmergencyKitScreen> createState() => _EmergencyKitScreenState();
}

class _EmergencyKitScreenState extends State<EmergencyKitScreen> with VaultLockAware {
  final _last = TextEditingController();

  /// 24 words for keys made since 2026-10-21; earlier keys are `CS1-XXXX-…`.
  late final List<String> _words = widget.keyText.contains(' ') ? widget.keyText.split(' ') : const [];
  bool get _isWords => _words.length == 24;
  /// To go on, one word the person must have written down (a random one, not always
  /// the last), or the last 4 characters of an earlier key.
  late final int _ask = Random.secure().nextInt(24);
  String get _tail => widget.keyText.replaceAll('-', '').substring(widget.keyText.replaceAll('-', '').length - 4);
  bool get _ok {
    if (!widget.confirm) return true;
    final typed = _last.text.trim().toLowerCase();
    if (!_isWords) return typed.toUpperCase() == _tail;
    final want = _words[_ask];
    return typed == want || (typed.length >= 4 && want.startsWith(typed));
  }

  /// For copying and saving: one numbered word per line.
  String get _plain => _isWords ? [for (final (i, w) in _words.indexed) '${i + 1}. $w'].join('\n') : widget.keyText;

  /// The word typed to go on is not kept while the vault is locked.
  @override
  void vaultLocking() => setState(_last.clear);

  @override
  void dispose() {
    _last.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    if (!wordsExport) return;
    final l = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: widget.keyText));
    LockGuard.copied(widget.keyText); // wiped from the clipboard after 60 s and on lock
    if (mounted) showToast(context, l.kitCopied, icon: Icons.check_rounded);
  }

  /// The words as a real .txt file (recovery_words.dart); an old CS1- key as plain text.
  Future<void> _share(BuildContext buttonContext) async {
    if (!wordsExport) return;
    if (_isWords) return saveWordsFile(buttonContext, _words);
    final l = AppLocalizations.of(context);
    final box = buttonContext.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      subject: l.kitTitle,
      text: '${l.kitTitle}\n\n$_plain\n\n${l.kitShareNote}',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: widget.confirm ? null : AppBar(),
      body: WordsAwake(
        child: FormColumn(
        children: [
          Text(l.kitTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_isWords ? l.kitLead : l.kitLeadLegacy, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.5)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: c.soft,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.border),
            ),
            child: SecretText(
              text: widget.keyText,
              builder: _isWords ? (context, shown) => WordGrid(words: _words, shown: shown) : null,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono'],
                fontSize: CsType.body,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                height: 1.6,
              ),
            ),
          ),
          if (wordsExport) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(onPressed: _copy, icon: const Icon(Icons.copy_rounded, size: 18), label: Text(l.kitCopy)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Builder(
                  builder: (b) => OutlinedButton.icon(
                    onPressed: () => _share(b),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: Text(l.wordsSave), // short: the long name wrapped on two lines
                  ),
                ),
              ),
            ],
          ),
          ],
          const SizedBox(height: 16),
          Material(
            color: c.warnBg,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(l.kitWarning, style: TextStyle(color: c.warnInk, fontSize: CsType.subhead, height: 1.45)),
            ),
          ),
          if (widget.onChange != null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('kit-change'),
              onPressed: widget.onChange,
              icon: const Icon(Icons.autorenew_rounded, size: 18),
              label: Text(_isWords ? l.changeKeyButton : l.changeKeyLegacy),
            ),
          ],
          if (widget.confirm) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _last,
              key: const ValueKey('kit-confirm'),
              maxLength: _isWords ? 8 : 4,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              textCapitalization: _isWords ? TextCapitalization.none : TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: _isWords ? l.kitConfirmWord(_ask + 1) : l.kitConfirmLabel,
                counterText: '',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _ok ? widget.onDone : null, child: Text(l.kitDone)),
          ],
        ],
        ),
      ),
    );
  }
}

/// The 24 words, numbered, three to a row like a hardware wallet's card; dots while
/// hidden (always the same, so the mask tells nothing).
class WordGrid extends StatelessWidget {
  const WordGrid({super.key, required this.words, required this.shown});
  final List<String> words;
  final bool shown;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return GridView.count(
      key: const ValueKey('recovery-words'),
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.9,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      children: [
        for (final (i, w) in words.indexed)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(9)),
            child: Row(children: [
              SizedBox(
                width: 22,
                child: Text('${i + 1}', style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              Expanded(
                child: Text(shown ? w : '•••••',
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w700, color: shown ? null : c.muted)),
              ),
            ]),
          ),
      ],
    );
  }
}
