import 'dart:async';

import 'package:flutter/material.dart';

import '../entries/entry.dart';
import '../entries/secure_clipboard.dart';
import '../entries/totp.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../note_format.dart' show safeLink;
import '../platform.dart';
import '../src/rust/api/history.dart' as hist;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/entry_row.dart';
import '../widgets/link_card.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show GlassButton;
import 'common.dart';
import 'entry_editor.dart';
import 'history.dart' show historyWhen;
import 'quick_look.dart' show ViewerMenu;

/// A web site as kept in a login, made into an address to open: "github.com" gets
/// https://. Null when it cannot be opened ([safeLink]).
String? entryUrl(String site) {
  final s = site.trim();
  if (s.isEmpty) return null;
  final url = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(s) ? s : 'https://$s';
  return safeLink(url)?.url;
}

/// The host a web site shows as: "github.com" for "https://github.com/login".
String entryHost(String site) {
  final url = entryUrl(site);
  return url == null ? site.trim() : (safeLink(url)?.host ?? site.trim());
}

/// A one-time code in groups, as authenticator apps show it: "123 456", "1234 5678".
String groupedCode(String code) {
  if (code.length < 6) return code;
  final half = code.length ~/ 2;
  return '${code.substring(0, half)} ${code.substring(half)}';
}

/// Copy a secret (or an account) through [SecureClipboard] and say for how long it stays.
Future<void> copySecret(BuildContext context, String text) async {
  final l = AppLocalizations.of(context);
  await SecureClipboard.copy(text);
  if (!context.mounted) return;
  final s = SecureClipboard.seconds;
  showToast(context, s == 0 ? l.detailsCopied : l.entryCopied(s), icon: Icons.copy_rounded);
}

/// A secure item opened (ADR 0009): a long page of grouped rows, as Settings, with Edit
/// in the middle of the bar and Delete red on the right. Its content is read when the
/// page opens and dropped when the vault locks; the list never reads it.
class EntryScreen extends StatefulWidget {
  const EntryScreen({super.key, required this.item, this.menu, this.onChanged, this.version});

  /// What the page pops when the item went to Recently deleted.
  static const deleted = 'entry-deleted';

  final rust.ItemInfo item;
  /// ⋯: the item's menu beside the button (favourite, info).
  final ViewerMenu? menu;
  /// The item was saved (an edit, a recovery code marked used): the vault reloads.
  final VoidCallback? onChanged;
  /// An older version, from its history: read only, with Restore (pops the restored
  /// item). Its document comes from `historyEntryJson`, never the plain history page.
  final hist.HistoryVersion? version;

  /// Mockups: an older version's document.
  static String Function(String rev)? debugVersionJson;

  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends State<EntryScreen> with WidgetsBindingObserver, VaultLockAware {
  late rust.ItemInfo _item = widget.item;
  Entry? _entry;
  /// The content's revision as read: a save is refused if it changed since (sync).
  String _rev = '';
  bool _failed = false;
  /// The password shown in clear (hidden again after 30 s, in the background, on lock).
  bool _shown = false;
  Timer? _hide;
  /// Ticks once a second while a one-time code shows.
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hide?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final v = widget.version;
      final String json;
      if (v != null) {
        json = EntryScreen.debugVersionJson?.call(v.rev) ?? await hist.historyEntryJson(id: _item.id, rev: v.rev);
      } else {
        final doc = await rust.entryJson(id: _item.id);
        json = doc.json;
        _rev = doc.rev;
      }
      if (!mounted) return;
      final entry = Entry.decode(_item.kind, json);
      setState(() {
        _entry = entry;
        _failed = false;
      });
      _tick?.cancel();
      if (entry.totp != null) {
        _tick = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _shown) _show(false);
  }

  /// The vault locks: the content goes, read again when it opens.
  @override
  void vaultLocking() {
    _hide?.cancel();
    _tick?.cancel();
    setState(() {
      _shown = false;
      _entry = null;
    });
  }

