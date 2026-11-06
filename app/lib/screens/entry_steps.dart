import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../entries/entry.dart';
import '../entries/password_gen.dart';
import '../entries/qr.dart';
import '../entries/totp.dart';
import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/entry_row.dart';
import '../widgets/password_strength.dart';
import '../widgets/secret.dart';
import '../widgets/secure_menu.dart';
import '../widgets/steps.dart';
import '../widgets/symbols.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show entryKindColor;
import 'common.dart';
import 'entry_page.dart' show EntryField, EntryGroup, entryHost, groupedCode;

/// Well-known services offered when adding a login or recovery codes: host names only,
/// shown with a letter, never a logo (owner 2026-11-07).
const commonSites = [
  'google.com', 'apple.com', 'microsoft.com', 'facebook.com', 'instagram.com', 'zalo.me', 'tiktok.com',
  'shopee.vn', 'lazada.vn', 'github.com', 'amazon.com', 'netflix.com', 'vietcombank.com.vn',
  'techcombank.com.vn', 'mbbank.com.vn', 'bidv.com.vn', 'vpbank.com.vn', 'momo.vn',
];

enum EntryStep { site, account, password, twoFactor, review, otpSource, otpReview, codes, codesReview }

/// Adding a secure item step by step (owner 2026-11-07: "lead me step by step, keep
/// typing to a minimum"): what to add first (Login · One-time code · Recovery codes, each
/// its icon and colour), then one question per screen, mostly taps. Changing an item
/// keeps the form ([EntryEditor]).
///
/// What the editor promises holds here too: the vault locking saves what can be saved
/// and empties the secrets from the screen; a save over a change made elsewhere keeps
/// both ("(unsaved)"); secrets copy only through [SecureClipboard]. Pops the saved item.
class EntryWizard extends StatefulWidget {
  const EntryWizard({super.key, this.items, this.tagId, this.debugPassword, this.debugKind, this.debugStep});

  /// The vault's items, for the sites and accounts already used; read when null.
  final List<rust.ItemInfo>? items;
  /// A new item carries this group (the one open in the vault).
  final String? tagId;
  /// Tests and mockups: a fixed password instead of a generated one.
  final String? debugPassword;
  /// Mockups: open on this kind and step.
  final String? debugKind;
  final EntryStep? debugStep;

  @override
  State<EntryWizard> createState() => EntryWizardState();
}

class EntryWizardState extends State<EntryWizard> with WidgetsBindingObserver, VaultLockAware {
  String? _kind;
  EntryStep _step = EntryStep.site;
  List<rust.ItemInfo> _items = const [];

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _name = TextEditingController();
  final _issuer = TextEditingController();
  final _codes = TextEditingController();
  final _shown = ValueNotifier<bool>(false);
  final _keyShown = ValueNotifier<bool>(false);
  late final _all = [_account, _password, _key, _name, _issuer, _codes];

  /// The site or app picked: a host name ("github.com") or a name typed ("Bank app").
  String _site = '';
  /// The password was typed or pasted (its strength shows), not generated.
  bool _ownPassword = false;
  bool _typing = false;
  /// The two-factor code taken (from a QR code or a pasted key).
  Totp? _totp;
  /// Showing the field for a setup key (the clipboard held none).
  bool _keyField = false;
  bool _typeCodes = false;
  bool _codesShown = false;
  /// What went wrong reading a QR code or the clipboard, under the choices.
  String? _problem;

