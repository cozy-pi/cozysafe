import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'common.dart';
import 'vault_home.dart';

class CreateVaultScreen extends StatefulWidget {
  const CreateVaultScreen({super.key, required this.libraryDir, required this.first});

  final String libraryDir;

  /// First vault on this device (no way back to an unlock screen).
  final bool first;

  @override
  State<CreateVaultScreen> createState() => _CreateVaultScreenState();
}

class _CreateVaultScreenState extends State<CreateVaultScreen> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _nameFilled = false;
  bool _obscure = true;
  bool _ack = false;
  bool _busy = false;
  int _score = 0;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_nameFilled) {
      _name.text = AppLocalizations.of(context).vaultNameDefault;
      _nameFilled = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _passwordsMatch => _password.text == _confirm.text;

  bool get _ready =>
      !_busy &&
      _ack &&
      _name.text.trim().isNotEmpty &&
      _score >= rust.minPasswordScore() &&
      _passwordsMatch;

  void _onPasswordChanged(String value) {
    setState(() {
      _score = value.isEmpty ? 0 : rust.passwordScore(password: value);
      _error = null;
    });
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await rust.createVault(
        dir: widget.libraryDir,
        name: _name.text,
        password: _password.text,
      );
      if (!mounted) return;
      _password.clear();
      _confirm.clear();
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
    final mismatch = _confirm.text.isNotEmpty && !_passwordsMatch;

    return Scaffold(
      appBar: widget.first ? null : AppBar(),
      body: FormColumn(
        children: [
          Text(
            widget.first ? l.createFirstTitle : l.createTitle,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(l.createLead, style: TextStyle(color: c.muted, fontSize: 15, height: 1.5)),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: l.vaultName),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l.password,
              suffixIcon: IconButton(
                tooltip: _obscure ? l.showPassword : l.hidePassword,
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: _onPasswordChanged,
          ),
          if (_password.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            _StrengthMeter(score: _score),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: l.confirmPassword,
              errorText: mismatch ? l.passwordsDiffer : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          // Material, not a decorated Container: the checkbox row paints its ink on
          // the nearest Material, and a coloured box in between would hide it.
          Material(
            color: c.warnBg,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: DefaultTextStyle.merge(
              style: TextStyle(color: c.warnInk, fontSize: 14, height: 1.45),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.noRecoveryTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(l.noRecoveryBody),
                  CheckboxListTile(
                    value: _ack,
                    onChanged: _busy ? null : (v) => setState(() => _ack = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l.acknowledge,
                      style: TextStyle(color: c.warnInk, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _ready ? _create : null,
            child: BusyLabel(busy: _busy, idle: l.createButton, working: l.creating),
          ),
        ],
      ),
    );
  }
}

class _StrengthMeter extends StatelessWidget {
  const _StrengthMeter({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ok = score >= rust.minPasswordScore();
    final fill = ok ? Theme.of(context).colorScheme.primary : c.warnInk;
    final label = switch (score) {
      <= 1 => l.strengthTooWeak,
      2 => l.strengthWeak,
      3 => l.strengthGood,
      _ => l.strengthStrong,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: i < score ? fill : c.soft,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: c.muted, fontSize: 13)),
      ],
    );
  }
}
