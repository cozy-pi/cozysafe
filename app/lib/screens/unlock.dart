import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../platform.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../prefs.dart';
import '../sync/status.dart';
import '../widgets/pin_pad.dart';
import '../widgets/brand.dart';
import '../widgets/vault_bar.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'debug.dart' show debugModeOn;
import 'new_vault.dart';
import 'restore.dart';
import 'vault_home.dart';
import '../theme.dart';
import '../widgets/drive_logo.dart';
import '../widgets/readable.dart';

/// The lock screen (design B2, docs/ui.md). Biometrics are asked for right away; the
/// vault password is the fallback (decisions 2026-10-28: no more PIN, it was the
/// weakest way in). The PIN pad shows only for a vault made with a PIN and never given
/// a password, until it gets one.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.libraryDir, this.askBiometricNow = true, this.resumeVaultId});

  final String libraryDir;

  /// Locked over the open vault's pages (lib/lock_resume.dart): opening that same vault
  /// goes back to them; Back cannot (it would show them without unlocking).
  final String? resumeVaultId;

  /// Ask for Face ID / fingerprint as soon as the screen shows. True when the app
  /// starts; false after locking (the person is still looking at the phone, so it
  /// would open again at once). Coming back from the background always asks.
  final bool askBiometricNow;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

enum _Mode { pin, password }

class _UnlockScreenState extends State<UnlockScreen> with WidgetsBindingObserver {
  final _password = TextEditingController();
  final _focus = FocusNode();
  final _keys = FocusNode(skipTraversal: true);
  late _Mode _mode;
  /// PIN lengths in use here: the pad checks at each, wrong only at the longest.
  late List<int> _lengths;
  int get _maxLen => _lengths.isEmpty ? 0 : _lengths.last;
  late bool _anyPassword;
  DateTime? _waitUntil;
  Timer? _waitTick;
  String _pin = '';
  bool _obscure = true;
  bool _busy = false;
  bool _checking = false;
  bool _leaving = false;
  String? _error;
  int _shake = 0;
  BiometricKind? _bioKind;
  bool _bioOn = false;

  /// Stop typing this long and the password is tried without pressing Enter.
  static const _pause = Duration(milliseconds: 350);
  Timer? _debounce;
  String? _tried;

