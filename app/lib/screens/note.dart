import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';

/// A note: plain text, saved as you type (a moment after you stop), when you leave,
/// and before the vault locks, so locking never loses what was typed. The list shows
/// its first line. New notes start with the keyboard open.
class NoteScreen extends StatefulWidget {
  const NoteScreen({super.key, this.item});

  /// null for a new note.
  final rust.ItemInfo? item;

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
        _id = (await rust.addNote(title: _title(text), text: text, createdMs: DateTime.now().millisecondsSinceEpoch)).id;
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).errorStorage)));
    }
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
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.chevron_left), tooltip: l.done, onPressed: _saveAndLeave),
          actions: [
            TextButton(onPressed: _saving ? null : _saveAndLeave, child: Text(l.done)),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: TextField(
                    controller: _text,
                    autofocus: widget.item == null,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 17, height: 1.5),
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
      ),
    );
  }
}
