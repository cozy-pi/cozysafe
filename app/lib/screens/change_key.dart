import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../lock_resume.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/recovery_words.dart';
import '../widgets/secret.dart';

/// A new Recovery Key for this device (owner 2026-10-24), from 24 words or from a key
/// made before them: what changes → the new words, written down → four typed back →
/// the vault is wrapped again with its password and the new key (no item is touched) →
/// done, with a reminder that earlier backups still need the old key.
///
/// Order, so that stopping anywhere never locks the vault out: Rust first keeps the old
/// wrap beside the new one and lets the library accept both keys, then the keystore
/// takes the new key, then Rust drops the old one.
class ChangeKeyScreen extends StatefulWidget {
  const ChangeKeyScreen({
    super.key,
    required this.libraryDir,
    this.password,
    required this.onBackup,
  });
  final String libraryDir;

  /// The vault password, typed just before (Face ID, then the password); null when the
  /// vault locked since, and it is asked again on the check step.
  final String? password;
  final Future<void> Function() onBackup;

  /// For the mockup renders: these words instead of a new key, and the step to show.
  static String? debugWords;
  static int? debugStep;

  @override
  State<ChangeKeyScreen> createState() => _ChangeKeyScreenState();
}

enum _Step { intro, words, check, done }

class _ChangeKeyScreenState extends State<ChangeKeyScreen> with VaultLockAware {
  late _Step _step = _Step.values[ChangeKeyScreen.debugStep ?? 0];
  late final List<int> _key = rust.newSecretKey();
  late final List<String> _words =
      (ChangeKeyScreen.debugWords ?? rust.secretKeyText(key: _key)).split(' ');
  late final List<int> _ask = pickFourWords(
    fixed: ChangeKeyScreen.debugWords != null,
  );
  bool _busy = false;
  String? _error;

  /// The passwords of the vaults to move: this vault's (typed before), then any other
  /// vault here that shares the key (owner 2026-10-25: with two vaults it refused).
  /// Dropped when the vault locks; the page itself stays under the lock with its words.
  late final List<String> _passwords = [?widget.password];
  final _typed = TextEditingController();

  /// Another vault here needs its password too.
  bool _other = false;

  /// A password is asked on the check step: this vault's again after a lock, or another's.
  bool get _asking => _passwords.isEmpty || _other;
  /// The four words typed back are right.
  bool _checkOk = false;

  @override
  void dispose() {
    _typed.clear();
    _typed.dispose();
    _passwords.clear();
    super.dispose();
  }

  @override
  void vaultLocking() {
    _passwords.clear();
    _typed.clear();
    setState(() => _other = false);
  }

  Future<void> _apply() async {
    final l = AppLocalizations.of(context);
    final typed = _typed.text;
    if (_asking && typed.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final all = [..._passwords, if (_asking) typed];
    try {
      final r = await rust.changeSecretKey(
        dir: widget.libraryDir,
        passwords: all,
        newKey: _key,
      );
      if (!mounted) return;
      switch (r.step) {
        case rust.KeyChangeStep.wrongPassword:
          setState(() => _error = l.wrongPassword);
          return;
        case rust.KeyChangeStep.otherVault:
          // The one just typed opened a vault: keep it and ask for the next.
          _passwords
            ..clear()
            ..addAll(all);
          _typed.clear();
          setState(() {
            _other = true;
            _error = null;
          });
          return;
        case rust.KeyChangeStep.changed:
      }
      await SecretKeyStore.write(Uint8List.fromList(_key));
      await rust.finishSecretKeyChange(dir: widget.libraryDir, newKey: _key);
      _passwords.clear();
      _typed.clear();
      if (mounted) setState(() => _step = _Step.done);
    } catch (e) {
      // What went wrong, by name, after the plain sentence (Settings → Debug has the rest).
      final why = e is rust.VaultError ? e.name : e.runtimeType.toString();
      if (mounted) setState(() => _error = '${l.changeKeyFailed}\n($why)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() => setState(() {
    _error = null;
    _step = _step == _Step.check ? _Step.words : _Step.intro;
  });

  Widget _button(Key key, String label, VoidCallback? onTap) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      key: key,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        shape: const StadiumBorder(),
      ),
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
        child: Text(
          l.changeKeyBackupNote,
          style: TextStyle(color: c.warnInk, fontSize: 14, height: 1.45),
        ),
      ),
    );
    final body = switch (_step) {
      _Step.intro => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.changeKeyLead,
            style: const TextStyle(fontSize: 16, height: 1.45),
          ),
          const SizedBox(height: 14),
          note,
          const SizedBox(height: 12),
          Text(
            l.changeNoReencrypt,
            key: const ValueKey('change-no-reencrypt'),
            style: TextStyle(color: c.muted, fontSize: 13.5, height: 1.4),
          ),
        ],
      ),
      _Step.words => RecoveryWordsPanel(words: _words),
      _Step.check => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_asking) ...[
            if (_other) ...[
              Text(
                l.changeKeyOtherVault,
                style: const TextStyle(fontSize: 15, height: 1.45),
              ),
              const SizedBox(height: 10),
            ],
            SecretField(
              key: const ValueKey('change-password'),
              controller: _typed,
              enabled: !_busy,
              label: _other ? l.changeKeyOtherPassword : l.backupPasswordLabel,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 16),
          ],
          RecoveryWordsCheck(
            words: _words,
            ask: _ask,
            onValid: (ok) => setState(() => _checkOk = ok),
            onShowAgain: () => setState(() {
              _checkOk = false;
              _step = _Step.words;
            }),
          ),
        ],
      ),
      _Step.done => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 64,
            color: Color(0xFF34C759),
          ),
          const SizedBox(height: 16),
          Text(
            l.changeKeyDone,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          note,
        ],
      ),
    };
    // Each step's button pinned at the bottom (owner 2026-10-25: within the thumb's reach).
    final actions = switch (_step) {
      _Step.intro => [
        _button(const ValueKey('change-start'), l.changeKeyStart, () => setState(() => _step = _Step.words)),
      ],
      _Step.words => [
        _button(const ValueKey('words-done'), l.wordsWritten, () => setState(() {
          _checkOk = false;
          _step = _Step.check;
        })),
      ],
      _Step.check => [
        _button(
          const ValueKey('change-apply'),
          _busy ? l.checking : l.changeKeyApply,
          _checkOk && !_busy && (!_asking || _typed.text.isNotEmpty) ? _apply : null,
        ),
      ],
      _Step.done => [
        _button(const ValueKey('change-backup'), l.backupNow, () async {
          Navigator.of(context).pop();
          await widget.onBackup();
        }),
        const SizedBox(height: 4),
        TextButton(
          key: const ValueKey('change-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.close),
        ),
      ],
    };
    // Back goes one step back (the same words), and leaves only from the first step or
    // the end; never while the key is being changed (owner 2026-10-25: Back on the check
    // step closed the whole page).
    final inner = _step == _Step.words || _step == _Step.check;
    return PopScope(
      canPop: !_busy && !inner,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && inner) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.changeKeyTitle),
          automaticallyImplyLeading: _step != _Step.done,
          leading: inner
              ? IconButton(
                  key: const ValueKey('change-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const BackButtonIcon(),
                  onPressed: _busy ? null : _back,
                )
              : null,
        ),
        body: PinnedAction(
          padding: 20,
          actions: actions,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [body],
          ),
        ),
      ),
    );
  }
}