  /// Set when the app really went to the background. The biometric prompt itself makes
  /// the app inactive and active again; that must not count, or it would ask forever.
  bool _wasHidden = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _wasHidden = true;
    } else if (state == AppLifecycleState.resumed && _wasHidden) {
      _wasHidden = false;
      // Only when this screen is the one showing: under a New vault or Restore opened from
      // here, an unlock would wipe what the person was doing there.
      if (_bioOn && _bioKind != null && (ModalRoute.of(context)?.isCurrent ?? false)) _unlockBiometric();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Locked because the app went to the background: ask when it comes back.
    final life = WidgetsBinding.instance.lifecycleState;
    _wasHidden = life == AppLifecycleState.paused || life == AppLifecycleState.hidden;
    // PINs of vaults that have a password go (decisions 2026-10-28).
    PinStore.retire(widget.libraryDir,
        forgetWithPassword: rust.forgetPinsWithPassword, lengths: rust.pinLengths);
    _lengths = rust.pinLengths(dir: widget.libraryDir);
    _anyPassword = rust.anyPassword(dir: widget.libraryDir);
    _mode = _lengths.isNotEmpty ? _Mode.pin : _Mode.password;
    // With a backup password, ask for it every 14 days so it is not forgotten.
    final last = int.tryParse(Prefs.read(_passwordSeenKey) ?? '');
    if (_anyPassword && last != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) > const Duration(days: 14)) {
      _mode = _Mode.password;
      _remind = true;
    }
    PinStore.waitUntil().then(_startWait);
    _bioOn = BiometricUnlock.platformSupported && rust.hasBiometricUnlock(dir: widget.libraryDir);
    if (_bioOn) {
      BiometricUnlock.available().then((kind) {
        if (!mounted || kind == null) return;
        setState(() => _bioKind = kind);
        if (widget.askBiometricNow) WidgetsBinding.instance.addPostFrameCallback((_) => _unlockBiometric());
      });
    }
  }

  static const _passwordSeenKey = 'password-seen';
  bool _remind = false;

  void _startWait(DateTime? until) {
    _waitTick?.cancel();
    if (!mounted) return;
    setState(() => _waitUntil = until);
    if (until == null) return;
    // Asks the store each second: the time left goes down there, on a clock that
    // moving the phone's date cannot speed up.
    _waitTick = Timer.periodic(const Duration(seconds: 1), (_) async {
      final now = await PinStore.waitUntil();
      if (!mounted) return;
      if (now == null) {
        _waitTick?.cancel();
        setState(() {
          _waitUntil = null;
          _error = null;
        });
      } else {
        setState(() => _waitUntil = now);
      }
    });
  }

  String _waitText(AppLocalizations l) {
    final left = _waitUntil!.difference(DateTime.now());
    final m = (left.inSeconds / 60).ceil();
    return l.pinWait(m < 1 ? 1 : m);
  }

  @override
  void dispose() {
    _waitTick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _password.dispose();
    _focus.dispose();
    _keys.dispose();
    super.dispose();
  }

  BiometricUnlock _bioStore(AppLocalizations l) =>
      BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel);

  Future<void> _unlockBiometric() async {
    if (_busy || _leaving) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final vault = await _bioStore(l).unlock(widget.libraryDir);
      if (vault != null) return await _open(vault);
    } on BiometricKeyGone {
      if (mounted) {
        setState(() {
          _bioOn = false;
          _error = l.biometricChanged;
        });
      }
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } finally {
      if (mounted && !_leaving) {
        setState(() => _busy = false);
        _focusOnComputer();
      }
    }
  }

  /// On a computer the keyboard is right there: the password field always has the
  /// caret, also after Touch ID was asked or cancelled (owner 2026-10-28: nothing showed
  /// that typing works).
  void _focusOnComputer() {
    if (!Device.desktop || _mode != _Mode.password || _leaving) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  // ---------- PIN (only a PIN-only vault from before) ----------

  void _digit(String d) {
    if (_busy || _waitUntil != null || _pin.length >= _maxLen) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    // Check at every length in use; only the longest one can be "wrong".
    if (_lengths.contains(_pin.length)) _checkPin(last: _pin.length == _maxLen);
  }

  void _deleteDigit() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _checkPin({required bool last}) async {
    final l = AppLocalizations.of(context);
    final tried = _pin;
    setState(() => _busy = true);
    try {
      if (await PinStore.waitUntil() case final until?) {
        setState(() => _pin = '');
        return _startWait(until);
      }
      final device = await PinStore.deviceKey();
      final vault = device == null
          ? null
          : await rust.unlockWithPin(dir: widget.libraryDir, pin: tried, deviceKey: device);
      if (vault != null) {
        await PinStore.resetFails();
        return await _open(vault);
      }
      if (!last) return; // a longer PIN may still match
      final wait = await PinStore.addFail();
      HapticFeedback.heavyImpact();
      if (_anyPassword && await PinStore.fails() >= PinStore.wipeAt) {
        // Too many: the PIN goes; the password opens the vault (owner 2026-10-26). A
        // vault without a password keeps its PIN (only the waits): wiping it would lock
        // the person out.
        await PinStore.wipe(widget.libraryDir, rust.forgetPin);
        if (!mounted) return;
        setState(() {
          _shake++;
          _pin = '';
          _lengths = const [];
          _mode = _Mode.password;
          _error = l.pinWiped;
        });
        _focusOnComputer();
        return;
      }
      if (!mounted) return;
      setState(() {
        _shake++;
        _pin = '';
        _error = wait > Duration.zero ? null : l.pinWrongTry;
      });
      if (wait > Duration.zero) _startWait(DateTime.now().add(wait));
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } finally {
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  // ---------- password (type to unlock) ----------

  void _onChanged(String _) {
    if (_error != null) setState(() => _error = null);
    _debounce?.cancel();
    if (_password.text.length >= 4) _debounce = Timer(_pause, () => _attempt(quiet: true));
  }

  /// Quiet tries (while typing) never say "wrong password"; Enter or the button does.
  /// One Argon2 run at a time; newer text is tried after the current run.
  Future<void> _attempt({required bool quiet}) async {
    final text = _password.text;
    if (text.isEmpty || _leaving) return;
    if (_checking) {
      if (!quiet) setState(() => _busy = true);
      return;
    }
    if (quiet && text == _tried) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _checking = true;
      if (!quiet) {
        _busy = true;
        _error = null;
      }
    });
    try {
      final until = await PinStore.passwordWaitUntil();
      if (until != null) {
        final m = (until.difference(DateTime.now()).inSeconds / 60).ceil();
        if (mounted && _busy) setState(() => _error = l.pinWait(m < 1 ? 1 : m));
        return;
      }
      final vault = await rust.unlock(dir: widget.libraryDir, password: text);
      _tried = text;
      if (!mounted) return;
      final possible = text.characters.length >= rust.minPasswordLength();
      if (vault == null && possible) {
        final wait = await PinStore.addPasswordFail();
        if (wait > Duration.zero && mounted) {
          final m = (wait.inSeconds / 60).ceil();
          setState(() => _error = l.pinWait(m < 1 ? 1 : m));
          return;
        }
      }
      if (vault != null) {
        await PinStore.resetPasswordFails();
        Prefs.write(_passwordSeenKey, '${DateTime.now().millisecondsSinceEpoch}');
        return await _open(vault, offerBiometric: true);
      }
      if (_password.text != text) {
        _checking = false;
        return await _attempt(quiet: !_busy);
      }
      if (_busy) setState(() => _error = l.wrongPassword);
    } on rust.VaultError catch (e) {
      if (mounted && _busy) setState(() => _error = vaultErrorText(l, e));
    } catch (_) {
      if (mounted && _busy) setState(() => _error = l.errorStorage);
    } finally {
      if (mounted && !_leaving) {
        setState(() {
          _checking = false;
          _busy = false;
        });
      }
    }
  }

  // ---------- open ----------

  Future<void> _open(rust.VaultInfo vault, {bool offerBiometric = false}) async {
    _leaving = true;
    _debounce?.cancel();
    _password.clear();
    final l = AppLocalizations.of(context);
    if (offerBiometric && !rust.hasBiometricUnlock(dir: widget.libraryDir)) {
      await _maybeOfferBiometric(l);
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    await playVaultSpin(context, opening: true,
        behind: revealIconOn() ? VaultBadge(icon: vault.icon, color: vault.color, size: 120) : null,
        glow: colorById(vault.color).color, onCovered: () {
      if (vault.id == widget.resumeVaultId) {
        nav.pop(vault);
        return;
      }
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault),
        ),
        (_) => false,
      );
    });
  }

  /// Once per device, for libraries made before biometric unlock existed.
  Future<void> _maybeOfferBiometric(AppLocalizations l) async {
    final marker = File('${widget.libraryDir}/.biometric-offered');
    if (marker.existsSync() || await BiometricUnlock.available() == null || !mounted) return;
    marker.writeAsStringSync('1');
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.biometricOfferTitle),
        content: Text(l.biometricOfferBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.biometricOfferNo)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.biometricOfferYes)),
        ],
      ),
    );
    if (yes == true) await turnOnBiometric(_bioStore(l));
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) =>
      // Over the vault's kept pages, Back and the swipe back stay here.
      PopScope(canPop: widget.resumeVaultId == null, child: _page(context));

  Widget _page(BuildContext context) {
    final l = AppLocalizations.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final cardColor = solidTint(context, Theme.of(context).cardColor);
    final ink = Theme.of(context).colorScheme.onSurface;
    final accent = ink;
    final bio = _bioOn ? _bioKind : null;

    final card = _ShakeOnChange(
      trigger: _shake,
      child: Container(
        margin: const EdgeInsets.only(top: 46),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(26),
          boxShadow: const [BoxShadow(color: Color(0x66041410), blurRadius: 50, offset: Offset(0, 24))],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 58),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _mode == _Mode.pin ? l.pinEnter : (_remind ? l.passwordRemindTitle : l.unlockTitle),
                    style: TextStyle(fontSize: CsType.title2, fontWeight: FontWeight.w700, color: ink, letterSpacing: -.3),
                  ),
                  const SizedBox(height: 14),
                  if (_mode == _Mode.pin)
                    PinDots(filled: _pin.length, color: accent)
                  else
                    _passwordField(l, ink),
                  if (_mode == _Mode.password && _remind) ...[
                    Text(l.passwordRemindBody, textAlign: TextAlign.center, style: TextStyle(color: ink.withValues(alpha: .7), fontSize: CsType.footnote)),
                    const SizedBox(height: 10),
                  ],
                  if (_mode == _Mode.pin)
                    // One fixed slot for "wrong PIN", the wait and "unlock first": the
                    // card never grows, so the keypad never slides under the dock.
                    SizedBox(
                      height: 30,
                      child: Center(
                        child: Text(
                          _waitUntil != null ? _waitText(l) : (_error ?? ''),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _waitUntil == null && _error == null ? accent : Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                            fontSize: CsType.footnote,
                            height: 1.25,
                          ),
                        ),
                      ),
                    )
                  else if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600, fontSize: CsType.footnote),
                    ),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
            Positioned(
              top: -46,
              child: Container(
                width: 92,
                height: 92,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: page,
                  boxShadow: const [BoxShadow(color: Color(0x4D041410), blurRadius: 24, offset: Offset(0, 10))],
                ),
                // The launch hand-over flies the splash dial onto this one.
                child: BrandMark(key: LaunchHandoff.running ? LaunchHandoff.target : null, size: 78, color: accent),
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: page,
      body: KeyboardListener(
        focusNode: _keys,
        autofocus: _mode == _Mode.pin,
        onKeyEvent: (e) {
          if (_mode != _Mode.pin || e is! KeyDownEvent) return;
          final c = e.character;
          if (c != null && RegExp(r'^\d$').hasMatch(c)) _digit(c);
          if (e.logicalKey == LogicalKeyboardKey.backspace) _deleteDigit();
        },
        child: Stack(
          children: [
            const Positioned.fill(child: VaultBackdrop()),
            Column(
              children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  const SizedBox(height: 12),
                                  // A sync that went on as the vault locked: how far it is.
                                  const _SyncBehindLock(),
                                  card,
                                  if (_mode == _Mode.pin) ...[
                                    // Breathing room so the "Use password" link and the
                                    // top row of keys are not mistaken for each other.
                                    const SizedBox(height: 24),
                                    PinPad(onDigit: _digit, onDelete: _deleteDigit, enabled: !_busy && _waitUntil == null),
                                    const SizedBox(height: 12),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // The lock screen only opens vaults (adding while locked is gone):
                // ⋯ for everything else under the left thumb, biometrics in the middle.
                // Typing the password: Unlock over that row, above the keyboard while it
                // is up (owner 2026-10-25: every button within the thumb's reach).
                if (_mode == _Mode.password)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: SizedBox(
                        width: double.infinity,
                        child: ListenableBuilder(
                          listenable: _password,
                          builder: (context, _) => FilledButton(
                            key: const ValueKey('unlock-password-go'),
                            onPressed: _busy || _password.text.isEmpty ? null : () => _attempt(quiet: false),
                            child: BusyLabel(busy: _busy, idle: l.unlockButton, working: l.unlocking),
                          ),
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
                    // A labelled button, not a bare glyph: a lone fingerprint looked like
                    // the system's own sensor prompt (owner 2026-10-21).
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Align(alignment: Alignment.centerLeft, child: _moreMenu(l)),
                        if (bio != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 60),
                            child: _BiometricButton(
                              key: const ValueKey('biometric-button'),
                              kind: bio,
                              label: unlockWithLabel(l, bio),
                              onTap: _busy ? null : _unlockBiometric,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The thumb menu is white in light and dark alike, so its text is always dark.
  ButtonStyle get _menuItem {
    final ink = Theme.of(context).colorScheme.onSurface;
    return MenuItemButton.styleFrom(foregroundColor: ink, iconColor: ink, minimumSize: const Size(220, 48));
  }

  /// "Use password" / "Use PIN", "Create a new vault" (owner check first), "Restore".
  /// The menu in the page's own colour, a shade lighter (dark) or darker (light), never
  /// a white slab over the dark lock (owner 2026-10-22: "too bright").
  Color get _menuFill {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Color.alphaBlend(ink.withValues(alpha: dark ? .10 : .05), page);
  }

  Widget _moreMenu(AppLocalizations l) => MenuAnchor(
        alignmentOffset: const Offset(0, -8),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(_menuFill),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(10),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          side: WidgetStatePropertyAll(
              BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .10))),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        ),
        menuChildren: [
          if (_mode == _Mode.pin && _anyPassword)
            MenuItemButton(
              style: _menuItem,
              leadingIcon: const Icon(Icons.key_rounded),
              onPressed: () => setState(() => _mode = _Mode.password),
              child: Text(l.usePassword),
            ),
          if (_mode == _Mode.password && _lengths.isNotEmpty)
            MenuItemButton(
              style: _menuItem,
              leadingIcon: const Icon(Icons.dialpad),
              onPressed: () => setState(() => _mode = _Mode.pin),
              child: Text(l.usePin),
            ),
          // One vault in the app; another only in debug mode (decisions 2026-10-24).
          if (debugModeOn())
            MenuItemButton(
              style: _menuItem,
              leadingIcon: const Icon(Icons.add),
              onPressed: _busy ? null : _newVault,
              child: Text(l.newVault),
            ),
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(Icons.settings_backup_restore_rounded),
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Readable(child: RestoreScreen(libraryDir: widget.libraryDir, needFile: true)),
                    )),
            child: Text(l.restoreFromBackup),
          ),
        ],
        builder: (context, controller, _) => _RoundButton(
          key: const ValueKey('more-button'),
          size: 50,
          tooltip: l.more,
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
          child: Icon(Icons.more_horiz, color: Theme.of(context).colorScheme.onSurface, size: 26),
        ),
      );

  /// Only the owner of the phone makes vaults here (Face ID, fingerprint or the
  /// phone's passcode), so nobody holding it can add vaults or probe PINs.
  Future<void> _newVault() async {
    final l = AppLocalizations.of(context);
    if (!await confirmOwner(l.ownerCheckReason) || !mounted) return;
    await Navigator.of(context).push(fadeRoute<void>((_) => Readable(child: NewVaultScreen(libraryDir: widget.libraryDir, first: false))));
  }

  Widget _passwordField(AppLocalizations l, Color ink) {
    return TextField(
      controller: _password,
      focusNode: _focus,
      enabled: !_busy,
      // Phones: not over Face ID (the keyboard would cover it). Computers: always.
      autofocus: Device.desktop || _bioKind == null,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.done,
      style: TextStyle(color: ink),
      decoration: InputDecoration(
        labelText: l.password,
        helperText: _checking && !_busy ? l.checking : null,
        suffixIcon: IconButton(
          tooltip: _obscure ? l.showPassword : l.hidePassword,
          icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
      onChanged: _onChanged,
      onSubmitted: (_) => _attempt(quiet: false),
    );
  }
}

/// Shakes its child sideways whenever `trigger` changes (a wrong PIN).
class _ShakeOnChange extends StatefulWidget {
  const _ShakeOnChange({required this.trigger, required this.child});

  final int trigger;
  final Widget child;

  @override
  State<_ShakeOnChange> createState() => _ShakeOnChangeState();
}

class _ShakeOnChangeState extends State<_ShakeOnChange> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void didUpdateWidget(_ShakeOnChange old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        final dx = t == 0 || t == 1 ? 0.0 : 9 * (1 - t) * (((t * 8).floor().isEven) ? 1 : -1);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}

/// A sync still running behind the lock (lib/sync/status.dart): its kind, how far it is,
/// and "Up to date" once done. Nothing when no sync runs.
class _SyncBehindLock extends StatelessWidget {
  const _SyncBehindLock();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SyncStatus?>(
        valueListenable: syncStatus,
        builder: (context, s, _) {
          if (s == null) return const SizedBox.shrink();
          final l = AppLocalizations.of(context);
          final c = CsColors.of(context);
          final ink = Theme.of(context).colorScheme.onSurface;
          final f = s.fraction;
          final text = s.finished ? l.syncDone : (f == null ? l.syncWorking : l.lockSyncPercent((f * 100).floor().toString()));
          return Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Container(
              key: const ValueKey('lock-sync'),
              width: 230,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: solidTint(context, ink.withValues(alpha: .08)),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (s.drive && !s.finished)
                    Semantics(label: l.syncDriveRow, child: const DriveLogo(size: 20))
                  else
                    Icon(
                      s.finished ? Icons.check_circle_rounded : Icons.phonelink_ring_rounded,
                      size: 20,
                      color: s.finished ? const Color(0xFF34C759) : ink,
                      semanticLabel: s.drive ? l.syncDriveRow : l.syncRow,
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(text,
                        key: const ValueKey('lock-sync-text'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: ink, fontSize: CsType.subhead, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ]),
                if (!s.finished) ...[
                  const SizedBox(height: 9),
                  LinearProgressIndicator(
                    value: f,
                    minHeight: 5,
                    backgroundColor: c.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ],
              ]),
            ),
          );
        },
      );
}

/// A round, translucent button for the bottom of the lock screen.
class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.size, required this.tooltip, required this.onTap, required this.child});
  final double size;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: solidTint(context, Theme.of(context).colorScheme.onSurface.withValues(alpha: .12)),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(dimension: size, child: Center(child: child)),
          ),
        ),
      );
}

/// "Unlock with Face ID / fingerprint": a soft blue pill with the symbol and the words.
class _BiometricButton extends StatelessWidget {
  const _BiometricButton({super.key, required this.kind, required this.label, required this.onTap});
  final BiometricKind kind;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xFF7CC0FF) : const Color(0xFF0A6FD8);
    return Material(
      color: solidTint(context, ink.withValues(alpha: dark ? .18 : .12)),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BiometricGlyph(kind: kind, size: 24, color: ink),
                  const SizedBox(width: 10),
                  Text(label, style: TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w600, color: ink)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
