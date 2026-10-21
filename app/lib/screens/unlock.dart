import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../prefs.dart';
import '../widgets/pin_pad.dart';
import '../widgets/brand.dart';
import '../widgets/vault_bar.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'new_vault.dart';
import 'restore.dart';
import 'set_pin.dart';
import 'vault_home.dart';

/// The lock screen (design B2, docs/ui.md). Biometrics are asked for right away; the
/// PIN pad is the fallback; the password is the fallback of the fallback. The add dock
/// at the bottom is the same as inside the vault: picking an action here unlocks first,
/// then runs it.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.libraryDir, this.askBiometricNow = true});

  final String libraryDir;

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
      if (_bioOn && _bioKind != null) _unlockBiometric();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Locked because the app went to the background: ask when it comes back.
    final life = WidgetsBinding.instance.lifecycleState;
    _wasHidden = life == AppLifecycleState.paused || life == AppLifecycleState.hidden;
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
    _waitTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(until)) {
        _waitTick?.cancel();
        setState(() {
          _waitUntil = null;
          _error = null;
        });
      } else {
        setState(() {});
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
      if (mounted && !_leaving) setState(() => _busy = false);
    }
  }

  // ---------- PIN ----------

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
      final vault = await rust.unlock(dir: widget.libraryDir, password: text);
      _tried = text;
      if (!mounted) return;
      if (vault != null) {
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
    // Opened with the password and no PIN for it here (e.g. restored on a new phone):
    // offer one now, so next time is the PIN pad.
    if (offerBiometric && !rust.pinEnabled() && mounted) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const SetPinScreen(skippable: true, forThisPhone: true)),
      );
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    await playVaultSpin(context, opening: true,
        behind: revealIconOn() ? VaultBadge(icon: vault.icon, color: vault.color, size: 120) : null,
        glow: colorById(vault.color).color, onCovered: () {
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
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final cardColor = Theme.of(context).cardColor.withValues(alpha: .94);
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
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: ink, letterSpacing: -.3),
                  ),
                  const SizedBox(height: 14),
                  if (_mode == _Mode.pin)
                    PinDots(filled: _pin.length, color: accent)
                  else
                    _passwordField(l, ink),
                  if (_mode == _Mode.password && _remind) ...[
                    Text(l.passwordRemindBody, textAlign: TextAlign.center, style: TextStyle(color: ink.withValues(alpha: .7), fontSize: 13)),
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
                            fontSize: 13,
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
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ],
                  if (_mode == _Mode.password) ...[
                    const SizedBox(height: 12),
                    ListenableBuilder(
                      listenable: _password,
                      builder: (context, _) => FilledButton(
                        onPressed: _busy || _password.text.isEmpty ? null : () => _attempt(quiet: false),
                        child: BusyLabel(busy: _busy, idle: l.unlockButton, working: l.unlocking),
                      ),
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
                child: BrandMark(size: 78, color: accent),
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
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Align(alignment: Alignment.centerLeft, child: _moreMenu(l)),
                        ),
                        if (bio != null)
                          _RoundButton(
                            key: const ValueKey('biometric-button'),
                            size: 60,
                            tooltip: bio == BiometricKind.face ? l.unlockWithFace : l.unlockWithFingerprint,
                            onTap: _busy ? null : _unlockBiometric,
                            child: BiometricGlyph(kind: bio, size: 28, color: ink),
                          ),
                        const Expanded(child: SizedBox()),
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
  static final _menuItem = MenuItemButton.styleFrom(
    foregroundColor: const Color(0xFF1A1D1F),
    iconColor: const Color(0xFF1A1D1F),
    minimumSize: const Size(220, 48),
  );

  /// "Use password" / "Use PIN", "Create a new vault" (owner check first), "Restore".
  Widget _moreMenu(AppLocalizations l) => MenuAnchor(
        alignmentOffset: const Offset(0, -8),
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(10),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          side: const WidgetStatePropertyAll(BorderSide.none),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        ),
        menuChildren: [
          if (_mode == _Mode.pin && _anyPassword)
            MenuItemButton(
              style: _menuItem,
              leadingIcon: const Icon(Icons.key_outlined),
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
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(Icons.add),
            onPressed: _busy ? null : _newVault,
            child: Text(l.newVault),
          ),
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(Icons.settings_backup_restore),
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RestoreScreen(libraryDir: widget.libraryDir, needFile: true),
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
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NewVaultScreen(libraryDir: widget.libraryDir, first: false),
    ));
  }

  Widget _passwordField(AppLocalizations l, Color ink) {
    return TextField(
      controller: _password,
      focusNode: _focus,
      enabled: !_busy,
      autofocus: _bioKind == null,
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
          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
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
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .12),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(dimension: size, child: Center(child: child)),
          ),
        ),
      );
}
