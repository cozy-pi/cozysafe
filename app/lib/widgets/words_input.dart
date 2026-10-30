import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'secret.dart';

/// The Recovery Key's word list (BIP39 English, from the core), for checking each word
/// as it is typed and completing it from its first four letters.
abstract final class RecoveryWords {
  /// Tests and mockups put the list here (the core is not loaded there).
  static List<String> Function() load = rust.recoveryWordList;

  /// Whether 24 words make a key (their checksum holds); tests put a stand-in here.
  static bool Function(String words) makesKey = (w) => rust.parseSecretKey(text: w) != null;

  static List<String>? _list;
  static Set<String>? _set;
  static List<String> get list => _list ??= load();
  static Set<String> get _known => _set ??= list.toSet();

  /// The whole word [typed] stands for: itself, or the only word starting with its first
  /// four letters (every word is known by them); null when it is no word.
  static String? expand(String typed) {
    final t = typed.trim().toLowerCase();
    if (t.isEmpty) return null;
    if (_known.contains(t)) return t;
    if (t.length < 4) return null;
    final head = t.substring(0, 4);
    final hit = list.where((w) => w.startsWith(head)).toList();
    return hit.length == 1 && hit.first.startsWith(t) ? hit.first : null;
  }

  /// [typed] is a whole word that no other word starts with ("zoo", not "act"), so the
  /// next cell can take over without a space.
  static bool finished(String typed) {
    final w = expand(typed);
    return w != null && w == typed.trim().toLowerCase() && list.where((x) => x.startsWith(w)).length == 1;
  }

  /// The words in pasted text: a numbered list ("1. word", "1) word") or words with any
  /// spaces and line breaks; numbers and bullets left out.
  static List<String> fromText(String text) => [
        for (final t in wordsFromText(text).split(RegExp(r'\s+')))
          if (t.isNotEmpty && !RegExp(r'^[\d.)•\-–*]+$').hasMatch(t)) t.toLowerCase(),
      ];
}

/// The 24 words typed in, as a numbered grid like the one they were written from (owner
/// 2026-10-30): a word turns to dots once its cell is left, Show/Hide for the whole grid;
/// four letters are enough and the cell moves on by itself; a word not on the list is
/// marked at once; Paste spreads the 24 words over the cells and empties the clipboard.
///
/// [controller] gets the words joined by spaces, as the screens read them. With [only],
/// just those cells (0-based) can be typed in, the others stay dots: four of the words
/// asked back. [accept] says whether a cell's word is right; by default, any word on the
/// list.
class WordsInput extends StatefulWidget {
  const WordsInput({
    super.key,
    this.controller,
    this.only,
    this.accept,
    this.onCells,
    this.enabled = true,
    this.paste = true,
  });

  final TextEditingController? controller;
  final List<int>? only;
  final bool Function(int index, String word)? accept;
  final ValueChanged<List<String>>? onCells;
  final bool enabled;
  final bool paste;

  static const count = 24;

  @override
  State<WordsInput> createState() => _WordsInputState();
}

class _WordsInputState extends State<WordsInput> with WidgetsBindingObserver, VaultLockAware {
  static const _showFor = Duration(seconds: 30);
  final _cells = List.generate(WordsInput.count, (_) => TextEditingController());
  final _focus = List.generate(WordsInput.count, (_) => FocusNode());
  bool _shown = false;
  Timer? _hide;
  /// Each cell's length before the last change: four letters complete a word only while
  /// typing forward, not while deleting back.
  final _was = List.filled(WordsInput.count, 0);

