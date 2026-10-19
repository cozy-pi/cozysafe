import 'dart:math' as math;

import 'package:flutter/material.dart';

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
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_password.text.isEmpty || _busy) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await rust.unlock(dir: widget.libraryDir, password: _password.text);
      if (!mounted) return;
      if (vault == null) {
        setState(() => _error = l.wrongPassword);
        return;
      }
      _password.clear();
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault),
        ),
        (_) => false,
      );
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } catch (_) {
      if (mounted) setState(() => _error = l.errorStorage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);

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
            autofocus: true,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l.password,
              errorText: _error,
              suffixIcon: IconButton(
                tooltip: _obscure ? l.showPassword : l.hidePassword,
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _unlock(),
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: _password,
            builder: (context, _) => FilledButton(
              onPressed: _busy || _password.text.isEmpty ? null : _unlock,
              child: BusyLabel(busy: _busy, idle: l.unlockButton, working: l.unlocking),
            ),
          ),
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
