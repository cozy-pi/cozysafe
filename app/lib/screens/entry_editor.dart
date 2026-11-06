import 'dart:async';

import 'package:flutter/material.dart';

import '../entries/entry.dart';
import '../entries/password_gen.dart';
import '../entries/totp.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/entry_row.dart';
import '../widgets/password_strength.dart';
import '../widgets/secret.dart';
import '../widgets/secure_menu.dart';
import '../widgets/toast.dart';
import 'common.dart';
import 'entry_page.dart' show entryHost;

/// Changing a secure item (ADR 0009), as a form; a new one is made step by step
/// ([EntryWizard], entry_steps.dart). Save stays off until there is something to keep.
/// Leaving with changes asks first; the vault locking saves what can be saved, as the
/// note editor does. Pops the saved item.
class EntryEditor extends StatefulWidget {
  const EntryEditor({super.key, this.item, this.entry, this.rev = '', this.tagId, this.kind = ItemKind.login, this.debugPassword});

  /// The item changed; null for a new one.
  final rust.ItemInfo? item;
  /// Its document as read; null for a new one.
  final Entry? entry;
  /// The content's revision as read ([rust.EntryDoc.rev]): a save is refused when the
  /// item changed since (sync), so that change is not overwritten.
  final String rev;
  /// A new item carries this group (the one open in the vault).
  final String? tagId;
  /// A new item's kind at first.
  final String kind;
  /// Mockups: a fixed password instead of a generated one.
  final String? debugPassword;

  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> with WidgetsBindingObserver, VaultLockAware {
  late final String _kind = widget.item?.kind ?? widget.kind;
  final _name = TextEditingController();
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _sites = TextEditingController();
  final _key = TextEditingController();
  final _issuer = TextEditingController();
  final _codes = TextEditingController();
  final _notes = TextEditingController();
  final _shown = ValueNotifier<bool>(false);
  final _keyShown = ValueNotifier<bool>(false);
  late final _all = [_name, _account, _password, _sites, _key, _issuer, _codes, _notes];
  /// The fields that hold secrets: emptied when the vault locks.
  late final _secrets = [_password, _key, _codes, _notes];

  /// The item once written (a new one is written once, then changed).
  rust.ItemInfo? _item;
  /// The document the fields are laid over: what this version does not show is kept.
  late Entry _base;
  late String _rev;
  /// The key field as loaded: the one-time code is replaced only when it changes.
  String _keyLoaded = '';
  /// What the fields held when last saved or loaded.
  String _saved = '';
  bool _busy = false;
  /// Emptied by a lock: filled again from the item once the vault opens.
  bool _cleared = false;
  Future<void>? _writing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _item = widget.item;
    _rev = widget.rev;
    _base = widget.entry ?? Entry(_kind);
    if (widget.entry != null) _fill(widget.item?.name ?? '');
    _saved = _snapshot;
    for (final c in _all) {
      c.addListener(_changed);
    }
    LockGuard.beforeLock = _saveOnLock;
  }

  void _fill(String name) {
    final e = _base;
    _name.text = name;
    _account.text = e.account;
    _password.text = e.password;
    _sites.text = e.urls.join('\n');
    _key.text = _keyLoaded = e.totp?.secret ?? '';
    _issuer.text = e.issuer;
    _codes.text = [for (final c in e.codes) c.code].join('\n');
    _notes.text = e.notes;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (LockGuard.beforeLock == _saveOnLock) LockGuard.beforeLock = null;
    for (final c in _all) {
      c.dispose();
    }
    _shown.dispose();
    _keyShown.dispose();
    super.dispose();
  }

  void _hide() {
    _shown.value = false;
    _keyShown.value = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _hide();
  }

  /// The vault locked (what could be saved was, [_saveOnLock]): no secret stays in the
  /// fields under the lock screen.
  @override
  void vaultLocking() {
    _hide();
    for (final c in _secrets) {
      c.clear();
    }
    _cleared = true;
    _saved = _snapshot;
  }

