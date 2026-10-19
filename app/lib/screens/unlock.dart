import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'common.dart';
import 'create_vault.dart';
import 'vault_home.dart';

/// One password field and no vault list: the password decides which vault opens.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.libraryDir});

  final String libraryDir;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  bool _checking = false;
  String? _error;
  BiometricKind? _bioKind;
  bool _bioOn = false;
  bool _leaving = false;

  /// Stop typing this long and the password is tried without pressing Enter.
  static const _pause = Duration(milliseconds: 350);
  Timer? _debounce;
  String? _tried;

  @override
  void initState() {
    super.initState();
    _bioOn = BiometricUnlock.platformSupported && rust.hasBiometricUnlock(dir: widget.libraryDir);
    if (_bioOn) {
      BiometricUnlock.available().then((kind) {
        if (!mounted || kind == null) return;
        setState(() => _bioKind = kind);
        // Ask right away, like the lock screen: most opens need no typing at all.
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlockBiometric());
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _password.dispose();
    super.dispose();
  }

  BiometricUnlock _store(AppLocalizations l) =>
      BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel);

  Future<void> _unlockBiometric() async {
    if (_busy || _leaving) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final vault = await _store(l).unlock(widget.libraryDir);
      if (vault != null) return _open(vault);
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

  void _onChanged(String _) {
    if (_error != null) setState(() => _error = null);
    _debounce?.cancel();
    if (_password.text.length >= 4) _debounce = Timer(_pause, () => _attempt(quiet: true));
  }

  /// Try the password. Quiet tries (while typing) never show "wrong password";
  /// Enter or the button does. One Argon2 run at a time; a newer text is tried after.
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
      if (vault != null) return _open(vault, offerBiometric: true);
      if (_password.text != text) {
        // Typing moved on while this ran: try the newer text next.
        _checking = false;
        return _attempt(quiet: !_busy);
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

  Future<void> _open(rust.VaultInfo vault, {bool offerBiometric = false}) async {
    _leaving = true;
    _debounce?.cancel();
    _password.clear();
    final l = AppLocalizations.of(context);
    if (offerBiometric && !rust.hasBiometricUnlock(dir: widget.libraryDir)) {
      await _maybeOfferBiometric(l);
    }
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault),
      ),
      (_) => false,
    );
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
    if (yes == true) await turnOnBiometric(_store(l));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    final bio = _bioOn ? _bioKind : null;

    return Scaffold(
      body: FormColumn(
        children: [
          const BrandHeader(center: true),
          const SizedBox(height: 28),
          const Center(child: SafeDial(size: 200)),
          const SizedBox(height: 24),
          Text(
            l.unlockTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(l.unlockLead, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15)),
          const SizedBox(height: 28),
          TextField(
            controller: _password,
            enabled: !_busy,
            autofocus: bio == null,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l.password,
              errorText: _error,
              helperText: _checking && !_busy ? l.checking : null,
              suffixIcon: IconButton(
                tooltip: _obscure ? l.showPassword : l.hidePassword,
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) => _attempt(quiet: false),
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: _password,
            builder: (context, _) => FilledButton(
              onPressed: _busy || _password.text.isEmpty ? null : () => _attempt(quiet: false),
              child: BusyLabel(busy: _busy, idle: l.unlockButton, working: l.unlocking),
            ),
          ),
          if (bio != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _unlockBiometric,
              icon: Icon(bio == BiometricKind.face ? Icons.face_outlined : Icons.fingerprint),
              label: Text(bio == BiometricKind.face ? l.unlockWithFace : l.unlockWithFingerprint),
            ),
          ],
          const SizedBox(height: 24),
          Center(
            child: TextButton(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CreateVaultScreen(libraryDir: widget.libraryDir, first: false),
                        ),
                      ),
              child: Text(l.newVault),
            ),
          ),
        ],
      ),
    );
  }
}

/// The safe's combination dial: the one memorable element of the design.
class SafeDial extends StatelessWidget {
  const SafeDial({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _DialPainter(ticks: c.muted, mark: scheme.primary),
          ),
          Container(
            width: size * 0.55,
            height: size * 0.55,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: c.border),
            ),
            child: Icon(Icons.lock_outline, size: size * 0.2, color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({required this.ticks, required this.mark});

  final Color ticks;
  final Color mark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.width / 2 - 2;
    final paint = Paint()
      ..color = ticks
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 60; i++) {
      final major = i % 5 == 0;
      final a = i * 6 * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      paint.strokeWidth = major ? 2 : 1;
      canvas.drawLine(center + dir * (outer - (major ? 12 : 6)), center + dir * outer, paint);
    }
    canvas.drawCircle(
      center,
      outer * 0.76,
      Paint()
        ..color = ticks
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawLine(
      center + Offset(0, -outer - 2),
      center + Offset(0, -outer + 12),
      Paint()
        ..color = mark
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.ticks != ticks || old.mark != mark;
}
