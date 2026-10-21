import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart';

/// A note: plain text, saved as you type (a moment after you stop), when you leave,
/// and before the vault locks, so locking never loses what was typed. The list shows
/// its first line. New notes start with the keyboard open.
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, this.item, this.tagId});

  /// null for a new note.
  final rust.ItemInfo? item;
  /// A new note carries this tag (the one open in the vault).
  final String? tagId;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  final _text = TextEditingController();
  String _loaded = '';
  bool _ready = false;
  bool _saving = false;
  /// Set once a new note has been written the first time.
  String? _id;
  Timer? _autosave;
  Future<void>? _writing;
  /// Something was written: the vault list needs reloading.
  bool _wrote = false;

  @override
  void initState() {
    super.initState();
    LockGuard.beforeLock = _saveNow;
    _text.addListener(_typed);
    final item = widget.item;
    _id = item?.id;
    if (item == null) {
      _ready = true;
    } else {
      rust.itemContent(id: item.id).then((bytes) {
        if (!mounted) return;
        _loaded = _decode(bytes);
        _text.text = _loaded;
        setState(() => _ready = true);
      });
    }
  }

  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  @override
  void dispose() {
    _autosave?.cancel();
    if (LockGuard.beforeLock == _saveNow) LockGuard.beforeLock = null;
    _text.dispose();
    super.dispose();
  }

  static String _title(String text) {
    final first = text.trimLeft().split('\n').first.trim();
    return first.length > 80 ? '${first.substring(0, 80)}…' : first;
  }

  void _typed() {
    LockGuard.activity(); // typing on a phone is no touch, but it is activity
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 1200), () => _saveNow());
  }

  /// Write the text if it changed. One write at a time; an empty new note is not written.
  Future<void> _saveNow() async {
    _autosave?.cancel();
    while (_writing != null) {
      await _writing;
    }
    final text = _text.text;
    if (!_ready || text == _loaded || (_id == null && text.trim().isEmpty)) return;
    final done = Completer<void>();
    _writing = done.future;
    try {
      final id = _id;
      if (id == null) {
        final id = (await rust.addNote(title: _title(text), text: text, createdMs: nowMs())).id;
        _id = id;
        final tagId = widget.tagId;
        if (tagId != null) await rust.setTag(itemIds: [id], tagId: tagId, tagged: true);
      } else {
        await rust.updateNote(id: id, title: _title(text), text: text);
      }
      _loaded = text;
      _wrote = true;
    } finally {
      _writing = null;
      done.complete();
    }
  }

  Future<void> _saveAndLeave() async {
    if (_saving) return;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await _saveNow();
      nav.pop(_wrote);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, AppLocalizations.of(context).errorStorage, icon: Icons.error_outline_rounded);
    }
  }

  /// The system menu, with Copy and Cut noting what left the vault so it can be
  /// cleared from the clipboard later.
  Widget _menu(BuildContext context, EditableTextState state) {
    final sel = _text.selection;
    final picked = sel.isValid && !sel.isCollapsed ? sel.textInside(_text.text) : null;
    final items = [
      for (final it in state.contextMenuButtonItems)
        if ((it.type == ContextMenuButtonType.copy || it.type == ContextMenuButtonType.cut) && picked != null)
          it.copyWith(onPressed: () {
            it.onPressed?.call();
            LockGuard.copied(picked);
          })
        else
          it,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _saveAndLeave();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // The vault's header language: a round glass back, and Done as the one filled
              // button, both Ui.circle tall (docs/ui.md, design language).
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                child: Row(
                  children: [
                    GlassButton(icon: Icons.arrow_back_ios_new, tooltip: l.back, onTap: _saving ? null : _saveAndLeave),
                    const Spacer(),
                    SizedBox(
                      height: Ui.circle,
                      child: FilledButton(
                        key: const ValueKey('note-done'),
                        onPressed: _saving ? null : _saveAndLeave,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, Ui.circle),
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(l.done, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
                  child: TextField(
                    controller: _text,
                    contextMenuBuilder: _menu,
                    autofocus: widget.item == null,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 18, height: 1.5),
                    decoration: InputDecoration(
                      hintText: l.noteHint,
                      hintStyle: TextStyle(color: c.muted),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
