import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/recovery_words.dart';

/// A new Recovery Key for this device (owner 2026-10-24), from 24 words or from a key
/// made before them: what changes → the new words, written down → four typed back →
/// the vault is wrapped again with its password and the new key (no item is touched) →
/// done, with a reminder that earlier backups still need the old key.
///
/// Order, so that stopping anywhere never locks the vault out: Rust first keeps the old
/// wrap beside the new one and lets the library accept both keys, then the keystore
/// takes the new key, then Rust drops the old one.
class ChangeKeyScreen extends StatefulWidget {
  const ChangeKeyScreen({super.key, required this.libraryDir, required this.password, required this.onBackup});
  final String libraryDir;
  /// The vault password, typed just before (Face ID, then the password).
  final String password;
  final Future<void> Function() onBackup;

  /// For the mockup renders: these words instead of a new key, and the step to show.
  static String? debugWords;
  static int? debugStep;

  @override
  State<ChangeKeyScreen> createState() => _ChangeKeyScreenState();
}

enum _Step { intro, words, check, done }

class _ChangeKeyScreenState extends State<ChangeKeyScreen> {
  late _Step _step = _Step.values[ChangeKeyScreen.debugStep ?? 0];
  late final List<int> _key = rust.newSecretKey();
  late final List<String> _words =
      (ChangeKeyScreen.debugWords ?? rust.secretKeyText(key: _key)).split(' ');
  late final List<int> _ask = pickFourWords(fixed: ChangeKeyScreen.debugWords != null);
  bool _busy = false;
  String? _error;

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final l = AppLocalizations.of(context);
    try {
      if (!await rust.changeSecretKey(dir: widget.libraryDir, password: widget.password, newKey: _key)) {
        throw StateError('password');
      }
      await SecretKeyStore.write(Uint8List.fromList(_key));
      await rust.finishSecretKeyChange(dir: widget.libraryDir, newKey: _key);
      if (mounted) setState(() => _step = _Step.done);
    } catch (_) {
      if (mounted) setState(() => _error = l.changeKeyFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(Key key, String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 50), shape: const StadiumBorder()),
          onPressed: onTap,
          child: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final note = Material(
      color: c.warnBg,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(l.changeKeyBackupNote, style: TextStyle(color: c.warnInk, fontSize: 14, height: 1.45)),
      ),
    );
    final body = switch (_step) {
      _Step.intro => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.changeKeyLead, style: const TextStyle(fontSize: 16, height: 1.45)),
          const SizedBox(height: 14),
          note,
          const SizedBox(height: 22),
          _button(const ValueKey('change-start'), l.changeKeyStart, () => setState(() => _step = _Step.words)),
        ]),
      _Step.words => RecoveryWordsPanel(
          words: _words,
          action: _button(const ValueKey('words-done'), l.wordsWritten, () => setState(() => _step = _Step.check)),
        ),
      _Step.check => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
          ],
          RecoveryWordsCheck(
            words: _words,
            ask: _ask,
            action: (ok) => _button(const ValueKey('change-apply'), _busy ? l.checking : l.changeKeyApply,
                ok && !_busy ? _apply : null),
            onShowAgain: () => setState(() => _step = _Step.words),
          ),
        ]),
      _Step.done => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.check_circle_rounded, size: 64, color: Color(0xFF34C759)),
          const SizedBox(height: 16),
          Text(l.changeKeyDone, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.4)),
          const SizedBox(height: 16),
          note,
          const SizedBox(height: 22),
          _button(const ValueKey('change-backup'), l.backupNow, () async {
            Navigator.of(context).pop();
            await widget.onBackup();
          }),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.close)),
        ]),
    };
    return PopScope(
      // Not while the key is being changed.
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(l.changeKeyTitle), automaticallyImplyLeading: _step != _Step.done),
        body: SafeArea(
          top: false,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), children: [body]),
        ),
      ),
    );
  }
}
