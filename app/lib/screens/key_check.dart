import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/words_input.dart';
import 'common.dart';

/// Settings → Check your 24 words and password (owner 2026-10-26, instead of asking for
/// them every so often): type them back to know they still open this vault. Only
/// compared: nothing is shown, kept or changed, and what was typed goes when the vault
/// locks or the page closes.
class KeyCheckScreen extends StatefulWidget {
  const KeyCheckScreen({super.key, required this.libraryDir, required this.hasPassword});
  final String libraryDir;
  final bool hasPassword;

  /// For the mockup renders: results without the Rust side.
  static ({bool? words, bool? password})? debugResults;

  @override
  State<KeyCheckScreen> createState() => _KeyCheckScreenState();
}

class _KeyCheckScreenState extends State<KeyCheckScreen> with VaultLockAware {
  final _words = TextEditingController();
  final _password = TextEditingController();
  bool? _wordsOk;
  bool? _passwordOk;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _wordsOk = KeyCheckScreen.debugResults?.words;
    _passwordOk = KeyCheckScreen.debugResults?.password;
  }

  @override
  void vaultLocking() {
    _words.clear();
    _password.clear();
    setState(() => _wordsOk = _passwordOk = null);
  }

  @override
  void dispose() {
    _words.clear();
    _password.clear();
    _words.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      if (_words.text.trim().isNotEmpty) {
        final key = rust.parseSecretKey(text: _words.text);
        _wordsOk = key != null && rust.secretKeyFits(dir: widget.libraryDir, key: key);
      }
      if (widget.hasPassword && _password.text.isNotEmpty) {
        // An Argon2id run, as when opening.
        _passwordOk = await rust.checkPassword(dir: widget.libraryDir, password: _password.text);
      }
    } catch (_) {
      _passwordOk ??= false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _result(bool? ok, String yes, String no, String key) {
    if (ok == null) return const SizedBox.shrink();
    final color = ok ? const Color(0xFF34C759) : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(key: ValueKey(key), children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(ok ? yes : no, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final empty = _words.text.trim().isEmpty && _password.text.isEmpty;
    return FormColumn(
      actions: [
        FilledButton(
          key: const ValueKey('key-check-go'),
          onPressed: empty || _busy ? null : _check,
          child: BusyLabel(busy: _busy, idle: l.keyCheckGo, working: l.keyCheckGo),
        ),
      ],
      children: [
        RecoveryKeyInput(
          key: const ValueKey('key-check-words'),
          controller: _words,
          onChanged: () => setState(() => _wordsOk = null),
        ),
        _result(_wordsOk, l.keyCheckWordsOk, l.keyCheckWordsBad, 'key-check-words-result'),
        if (widget.hasPassword) ...[
          const SizedBox(height: 16),
          SecretField(
            key: const ValueKey('key-check-password'),
            controller: _password,
            label: l.backupPasswordLabel,
            onChanged: (_) => setState(() => _passwordOk = null),
            onSubmitted: (_) => _check(),
          ),
          _result(_passwordOk, l.keyCheckPasswordOk, l.keyCheckPasswordBad, 'key-check-password-result'),
        ],
        const SizedBox(height: 16),
        Text(l.keyCheckNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
      ],
    );
  }
}