  @override
  void vaultUnlocked() {
    if (_cleared && _item != null) _reload();
  }

  /// Read the item again and show it as it is now (what was typed is dropped).
  Future<void> _reload() async {
    final item = _item;
    if (item == null) return;
    try {
      final doc = await rust.entryJson(id: item.id);
      if (!mounted) return;
      setState(() {
        _base = Entry.decode(_kind, doc.json);
        _rev = doc.rev;
        _fill(_name.text.isEmpty ? item.name : _name.text);
        _saved = _snapshot;
        _cleared = false;
      });
    } catch (_) {}
  }

  void _changed() {
    LockGuard.activity();
    if (mounted) setState(() {});
  }

  String get _snapshot => [_kind, for (final c in _all) c.text].join('\u0000');
  bool get _dirty => _snapshot != _saved;

  List<String> get _siteList => [for (final s in _sites.text.split('\n')) if (s.trim().isNotEmpty) s.trim()];

  /// The one-time code typed or pasted: null when the field is empty.
  Totp? get _totp => _key.text.trim().isEmpty ? null : Totp.parse(_key.text);
  bool get _keyBad => _key.text.trim().isNotEmpty && _totp == null;

  /// The code to keep for a changed key field: a bare secret keeps the parameters the
  /// code had (digits, period, algorithm, service, account); a link brings its own.
  Totp? _newTotp(Totp? old) {
    final t = _totp;
    if (t == null || old == null || _key.text.trim().toLowerCase().startsWith('otpauth://')) return t;
    return Totp(secret: t.secret, algo: old.algo, digits: old.digits, period: old.period, issuer: old.issuer, account: old.account);
  }

  /// The name kept when the Name field is left empty: a login's first web site or its
  /// account, a one-time code's service, recovery codes' account.
  String get _defaultName {
    final sites = _siteList;
    return switch (_kind) {
      ItemKind.otp => _issuer.text.trim().isNotEmpty ? _issuer.text.trim() : _account.text.trim(),
      ItemKind.codes => _account.text.trim(),
      _ => sites.isNotEmpty ? entryHost(sites.first) : _account.text.trim(),
    };
  }

  bool get _canSave => switch (_kind) {
        ItemKind.otp => _totp != null,
        ItemKind.codes => Entry.splitCodes(_codes.text).isNotEmpty,
        _ => !_keyBad && (_name.text.trim().isNotEmpty || _siteList.isNotEmpty || _account.text.trim().isNotEmpty),
      };

  /// A pasted otpauth link fills the service and account it names.
  void _keyChanged(String text) {
    final t = Totp.parse(text);
    if (t == null || _kind != ItemKind.otp) return;
    if (_issuer.text.trim().isEmpty && t.issuer.isNotEmpty) _issuer.text = t.issuer;
    if (_account.text.trim().isEmpty && t.account.isNotEmpty) _account.text = t.account;
  }

  void _generate() {
    _password.text = widget.debugPassword ?? generatePassword();
    _shown.value = true;
  }

