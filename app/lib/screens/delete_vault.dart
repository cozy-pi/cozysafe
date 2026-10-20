import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../widgets/pin_pad.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'new_vault.dart';
import 'unlock.dart';

/// Delete the open vault, confirmed with its own PIN. Red, so it is never taken for the
/// lock screen. Wrong PINs count towards the same waits as the PIN pad.
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

class _DeleteVaultScreenState extends State<DeleteVaultScreen> {
  static const _bg = Color(0xFF3A1210);
  static const _ink = Color(0xFFFFB4AB);
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
      await LockGuard.clearCopied();
      if (!mounted) return;
      final any = rust.hasVaults(dir: widget.libraryDir);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => any
              ? UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false)
              : NewVaultScreen(libraryDir: widget.libraryDir, first: true),
        ),
        (_) => false,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.vaultDeleted)));
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
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
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
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    l.deleteVaultBody(widget.sizeText),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xD9FFFFFF), height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _ink.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error ?? l.deleteVaultPin,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: _error != null ? _ink : const Color(0xFFFFD9D4),
                            fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400)),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(height: 20, child: PinDots(filled: _pin.length, color: _ink)),
                  const SizedBox(height: 16),
                  PinPad(onDigit: _digit, onDelete: _back, enabled: !_busy),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 240,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _ink, foregroundColor: _bg),
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
