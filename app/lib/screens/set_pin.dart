import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/brand.dart';
import 'common.dart';

/// Choose a PIN for this vault on this device: at least 4 digits, then the same again.
/// Pops with `true` once it is set. `skippable` adds "Not now" (after the first vault).
class SetPinScreen extends StatefulWidget {
  const SetPinScreen({super.key, this.skippable = false});

  final bool skippable;

  @override
  State<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends State<SetPinScreen> {
  static const _max = 256, _min = 4;
  String _pin = '';
  String? _first;
  String? _error;
  bool _busy = false;

  void _digit(String d) {
    if (_busy) return;
    final limit = _first?.length ?? _max;
    if (_pin.length >= limit) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    // Confirming: the length is known, so check as soon as it is reached.
    if (_first != null && _pin.length == _first!.length) _confirm();
  }

  void _delete() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _next() {
    if (_pin.length < _min) return;
    setState(() {
      _first = _pin;
      _pin = '';
    });
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    if (_pin != _first) {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = l.pinMismatch;
        _first = null;
        _pin = '';
      });
      return;
    }
    setState(() => _busy = true);
    try {
      // Same waits as the PIN pad: "taken" would otherwise reveal another vault's PIN.
      final until = await PinStore.waitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        final m = until.difference(DateTime.now()).inSeconds;
        if (mounted) {
          setState(() {
            _busy = false;
            _error = l.pinWait(m <= 60 ? 1 : (m / 60).ceil());
            _first = null;
            _pin = '';
          });
        }
        return;
      }
      final device = await PinStore.deviceKeyOrCreate(rust.newSecretKey);
      await rust.enablePin(pin: _pin, deviceKey: device);
      if (mounted) Navigator.of(context).pop(true);
    } on rust.VaultError catch (e) {
      if (e == rust.VaultError.pinInUse) await PinStore.addFail();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = vaultErrorText(l, e);
          _first = null;
          _pin = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l.errorStorage;
          _first = null;
          _pin = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final confirming = _first != null;
    return Scaffold(
      backgroundColor: Brand.deep,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: !widget.skippable,
        actions: [
          if (widget.skippable)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(l.notNow),
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const Positioned.fill(child: VaultBackdrop()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      confirming ? l.pinConfirmTitle : l.pinSetTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      confirming ? l.pinConfirmLead : l.pinSetLead,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xCCFFFFFF), height: 1.45),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      height: 20,
                      child: PinDots(filled: _pin.length,
                        color: Brand.gold,
                      ),
                    ),
                    SizedBox(
                      height: 44,
                      child: Center(
                        child: Text(
                          _error ?? (!confirming && _pin.length < 6 && _pin.length >= _min ? l.pinShortNote : ''),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _error != null ? const Color(0xFFFFB4AB) : const Color(0xB3FFFFFF),
                            fontSize: 13,
                            fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                    PinPad(onDigit: _digit, onDelete: _delete, enabled: !_busy),
                    const SizedBox(height: 18),
                    if (!confirming)
                      SizedBox(
                        width: 220,
                        child: FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Brand.gold, foregroundColor: Brand.goldInk),
                          onPressed: _pin.length >= _min ? _next : null,
                          child: Text(l.pinNext),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
