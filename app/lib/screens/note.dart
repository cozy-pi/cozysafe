import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';

/// A note: plain text, saved when you leave the screen. The list shows its first line.
/// New notes start with the keyboard open. The text lives in memory only while open.
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

  @override
  void initState() {
    super.initState();
    final item = widget.item;
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
    _text.dispose();
    super.dispose();
  }

  static String _title(String text) {
    final first = text.trimLeft().split('\n').first.trim();
    return first.length > 80 ? '${first.substring(0, 80)}…' : first;
  }

  /// Save if anything changed; an empty new note is simply dropped.
  Future<void> _saveAndLeave() async {
    if (_saving) return;
    final text = _text.text;
    final nav = Navigator.of(context);
    if (!_ready || text == _loaded || (widget.item == null && text.trim().isEmpty)) {
      nav.pop(false);
      return;
    }
    setState(() => _saving = true);
    try {
      final item = widget.item;
      if (item == null) {
        await rust.addNote(title: _title(text), text: text, createdMs: DateTime.now().millisecondsSinceEpoch);
      } else {
        await rust.updateNote(id: item.id, title: _title(text), text: text);
      }
      nav.pop(true);
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
