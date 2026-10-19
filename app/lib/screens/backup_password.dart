import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'common.dart';
import 'emergency_kit.dart';

/// The backup password, set when it is needed (first backup, or the nudge in the
/// vault) and changed the same way. "Suggest a password" fills five random words in one
/// tap; it is typed again once so it is really known. The first time, the Emergency
/// Kit follows. Pops with the updated vault info.
class BackupPasswordScreen extends StatefulWidget {
  const BackupPasswordScreen({super.key, required this.libraryDir, required this.change});

  final String libraryDir;
  /// The vault already has a password (this changes it; no Emergency Kit step).
  final bool change;

  @override
  State<BackupPasswordScreen> createState() => _BackupPasswordScreenState();
}

class _BackupPasswordScreenState extends State<BackupPasswordScreen> {
  final _pw = TextEditingController();
  final _again = TextEditingController();
  int _score = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _again.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        _score = _pw.text.isEmpty ? 0 : rust.passwordScore(password: _pw.text);
        _error = null;
      });

  void _suggest() {
    _pw.text = rust.suggestPassphrase();
    _again.clear();
    _changed();
  }

  bool get _ready => !_busy && _score >= rust.minPasswordScore() && _pw.text == _again.text;

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final info = await rust.setPassword(dir: widget.libraryDir, password: _pw.text);
      _pw.clear();
      _again.clear();
      if (!mounted) return;
      if (!widget.change) {
        final key = await SecretKeyStore.read();
        if (key != null && mounted) {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (kitContext) => EmergencyKitScreen(
              keyText: rust.secretKeyText(key: key),
              confirm: true,
              onDone: () => Navigator.of(kitContext).pop(),
            ),
          ));
        }
      }
      if (mounted) Navigator.of(context).pop(info);
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    final strong = _score >= rust.minPasswordScore();
    return Scaffold(
      appBar: AppBar(),
      body: FormColumn(
        children: [
          Text(widget.change ? l.changePasswordTitle : l.backupPasswordTitle,
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(l.backupPasswordLead, style: TextStyle(color: c.muted, fontSize: 15, height: 1.5)),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _suggest,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(l.suggestPassword),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(labelText: l.password),
            onChanged: (_) => _changed(),
          ),
          const SizedBox(height: 6),
          if (_pw.text.isNotEmpty)
            Text(
              strong ? l.passwordStrongEnough : l.strengthTooWeak,
              style: TextStyle(color: strong ? theme.colorScheme.primary : c.warnInk, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _again,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              labelText: l.typeAgain,
              errorText: _again.text.isNotEmpty && _again.text != _pw.text ? l.passwordsDiffer : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _ready ? _save : null,
            child: BusyLabel(busy: _busy, idle: l.save, working: l.saving),
          ),
        ],
      ),
    );
  }
}