  @override
  void vaultUnlocked() => _load();

  void _show(bool shown) {
    _hide?.cancel();
    if (shown) _hide = Timer(const Duration(seconds: 30), () => _show(false));
    if (mounted) setState(() => _shown = shown);
  }

  Future<void> _edit() async {
    final entry = _entry;
    if (entry == null) return;
    final saved = await Navigator.of(context).push<rust.ItemInfo>(MaterialPageRoute(
      builder: (_) => EntryEditor(item: _item, entry: Entry(entry.kind, Map.of(entry.doc)), rev: _rev),
    ));
    if (!mounted) return;
    if (saved != null) {
      setState(() => _item = saved);
      widget.onChanged?.call();
    }
    // Saved as the vault locked, or changed elsewhere: read it as it is now.
    await _load();
  }

  Future<void> _delete() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    if (!await confirmTrash(context, count: 1, name: _item.name) || !mounted) return;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await rust.trashItem(id: _item.id, nowMs: nowMs());
      nav.pop(EntryScreen.deleted);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, l.errorStorage, icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _more(BuildContext button) async {
    final menu = widget.menu;
    if (menu == null) return;
    final now = await menu(button, _item);
    if (now != null && mounted) setState(() => _item = now);
    // An older version may have been restored from its history.
    if (mounted) await _load();
  }

