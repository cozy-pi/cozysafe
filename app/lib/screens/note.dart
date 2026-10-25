import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/format_bar.dart';
import '../widgets/toast.dart';
import '../widgets/text_styles.dart';
import 'file_view.dart' show shareById;
import '../widgets/vault_bar.dart';

/// A note's title for the list: its first line, at most 80 characters.
String noteTitle(String text) {
  final first = text.trimLeft().split('\n').first.trim();
  return first.length > 80 ? '${first.substring(0, 80)}…' : first;
}

/// A note: plain text, saved as you type (a moment after you stop), when you leave,
/// and before the vault locks, so locking never loses what was typed. The list shows
/// its first line. New notes start with the keyboard open.
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, this.item, this.tagId, this.vaultId = ''});

  /// The write started by a swipe back (null when the back button already saved).
  static Future<void>? lastSave;

  /// The note just moved to Recently deleted from inside it, for the vault's Undo.
  static String? lastDeleted;
  /// For Send (the first share out of each vault asks once).
  final String vaultId;

  /// null for a new note.
  final rust.ItemInfo? item;
  /// A new note carries this tag (the one open in the vault).
  final String? tagId;

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> with VaultLockAware {
  final _text = NoteTextController();
  /// The format bar shows over the keyboard while the text has the focus.
  final _focus = FocusNode();
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
    _focus.addListener(_focusChanged);
    final item = widget.item;
    _id = item?.id;
    if (item == null) {
      _ready = true;
    } else {
      _load(item.id);
    }
  }

  void _load(String id) {
    rust.itemContent(id: id).then((bytes) {
      if (!mounted || _ready) return;
      _loaded = _decode(bytes);
      _text.text = _loaded;
      setState(() => _ready = true);
    }, onError: (Object _) {}); // locked meanwhile: read again once it opens
  }

  /// The editor stays open under the lock with its text (written before the lock); one
  /// that had not finished reading the note reads it now.
  @override
  void vaultUnlocked() {
    final item = widget.item;
    if (!_ready && item != null) _load(item.id);
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
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  void _typed() {
    LockGuard.activity(); // typing on a phone is no touch, but it is activity
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 1200), () => _saveNow());
  }

  /// Write the text if it changed. One write at a time; an empty new note is not written.
  Future<void> _saveNow() async {
    _autosave?.cancel();
    // Read before waiting: a swipe back saves after the screen (and its controller) is gone.
    final text = _text.text;
    while (_writing != null) {
      await _writing;
    }
    if (!_ready || text == _loaded || (_id == null && text.trim().isEmpty)) return;
    final done = Completer<void>();
    _writing = done.future;
    try {
      final id = _id;
      if (id == null) {
        final id = (await rust.addNote(title: noteTitle(text), text: text, createdMs: nowMs())).id;
        _id = id;
        final tagId = widget.tagId;
        if (tagId != null) await rust.setTag(itemIds: [id], tagId: tagId, tagged: true);
      } else {
        await rust.updateNote(id: id, title: noteTitle(text), text: text);
      }
      _loaded = text;
      _wrote = true;
    } finally {
      _writing = null;
      done.complete();
    }
  }

  Future<void> _send() async {
    await _saveNow();
    final id = _id;
    if (id == null || !mounted) return;
    final title = noteTitle(_text.text);
    await shareById(context, id, 'text/plain', '${title.isEmpty ? 'note' : title}.txt', widget.vaultId);
  }

  /// Delete from inside the note (owner 2026-10-22): what was typed is saved first, so
  /// Undo brings back all of it.
  Future<void> _delete() async {
    if (_saving) return;
    final nav = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await _saveNow();
      final id = _id;
      if (id != null) {
        await rust.trashItem(id: id, nowMs: nowMs());
        NoteScreen.lastDeleted = id;
      }
      nav.pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, AppLocalizations.of(context).errorStorage, icon: Icons.error_outline_rounded);
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
    // Swipe back must work like the back button (owner 2026-10-21): blocking the pop to
    // save first also switched off the iOS edge swipe. The pop goes through and the
    // last words are written behind it; the list waits for [lastSave] before reloading.
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && result == null) NoteScreen.lastSave = _saveNow();
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
                    // A new note has nothing to delete yet: no red button beside Done
                    // (owner's testers 2026-10-24: afraid of losing what they typed).
                    if (widget.item != null)
                    GlassButton(
                      key: const ValueKey('note-delete'),
                      icon: null,
                      tooltip: AppLocalizations.of(context).delete,
                      onTap: _saving ? null : _delete,
                      child: Icon(Icons.delete_outline, color: recordRed(context), size: 22),
                    ),
                    if (widget.item != null) const SizedBox(width: 8),
                    // Send the note as a text file ("Title.txt"); saved first.
                    GlassButton(
                      key: const ValueKey('note-send'),
                      icon: Icons.ios_share,
                      tooltip: l.sendOut,
                      onTap: _saving ? null : _send,
                    ),
                    const SizedBox(width: 8),
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
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    contextMenuBuilder: _menu,
                    autofocus: widget.item == null,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: NoteTextController.body,
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
              // Bold, Italic, Heading, List, Checklist, Link over the keyboard: they type
              // Markdown marks, the preview draws them.
              if (_ready && _focus.hasFocus)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Center(child: NoteFormatBar(controller: _text)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
