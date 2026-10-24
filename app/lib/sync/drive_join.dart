import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/common.dart';
import '../screens/set_pin.dart';
import '../screens/vault_home.dart';
import '../secret_key_store.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/secret.dart';
import 'consent.dart';
import 'drive.dart';

/// A new device with no vault: open the one kept in Google Drive with the 24 words and
/// the vault password, no backup file (owner 2026-10-24). Sign in, allow the
/// connection, type the two secrets; the vault comes down sealed, opens here, then this
/// phone gets its own PIN.
class DriveJoinScreen extends StatefulWidget {
  const DriveJoinScreen({super.key, required this.libraryDir});
  final String libraryDir;

  /// For the mockup renders: signed in as this account, nothing asked.
  static String? debugAccount;

  @override
  State<DriveJoinScreen> createState() => _DriveJoinScreenState();
}

class _DriveJoinScreenState extends State<DriveJoinScreen> {
  final _words = TextEditingController();
  final _password = TextEditingController();
  DriveSession? _session;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _words.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  String? get _account => DriveJoinScreen.debugAccount ?? _session?.email;

  Future<void> _signIn() async {
    final l = AppLocalizations.of(context);
    setState(() => _error = null);
    try {
      final s = await driveSignIn();
      if (s == null || !mounted) return;
      if (!await allowConnection(context, l.syncAllowDrive(s.email)) || !mounted) return;
      setState(() => _session = s);
    } catch (_) {
      if (mounted) setState(() => _error = l.syncFailed);
    }
  }

  Future<void> _open() async {
    final l = AppLocalizations.of(context);
    final session = _session;
    if (session == null || _busy) return;
    final parsed = rust.parseSecretKey(text: _words.text);
    if (parsed == null) {
      setState(() => _error = l.secretKeyTypo);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await sync.driveJoin(
          dir: widget.libraryDir, token: session.token, words: _words.text, password: _password.text);
      if (!mounted) return;
      final vault = r.vault;
      if (r.outcome != sync.JoinOutcome.joined || vault == null) {
        setState(() => _error = switch (r.outcome) {
              sync.JoinOutcome.noVault => l.joinNoVault,
              sync.JoinOutcome.wrongWords => l.joinWrongWords,
              sync.JoinOutcome.wrongPassword => l.wrongPassword,
              sync.JoinOutcome.signIn => l.syncSignInAgain,
              _ => l.syncFailed,
            });
        if (r.outcome == sync.JoinOutcome.signIn) _session = null;
        return;
      }
      // This device keeps the words now, like a device that made the vault.
      await SecretKeyStore.write(Uint8List.fromList(parsed));
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const SetPinScreen(skippable: true, forThisPhone: true)),
      );
      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault)),
        (_) => false,
      );
    } catch (_) {
      if (mounted) setState(() => _error = l.syncFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    final account = _account;
    return Scaffold(
      appBar: AppBar(),
      body: FormColumn(
        children: [
          Text(l.joinDriveTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(l.joinDriveLead, style: TextStyle(color: c.muted, fontSize: 15, height: 1.5)),
          const SizedBox(height: 24),
          if (account == null)
            FilledButton.icon(
              key: const ValueKey('join-sign-in'),
              onPressed: _signIn,
              icon: const Icon(Icons.account_circle_outlined),
              label: Text(l.joinSignIn),
            )
          else ...[
            Row(children: [
              const Icon(Icons.cloud_done_outlined, size: 20, color: Color(0xFF34A853)),
              const SizedBox(width: 8),
              Expanded(child: Text(account, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 16),
            SecretField(
              key: const ValueKey('join-words'),
              controller: _words,
              enabled: !_busy,
              multiline: true,
              label: l.secretKeyLabel,
              hint: l.recoveryWordsHint,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 12),
            SecretField(
              key: const ValueKey('join-password'),
              controller: _password,
              enabled: !_busy,
              label: l.backupPasswordLabel,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _open(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('join-open'),
              onPressed: _busy || _words.text.trim().isEmpty || _password.text.isEmpty ? null : _open,
              child: BusyLabel(busy: _busy, idle: l.joinOpen, working: l.restoring),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