  /// Write the item, the fields laid over the document as read. One write at a time.
  /// [asNew]: as a new item of the same kind beside the one being edited ("Name
  /// (unsaved)"), when that one changed elsewhere and nobody is there to choose.
  Future<rust.ItemInfo?> _save({bool asNew = false}) async {
    final l = AppLocalizations.of(context);
    final kindName = entryKindLabel(l, _kind);
    while (_writing != null) {
      await _writing;
    }
    // Never over a newer version's document: this version would drop what it added.
    if (!_canSave || _cleared || _base.newer) return null;
    final done = Completer<void>();
    _writing = done.future;
    try {
      final snapshot = _snapshot;
      // A new item whose kind was switched starts from an empty document of that kind.
      final e = _base.kind == _kind ? Entry(_kind, Map.of(_base.doc)) : Entry(_kind);
      final before = {for (final c in e.codes) c.code: c.used};
      e.notes = _notes.text;
      final keyChanged = _key.text != _keyLoaded;
      switch (_kind) {
        case ItemKind.otp:
          e.issuer = _issuer.text;
          e.account = _account.text;
          if (keyChanged) e.totp = _newTotp(e.totp);
        case ItemKind.codes:
          e.account = _account.text;
          e.codes = [for (final c in Entry.splitCodes(_codes.text)) (code: c, used: before[c] ?? false)];
        default:
          e.account = _account.text;
          e.password = _password.text;
          e.urls = _siteList;
          if (keyChanged) e.totp = _newTotp(e.totp);
      }
      var name = _name.text.trim();
      if (name.isEmpty) name = _defaultName;
      if (name.isEmpty) name = kindName;
      if (asNew) name = l.entryUnsavedCopy(name);
      final id = asNew ? null : _item?.id;
      final rust.ItemInfo saved;
      if (id == null) {
        saved = await rust.addEntry(kind: _kind, name: name, json: e.encode(), createdMs: nowMs());
        final tagId = widget.tagId;
        if (tagId != null) await rust.setTag(itemIds: [saved.id], tagId: tagId, tagged: true);
      } else {
        saved = await rust.updateEntry(id: id, name: name, json: e.encode(), rev: _rev);
      }
      // Now an existing item: its kind is fixed (the switch goes), and the next save
      // goes over this one.
      _item = saved;
      _base = e;
      _keyLoaded = _key.text;
      try {
        _rev = (await rust.entryJson(id: saved.id)).rev;
      } catch (_) {}
      _saved = snapshot;
      return saved;
    } finally {
      _writing = null;
      done.complete();
    }
  }