  /// A recovery code marked used, or not: saved at once.
  Future<void> _toggleUsed(int at) async {
    final entry = _entry;
    if (entry == null || _busy || _readOnly) return;
    final codes = entry.codes;
    if (at >= codes.length) return;
    final c = codes[at];
    codes[at] = (code: c.code, used: !c.used);
    entry.codes = codes;
    setState(() => _busy = true);
    try {
      final saved = await rust.updateEntry(id: _item.id, name: _item.name, json: entry.encode(), rev: _rev);
      if (!mounted) return;
      setState(() => _item = saved);
      widget.onChanged?.call();
      _rev = (await rust.entryJson(id: _item.id)).rev;
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      if (e == rust.VaultError.changed) {
        // Changed on another device since it was read: show that, not this tap.
        showToast(context, l.entryChangedReloaded, icon: Icons.sync_rounded);
        await _load();
      } else {
        codes[at] = c;
        entry.codes = codes;
        showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
      }
    } catch (_) {
      // Not saved: show it as it was.
      codes[at] = c;
      entry.codes = codes;
      if (mounted) showToast(context, AppLocalizations.of(context).errorStorage, icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// An older version, or a document from a newer version of the app: shown, not changed.
  bool get _readOnly => widget.version != null || (_entry?.newer ?? false);

  Future<void> _restore() async {
    final v = widget.version;
    if (v == null || _busy) return;
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final restored = EntryScreen.debugVersionJson != null ? _item : await hist.restoreVersion(id: _item.id, rev: v.rev);
      nav.pop(restored);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final l = AppLocalizations.of(context);
      showToast(context, withCode(l, l.errorStorage, e), icon: Icons.error_outline_rounded);
    }
  }

  /// An older version's foot: what Restore does, then Restore.
  Widget _restoreBar(BuildContext context, AppLocalizations l) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ui.side, 4, Ui.side, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.historyRestoreNote,
                  textAlign: TextAlign.center, style: TextStyle(color: CsColors.of(context).muted, fontSize: CsType.footnote)),
              const SizedBox(height: 10),
              FilledButton(
                key: const ValueKey('history-restore'),
                onPressed: _busy || _entry == null ? null : _restore,
                child: Text(l.historyRestore),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final v = widget.version;
    final title = v != null
        ? historyWhen(context, v.replacedMs)
        : _item.name.isEmpty
        ? entryKindLabel(l, _item.kind)
        : _item.name;
    return groupedPage(
      context,
      Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(title, key: const ValueKey('entry-title'), maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (widget.menu != null && v == null)
                Padding(
                  padding: const EdgeInsets.only(right: Ui.side - 4),
                  child: Builder(
                    builder: (button) => GlassButton(
                      key: const ValueKey('entry-more'),
                      icon: Icons.more_horiz,
                      tooltip: l.more,
                      onTap: () => _more(button),
                    ),
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _body(context, l)),
              if (v != null)
                _restoreBar(context, l)
              else
              ActionBar(
                actions: [
                  BarIcon(
                    key: const ValueKey('entry-edit'),
                    icon: Icons.edit_rounded,
                    tooltip: l.previewEdit,
                    // A newer version's document is never written by this one.
                    onTap: _entry == null || _busy || _readOnly ? null : (_) => _edit(),
                  ),
                ],
                end: BarIcon(
                  key: const ValueKey('entry-delete'),
                  icon: Icons.delete_rounded,
                  tooltip: l.delete,
                  onTap: _busy ? null : (_) => _delete(),
                  color: recordRed(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l) {
    final entry = _entry;
    if (entry == null) {
      return Center(
        child: _failed
            ? Text(l.errorStorage, style: TextStyle(color: CsColors.of(context).muted))
            : const CircularProgressIndicator(),
      );
    }
    final groups = switch (_item.kind) {
      ItemKind.otp => _otp(context, l, entry),
      ItemKind.codes => _codes(context, l, entry),
      _ => _login(context, l, entry),
    };
    final notes = entry.notes;
    return ListView(
      key: const ValueKey('entry-page'),
      padding: const EdgeInsets.fromLTRB(Ui.side, 4, Ui.side, 24),
      children: [
        // What it is, in its kind's icon and colour (owner 2026-11-07).
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: EntryKindLine(kind: _item.kind),
        ),
        if (entry.newer)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(l.entryNewer,
                key: const ValueKey('entry-newer'),
                style: TextStyle(color: CsColors.of(context).muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
          ),
        ...groups,
        if (notes.isNotEmpty)
          EntryGroup(children: [
            EntryField(label: l.entryNotes, value: Text(notes, style: const TextStyle(fontSize: CsType.body, height: 1.35))),
          ]),
        ..._extraFields(context, l, entry),
      ],
    );
  }

  /// A login: account, password, its one-time code, web sites.
  List<Widget> _login(BuildContext context, AppLocalizations l, Entry e) {
    final c = CsColors.of(context);
    final totp = e.totp;
    return [
      EntryGroup(children: [
        if (e.account.isNotEmpty)
          EntryField(
            key: const ValueKey('entry-account'),
            label: l.entryAccount,
            value: Text(e.account, style: const TextStyle(fontSize: CsType.body)),
            onTap: () => copySecret(context, e.account),
            trailing: [_CopyButton(onTap: () => copySecret(context, e.account))],
          ),
        if (e.password.isNotEmpty)
          EntryField(
            key: const ValueKey('entry-password'),
            label: l.password,
            value: _shown
                ? Text(e.password,
                    key: const ValueKey('entry-password-shown'),
                    style: const TextStyle(fontSize: CsType.body, fontFamily: 'monospace', height: 1.3))
                // Always the same dots: the mask does not tell the password's length.
                : Text('••••••••••',
                    style: TextStyle(fontSize: CsType.body, color: c.muted, letterSpacing: 1.5)),
            onTap: () => copySecret(context, e.password),
            trailing: [
              IconButton(
                key: const ValueKey('entry-reveal'),
                tooltip: _shown ? l.hidePassword : l.showPassword,
                icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                onPressed: () => _show(!_shown),
              ),
              _CopyButton(key: const ValueKey('entry-copy-password'), onTap: () => copySecret(context, e.password)),
            ],
          ),
        if (totp != null) _codeField(context, l, totp),
      ]),
      if (e.urls.isNotEmpty)
        EntryGroup(children: [
          for (final (i, u) in e.urls.indexed)
            EntryField(
              key: ValueKey('entry-site-$i'),
              label: i == 0 ? l.entryWebsites : null,
              value: Text(entryHost(u), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: CsType.body)),
              onTap: entryUrl(u) == null ? null : () => confirmOpenLink(context, entryUrl(u)!),
              trailing: [
                if (entryUrl(u) != null)
                  IconButton(
                    tooltip: l.openItem,
                    icon: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => confirmOpenLink(context, entryUrl(u)!),
                  ),
              ],
            ),
        ]),
    ];
  }

  /// A login's one-time code: live, in groups, a ring for the time left; a tap copies.
  Widget _codeField(BuildContext context, AppLocalizations l, Totp totp) {
    final now = DateTime.now();
    final code = totp.code(now);
    return EntryField(
      key: const ValueKey('entry-code'),
      label: l.entryKindOtp,
      value: Text(groupedCode(code),
          key: const ValueKey('entry-code-value'),
          style: const TextStyle(fontSize: CsType.title2, fontWeight: FontWeight.w700, letterSpacing: 1.5,
              fontFeatures: [FontFeature.tabularFigures()])),
      onTap: () => copySecret(context, code),
      trailing: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: CodeRing(left: totp.secondsLeft(now), period: totp.period),
        ),
        _CopyButton(onTap: () => copySecret(context, code)),
      ],
    );
  }

  /// A one-time code on its own: the code big, its service and account under it.
  List<Widget> _otp(BuildContext context, AppLocalizations l, Entry e) {
    final c = CsColors.of(context);
    final totp = e.totp;
    final now = DateTime.now();
    final code = totp?.code(now);
    return [
      if (totp != null && code != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('entry-otp'),
              onTap: () => copySecret(context, code),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
                child: Column(
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(groupedCode(code),
                          key: const ValueKey('entry-code-value'),
                          style: const TextStyle(fontSize: CsType.largeTitle, fontWeight: FontWeight.w700,
                              letterSpacing: 3, fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CodeRing(left: totp.secondsLeft(now), period: totp.period),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(l.entryTapToCopy,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (e.issuer.isNotEmpty || e.account.isNotEmpty)
        EntryGroup(children: [
          if (e.issuer.isNotEmpty)
            EntryField(label: l.entryIssuer, value: Text(e.issuer, style: const TextStyle(fontSize: CsType.body))),
          if (e.account.isNotEmpty)
            EntryField(
              label: l.entryAccount,
              value: Text(e.account, style: const TextStyle(fontSize: CsType.body)),
              onTap: () => copySecret(context, e.account),
              trailing: [_CopyButton(onTap: () => copySecret(context, e.account))],
            ),
        ]),
    ];
  }

  /// Recovery codes: each with a round mark for used, and Copy.
  List<Widget> _codes(BuildContext context, AppLocalizations l, Entry e) {
    final c = CsColors.of(context);
    final codes = e.codes;
    final left = codes.where((x) => !x.used).length;
    return [
      if (e.account.isNotEmpty)
        EntryGroup(children: [
          EntryField(
            label: l.entryAccount,
            value: Text(e.account, style: const TextStyle(fontSize: CsType.body)),
            onTap: () => copySecret(context, e.account),
            trailing: [_CopyButton(onTap: () => copySecret(context, e.account))],
          ),
        ]),
      if (codes.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
          child: Row(children: [
            Expanded(
              child: Text(l.entryCodesLeft(left, codes.length),
                  key: const ValueKey('entry-codes-left'),
                  style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
            ),
            // One eye for every code; hidden again as the password is.
            IconButton(
              key: const ValueKey('entry-codes-reveal'),
              tooltip: _shown ? l.entryHideCodes : l.entryShowCodes,
              icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              onPressed: () => _show(!_shown),
            ),
          ]),
        ),
        EntryGroup(top: 4, children: [
          for (final (i, x) in codes.indexed)
            EntryField(
              key: ValueKey('entry-recovery-$i'),
              leading: IconButton(
                key: ValueKey('entry-used-$i'),
                tooltip: l.entryCodeUsed,
                onPressed: _busy || _readOnly ? null : () => _toggleUsed(i),
                icon: Icon(
                  x.used ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: x.used ? Theme.of(context).colorScheme.onSurface : c.muted,
                ),
              ),
              // Masked as the password is, always the same dots.
              value: Text(_shown ? x.code : '••••••••',
                  key: ValueKey('entry-recovery-text-$i'),
                  style: TextStyle(
                    fontSize: CsType.body,
                    fontFamily: _shown ? 'monospace' : null,
                    letterSpacing: _shown ? null : 1.5,
                    color: x.used || !_shown ? c.muted : null,
                    decoration: x.used && _shown ? TextDecoration.lineThrough : null,
                  )),
              onTap: () => copySecret(context, x.code),
              trailing: [_CopyButton(onTap: () => copySecret(context, x.code))],
            ),
        ]),
      ],
    ];
  }

  /// Fields without a place of their own (`fields` in the document): label and value,
  /// a secret one masked until copied.
  List<Widget> _extraFields(BuildContext context, AppLocalizations l, Entry e) {
    final raw = e.doc['fields'];
    if (raw is! List) return const [];
    final fields = [
      for (final f in raw)
        if (f is Map && f['value'] is String && (f['value'] as String).isNotEmpty)
          (label: f['label'] is String ? f['label'] as String : '', value: f['value'] as String, secret: f['secret'] == true),
    ];
    if (fields.isEmpty) return const [];
    final c = CsColors.of(context);
    return [
      EntryGroup(children: [
        for (final f in fields)
          EntryField(
            label: f.label.isEmpty ? null : f.label,
            value: f.secret
                ? Text('••••••••••', style: TextStyle(fontSize: CsType.body, color: c.muted, letterSpacing: 1.5))
                : Text(f.value, style: const TextStyle(fontSize: CsType.body)),
            onTap: () => copySecret(context, f.value),
            trailing: [_CopyButton(onTap: () => copySecret(context, f.value))],
          ),
      ]),
    ];
  }
}

/// Rows in one rounded card, as Settings' groups.
class EntryGroup extends StatelessWidget {
  const EntryGroup({super.key, required this.children, this.top = 20});
  final List<Widget> children;
  final double top;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (i, r) in children.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: 16, color: c.border.withValues(alpha: .6)),
              r,
            ],
          ],
        ),
      ),
    );
  }
}

/// One row of a secure item: a small label over its value, then its buttons.
class EntryField extends StatelessWidget {
  const EntryField({super.key, this.label, required this.value, this.onTap, this.trailing = const [], this.leading});
  final String? label;
  final Widget value;
  final VoidCallback? onTap;
  final List<Widget> trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Padding(
          padding: EdgeInsets.fromLTRB(leading == null ? 16 : 4, 8, 4, 8),
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null) ...[
                      Text(label!, style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                    ],
                    value,
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppLocalizations.of(context).kitCopy,
        icon: const Icon(Icons.copy_rounded),
        onPressed: onTap,
      );
}

/// The time a one-time code has left, as a small ring that empties; red for the last
/// five seconds.
class CodeRing extends StatelessWidget {
  const CodeRing({super.key, required this.left, required this.period});
  final int left;
  final int period;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final color = left <= 5 ? recordRed(context) : ink;
    return SizedBox.square(
      key: const ValueKey('entry-code-ring'),
      dimension: 26,
      child: Stack(alignment: Alignment.center, children: [
        CircularProgressIndicator(
          value: left / period,
          strokeWidth: 2.5,
          color: color,
          backgroundColor: ink.withValues(alpha: .12),
        ),
        Text('$left', style: TextStyle(fontSize: CsType.caption2, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}
