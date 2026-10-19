import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/brand.dart';
import 'common.dart';
import 'create_vault.dart';
import 'vault_home.dart';

/// The lock screen (design B2, docs/ui.md). Biometrics are asked for right away; the
/// PIN pad is the fallback; the password is the fallback of the fallback. The add dock
/// at the bottom is the same as inside the vault: picking an action here unlocks first,
/// then runs it.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.libraryDir});

  final String libraryDir;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

enum _Mode { pin, password }

class _UnlockScreenState extends State<UnlockScreen> {
  final _password = TextEditingController();
  final _focus = FocusNode();
  final _keys = FocusNode(skipTraversal: true);
  late _Mode _mode;
  late int _pinLength;
  String _pin = '';
  bool _obscure = true;
  bool _busy = false;
  bool _checking = false;
  bool _leaving = false;
  String? _error;
  int _shake = 0;
  BiometricKind? _bioKind;
  bool _bioOn = false;
  AddMode? _pending;

  /// Stop typing this long and the password is tried without pressing Enter.
  static const _pause = Duration(milliseconds: 350);
  Timer? _debounce;
  String? _tried;

  @override
  void initState() {
    super.initState();
    _pinLength = rust.pinLength(dir: widget.libraryDir);
    _mode = _pinLength > 0 ? _Mode.pin : _Mode.password;
    _bioOn = BiometricUnlock.platformSupported && rust.hasBiometricUnlock(dir: widget.libraryDir);
    if (_bioOn) {
      BiometricUnlock.available().then((kind) {
        if (!mounted || kind == null) return;
        setState(() => _bioKind = kind);
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlockBiometric());
      });
    }
  }

  @override
  void dispose() {
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
    if (_busy || _pin.length >= _pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == _pinLength) _checkPin();
  }

  void _deleteDigit() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _checkPin() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final device = await PinStore.deviceKey();
      final vault = device == null
          ? null
          : await rust.unlockWithPin(dir: widget.libraryDir, pin: _pin, deviceKey: device);
      if (vault != null) {
        await PinStore.setFails(0);
        return await _open(vault);
      }
      final fails = (await PinStore.fails()) + 1;
      if (device == null || fails >= PinStore.maxTries) {
        await rust.forgetPin(dir: widget.libraryDir);
        await PinStore.clear();
        if (!mounted) return;
        setState(() {
          _mode = _Mode.password;
          _pinLength = 0;
          _error = l.pinLocked;
        });
        return;
      }
      await PinStore.setFails(fails);
      HapticFeedback.heavyImpact();
      if (mounted) {
        setState(() {
          _shake++;
          _error = l.pinWrong(PinStore.maxTries - fails);
        });
      }
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } finally {
      if (mounted && !_leaving) {
        setState(() {
          _busy = false;
          _pin = '';
        });
      }
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
      if (vault != null) return await _open(vault, offerBiometric: true);
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
    final pending = _pending;
    await playVaultSpin(context, opening: true, onCovered: () {
      nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) =>
              VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault, initialAction: pending),
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

  /// An add action picked while locked: unlock first, then the vault runs it.
  void _onDockAction(AddMode mode) {
    final l = AppLocalizations.of(context);
    setState(() => _pending = mode);
    if (_bioKind != null && _bioOn) {
      _unlockBiometric();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.unlockToAdd)));
      if (_mode == _Mode.password) _focus.requestFocus();
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? const Color(0xF0103029) : const Color(0xF0FFFFFF);
    final ink = dark ? const Color(0xFFE9ECEB) : const Color(0xFF1A1D1F);
    final accent = dark ? Brand.gold : Brand.green;
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
                    _mode == _Mode.pin ? l.pinEnter : l.unlockTitle,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: ink, letterSpacing: -.3),
                  ),
                  const SizedBox(height: 14),
                  if (_mode == _Mode.pin)
                    PinDots(length: _pinLength, filled: _pin.length, color: accent)
                  else
                    _passwordField(l, ink),
                  if (_error != null) ...[
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
                  const SizedBox(height: 4),
                  if (_mode == _Mode.pin)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _mode = _Mode.password),
                      child: Text(l.usePassword),
                    )
                  else
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        if (_pinLength > 0)
                          TextButton(onPressed: () => setState(() => _mode = _Mode.pin), child: Text(l.usePin)),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                                    builder: (_) => CreateVaultScreen(libraryDir: widget.libraryDir, first: false),
                                  )),
                          child: Text(l.newVault),
                        ),
                      ],
                    ),
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
                  color: dark ? Brand.night : Colors.white,
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
      backgroundColor: Brand.deep,
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
                                    PinPad(onDigit: _digit, onDelete: _deleteDigit, enabled: !_busy),
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
                AddDock(
                  leading: DockSlot(icon: Icons.lock_outline, label: l.lockedAddOnly, outlined: true),
                  trailing: bio == null
                      ? const SizedBox(width: 46)
                      : DockSlot(
                          icon: bio == BiometricKind.face ? Icons.face_outlined : Icons.fingerprint,
                          label: bio == BiometricKind.face ? l.unlockWithFace : l.unlockWithFingerprint,
                          onTap: _busy ? null : _unlockBiometric,
                        ),
                  onAction: _onDockAction,
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