  /// The vault is locking: keep what can be kept, quietly. When the item changed
  /// elsewhere meanwhile, neither is lost: what was typed becomes a new item beside it
  /// (as sync keeps both sides of a conflict), and this editor goes on with that one.
  Future<void> _saveOnLock() async {
    if (!_dirty || !_canSave) return;
    try {
      await _save();
    } on rust.VaultError catch (e) {
      if (e != rust.VaultError.changed) return;
      try {
        await _save(asNew: true);
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _saveAndLeave() async {
    if (_busy || !_canSave) return;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final saved = await _save();
      if (saved != null) nav.pop(saved);
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e == rust.VaultError.changed) return _changedElsewhere();
      showToast(context, vaultErrorText(AppLocalizations.of(context), e), icon: Icons.error_outline_rounded);
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      showToast(context, withCode(l, l.errorStorage, e), icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The item changed on another device while it was edited here: what was typed stays
  /// on screen; reload it (dropping the typing) or save over that change.
  Future<void> _changedElsewhere() async {
    final l = AppLocalizations.of(context);
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('entry-changed'),
        title: Text(l.entryChangedTitle),
        content: Text(l.entryChangedBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          TextButton(
            key: const ValueKey('entry-changed-reload'),
            onPressed: () => Navigator.pop(context, 'reload'),
            child: Text(l.entryReload),
          ),
          TextButton(
            key: const ValueKey('entry-changed-save'),
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(l.entrySaveAnyway),
          ),
        ],
      ),
    );
    if (!mounted || answer == null) return;
    if (answer == 'reload') return _reload();
    // Over the item as it is now: its revision, and what it holds that is not shown here.
    final item = _item;
    if (item == null) return;
    try {
      final doc = await rust.entryJson(id: item.id);
      _base = Entry.decode(_kind, doc.json);
      _rev = doc.rev;
    } catch (_) {
      return;
    }
    if (mounted) await _saveAndLeave();
  }

  /// Back with changes: Save, Discard or stay.
  Future<void> _askLeave() async {
    final l = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('entry-leave'),
        title: Text(l.entryLeaveTitle),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          TextButton(
            key: const ValueKey('entry-discard'),
            onPressed: () => Navigator.pop(context, 'discard'),
            style: TextButton.styleFrom(foregroundColor: recordRed(context)),
            child: Text(l.entryDiscard),
          ),
          if (_canSave)
            TextButton(
              key: const ValueKey('entry-leave-save'),
              onPressed: () => Navigator.pop(context, 'save'),
              child: Text(l.save),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (answer == 'save') return _saveAndLeave();
    if (answer == 'discard') {
      _saved = _snapshot;
      nav.pop(_item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    const gap = SizedBox(height: 12);
    final fresh = _item == null;
    Widget field(TextEditingController controller, String label,
            {String? hint, Key? key, TextInputType? type, int lines = 1, TextCapitalization caps = TextCapitalization.none,
            bool secret = false}) =>
        TextField(
          key: key,
          controller: controller,
          keyboardType: type ?? (lines > 1 ? TextInputType.multiline : null),
          minLines: lines > 1 ? 2 : 1,
          maxLines: lines,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textCapitalization: caps,
          contextMenuBuilder: secret ? secureContextMenu : null,
          decoration: InputDecoration(labelText: label, hintText: hint),
        );
    final keyField = SecureCopy(controller: _key, allowed: () => _keyShown.value, child: SecretField(
      key: const ValueKey('entry-key'),
      controller: _key,
      label: l.entryOtpKey,
      paste: true,
      openFile: false,
      shown: _keyShown,
      contextMenuBuilder: secureContextMenu,
      errorText: _keyBad ? l.entryOtpKeyBad : null,
      onChanged: _keyChanged,
    ));
    final notes = SecureCopy(
        controller: _notes,
        child: field(_notes, l.entryNotes,
            key: const ValueKey('entry-notes'), lines: 6, caps: TextCapitalization.sentences, secret: true));
    final fields = switch (_kind) {
      ItemKind.otp => [
          keyField,
          gap,
          field(_issuer, l.entryIssuer, key: const ValueKey('entry-issuer'), caps: TextCapitalization.words),
          gap,
          field(_account, l.entryAccount, key: const ValueKey('entry-account-field'), type: TextInputType.emailAddress),
          gap,
          notes,
        ],
      ItemKind.codes => [
          field(_account, l.entryCodesAccount, key: const ValueKey('entry-account-field'), type: TextInputType.emailAddress),
          gap,
          SecureCopy(controller: _codes, child: TextField(
            key: const ValueKey('entry-codes'),
            controller: _codes,
            keyboardType: TextInputType.multiline,
            minLines: 4,
            maxLines: 12,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            contextMenuBuilder: secureContextMenu,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(labelText: l.entryCodesField, alignLabelWithHint: true),
          )),
          gap,
          notes,
        ],
      _ => [
          field(_account, l.entryAccount,
              key: const ValueKey('entry-account-field'), hint: l.entryAccountHint, type: TextInputType.emailAddress),
          gap,
          SecureCopy(controller: _password, allowed: () => _shown.value, child: SecretField(
            key: const ValueKey('entry-password-field'),
            fieldKey: const ValueKey('entry-password-input'),
            controller: _password,
            label: l.password,
            shown: _shown,
            contextMenuBuilder: secureContextMenu,
          )),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('entry-generate'),
              onPressed: _generate,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(l.entryGenerate),
            ),
          ),
          if (_password.text.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: PasswordStrength(password: _password.text),
            ),
            gap,
          ],
          field(_sites, l.entryWebsites,
              key: const ValueKey('entry-sites'), hint: l.entryWebsitesHint, type: TextInputType.url, lines: 4),
          gap,
          keyField,
          gap,
          notes,
        ],
    };
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _askLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(fresh ? l.newPassword : l.previewEdit)),
        body: FormColumn(
          actions: [
            FilledButton(
              key: const ValueKey('entry-save'),
              onPressed: _canSave && !_busy ? _saveAndLeave : null,
              child: Text(l.save),
            ),
          ],
          children: [
            EntryKindLine(kind: _kind),
            const SizedBox(height: 14),
            field(_name, l.entryName, key: const ValueKey('entry-name'), hint: _defaultName.isEmpty ? null : _defaultName,
                caps: TextCapitalization.sentences),
            gap,
            ...fields,
          ],
        ),
      ),
    );
  }
}