  /// The item once written (the vault locked mid-way); later saves change it.
  rust.ItemInfo? _item;
  String _rev = '';
  Entry? _base;
  String _saved = '';
  bool _busy = false;
  bool _cleared = false;
  Future<void>? _writing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _password.text = widget.debugPassword ?? generatePassword();
    final kind = widget.debugKind;
    if (kind != null) _choose(kind, quiet: true);
    if (widget.debugStep != null) _step = widget.debugStep!;
    _saved = _snapshot;
    for (final c in _all) {
      c.addListener(_changed);
    }
    _search.addListener(_changed);
    LockGuard.beforeLock = _saveOnLock;
    final items = widget.items;
    if (items != null) {
      _items = items;
    } else {
      _loadItems();
    }
  }

  Future<void> _loadItems() async {
    try {
      final items = await rust.listItems();
      if (mounted) setState(() => _items = items);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (LockGuard.beforeLock == _saveOnLock) LockGuard.beforeLock = null;
    for (final c in [..._all, _search]) {
      c.dispose();
    }
    _searchFocus.dispose();
    _shown.dispose();
    _keyShown.dispose();
    super.dispose();
  }

  void _changed() {
    LockGuard.activity();
    if (mounted) setState(() {});
  }

  void _hide() {
    _shown.value = false;
    _keyShown.value = false;
    _codesShown = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _hide();
  }

  /// The vault locked (what could be saved was, [_saveOnLock]): no secret stays on the
  /// screen under the lock.
  @override
  void vaultLocking() {
    _hide();
    QrCode.cancel();
    for (final c in [_password, _key, _codes]) {
      c.clear();
    }
    _totp = null;
    _cleared = true;
    _saved = _snapshot;
    if (mounted) setState(() {});
  }

  @override
  void vaultUnlocked() {
    if (_cleared && _item != null) _reload();
  }

  /// The item as saved on lock, back on screen.
  Future<void> _reload() async {
    final item = _item;
    final kind = _kind;
    if (item == null || kind == null) return;
    try {
      final doc = await rust.entryJson(id: item.id);
      if (!mounted) return;
      final e = Entry.decode(kind, doc.json);
      setState(() {
        _base = e;
        _rev = doc.rev;
        _password.text = e.password;
        _totp = e.totp;
        _codes.text = [for (final c in e.codes) c.code].join('\n');
        _cleared = false;
        _saved = _snapshot;
      });
    } catch (_) {}
  }

  String get _snapshot =>
      [_kind, _site, _totp?.secret, for (final c in _all) c.text].join('\u0000');
  bool get _dirty => _snapshot != _saved;

  List<EntryStep> get _steps => switch (_kind) {
        ItemKind.otp => const [EntryStep.otpSource, EntryStep.otpReview],
        ItemKind.codes => const [EntryStep.site, EntryStep.codes, EntryStep.codesReview],
        _ => const [EntryStep.site, EntryStep.account, EntryStep.password, EntryStep.twoFactor, EntryStep.review],
      };

  void _choose(String kind, {bool quiet = false}) {
    void set() {
      _kind = kind;
      _step = _steps.first;
      _problem = null;
    }

    quiet ? set() : setState(set);
  }

  void _go(EntryStep step) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _step = step;
      _problem = null;
    });
  }

  void _next() {
    final i = _steps.indexOf(_step);
    if (i + 1 < _steps.length) _go(_steps[i + 1]);
  }

  /// One step back; from the first, back to what to add (or out, once saved).
  void _back() {
    if (_busy) return;
    final kind = _kind;
    if (kind == null || (_item != null && _step == _steps.first)) {
      Navigator.of(context).pop(_item);
      return;
    }
    final i = _steps.indexOf(_step);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _problem = null;
      _typing = false;
      if (i <= 0) {
        _kind = null;
      } else {
        _step = _steps[i - 1];
      }
    });
  }

  // ---- what the vault already holds ----

  /// Web sites of the vault's logins, the most used first.
  List<String> get _vaultSites => _ranked([for (final it in _items) if (it.kind == ItemKind.login) ...it.hosts]);

  /// Accounts of the vault's secure items, the most used first, each once.
  List<String> get _vaultAccounts =>
      _ranked([for (final it in _items) if (ItemKind.isEntry(it.kind) && it.account.trim().isNotEmpty) it.account.trim()]);

  static List<String> _ranked(List<String> all) {
    final count = <String, int>{};
    for (final a in all) {
      count[a] = (count[a] ?? 0) + 1;
    }
    final keys = count.keys.toList();
    // Most used first; a tie keeps the order met.
    keys.sort((a, b) => count[b]!.compareTo(count[a]!));
    return keys;
  }

  // ---- picking ----

  /// A site picked or typed: the name follows it unless one was typed.
  void _pickSite(String site) {
    final s = site.trim();
    if (s.isEmpty) return;
    _site = s.contains('://') ? entryHost(s) : s;
    _name.text = _site;
    _search.clear();
    _next();
  }

  /// Whether [site] reads as an address ("github.com"), not a name ("Bank app").
  static bool _isAddress(String site) => !site.contains(' ') && site.contains('.');

  Future<String?> _clipboard() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();

  /// Paste link: the clipboard read once, now.
  Future<void> _pasteLink() async {
    final text = await _clipboard();
    if (!mounted) return;
    final host = text == null || text.isEmpty ? '' : entryHost(text);
    if (host.isEmpty || !_isAddress(host)) {
      setState(() => _problem = AppLocalizations.of(context).stepNoLink);
      return;
    }
    _pickSite(host);
  }

  void _pickAccount(String account) {
    _account.text = account;
    _next();
  }

  void _generate() {
    _password.text = generatePassword();
    _ownPassword = false;
    _typing = false;
    _shown.value = true;
  }

  /// A secret pasted in is taken off the clipboard after, as the 24 words are.
  Future<String?> _pasteSecret() async {
    final text = await _clipboard();
    if (text == null || text.isEmpty) {
      if (mounted) showToast(context, AppLocalizations.of(context).stepClipboardEmpty, icon: Icons.content_paste_off_rounded);
      return null;
    }
    await Clipboard.setData(const ClipboardData(text: ''));
    return text;
  }

  Future<void> _pastePassword() async {
    final text = await _pasteSecret();
    if (text == null || !mounted) return;
    setState(() {
      _password.text = text;
      _ownPassword = true;
      _typing = false;
      _shown.value = false;
    });
  }

  /// A two-factor code taken: on to the next step.
  void _tookTotp(Totp t) {
    setState(() {
      _totp = t;
      _problem = null;
      _keyField = false;
      _key.clear();
      if (_kind == ItemKind.otp) {
        if (_issuer.text.trim().isEmpty) _issuer.text = t.issuer;
        if (_account.text.trim().isEmpty) _account.text = t.account;
      } else if (_name.text.trim().isEmpty && t.issuer.isNotEmpty) {
        _name.text = t.issuer;
      }
    });
    _next();
  }

  void _qrResult(QrResult? r) {
    if (r == null || !mounted) return;
    switch (r) {
      case QrTotp(:final totp):
        _tookTotp(totp);
      case QrNotTotp():
        setState(() => _problem = AppLocalizations.of(context).qrNotTotp);
      case QrNone():
        setState(() => _problem = AppLocalizations.of(context).qrNone);
    }
  }

  Future<void> _scan() async {
    setState(() => _problem = null);
    try {
      _qrResult(await QrCode.scan(context));
    } catch (_) {
      if (mounted) setState(() => _problem = AppLocalizations.of(context).qrCameraFailed);
    }
  }

  Future<void> _fromPhoto() async {
    setState(() => _problem = null);
    try {
      _qrResult(await QrCode.readPhoto());
    } catch (_) {
      if (mounted) setState(() => _problem = AppLocalizations.of(context).qrNotTotp);
    }
  }

  /// Paste setup key: the clipboard's key or link; else a field to put it in.
  Future<void> _pasteKey() async {
    final text = await _clipboard();
    if (!mounted) return;
    final t = text == null ? null : Totp.parse(text);
    if (t != null) {
      await Clipboard.setData(const ClipboardData(text: ''));
      _tookTotp(t);
      return;
    }
    setState(() {
      _problem = null;
      _keyField = true;
    });
  }

  Future<void> _pasteCodes() async {
    final text = await _pasteSecret();
    if (text == null || !mounted) return;
    setState(() {
      _codes.text = Entry.splitCodes(text).join('\n');
      _typeCodes = false;
    });
  }

  // ---- saving ----

  List<String> get _codeList => Entry.splitCodes(_codes.text);

  bool get _canSave => switch (_kind) {
        ItemKind.otp => _totp != null,
        ItemKind.codes => _codeList.isNotEmpty,
        ItemKind.login => _name.text.trim().isNotEmpty || _site.isNotEmpty || _account.text.trim().isNotEmpty,
        _ => false,
      };

  String get _defaultName {
    final l = AppLocalizations.of(context);
    final kind = _kind ?? ItemKind.login;
    final name = switch (kind) {
      ItemKind.otp => _issuer.text.trim().isNotEmpty ? _issuer.text.trim() : _account.text.trim(),
      _ => _site.isNotEmpty ? _site : _account.text.trim(),
    };
    return name.isEmpty ? entryKindLabel(l, kind) : name;
  }

  /// The document from the steps, over what was saved before (a lock mid-way).
  Entry _document() {
    final kind = _kind!;
    final base = _base;
    final e = base != null ? Entry(kind, Map.of(base.doc)) : Entry(kind);
    switch (kind) {
      case ItemKind.otp:
        e.issuer = _issuer.text;
        e.account = _account.text;
        e.totp = _totp;
      case ItemKind.codes:
        final before = {for (final c in e.codes) c.code: c.used};
        e.codes = [for (final c in _codeList) (code: c, used: before[c] ?? false)];
      default:
        e.account = _account.text;
        e.password = _password.text;
        e.urls = _site.isNotEmpty && _isAddress(_site) ? ['https://$_site'] : const [];
        e.totp = _totp;
    }
    return e;
  }

  /// Write the item (one write at a time). [asNew]: beside the one written before, when
  /// that one changed elsewhere meanwhile ("Name (unsaved)").
  Future<rust.ItemInfo?> _save({bool asNew = false}) async {
    final l = AppLocalizations.of(context);
    while (_writing != null) {
      await _writing;
    }
    final kind = _kind;
    if (kind == null || !_canSave || _cleared) return null;
    final done = Completer<void>();
    _writing = done.future;
    try {
      final snapshot = _snapshot;
      final e = _document();
      var name = _name.text.trim();
      if (name.isEmpty) name = _defaultName;
      if (asNew) name = l.entryUnsavedCopy(name);
      final id = asNew ? null : _item?.id;
      final rust.ItemInfo saved;
      if (id == null) {
        saved = await rust.addEntry(kind: kind, name: name, json: e.encode(), createdMs: nowMs());
        final tagId = widget.tagId;
        if (tagId != null) await rust.setTag(itemIds: [saved.id], tagId: tagId, tagged: true);
      } else {
        saved = await rust.updateEntry(id: id, name: name, json: e.encode(), rev: _rev);
      }
      _item = saved;
      _base = e;
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

  /// The vault is locking: keep what can be kept, quietly (as the editor does).
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
      // Saved on lock, then changed elsewhere: this one is kept beside it.
      if (e == rust.VaultError.changed) {
        try {
          final copy = await _save(asNew: true);
          if (copy != null) nav.pop(copy);
          return;
        } catch (_) {}
      }
      if (mounted) showToast(context, vaultErrorText(AppLocalizations.of(context), e), icon: Icons.error_outline_rounded);
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      showToast(context, withCode(l, l.errorStorage, e), icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- screens ----

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final kind = _kind;
    final Widget page;
    if (kind == null) {
      page = StepPage(key: const ValueKey('steps-chooser'), title: l.addWhatTitle, onBack: _back, body: _chooser(l));
    } else {
      final steps = _steps;
      page = KeyedSubtree(
        key: ValueKey('steps-${_step.name}'),
        child: switch (_step) {
          EntryStep.site => _sitePage(l, steps),
          EntryStep.account => _accountPage(l, steps),
          EntryStep.password => _passwordPage(l, steps),
          EntryStep.twoFactor || EntryStep.otpSource => _twoFactorPage(l, steps),
          EntryStep.review => _reviewPage(l, steps),
          EntryStep.otpReview => _otpReviewPage(l, steps),
          EntryStep.codes => _codesPage(l, steps),
          EntryStep.codesReview => _codesReviewPage(l, steps),
        },
      );
    }
    // Back and the system's back go one step back; on what to add, they leave. The steps
    // live in one page, so the edge swipe has nothing to pop: there it is Back too.
    return PopScope(
      canPop: kind == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: EdgeSwipeBack(
        enabled: kind != null && !_busy,
        follow: true,
        onBack: _back,
        child: Scaffold(
          body: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: page),
        ),
      ),
    );
  }

  Widget _chooser(AppLocalizations l) {
    Widget card(String kind, String line) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ChoiceCard(
            key: ValueKey('steps-kind-$kind'),
            icon: entryIcon(kind),
            color: entryKindColor(kind),
            title: entryKindLabel(l, kind),
            line: line,
            onTap: () => _choose(kind),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      card(ItemKind.login, l.addKindLoginLine),
      card(ItemKind.otp, l.addKindOtpLine),
      card(ItemKind.codes, l.addKindCodesLine),
    ]);
  }

  StepPage _page(AppLocalizations l, List<EntryStep> steps,
          {required String title, String? lead, required Widget body, List<Widget> actions = const [], bool scroll = true}) =>
      StepPage(
        title: title,
        lead: lead,
        body: body,
        count: steps.length,
        at: steps.indexOf(_step),
        onBack: _back,
        actions: actions,
        scroll: scroll,
      );

  Widget _problemLine() => _problem == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_problem!,
              key: const ValueKey('steps-problem'),
              style: TextStyle(color: recordRed(context), fontSize: CsType.subhead, fontWeight: FontWeight.w600)),
        );

  /// Which site or app: the vault's own first, then well-known ones, filtered as typed.
  Widget _sitePage(AppLocalizations l, List<EntryStep> steps) {
    final c = CsColors.of(context);
    final q = _search.text.trim().toLowerCase();
    bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);
    final mine = _vaultSites.where(match).toList();
    final common = commonSites.where((s) => match(s) && !mine.contains(s)).toList();
    final typed = _search.text.trim();
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(text, style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
        );
    return _page(
      l,
      steps,
      title: l.stepSiteTitle,
      scroll: false,
      actions: [StepTextButton(key: const ValueKey('steps-skip'), label: l.stepSkip, onTap: _next)],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('steps-site-search'),
            controller: _search,
            focusNode: _searchFocus,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onSubmitted: (v) => _pickSite(v),
            decoration: InputDecoration(hintText: l.stepSiteSearch, prefixIcon: const Icon(Sym.search)),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            ActionChip(
              key: const ValueKey('steps-site-paste'),
              avatar: const Icon(Sym.link, size: 18),
              label: Text(l.stepSitePaste),
              onPressed: _pasteLink,
            ),
          ]),
          _problemLine(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 6, bottom: 12),
              children: [
                if (typed.isNotEmpty)
                  _SiteRow(
                    key: const ValueKey('steps-site-typed'),
                    label: l.stepSiteUse(typed),
                    icon: Sym.edit,
                    onTap: () => _pickSite(typed),
                  )
                else
                  _SiteRow(
                    key: const ValueKey('steps-site-other'),
                    label: l.stepSiteOther,
                    icon: Sym.edit,
                    onTap: () => _searchFocus.requestFocus(),
                  ),
                if (mine.isNotEmpty) ...[
                  header(l.stepSiteInVault),
                  for (final s in mine) _SiteRow(key: ValueKey('steps-site-$s'), label: s, onTap: () => _pickSite(s)),
                ],
                if (common.isNotEmpty) ...[
                  header(l.stepSiteCommon),
                  for (final s in common) _SiteRow(key: ValueKey('steps-site-$s'), label: s, onTap: () => _pickSite(s)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountPage(AppLocalizations l, List<EntryStep> steps) {
    final used = _vaultAccounts;
    return _page(
      l,
      steps,
      title: l.stepAccountTitle,
      lead: _site.isEmpty ? null : _site,
      actions: [
        StepMainButton(
          key: const ValueKey('steps-next'),
          label: l.pinNext,
          onTap: _account.text.trim().isEmpty ? null : _next,
        ),
        StepTextButton(key: const ValueKey('steps-skip'), label: l.stepSkip, onTap: _next),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (used.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, a) in used.take(8).indexed)
                  ActionChip(
                    key: ValueKey('steps-account-$i'),
                    avatar: const Icon(Sym.person, size: 18),
                    label: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: () => _pickAccount(a),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            key: const ValueKey('steps-account-field'),
            controller: _account,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) {
              if (_account.text.trim().isNotEmpty) _next();
            },
            decoration: InputDecoration(
                labelText: l.entryAccount, hintText: l.entryAccountHint, prefixIcon: const Icon(Sym.alternateEmail)),
          ),
        ],
      ),
    );
  }

  Widget _passwordPage(AppLocalizations l, List<EntryStep> steps) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final Widget shown;
    if (_typing) {
      shown = SecureCopy(
        controller: _password,
        allowed: () => _shown.value,
        child: SecretField(
          key: const ValueKey('steps-password-field'),
          fieldKey: const ValueKey('steps-password-input'),
          controller: _password,
          label: l.password,
          shown: _shown,
          contextMenuBuilder: secureContextMenu,
          onChanged: (_) => _ownPassword = true,
        ),
      );
    } else {
      shown = ValueListenableBuilder<bool>(
        valueListenable: _shown,
        builder: (context, on, _) => Container(
          key: const ValueKey('steps-password-card'),
          padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
          decoration: BoxDecoration(color: ink.withValues(alpha: .06), borderRadius: BorderRadius.circular(Ui.radius)),
          child: Row(children: [
            Expanded(
              child: Text(
                on ? _password.text : '•' * 12,
                key: const ValueKey('steps-password-text'),
                maxLines: 2,
                style: TextStyle(
                    fontSize: CsType.title3,
                    fontWeight: FontWeight.w600,
                    fontFamily: on ? 'monospace' : null,
                    letterSpacing: on ? 0 : 2),
              ),
            ),
            IconButton(
              key: const ValueKey('steps-password-eye'),
              tooltip: on ? l.hidePassword : l.showPassword,
              icon: Icon(on ? Sym.visibilityOff : Sym.visibility),
              onPressed: () => _shown.value = !on,
            ),
          ]),
        ),
      );
    }
    return _page(
      l,
      steps,
      title: l.stepPasswordTitle,
      lead: _typing || _ownPassword ? null : l.stepPasswordLead,
      actions: [
        StepMainButton(
          key: const ValueKey('steps-password-use'),
          label: l.stepPasswordUse,
          onTap: _password.text.isEmpty ? null : _next,
        ),
        if (!_typing)
          StepTextButton(
            key: const ValueKey('steps-password-own'),
            label: l.stepPasswordOwn,
            onTap: () => setState(() {
              _typing = true;
              _ownPassword = true;
              _password.clear();
              _shown.value = false;
            }),
          ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          shown,
          if (_ownPassword && _password.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: PasswordStrength(password: _password.text)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 4, children: [
            TextButton.icon(
              key: const ValueKey('steps-password-again'),
              onPressed: _generate,
              icon: const Icon(Sym.autorenew, size: 20),
              label: Text(l.stepPasswordAgain),
            ),
            TextButton.icon(
              key: const ValueKey('steps-password-paste'),
              onPressed: _pastePassword,
              icon: const Icon(Sym.contentPaste, size: 20),
              label: Text(l.modePaste),
            ),
          ]),
        ],
      ),
    );
  }

  /// Bringing in a two-factor code: the camera, a picture, or a pasted key.
  Widget _twoFactorPage(AppLocalizations l, List<EntryStep> steps) {
    final otp = _kind == ItemKind.otp;
    final color = entryKindColor(ItemKind.otp);
    Widget card(String key, IconData icon, String title, String line, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ChoiceCard(key: ValueKey(key), icon: icon, color: color, title: title, line: line, onTap: onTap),
        );
    final keyOk = _key.text.trim().isNotEmpty && Totp.parse(_key.text) != null;
    return _page(
      l,
      steps,
      title: otp ? l.stepOtpTitle : l.stepTwoFactorTitle,
      lead: otp ? l.stepOtpLead : l.stepTwoFactorLead,
      actions: [
        if (_keyField)
          StepMainButton(
            key: const ValueKey('steps-key-next'),
            label: l.pinNext,
            onTap: keyOk ? () => _tookTotp(Totp.parse(_key.text)!) : null,
          ),
        if (!otp) StepTextButton(key: const ValueKey('steps-2fa-skip'), label: l.stepSkip, onTap: _skipTwoFactor),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (QrCode.canScan) card('steps-qr-scan', Sym.qrCodeScanner, l.qrScan, l.qrScanLine, _scan),
          if (QrCode.canReadPhoto)
            card('steps-qr-photo', Sym.image, Theme.of(context).platform == TargetPlatform.macOS ? l.qrImageFile : l.qrPhoto, l.qrPhotoLine, _fromPhoto),
          card('steps-qr-paste', Sym.contentPaste, l.qrPaste, l.qrPasteLine, _pasteKey),
          if (_keyField) ...[
            const SizedBox(height: 4),
            SecureCopy(
              controller: _key,
              allowed: () => _keyShown.value,
              child: SecretField(
                key: const ValueKey('steps-key-field'),
                controller: _key,
                label: l.entryOtpKey,
                paste: true,
                openFile: false,
                shown: _keyShown,
                contextMenuBuilder: secureContextMenu,
                errorText: _key.text.trim().isNotEmpty && !keyOk ? l.entryOtpKeyBad : null,
              ),
            ),
          ],
          if (_totp != null && !otp)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Icon(Sym.checkCircle, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(l.stepTwoFactorAdded, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          _problemLine(),
        ],
      ),
    );
  }

  void _skipTwoFactor() {
    setState(() => _totp = null);
    _next();
  }

  /// A compact card of what will be kept; a tap on a line goes back to its step.
  Widget _reviewPage(AppLocalizations l, List<EntryStep> steps) {
    final c = CsColors.of(context);
    Text value(String s, {Key? key}) =>
        Text(s, key: key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: CsType.body));
    final none = l.stepNone;
    return _page(
      l,
      steps,
      title: l.stepReviewTitle,
      actions: [
        StepMainButton(key: const ValueKey('steps-save'), label: l.save, onTap: _canSave && !_busy ? _saveAndLeave : null),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const EntryBadge(kind: ItemKind.login, width: 44, height: 44),
          const SizedBox(width: 12),
          Expanded(child: _nameField(l)),
        ]),
        EntryGroup(children: [
          EntryField(
            label: l.stepReviewSite,
            value: value(_site.isEmpty ? none : _site, key: const ValueKey('steps-review-site')),
            onTap: () => _go(EntryStep.site),
          ),
          EntryField(
            label: l.entryAccount,
            value: value(_account.text.trim().isEmpty ? none : _account.text.trim(), key: const ValueKey('steps-review-account')),
            onTap: () => _go(EntryStep.account),
          ),
          EntryField(
            label: l.password,
            value: value(_password.text.isEmpty ? none : '•' * 12),
            onTap: () => _go(EntryStep.password),
          ),
          EntryField(
            label: l.stepTwoFactorTitle,
            value: Row(children: [
              if (_totp != null) ...[Icon(Sym.checkCircle, size: 18, color: entryKindColor(ItemKind.otp)), const SizedBox(width: 6)],
              Expanded(
                  child: value(_totp != null ? l.stepTwoFactorYes : none, key: const ValueKey('steps-review-2fa'))),
            ]),
            onTap: () => _go(EntryStep.twoFactor),
          ),
        ]),
        const SizedBox(height: 10),
        Text(l.stepReviewNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
      ]),
    );
  }

  Widget _nameField(AppLocalizations l) => TextField(
        key: const ValueKey('steps-name'),
        controller: _name,
        autocorrect: false,
        textCapitalization: TextCapitalization.sentences,
        style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700),
        decoration: InputDecoration(labelText: l.entryName, hintText: _defaultName),
      );

  Widget _otpReviewPage(AppLocalizations l, List<EntryStep> steps) {
    final t = _totp;
    return _page(
      l,
      steps,
      title: l.stepReviewTitle,
      actions: [
        StepMainButton(key: const ValueKey('steps-save'), label: l.save, onTap: _canSave && !_busy ? _saveAndLeave : null),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (t != null) _LiveCode(totp: t),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('steps-issuer'),
          controller: _issuer,
          autocorrect: false,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: l.entryIssuer),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('steps-otp-account'),
          controller: _account,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: l.entryAccount),
        ),
      ]),
    );
  }

  Widget _codesPage(AppLocalizations l, List<EntryStep> steps) {
    final codes = _codeList;
    final ink = Theme.of(context).colorScheme.onSurface;
    final has = codes.isNotEmpty;
    return _page(
      l,
      steps,
      title: l.stepCodesTitle,
      lead: _site.isEmpty ? l.stepCodesLead : '$_site · ${l.stepCodesLead}',
      actions: [
        if (has)
          StepMainButton(key: const ValueKey('steps-next'), label: l.pinNext, onTap: _next)
        else
          StepMainButton(
              key: const ValueKey('steps-codes-paste'), icon: Sym.contentPaste, label: l.stepCodesPaste, onTap: _pasteCodes),
        if (!_typeCodes)
          StepTextButton(
            key: const ValueKey('steps-codes-type'),
            label: has ? l.stepCodesEdit : l.stepCodesType,
            onTap: () => setState(() => _typeCodes = true),
          ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_typeCodes)
          SecureCopy(
            controller: _codes,
            child: TextField(
              key: const ValueKey('steps-codes-field'),
              controller: _codes,
              keyboardType: TextInputType.multiline,
              minLines: 5,
              maxLines: 12,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              contextMenuBuilder: secureContextMenu,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(labelText: l.entryCodesField, alignLabelWithHint: true),
            ),
          )
        else if (has)
          Container(
            key: const ValueKey('steps-codes-list'),
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 12),
            decoration: BoxDecoration(color: ink.withValues(alpha: .06), borderRadius: BorderRadius.circular(Ui.radius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(l.stepCodesCount(codes.length),
                      key: const ValueKey('steps-codes-count'), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  key: const ValueKey('steps-codes-eye'),
                  tooltip: _codesShown ? l.hidePassword : l.showPassword,
                  icon: Icon(_codesShown ? Sym.visibilityOff : Sym.visibility),
                  onPressed: () => setState(() => _codesShown = !_codesShown),
                ),
              ]),
              Wrap(spacing: 18, runSpacing: 6, children: [
                for (final code in codes.take(30))
                  Text(_codesShown ? code : '•' * 8,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: CsType.callout)),
              ]),
            ]),
          ),
      ]),
    );
  }

  Widget _codesReviewPage(AppLocalizations l, List<EntryStep> steps) => _page(
        l,
        steps,
        title: l.stepReviewTitle,
        actions: [
          StepMainButton(key: const ValueKey('steps-save'), label: l.save, onTap: _canSave && !_busy ? _saveAndLeave : null),
        ],
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const EntryBadge(kind: ItemKind.codes, width: 44, height: 44),
            const SizedBox(width: 12),
            Expanded(child: _nameField(l)),
          ]),
          EntryGroup(children: [
            EntryField(
              label: l.stepReviewSite,
              value: Text(_site.isEmpty ? l.stepNone : _site, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _go(EntryStep.site),
            ),
            EntryField(
              label: l.entryKindCodes,
              value: Text(l.stepCodesCount(_codeList.length), key: const ValueKey('steps-review-codes')),
              onTap: () => _go(EntryStep.codes),
            ),
          ]),
        ]),
      );
}

