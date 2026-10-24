import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/password_strength.dart';
import '../widgets/recovery_words.dart';
import '../widgets/pin_pad.dart';
import '../widgets/secret.dart';
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'vault_home.dart';

/// Create a vault (owner 2026-10-23): what each key is for → (first vault on this
/// device) the 24 words, written down and four of them typed back → the vault password
/// (8 characters at least; strength shown, never blocked) → a PIN of 6 digits or more,
/// twice → Face ID → icon and colour, which can be skipped. The 24 words belong to the
/// device and every vault shares them; each vault has its own password and PIN.
class NewVaultScreen extends StatefulWidget {
  const NewVaultScreen({super.key, required this.libraryDir, required this.first, this.avoid});

  final String libraryDir;
  final bool first;
  /// The open vault's icon and colour, not suggested again (creating from inside it).
  final (String, String)? avoid;

  /// Mockups: the words to show, instead of the keystore's.
  @visibleForTesting
  static String? debugWords;
  /// For the mockup renders: open on the Face ID step.
  @visibleForTesting
  static bool debugBiometricStep = false;

  @override
  State<NewVaultScreen> createState() => _NewVaultScreenState();
}

enum _Step { intro, words, check, password, pin, confirm, biometric, icon, color }

class _NewVaultScreenState extends State<NewVaultScreen> {
  _Step _step = _Step.intro;
  late int _icon;
  late int _color;
  String _pin = '';
  String? _first;
  String? _error;
  bool _busy = false;
  /// Face ID or fingerprint, when this phone has one (asked after the PIN).
  BiometricKind? _bioKind;
  int _shake = 0;

  /// The device's Secret Key as 24 words; null until known. [_newWords]: made now, so
  /// this vault is the one that shows them.
  List<String>? _words;
  bool _newWords = false;
  /// The four words asked back, by position (0-based), in order.
  late final List<int> _ask = pickFourWords(fixed: NewVaultScreen.debugWords != null);
  final _pw = TextEditingController();
  final _pwAgain = TextEditingController();
  rust.VaultInfo? _vault;

  /// One thing per step, said briefly (owner 2026-10-24: no screen explaining all three
  /// at once). The first vault starts from the welcome screen, so it has no intro.
  List<_Step> get _steps => [
        if (!widget.first) _Step.intro,
        if (_newWords) ...[_Step.words, _Step.check],
        _Step.password,
        _Step.pin,
        _Step.icon,
      ];