  bool _open(int i) => widget.only?.contains(i) ?? true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final f in _focus) {
      f.addListener(_focusChanged);
    }
    final start = widget.controller?.text ?? '';
    if (start.trim().isNotEmpty) _spread(RecoveryWords.fromText(start), 0, report: false);
  }

  @override
  void dispose() {
    _hide?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in _cells) {
      c.clear();
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _shown) _show(false);
  }

  /// The words typed are not kept while the vault is locked.
  @override
  void vaultLocking() {
    for (final c in _cells) {
      c.clear();
    }
    _show(false);
    _report();
  }

  void _show(bool on) {
    _hide?.cancel();
    if (on) _hide = Timer(_showFor, () => _show(false));
    if (mounted) setState(() => _shown = on);
  }

  /// A cell left: its word completed from four letters, then dots.
  void _focusChanged() {
    for (var i = 0; i < WordsInput.count; i++) {
      if (_focus[i].hasFocus) continue;
      final w = RecoveryWords.expand(_cells[i].text);
      if (w != null && w != _cells[i].text) _cells[i].text = w;
    }
    if (mounted) setState(() {});
  }

  void _next(int i) {
    for (var j = i + 1; j < WordsInput.count; j++) {
      if (_open(j)) return _focus[j].requestFocus();
    }
    _focus[i].unfocus();
  }

  /// Words from [from] on, into the open cells; the focus to the first empty one left.
  void _spread(List<String> words, int from, {bool report = true}) {
    var j = from;
    for (final w in words) {
      while (j < WordsInput.count && !_open(j)) {
        j++;
      }
      if (j >= WordsInput.count) break;
      _cells[j].text = RecoveryWords.expand(w) ?? w;
      _was[j] = _cells[j].text.length;
      j++;
    }
    if (report) {
      for (final f in _focus) {
        f.unfocus();
      }
      _report();
      setState(() {});
    }
  }

  void _changed(int i, String v) {
    final words = RecoveryWords.fromText(v);
    if (words.length > 1) {
      // Pasted into a cell: the whole list from the first cell, a few words from here.
      _cells[i].clear();
      _spread(words, words.length >= WordsInput.count ? 0 : i);
      Clipboard.setData(const ClipboardData(text: ''));
      return;
    }
    if (RegExp(r'\s$').hasMatch(v) && words.length == 1) {
      _cells[i].text = RecoveryWords.expand(words.first) ?? words.first;
      _next(i);
    } else if (words.length == 1 && v.length > _was[i]) {
      final t = words.first;
      final w = RecoveryWords.expand(t);
      if (w != null && (t.length >= 4 || RecoveryWords.finished(t))) {
        if (w != t) _cells[i].text = w;
        _next(i);
      }
    }
    _was[i] = _cells[i].text.length;
    _report();
    setState(() {});
  }

  Future<void> _pasteAll() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    final words = RecoveryWords.fromText(text);
    if (words.isEmpty) return;
    await Clipboard.setData(const ClipboardData(text: ''));
    if (!mounted) return;
    _spread(words, 0);
  }

  void _report() {
    final cells = [for (final c in _cells) c.text.trim().toLowerCase()];
    final c = widget.controller;
    if (c != null) {
      final joined = cells.where((w) => w.isNotEmpty).join(' ');
      if (c.text != joined) c.text = joined;
    }
    widget.onCells?.call(cells);
  }

  /// Every word typed and on the list, yet no key: one is wrong or out of place (the
  /// last word carries a checksum of the others).
  bool get _noKey {
    if (widget.only != null || widget.accept != null) return false;
    for (var i = 0; i < WordsInput.count; i++) {
      if (_focus[i].hasFocus || _cells[i].text.trim().isEmpty || !_good(i)) return false;
    }
    return !RecoveryWords.makesKey(_cells.map((c) => c.text.trim().toLowerCase()).join(' '));
  }

  bool _good(int i) {
    final w = _cells[i].text.trim().toLowerCase();
    return widget.accept?.call(i, w) ?? RecoveryWords.expand(w) != null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          if (widget.paste)
            TextButton.icon(
              key: const ValueKey('words-paste'),
              onPressed: widget.enabled ? _pasteAll : null,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: Text(l.modePaste),
            ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('words-show'),
            onPressed: () => _show(!_shown),
            icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
            label: Text(_shown ? l.secretHide : l.secretShow),
          ),
        ]),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (context, box) {
          const gap = 6.0;
          final w = (box.maxWidth - gap * 2) / 3;
          return Wrap(
            key: const ValueKey('words-input'),
            spacing: gap,
            runSpacing: gap,
            children: [for (var i = 0; i < WordsInput.count; i++) SizedBox(width: w, child: _cell(context, l, i))],
          );
        }),
        if (_noKey)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(l.wordsNoKey,
                key: const ValueKey('words-no-key'),
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, AppLocalizations l, int i) {
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    final open = _open(i) && widget.enabled;
    final focused = _focus[i].hasFocus;
    final text = _cells[i].text.trim();
    final masked = text.isNotEmpty && !focused && !_shown;
    final bad = text.isNotEmpty && !focused && !_good(i);
    final ok = text.isNotEmpty && !focused && !bad;
    final word = TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface);
    return Container(
      key: ValueKey('words-cell-$i'),
      height: 42,
      padding: const EdgeInsets.only(left: 8, right: 6),
      decoration: BoxDecoration(
        color: _open(i) ? theme.cardColor : c.soft,
        borderRadius: BorderRadius.circular(9),
        // A word not on the list in the system red (the theme's errors are ink, which
        // would read as the cell being typed in); a cell asked back stands out from the dots.
        border: Border.all(
          width: focused || bad || (widget.only != null && _open(i)) ? 1.6 : 1,
          color: bad
              ? recordRed(context)
              : focused
                  ? theme.colorScheme.primary
                  : widget.only != null && _open(i)
                      ? c.muted
                      : c.border,
        ),
      ),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: Text('${i + 1}', style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        Expanded(
          child: !_open(i)
              ? Text('•••••', style: word.copyWith(color: c.muted))
              : Stack(alignment: Alignment.centerLeft, children: [
                  Semantics(
                    label: l.wordNumber(i + 1),
                    child: TextField(
                      key: ValueKey('words-field-$i'),
                      controller: _cells[i],
                      focusNode: _focus[i],
                      enabled: open,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      keyboardType: TextInputType.visiblePassword, // no suggestion bar, no learning
                      textCapitalization: TextCapitalization.none,
                      textInputAction: TextInputAction.next,
                      // Not one line: a single-line field drops the line breaks of a pasted
                      // list ("bounce2. announce"); every word ends up in its own cell anyway.
                      maxLines: null,
                      showCursor: !masked,
                      style: masked ? word.copyWith(color: Colors.transparent) : word,
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                      onChanged: (v) => _changed(i, v),
                      onSubmitted: (_) {
                        final w = RecoveryWords.expand(_cells[i].text);
                        if (w != null) _cells[i].text = w;
                        _report();
                        _next(i);
                      },
                    ),
                  ),
                  if (masked) IgnorePointer(child: Text('•••••', style: word.copyWith(color: c.muted))),
                ]),
        ),
        if (ok) Icon(Icons.check_rounded, size: 15, color: c.muted),
      ]),
    );
  }
}

