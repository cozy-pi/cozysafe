import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/countdown.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/pin_pad.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'unlock.dart';
import '../widgets/toast.dart';
import 'welcome.dart';

/// Delete the open vault, confirmed with its own PIN. In the opposite brightness (light when the app is dark, and the reverse), so it is
/// never taken for the lock screen. Wrong PINs count towards the same waits as the PIN pad.
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
  String _pin = '';
  String? _error;
  bool _busy = false;

  void _digit(String d) {
    if (_busy || _pin.length >= 256) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  /// The PIN typed is not kept while the vault is locked (the countdown, if open,
  /// closes as Cancel).
  @override
  void vaultLocking() => setState(() => _pin = '');

  void _back() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final until = await PinStore.waitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        final m = until.difference(DateTime.now()).inSeconds;
        setState(() {
          _busy = false;
          _pin = '';
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
      final device = await PinStore.deviceKey();
      final ok = device != null &&
          await rust.deleteVault(dir: widget.libraryDir, pin: _pin, deviceKey: device);
      if (!ok) {
        await PinStore.addFail();
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _busy = false;
            _pin = '';
            _error = l.pinWrongTry;
          });
        }
        return;
      }
      await PinStore.resetFails();
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
      Navigator.of(context).pushAndRemoveUntil(
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
          _pin = '';
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
      body: SafeArea(
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
                      style: TextStyle(color: ink, fontSize: 22, fontWeight: FontWeight.w700)),
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
                    child: Text(_error ?? l.deleteVaultPin,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: ink,
                            fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400)),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(height: 20, child: PinDots(filled: _pin.length, color: ink)),
                  const SizedBox(height: 16),
                  PinPad(onDigit: _digit, onDelete: _back, enabled: !_busy),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 240,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
                      onPressed: _pin.length >= 4 && !_busy ? _confirm : null,
                      child: Text(l.deleteVaultAction),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