  @override
  void initState() {
    super.initState();
    final (i, c) = randomIdentity(avoid: widget.avoid);
    _icon = vaultIcons.indexWhere((x) => x.id == i);
    _color = vaultColors.indexWhere((x) => x.id == c);
    _loadWords();
    if (NewVaultScreen.debugBiometricStep) {
      _step = _Step.biometric;
      _bioKind = BiometricKind.face;
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _pwAgain.dispose();
    super.dispose();
  }

  /// The first vault on a device makes the Secret Key (kept in the keystore at once, so
  /// leaving half-way and coming back shows the same words).
  Future<void> _loadWords() async {
    // Fixed words only in tests and mockups, never in a release build.
    final debug = kReleaseMode ? null : NewVaultScreen.debugWords;
    if (debug != null) {
      setState(() {
        _words = debug.split(' ');
        _newWords = widget.first;
        if (_step == _Step.intro) _step = _steps.first;
      });
      return;
    }
    var key = await SecretKeyStore.read();
    // The last vault was deleted and this device still holds a Secret Key from before the
    // 24 words: start afresh with a new one (owner 2026-10-24: Start stayed greyed out).
    if (key != null && widget.first && !rust.secretKeyText(key: key).contains(' ')) {
      if (await rust.resetEmptyLibrary(dir: widget.libraryDir)) key = null;
    }
    final made = key == null;
    if (key == null) {
      key = rust.newSecretKey();
      await SecretKeyStore.write(key);
    }
    rust.setSecretKey(key: key);
    final text = rust.secretKeyText(key: key);
    if (!mounted) return;
    setState(() {
      _words = text.contains(' ') ? text.split(' ') : null;
      // Shown when this device has no vault yet: the words were just made, or made by a
      // start that was left half-way.
      _newWords = (made || widget.first) && _words?.length == 24;
      if (_step == _Step.intro) _step = _steps.first;
    });
  }

  void _go(_Step s) => setState(() {
        _step = s;
        _error = null;
        if (s == _Step.pin) {
          _pin = '';
          _first = null;
        }
      });

  /// Back stops at the PIN once the vault exists: it is made then.
  void _back() {
    if (_vault != null) {
      if (_step == _Step.color) _go(_Step.icon);
      return;
    }
    if (_step == _Step.confirm) return _go(_Step.pin);
    final i = _steps.indexOf(_step);
    if (i <= 0) {
      if (!widget.first) Navigator.of(context).maybePop();
      return;
    }
    _go(_steps[i - 1]);
  }

  bool get _canGoBack => !_busy && (_vault == null ? _step != _steps.first : _step == _Step.color);

  // ---------- words ----------

  // ---------- password ----------

  bool get _passwordOk =>
      _pw.text.characters.length >= rust.minPasswordLength() && _pw.text == _pwAgain.text;

  void _suggest() => setState(() {
        _pw.text = rust.suggestPassphrase();
        _pwAgain.clear();
        _error = null;
      });

  // ---------- PIN ----------

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

  int get _minPin => rust.minPinLength();

  void _next() {
    if (_pin.length < _minPin) return;
    setState(() {
      _first = _pin;
      _pin = '';
      _step = _Step.confirm;
    });
  }

  /// PIN typed twice: make the vault with it, then give it the password. A password
  /// another vault already opens with sends back to the password step (the vault stays,
  /// open, and gets the next one).
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
      // "This PIN is taken" tells that some vault opens with it, so creating a vault
      // shares the wrong-PIN waits: from the lock screen it is no faster than
      // guessing on the PIN pad.
      final until = await PinStore.waitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        throw _Wait(until.difference(DateTime.now()));
      }
      final device = await PinStore.deviceKeyOrCreate(rust.newSecretKey);
      _vault = await rust.createVaultWithPin(
        dir: widget.libraryDir,
        icon: vaultIcons[_icon].id,
        color: vaultColors[_color].id,
        pin: _pin,
        deviceKey: device,
      );
      _pin = '';
      await _givePassword(l);
    } on _Wait catch (w) {
      if (mounted) _retryPin(l.pinWait(_minutes(w.left)));
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      if (e == rust.VaultError.pinInUse) {
        final wait = await PinStore.addFail();
        if (!mounted) return;
        if (wait > Duration.zero) return _retryPin(l.pinWait(_minutes(wait)));
      }
      _retryPin(vaultErrorText(l, e));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l.errorStorage;
        });
      }
    }
  }

  /// The password onto the vault just made; then Face ID, then the look.
  Future<void> _givePassword(AppLocalizations l) async {
    setState(() => _busy = true);
    try {
      _vault = await rust.setPassword(dir: widget.libraryDir, password: _pw.text);
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.password;
        _error = vaultErrorText(l, e);
      });
      return;
    }
    _pw.clear();
    _pwAgain.clear();
    if (!mounted) return;
    _bioKind = widget.first ? await BiometricUnlock.available() : null;
    final bio = _bioKind != null;
    if (!mounted) return;
    setState(() => _busy = false);
    _go(bio ? _Step.biometric : _Step.icon);
  }

  void _retryPin(String error) => setState(() {
        _busy = false;
        _step = _Step.pin;
        _first = null;
        _pin = '';
        _shake++;
        _error = error;
      });

  static int _minutes(Duration d) => d.inSeconds <= 60 ? 1 : (d.inSeconds / 60).ceil();

  // ---------- look, then in ----------

  void _pickIcon(int i) {
    setState(() => _icon = i);
    Future.delayed(const Duration(milliseconds: 200), () => mounted ? _go(_Step.color) : null);
  }

  void _pickColor(int i) {
    setState(() => _color = i);
    Future.delayed(const Duration(milliseconds: 240), () => mounted ? _enter(save: true) : null);
  }

  Future<void> _enter({required bool save}) async {
    var vault = _vault!;
    if (_busy) return;
    setState(() => _busy = true);
    if (save) {
      try {
        vault = await rust.setIdentity(icon: vaultIcons[_icon].id, color: vaultColors[_color].id);
      } catch (_) {} // the suggested look stays; it can be changed in Settings
    }
    if (!mounted) return;
    final nav = Navigator.of(context);
    await playVaultSpin(
      context,
      opening: true,
      onCovered: () => nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault),
        ),
        (_) => false,
      ),
    );
  }

  Future<void> _biometricAnswer(bool yes) async {
    final l = AppLocalizations.of(context);
    if (yes) {
      setState(() => _busy = true);
      await turnOnBiometric(BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel));
      if (!mounted) return;
      setState(() => _busy = false);
    }
    _go(_Step.icon);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    final steps = _steps;
    final progress = steps.indexOf(switch (_step) {
      _Step.confirm || _Step.biometric => _Step.pin,
      _Step.color => _Step.icon,
      _Step.intro => steps.first,
      final s => s,
    });
    final title = switch (_step) {
      _Step.intro => widget.first ? l.firstVaultTitle : l.newVaultTitle,
      _Step.words => l.wordsTitle,
      _Step.check => l.wordsCheckTitle,
      _Step.password => l.backupPasswordTitle,
      _Step.pin => l.pinSetTitle,
      _Step.biometric => l.biometricAskTitle,
      _Step.confirm => l.pinConfirmTitle,
      _Step.icon => l.pickIconHint,
      _Step.color => l.pickColorTitle,
    };
    final hint = switch (_step) {
      _Step.intro => l.introLead,
      _Step.words => l.wordsLead,
      _Step.check => l.wordsCheckLead,
      _Step.password => l.passwordLead,
      _Step.biometric => l.biometricAskBody,
      _Step.pin => _error ?? l.pinSetLead(_minPin),
      _Step.confirm => _error ?? l.pinConfirmLead,
      _Step.icon => l.lookLead,
      _Step.color => l.lookLead,
    };
    final pinError = _error != null && (_step == _Step.pin || _step == _Step.confirm);
    final body = switch (_step) {
      _Step.intro => _intro(l),
      _Step.words => _wordsBody(l),
      _Step.check => _checkBody(l),
      _Step.password => _passwordBody(l),
      _Step.biometric => _biometricBody(l),
      _Step.icon => _choiceGrid(
          count: gridCount,
          selected: _icon < gridCount ? _icon : -1,
          moreSelected: _icon >= gridCount,
          tile: (i) => Icon(vaultIcons[i].icon, color: ink, size: 34),
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
              child: PinDots(filled: _pin.length, color: ink),
            ),
            const SizedBox(height: 22),
            PinPad(onDigit: _digit, onDelete: _delete, enabled: !_busy),
            const SizedBox(height: 14),
            SizedBox(
              height: 46,
              child: _step == _Step.pin
                  ? FilledButton(
                      key: const ValueKey('pin-next'),
                      style: FilledButton.styleFrom(minimumSize: const Size(180, 46)),
                      onPressed: _pin.length >= _minPin ? _next : null,
                      child: Text(l.pinNext),
                    )
                  : _busy
                      ? Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(color: ink)))
                      : null,
            ),
          ],
        ),
    };
    // The badge is the vault being made; forms (words, password) need the room, and the
    // Face ID step has its own glyph.
    final badge = switch (_step) { _Step.words || _Step.check || _Step.password || _Step.biometric => false, _ => true };

    return PopScope(
      // The system back gesture steps back too; on the first step it leaves.
      // Back from the first step leaves (to the welcome screen for the first vault).
      canPop: _step == _steps.first || _step == _Step.intro,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack) _back();
      },
      // Steps live in one page, so the system swipe has nothing to pop: swipe = Back.
      child: EdgeSwipeBack(
      enabled: _canGoBack,
      onBack: _back,
      child: Scaffold(
      backgroundColor: page,
      body: Stack(
        children: [
          const Positioned.fill(child: VaultBackdrop()),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Row(
                    children: [
                      for (var i = 0; i < steps.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= progress ? ink : ink.withValues(alpha: .22),
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
                      key: ValueKey(_step),
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
                                if (badge) ...[
                                  VaultBadge(
                                    icon: vaultIcons[_icon].id,
                                    color: vaultColors[_color].id,
                                    size: _step == _Step.intro ? 76 : 92,
                                    ring: true,
                                  ),
                                  const SizedBox(height: 20),
                                ],
                                Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: ink, fontSize: 23, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  hint,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: pinError ? ink : ink.withValues(alpha: .78),
                                    fontWeight: pinError ? FontWeight.w600 : FontWeight.w400,
                                    height: 1.4,
                                  ),
                                ),
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
                // Back and Cancel under the thumbs, large, instead of a small arrow in
                // the top corner. The very first vault has nothing to cancel back to;
                // once the vault exists, the look can be skipped.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Row(
                    children: [
                      if (_canGoBack)
                        _BottomButton(
                          key: const ValueKey('new-vault-back'),
                          icon: Icons.arrow_back,
                          label: l.back,
                          onTap: _back,
                        ),
                      const Spacer(),
                      if (_step == _Step.words)
                        FilledButton(
                          key: const ValueKey('words-done'),
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 52), shape: const StadiumBorder()),
                          onPressed: () => _go(_Step.check),
                          child: Text(l.wordsWritten),
                        )
                      else if (_vault != null && (_step == _Step.icon || _step == _Step.color))
                        _BottomButton(
                          key: const ValueKey('new-vault-skip'),
                          label: l.lookSkip,
                          onTap: _busy ? null : () => _enter(save: _step == _Step.color),
                        )
                      else if (!widget.first)
                        _BottomButton(
                          key: const ValueKey('new-vault-cancel'),
                          label: l.cancel,
                          onTap: _busy ? null : () => Navigator.of(context).maybePop(),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    ),
    );
  }

  /// Wide main button at the end of a form step.
  /// Face ID (or fingerprint): one question, its own step.
  Widget _biometricBody(AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Column(
      children: [
        const SizedBox(height: 8),
        BiometricGlyph(kind: _bioKind ?? BiometricKind.face, size: 72, color: ink),
        const SizedBox(height: 28),
        _primary(const ValueKey('bio-yes'), l.biometricOfferYes, _busy ? null : () => _biometricAnswer(true)),
        const SizedBox(height: 6),
        TextButton(
          key: const ValueKey('bio-no'),
          onPressed: _busy ? null : () => _biometricAnswer(false),
          child: Text(l.biometricOfferNo),
        ),
      ],
    );
  }

  Widget _primary(Key key, String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 50), shape: const StadiumBorder()),
          onPressed: onTap,
          child: Text(label),
        ),
      );

  /// What each key is for, before any of them is made.
  Widget _intro(AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget row(IconData icon, String title, String body, Key key) => Container(
          key: key,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: solidTint(context, ink.withValues(alpha: .08)), borderRadius: BorderRadius.circular(16)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: solidTint(context, ink.withValues(alpha: .1)), shape: BoxShape.circle),
                child: Icon(icon, color: ink, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: ink, fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(body, style: TextStyle(color: ink.withValues(alpha: .78), fontSize: 14, height: 1.4)),
                  ],
                ),
              ),
            ],
          ),
        );
    return Column(
      children: [
        row(Icons.pin_outlined, l.introPinTitle, l.introPinBody, const ValueKey('intro-pin')),
        const SizedBox(height: 10),
        row(Icons.password_rounded, l.introPasswordTitle, l.introPasswordBody, const ValueKey('intro-password')),
        const SizedBox(height: 10),
        row(Icons.key_rounded, l.introWordsTitle, _newWords ? l.introWordsBody : l.introWordsShared,
            const ValueKey('intro-words')),
        const SizedBox(height: 12),
        Text(l.introNoCopy,
            textAlign: TextAlign.center, style: TextStyle(color: ink.withValues(alpha: .78), fontSize: 13, height: 1.4)),
        const SizedBox(height: 18),
        _primary(const ValueKey('intro-start'), l.introStart,
            _words == null && NewVaultScreen.debugWords == null && widget.first ? null : () => _go(_steps[1])),
      ],
    );
  }

  // "I wrote them down" sits in the bottom row, always in sight: on a small Android
  // phone it was below the fold (owner 2026-10-24).
  Widget _wordsBody(AppLocalizations l) => RecoveryWordsPanel(words: _words ?? const []);

  Widget _checkBody(AppLocalizations l) => RecoveryWordsCheck(
        words: _words ?? const [],
        ask: _ask,
        action: (ok) => _primary(const ValueKey('check-done'), l.pinNext, ok ? () => _go(_Step.password) : null),
        onShowAgain: () => _go(_Step.words),
      );

  Widget _passwordBody(AppLocalizations l) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _suggest,
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(l.suggestPassword),
          ),
        ),
        const SizedBox(height: 12),
        SecretField(
          key: const ValueKey('new-password'),
          controller: _pw,
          label: l.password,
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 8),
        PasswordStrength(password: _pw.text),
        const SizedBox(height: 12),
        SecretField(
          key: const ValueKey('new-password-again'),
          controller: _pwAgain,
          label: l.typeAgain,
          errorText: _pwAgain.text.isNotEmpty && _pwAgain.text != _pw.text ? l.passwordsDiffer : null,
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 18),
        // Back here after the vault was made (password taken): this sets it at once.
        _primary(
          const ValueKey('password-next'),
          l.pinNext,
          !_passwordOk || _busy ? null : () => _vault != null ? _givePassword(l) : _go(_Step.pin),
        ),
      ],
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
    final ink = Theme.of(context).colorScheme.onSurface;
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
              color: bg ?? solidTint(context, ink.withValues(alpha: .08)),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: on ? ink : Colors.transparent, width: 3),
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
          child: Icon(Icons.more_horiz, color: ink, size: 30),
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

/// A large, thumb-height text button for the bottom of the steps.
class _BottomButton extends StatelessWidget {
  const _BottomButton({super.key, this.icon, required this.label, required this.onTap});
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          minimumSize: const Size(96, 52),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          backgroundColor: solidTint(context, Theme.of(context).colorScheme.onSurface.withValues(alpha: .1)),
          shape: const StadiumBorder(),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Text(label),
          ],
        ),
      );
}