/// Where a Recovery Key is typed back (restore, joining from Drive, the check in
/// Settings): the 24-word grid, or one field for a key made before the words
/// (`CS1-…`, 2026-10-21), behind a quiet link.
class RecoveryKeyInput extends StatefulWidget {
  const RecoveryKeyInput({super.key, required this.controller, required this.onChanged, this.enabled = true});
  final TextEditingController controller;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  State<RecoveryKeyInput> createState() => _RecoveryKeyInputState();
}

class _RecoveryKeyInputState extends State<RecoveryKeyInput> {
  late bool _legacy = widget.controller.text.trim().toUpperCase().startsWith('CS1');

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_legacy)
          SecretField(
            key: const ValueKey('legacy-key'),
            controller: widget.controller,
            enabled: widget.enabled,
            capitalization: TextCapitalization.characters,
            paste: true,
            label: l.secretKeyLabel,
            onChanged: (_) => widget.onChanged(),
          )
        else
          WordsInput(controller: widget.controller, enabled: widget.enabled, onCells: (_) => widget.onChanged()),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('words-legacy-switch'),
            onPressed: widget.enabled
                ? () {
                    widget.controller.clear();
                    setState(() => _legacy = !_legacy);
                    widget.onChanged();
                  }
                : null,
            child: Text(_legacy ? l.wordsUseGrid : l.wordsUseLegacy),
          ),
        ),
      ],
    );
  }
}