/// A site in the list: a letter in a circle (never a logo), the host, an arrow.
class _SiteRow extends StatelessWidget {
  const _SiteRow({super.key, required this.label, required this.onTap, this.icon});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final bare = label.startsWith('www.') ? label.substring(4) : label;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: ink.withValues(alpha: .08), shape: BoxShape.circle),
            child: icon != null
                ? Icon(icon, size: 20)
                : Text(bare.isEmpty ? '?' : bare.characters.first.toUpperCase(),
                    style: const TextStyle(fontSize: CsType.headline, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: CsType.body)),
          ),
          Icon(Sym.chevronRight, color: ink.withValues(alpha: .35)),
        ]),
      ),
    );
  }
}

/// The code a two-factor key makes now, as a check that it was read right.
class _LiveCode extends StatefulWidget {
  const _LiveCode({required this.totp});
  final Totp totp;

  @override
  State<_LiveCode> createState() => _LiveCodeState();
}

class _LiveCodeState extends State<_LiveCode> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final c = CsColors.of(context);
    final color = entryKindColor(ItemKind.otp);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(Ui.radius)),
      child: Row(children: [
        Icon(entryIcon(ItemKind.otp), color: color, size: 30),
        const SizedBox(width: 14),
        Expanded(
          child: Text(groupedCode(widget.totp.code(now)),
              key: const ValueKey('steps-code-preview'),
              style: const TextStyle(
                  fontSize: CsType.title1, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
        ),
        Text('${widget.totp.secondsLeft(now)} s', style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
      ]),
    );
  }
}
