import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/add_dock.dart';
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'restore.dart';
import 'vault_home.dart';

/// Create a vault in as few steps as possible, one thing per step (docs/ui.md, first
/// run): icon → colour → PIN → PIN again → (first vault) Face ID. Tapping a choice moves
/// on; icon and colour start on a random suggestion. No name, no password: the backup
/// password comes later, when it is needed.
class NewVaultScreen extends StatefulWidget {
  const NewVaultScreen({super.key, required this.libraryDir, required this.first, this.avoid});

  final String libraryDir;
  final bool first;
  /// The open vault's icon and colour, not suggested again (creating from inside it).
  final (String, String)? avoid;

  @override
  State<NewVaultScreen> createState() => _NewVaultScreenState();
}

enum _Step { icon, color, pin, confirm }

class _NewVaultScreenState extends State<NewVaultScreen> {
  _Step _step = _Step.icon;
  late int _icon;
  late int _color;
  String _pin = '';
  String? _first;
  String? _error;
  bool _busy = false;
  int _shake = 0;

  @override
  void initState() {
    super.initState();
    final (i, c) = randomIdentity(avoid: widget.avoid);
    _icon = vaultIcons.indexWhere((x) => x.id == i);
    _color = vaultColors.indexWhere((x) => x.id == c);
  }

  void _go(_Step s) => setState(() {
        _step = s;
        _error = null;
        if (s == _Step.pin) {
          _pin = '';
          _first = null;
        }
      });

  void _back() {
    if (_step.index == 0) {
      if (!widget.first) Navigator.of(context).maybePop();
      return;
    }
    _go(_step == _Step.confirm ? _Step.pin : _Step.values[_step.index - 1]);
  }

  void _pickIcon(int i) {
    setState(() => _icon = i);
    Future.delayed(const Duration(milliseconds: 200), () => mounted ? _go(_Step.color) : null);
  }

  void _pickColor(int i) {
    setState(() => _color = i);
    Future.delayed(const Duration(milliseconds: 240), () => mounted ? _go(_Step.pin) : null);
  }

