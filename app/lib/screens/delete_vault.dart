import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/countdown.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'unlock.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/toast.dart';
import 'welcome.dart';

/// Delete the open vault, confirmed with its own password (no PIN since 2026-10-28). In the opposite brightness (light when the app is dark, and the reverse), so it is
/// never taken for the lock screen. Wrong passwords count towards the same waits as the lock screen.
class DeleteVaultScreen extends StatefulWidget {
  const DeleteVaultScreen({
    super.key,
    required this.libraryDir,
    required this.vault,
    required this.sizeText,
  });

  final String libraryDir;
  final rust.VaultInfo vault;
  /// "214 MB · 86 items", what goes with it.
  final String sizeText;

  @override
  State<DeleteVaultScreen> createState() => _DeleteVaultScreenState();
}

class _DeleteVaultScreenState extends State<DeleteVaultScreen> with VaultLockAware {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  /// The password typed is not kept while the vault is locked (the countdown, if open,
  /// closes as Cancel).
  @override
  void vaultLocking() => setState(_pw.clear);

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final until = await PinStore.passwordWaitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        final m = until.difference(DateTime.now()).inSeconds;
        setState(() {
          _busy = false;
          _error = l.pinWait(m <= 60 ? 1 : (m / 60).ceil());
        });
        return;
      }
      // Ten seconds to change one's mind (owner 2026-10-25).
      if (!mounted) return;
      if (!await confirmCountdown(context, title: l.deleteVaultTitle) || !mounted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final ok = await rust.deleteVault(dir: widget.libraryDir, password: _pw.text);
      if (!ok) {
        await PinStore.addPasswordFail();
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _busy = false;
            _error = l.wrongPassword;
          });
        }
        return;
      }
      await PinStore.resetPasswordFails();
      _pw.clear();
      if (!mounted) return;
      await LockGuard.clearCopied();
      if (!mounted) return;
      final any = rust.hasVaults(dir: widget.libraryDir);
      // The last vault: its 24 words go too, and the next vault starts afresh (owner
      // 2026-10-24: keeping the old key after deleting the vault was not safe).
      if (!any) {
        try {
          await rust.resetEmptyLibrary(dir: widget.libraryDir);
          await SecretKeyStore.delete();
          rust.forgetSecretKey();
          await PinStore.resetFails();
          await PinStore.resetPasswordFails();
        } catch (_) {
          // The new-vault screen still starts afresh from an empty library.
        }
      }
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => any
              ? UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false)
              : WelcomeScreen(libraryDir: widget.libraryDir),
        ),
        (_) => false,
      );
      showToast(context, l.vaultDeleted, icon: Icons.check_rounded);
    } on rust.VaultError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = vaultErrorText(l, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final inverted = Theme.of(context).brightness == Brightness.dark ? Brightness.light : Brightness.dark;
    return Theme(data: buildTheme(inverted), child: Builder(builder: _page));
  }

  Widget _page(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: ink),
      // Delete, red, pinned at the bottom (owner 2026-10-25: buttons within the thumb's reach).
      body: SafeArea(
        bottom: false,
        child: PinnedAction(
          actions: [
            FilledButton(
              key: const ValueKey('delete-vault-go'),
              style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
              onPressed: _pw.text.isNotEmpty && !_busy ? _confirm : null,
              child: Text(l.deleteVaultAction),
            ),
          ],
          child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                children: [
                  VaultBadge(icon: widget.vault.icon, color: widget.vault.color, size: 64),
                  const SizedBox(height: 14),
                  Text(l.deleteVaultTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, fontSize: CsType.title2, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    l.deleteVaultBody(widget.sizeText),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink.withValues(alpha: .85), height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: ink.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error ?? l.deleteVaultPassword,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: ink,
                            fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400)),
                  ),
                  const SizedBox(height: 16),
                  SecretField(
                    key: const ValueKey('delete-vault-password'),
                    controller: _pw,
                    label: l.password,
                    enabled: !_busy,
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _pw.text.isNotEmpty && !_busy ? _confirm() : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
