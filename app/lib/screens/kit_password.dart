import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../lock_resume.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/secret.dart';
import 'common.dart';

/// The vault password, asked after Face ID before the Recovery Key is shown (owner
/// 2026-10-24: Face ID alone was too little for the 24 words). Wrong tries count with
/// the lock screen's, so the same waits apply.
class KitPasswordScreen extends StatefulWidget {
  const KitPasswordScreen({super.key, required this.libraryDir});
  final String libraryDir;

  /// Pushes the screen; the password once it was the right one (a Recovery Key change
  /// needs it again), null otherwise.
  static Future<String?> ask(BuildContext context, String libraryDir) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => KitPasswordScreen(libraryDir: libraryDir)));

  @override
  State<KitPasswordScreen> createState() => _KitPasswordScreenState();
}

class _KitPasswordScreenState extends State<KitPasswordScreen> with VaultLockAware {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void vaultLocking() => setState(() {
        _pw.clear();
        _error = null;
      });

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final l = AppLocalizations.of(context);
    if (_pw.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final until = await PinStore.passwordWaitUntil();
      if (until != null) {
        final m = (until.difference(DateTime.now()).inSeconds / 60).ceil();
        setState(() => _error = l.pinWait(m < 1 ? 1 : m));
        return;
      }
      final ok = await rust.checkPassword(dir: widget.libraryDir, password: _pw.text);
      if (!mounted) return;
      if (ok) {
        await PinStore.resetPasswordFails();
        if (mounted) Navigator.of(context).pop(_pw.text);
        return;
      }
      final wait = await PinStore.addPasswordFail();
      if (!mounted) return;
      final m = (wait.inSeconds / 60).ceil();
      setState(() => _error = wait > Duration.zero ? l.pinWait(m < 1 ? 1 : m) : l.wrongPassword);
    } catch (_) {
      if (mounted) setState(() => _error = l.wrongPassword);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.showKit)),
      body: PinnedAction(
        padding: 20,
        actions: [
          FilledButton(
            key: const ValueKey('kit-password-go'),
            onPressed: _busy || _pw.text.isEmpty ? null : _check,
            child: BusyLabel(busy: _busy, idle: l.kitPasswordGo, working: l.checking),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(l.kitPasswordLead, style: TextStyle(color: c.muted, fontSize: 15.5, height: 1.4)),
            const SizedBox(height: 18),
            SecretField(
              key: const ValueKey('kit-password'),
              controller: _pw,
              enabled: !_busy,
              label: l.kitPasswordTitle,
              errorText: _error,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _check(),
            ),
          ],
        ),
      ),
    );
  }
}