  void _digit(String d) {
    if (_busy) return;
    final max = _first?.length ?? 256;
    if (_pin.length >= max) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_step == _Step.confirm && _pin.length == _first!.length) _confirm();
  }

  void _delete() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _next() {
    if (_pin.length < 4) return;
    setState(() {
      _first = _pin;
      _pin = '';
      _step = _Step.confirm;
    });
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    if (_pin != _first) {
      HapticFeedback.heavyImpact();
      setState(() {
        _shake++;
        _step = _Step.pin;
        _first = null;
        _pin = '';
        _error = l.pinMismatch;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      // The first vault on a device makes the Secret Key; it lives in the keystore.
      var key = await SecretKeyStore.read();
      if (key == null) {
        key = rust.newSecretKey();
        await SecretKeyStore.write(key);
      }
      rust.setSecretKey(key: key);
      // "This PIN is taken" tells that some vault opens with it, so creating a vault
      // shares the wrong-PIN waits: from the lock screen it is no faster than
      // guessing on the PIN pad.
      final until = await PinStore.waitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        throw _Wait(until.difference(DateTime.now()));
      }
      final device = await PinStore.deviceKeyOrCreate(rust.newSecretKey);
      final vault = await rust.createVaultWithPin(
        dir: widget.libraryDir,
        icon: vaultIcons[_icon].id,
        color: vaultColors[_color].id,
        pin: _pin,
        deviceKey: device,
      );
      if (!mounted) return;
      if (widget.first && await BiometricUnlock.available() != null && mounted) {
        final yes = await _askBiometric(l);
        if (yes == true) await turnOnBiometric(BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel));
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      await playVaultSpin(
        context,
        opening: true,
        color: vaultColors[_color].color,
        onCovered: () => nav.pushAndRemoveUntil(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault),
          ),
          (_) => false,
        ),
      );
    } on _Wait catch (w) {
      if (mounted) _back(l.pinWait(_minutes(w.left)));
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      if (e == rust.VaultError.pinInUse) {
        final wait = await PinStore.addFail();
        if (!mounted) return;
        if (wait > Duration.zero) return _back(l.pinWait(_minutes(wait)));
      }
      _back(vaultErrorText(l, e));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l.errorStorage;
        });
      }
    }
  }

  void _back(String error) => setState(() {
        _busy = false;
        _step = _Step.pin;
        _first = null;
        _pin = '';
        _shake++;
        _error = error;
      });

  static int _minutes(Duration d) => d.inSeconds <= 60 ? 1 : (d.inSeconds / 60).ceil();

  Future<bool?> _askBiometric(AppLocalizations l) => showModalBottomSheet<bool>(
        context: context,
        isDismissible: false,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.biometricAskTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(l.biometricAskBody, style: TextStyle(color: CsColors.of(context).muted)),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: Text(l.biometricOfferNo))),
                    const SizedBox(width: 10),
                    Expanded(child: FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.biometricOfferYes))),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tint = backdropTint(vaultColors[_color].color);
    final progress = _step == _Step.confirm ? 2 : _step.index;
    final title = switch (_step) {
      _Step.icon => widget.first ? l.firstVaultTitle : l.newVaultTitle,
      _Step.color => l.pickColorTitle,
      _Step.pin => l.pinSetTitle,
      _Step.confirm => l.pinConfirmTitle,
    };
    final hint = switch (_step) {
      _Step.icon => l.pickIconHint,
      _Step.color => l.pickColorHint,
      _Step.pin => _error ?? l.pinSetLead,
      _Step.confirm => _error ?? l.pinConfirmLead,
    };

    Widget body = switch (_step) {
      _Step.icon => _choiceGrid(
          count: gridCount,
          selected: _icon < gridCount ? _icon : -1,
          moreSelected: _icon >= gridCount,
          tile: (i) => Icon(vaultIcons[i].icon, color: Colors.white, size: 34),
          label: (i) => vaultIcons[i].label,
          onTap: _pickIcon,
          onMore: () async {
            final i = await showAllIcons(context, _icon);
            if (i != null) _pickIcon(i);
          },
          moreLabel: l.moreIcons,
        ),
      _Step.color => _choiceGrid(
          count: gridCount,
          selected: _color < gridCount ? _color : -1,
          moreSelected: _color >= gridCount,
          tileColor: (i) => vaultColors[i].color,
          tile: (_) => const SizedBox.shrink(),
          label: (i) => vaultColors[i].label,
          onTap: _pickColor,
          onMore: () async {
            final i = await showAllColors(context, _color);
            if (i != null) _pickColor(i);
          },
          moreLabel: l.moreColors,
        ),
      _ => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Shake(
              trigger: _shake,
              child: PinDots(filled: _pin.length,
                color: Brand.gold,
              ),
            ),
            const SizedBox(height: 22),
            PinPad(onDigit: _digit, onDelete: _delete, enabled: !_busy),
            const SizedBox(height: 14),
            SizedBox(
              height: 46,
              child: _step == _Step.pin
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Brand.gold,
                        foregroundColor: Brand.goldInk,
                        minimumSize: const Size(180, 46),
                      ),
                      onPressed: _pin.length >= 4 ? _next : null,
                      child: Text(l.pinNext),
                    )
                  : _busy
                      ? const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(color: Colors.white)))
                      : null,
            ),
          ],
        ),
    };

    return Scaffold(
      backgroundColor: tint,
      body: Stack(
        children: [
          Positioned.fill(child: VaultBackdrop(tint: tint)),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: (_step.index > 0 || !widget.first)
                            ? IconButton(
                                onPressed: _busy ? null : _back,
                                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                                icon: const Icon(Icons.chevron_left, color: Colors.white),
                              )
                            : null,
                      ),
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= progress ? Brand.gold : const Color(0x38FFFFFF),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) => SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: box.maxHeight),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 16),
                                VaultBadge(
                                  icon: vaultIcons[_icon].id,
                                  color: vaultColors[_color].id,
                                  size: 92,
                                  ring: true,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  hint,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _error != null && _step.index >= 2 ? const Color(0xFFFFB4AB) : const Color(0xC7FFFFFF),
                                    fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                                if (_step == _Step.pin && _error == null) ...[
                                  const SizedBox(height: 12),
                                  // A new vault has no backup password yet: say what a
                                  // forgotten PIN means, while the PIN is being chosen.
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Brand.gold.withValues(alpha: .16),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      l.pinNoRecovery,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Brand.gold, fontSize: 13, height: 1.4),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 20),
                                body,
                                const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.first && _step == _Step.icon)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: const Color(0xD9FFFFFF)),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RestoreScreen(libraryDir: widget.libraryDir, needFile: true),
                    )),
                    child: Text(l.restoreFromBackup),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 11 choices + a "⋯" tile, 3 per row. No text anywhere: labels are for screen readers.
  Widget _choiceGrid({
    required int count,
    required int selected,
    required bool moreSelected,
    required Widget Function(int) tile,
    required String Function(int) label,
    required void Function(int) onTap,
    required VoidCallback onMore,
    required String moreLabel,
    Color Function(int)? tileColor,
  }) {
    Widget cell({required bool on, required VoidCallback tap, required String semantics, required Widget child, Color? bg}) {
      return Semantics(
        button: true,
        selected: on,
        label: semantics,
        child: GestureDetector(
          onTap: tap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: bg ?? const Color(0x1AFFFFFF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: on ? Brand.gold : Colors.transparent, width: 3),
            ),
            child: Center(child: child),
          ),
        ),
      );
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.3,
      children: [
        for (var i = 0; i < count; i++)
          cell(on: i == selected, tap: () => onTap(i), semantics: label(i), child: tile(i), bg: tileColor?.call(i)),
        cell(
          on: moreSelected,
          tap: onMore,
          semantics: moreLabel,
          child: const Icon(Icons.more_horiz, color: Colors.white, size: 30),
        ),
      ],
    );
  }
}

class _Shake extends StatefulWidget {
  const _Shake({required this.trigger, required this.child});
  final int trigger;
  final Widget child;

  @override
  State<_Shake> createState() => _ShakeState();
}

class _ShakeState extends State<_Shake> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void didUpdateWidget(_Shake old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.value;
          final dx = t == 0 || t == 1 ? 0.0 : 9 * (1 - t) * (((t * 8).floor().isEven) ? 1 : -1);
          return Transform.translate(offset: Offset(dx, 0), child: child);
        },
        child: widget.child,
      );
}

class _Wait implements Exception {
  const _Wait(this.left);
  final Duration left;
}
