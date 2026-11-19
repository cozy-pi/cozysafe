import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric.dart';
import '../key_backup.dart';
import '../l10n/app_localizations.dart';
import '../prefs.dart';
import '../secret_key_store.dart';
import '../src/rust/api/run.dart' as run_api;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/steps.dart' show StepMainButton, StepPage, StepSideButton;
import '../widgets/edge_swipe_back.dart';
import '../widgets/password_strength.dart';
import '../widgets/recovery_words.dart';
import '../widgets/secret.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show showCard;
import '../widgets/brand.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'settings.dart' show SettingsSpot, settingsPath;
import 'tour.dart' show TourKind;
import 'top_secret_page.dart';
import '../top_secret_mode.dart';
import 'vault_home.dart';

/// Create a vault, a few taps (owner 2026-11-05: "chỉ cần bấm bấm là được"): its mode →
/// (another vault here) its 24 words, the device's or its own → (new words) the words,
/// with a copy kept in the iCloud Keychain / Google Block Store, on by default for an
/// everyday vault → (no copy) four words typed back, which can be skipped after a warning
/// → the vault password, which the system's password manager can suggest and keeps under
/// the vault's code (ADR 0008) → the review → Face ID → in. The icon and
/// colour are suggested at random and chosen on the review, the last step, where a tap
/// on any line goes back to it (owner 2026-11-18); "Create vault" makes it there. Nothing goes to the cloud for
/// a Top secret vault, and its words are always typed back.
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
  /// Mockups of the later steps: start at the password, as before the mode step.
  @visibleForTesting
  static bool debugSkipMode = false;

  @override
  State<NewVaultScreen> createState() => _NewVaultScreenState();
}

enum _Step { mode, look, keys, words, check, password, review, biometric }

class _NewVaultScreenState extends State<NewVaultScreen> {
  _Step _step = _Step.mode;
  /// A step was chosen (until then the first one follows the words as they load).
  bool _moved = false;
  late int _icon;
  late int _color;
  String? _error;
  bool _busy = false;
  /// Face ID, Touch ID or fingerprint, when this device has one: its own step, after the
  /// password and the words (owner 2026-10-28, 2026-10-29).
  BiometricKind? _bioKind;

  /// The device's Secret Key as 24 words; null until known. [_newWords]: made now, so
  /// this vault is the one that shows them.
  List<String>? _words;
  bool _newWords = false;
  /// The four words asked back, by position (0-based), in order.
  /// Picked again each time the check opens (owner 2026-11-02: back and forth showed the
  /// same four cells).
  late List<int> _ask = pickFourWords(fixed: NewVaultScreen.debugWords != null);
  final _pw = TextEditingController();
  final _pwAgain = TextEditingController();
  rust.VaultInfo? _vault;
  /// [_Step.keys]: a new set of 24 words for this vault, or the device's set.
  bool _ownKey = false;

  /// [_Step.words]: keep a copy of the words in the iCloud Keychain / Google Block Store
  /// (owner 2026-11-05: on by default, can be turned off).
  bool _cloud = true;
  /// The key whose copy was made here: taken out again if the person turns it off, or
  /// leaves before the vault exists with a set made for it.
  Uint8List? _cloudKey;
  /// The device's set already has a cloud copy: a Top secret vault then gets its own.
  bool _deviceInCloud = false;
  /// The four words were not typed back: a tip reminds once, later (vault_home.dart).
  bool _checkSkipped = false;
  /// The vault's code, from its draft, before the password is typed (ADR 0008): the
  /// password manager keeps the password under it.
  late final String _code = rust.prepareVault();
  late final _account = TextEditingController(text: 'Cozy Safe $_code');

  bool get _cloudOffered => KeyBackup.supported && _topSecret == false;
  bool get _cloudOn => _cloudOffered && _cloud;
  /// A Top secret vault whose device set is in the cloud: its own set, no question.
  bool get _forcedOwn => !widget.first && _topSecret == true && _deviceInCloud;

  /// The mode chosen on [_Step.mode]: this vault's own (ADR 0007).
  /// Nothing chosen at first (owner 2026-11-03: the person picks; none is lit up). With
  /// the mode step skipped (tests), the run's own mode.
  bool? _topSecret = NewVaultScreen.debugSkipMode ? TopSecretMode.on : null;
  /// Face ID opens one vault per device; while another vault has it, making this one does
  /// not ask (owner 2026-10-31: asking took it from the other). Settings can move it.
  late final bool _bioTaken = rust.hasBiometricUnlock(dir: widget.libraryDir);

  /// One thing per step, said briefly (owner 2026-10-24: no screen explaining all three
  /// at once). The first vault starts from the welcome screen, so it has no intro.
  List<_Step> get _steps => [
        // Every vault chooses Top Secret Mode or not, its own (ADR 0007, owner 2026-10-31:
        // with the differences listed, and said it can change later).
        if (!NewVaultScreen.debugSkipMode) _Step.mode,
        // Its icon and colour (owner 2026-11-18: a step of its own, not only a line on the
        // review), so it stands apart from the other vaults on the lock screen.
        if (!NewVaultScreen.debugSkipMode) _Step.look,
        // Another vault on this device: its 24 words, a new set or the one the device
        // already has (owner 2026-11-01: a choice). The first vault always makes its set.
        if (!widget.first && !_forcedOwn) _Step.keys,
        // Typed back even with the cloud copy on, Skip right there (owner 2026-11-18).
        if (_newWords) ...[_Step.words, _Step.check],
        _Step.password,
        // Everything once more, the look to choose, and "Create vault" (owner 2026-11-18:
        // a last step that only said Next felt wrong). The vault is made here.
        _Step.review,
        if (_bioKind != null && !_bioTaken) _Step.biometric,
      ];

  @override
  void initState() {
    super.initState();
    final (i, c) = randomIdentity(avoid: widget.avoid);
    _icon = vaultIcons.indexWhere((x) => x.id == i);
    _color = vaultColors.indexWhere((x) => x.id == c);
    _loadWords();
    BiometricUnlock.available().then((kind) {
      if (mounted && kind != null && _bioKind == null) setState(() => _bioKind = kind);
    });
    if (NewVaultScreen.debugBiometricStep) {
      _step = _Step.biometric;
      _bioKind = BiometricKind.face;
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _pwAgain.dispose();
    _account.dispose();
    if (_vault == null) {
      // Left before the vault was made: its draft goes, and so does a copy of a set made
      // for it, which no vault uses.
      rust.forgetVaultDraft();
      if (_cloudKey case final key? when _ownKey) KeyBackup.remove(key);
    }
    super.dispose();
  }

  /// The first vault on a device makes the Secret Key. Words shown by a start that was
  /// left half-way are never shown again (owner 2026-10-24): someone may have seen
  /// them, so a device with no vault yet always gets fresh ones.
  Future<void> _loadWords() async {
    // Fixed words only in tests and mockups, never in a release build.
    final debug = kReleaseMode ? null : NewVaultScreen.debugWords;
    if (debug != null) {
      setState(() {
        _words = debug.split(' ');
        _newWords = widget.first;
        if (!_moved) _step = _steps.first;
      });
      return;
    }
    var key = await SecretKeyStore.read();
    // No vault here yet: whatever key is kept (a start left half-way, or one from before
    // the 24 words) is dropped for a new one.
    if (key != null && widget.first && !rust.hasVaults(dir: widget.libraryDir)) {
      await rust.resetEmptyLibrary(dir: widget.libraryDir);
      await SecretKeyStore.delete();
      rust.forgetSecretKey();
      key = null;
    }
    final made = key == null;
    if (key == null) {
      key = rust.newSecretKey();
      await SecretKeyStore.write(key);
    }
    rust.setSecretKey(dir: widget.libraryDir, key: key);
    final text = rust.secretKeyText(key: key);
    final inCloud = !made && KeyBackup.isOn(key);
    if (!mounted) return;
    setState(() {
      _deviceInCloud = inCloud;
      _words = text.contains(' ') ? text.split(' ') : null;
      // Shown when this device has no vault yet: the words were just made, or made by a
      // start that was left half-way.
      _newWords = (made || widget.first) && _words?.length == 24;
      if (!_moved) _step = _steps.first;
    });
  }

  void _go(_Step s) => setState(() {
        _step = s;
        _moved = true;
        _error = null;
      });

  /// Back stops once the vault exists: it is made with the password.
  void _back() {
    if (_vault != null) return;
    final i = _steps.indexOf(_step);
    if (i <= 0) {
      if (!widget.first) Navigator.of(context).maybePop();
      return;
    }
    _go(_steps[i - 1]);
  }

  bool get _canGoBack => !_busy && _vault == null && _step != _steps.first;

  // ---------- words ----------

  // ---------- password ----------

  bool get _passwordOk => PasswordStrength.acceptable(_pw.text) && _pw.text == _pwAgain.text;

  /// The vault is made with its password (decisions 2026-10-28: no PIN), from the review;
  /// then Face ID. An error is shown on the review. The system's password manager is told the form is done: it offers to keep
  /// the password under the vault's code (never for a Top secret vault).
  Future<void> _create(AppLocalizations l) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _vault = _vault == null
          ? await rust.createVaultWithPassword(
              dir: await _libraryForNew(),
              icon: vaultIcons[_icon].id,
              color: vaultColors[_color].id,
              password: _pw.text,
              topSecret: _topSecret ?? TopSecretMode.on,
            )
          : await rust.setPassword(dir: widget.libraryDir, password: _pw.text);
    } on rust.VaultError catch (e) {
      if (!mounted) return;
      // Made, but a Top secret vault cannot open after an everyday one in this run: the
      // app starts again and it is unlocked with its password.
      if (e == rust.VaultError.restartForMode) {
        _pw.clear();
        _pwAgain.clear();
        return restartForMode(context);
      }
      setState(() {
        _busy = false;
        _error = vaultErrorText(l, e);
      });
      return;
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = withCode(l, l.errorStorage, e);
        });
      }
      return;
    }
    final vault = _vault!;
    TextInput.finishAutofillContext(shouldSave: !vault.topSecret);
    // A copy made, then the vault turned Top secret on the review: it is taken out.
    if (_cloudKey case final key? when !_cloudOn) {
      _cloudKey = null;
      await KeyBackup.remove(key);
    }
    _pw.clear();
    _pwAgain.clear();
    // The copy of the words names the vault now that it exists, and says so once: which
    // set, for which vault, and where to see it again (owner 2026-11-18: nothing told what
    // was kept, nor how to find it later).
    if (_cloudKey case final key?) {
      if (await KeyBackup.save(key, vault: vault.code, icon: vault.icon, color: vault.color) && mounted && vault.code.isNotEmpty) {
        final l = AppLocalizations.of(context);
        showToast(
            context,
            l.keyBackupSavedFor(rust.secretKeyFingerprint(key: key).toUpperCase(), vault.code,
                KeyBackup.google ? 'Google' : 'iCloud Keychain', '${l.settings} → ${l.reopenTitle}'),
            icon: Icons.cloud_done_rounded);
      }
    }
    if (_checkSkipped) Prefs.write(wordsUncheckedPref(vault.id), '1');
    _bioKind ??= await BiometricUnlock.available();
    if (!mounted) return;
    setState(() => _busy = false);
    _bioKind != null && !_bioTaken ? _go(_Step.biometric) : await _enter();
  }

  // ---------- in ----------

  /// The look was suggested at random (it avoids the others on this device) or chosen on
  /// the review; Settings changes it.
  Future<void> _enter() async {
    final vault = _vault!;
    if (_busy) return;
    setState(() => _busy = true);
    TopSecretMode.opened(vault);
    // The root: from a computer's right-hand pane the vault replaces the whole window.
    final nav = Navigator.of(context, rootNavigator: true);
    await playVaultSpin(
      context,
      opening: true,
      onCovered: () => nav.pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          // A short tour of the basics once the vault is open (owner 2026-10-25).
          pageBuilder: (_, _, _) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault, tour: TourKind.created),
        ),
        (_) => false,
      ),
    );
  }

  Future<void> _biometricAnswer(bool yes) async {
    final l = AppLocalizations.of(context);
    if (yes) {
      setState(() => _busy = true);
      final on = await turnOnBiometric(BiometricUnlock(promptTitle: l.biometricPrompt, promptCancel: l.cancel));
      if (!mounted) return;
      setState(() => _busy = false);
      // Cancelled or failed: the vault opens all the same, but not without a word (the
      // person believes Face ID is on). The message stays over the vault as it opens.
      if (!on) showToast(context, l.biometricNotOn, icon: Icons.info_outline_rounded);
    }
    await _enter();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final steps = _steps;
    final progress = steps.indexOf(_step);
    final title = switch (_step) {
      _Step.mode => l.modeChooseTitle,
      _Step.look => l.lookTitle,
      _Step.keys => l.keysTitle,
      _Step.words => l.wordsTitle,
      _Step.check => l.wordsCheckTitle,
      _Step.password => l.backupPasswordTitle,
      _Step.review => l.reviewTitle,
      _Step.biometric => l.biometricAskTitle,
    };
    final hint = switch (_step) {
      _Step.mode => l.modeChooseLead,
      _Step.look => l.lookLead,
      _Step.keys => l.keysLead,
      _Step.words => l.wordsLead,
      _Step.check => l.wordsCheckLead,
      _Step.password => l.passwordLead,
      _Step.review => l.reviewLead,
      _Step.biometric => l.biometricAskBody,
    };
    final body = switch (_step) {
      _Step.mode => _modeBody(l),
      _Step.look => VaultLookPicker(icon: _icon, color: _color, onChanged: (i, c) => setState(() { _icon = i; _color = c; })),
      _Step.keys => _keysBody(l),
      _Step.words => _wordsBody(l),
      _Step.check => _checkBody(l),
      _Step.password => _passwordBody(l),
      _Step.review => _reviewBody(l),
      _Step.biometric => _biometricBody(l),
    };

    return PopScope(
      // The system back gesture steps back too; on the first step it leaves.
      // Back from the first step leaves (to the welcome screen for the first vault).
      canPop: _step == _steps.first && _vault == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack) _back();
      },
      // Steps live in one page, so the system swipe has nothing to pop: swipe = Back.
      child: EdgeSwipeBack(
      enabled: _canGoBack,
      follow: true,
      onBack: _back,
      // The steps' one frame (docs/design-language.md, Steps; 2026-11-07 review: this
      // flow had its own, centred, with a short button off to the right): Back with the
      // progress on top, the title big on the left, the main button the page's width.
      child: Scaffold(
      backgroundColor: page,
      body: _autofill(StepPage(
        key: ValueKey(_step),
        title: title,
        lead: hint,
        count: steps.length,
        at: progress,
        // Once the vault exists there is no way back (Face ID's question comes after it).
        onBack: _vault != null || _step == _Step.biometric ? null : (_canGoBack ? _back : () => Navigator.of(context).maybePop()),
        actions: [
          ?_primaryButton(l),
          // Face ID's question: its No under Yes.
          if (_step == _Step.biometric)
            StepSideButton(
              key: const ValueKey('bio-no'),
              label: l.biometricOfferNo,
              onTap: _busy ? null : () => _biometricAnswer(false),
            ),
          // No Cancel on the first step (owner 2026-11-18): Back on top leaves.
        ],
        body: body,
      )),
    ),
    ),
    );
  }

  /// The password manager's form spans the password and the review (the fields stay,
  /// hidden, on the review): leaving the password step for the review must not end it,
  /// or the password would not be offered for saving once the vault is made. Not for a
  /// Top secret vault, and not on the other steps (the four words typed back are no login).
  Widget _autofill(Widget page) => _topSecret != true && (_step == _Step.password || _step == _Step.review)
      ? AutofillGroup(onDisposeAction: AutofillContextAction.cancel, child: page)
      : page;

  /// Wide main button at the end of a form step.
  /// Face ID (or fingerprint): one question, its own step.
  Widget _biometricBody(AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Column(
      children: [
        const SizedBox(height: 8),
        BiometricGlyph(kind: _bioKind ?? BiometricKind.face, size: 72, color: ink),
      ],
    );
  }

  /// The step's main button, at the right of the bottom row.
  Widget? _primaryButton(AppLocalizations l) {
    Widget button(Key key, String label, VoidCallback? onTap) => StepMainButton(key: key, label: label, onTap: onTap);
    // The first vault waits for its words to be made (a moment, at the very start).
    final loading = widget.first && _words == null && NewVaultScreen.debugWords == null;
    return switch (_step) {
      _Step.mode => button(const ValueKey('mode-next'), l.pinNext, _topSecret == null || loading ? null : _afterMode),
      _Step.look => button(const ValueKey('look-next'), l.pinNext, () => _next(_Step.look)),
      _Step.keys => button(const ValueKey('keys-next'), l.pinNext, () {
          _chooseKeys();
          _next(_Step.keys);
        }),
      _Step.words => button(const ValueKey('words-done'), _cloudOn ? l.pinNext : l.wordsWritten, _busy ? null : () => _wordsDone(l)),
      _Step.check => button(const ValueKey('check-done'), l.pinNext, _checkOk && !_busy ? () => _go(_Step.password) : null),
      _Step.password => button(const ValueKey('password-next'), l.pinNext, !_passwordOk || _busy ? null : () => _go(_Step.review)),
      // The vault is made here.
      _Step.review => button(const ValueKey('review-create'), l.reviewCreate, !_passwordOk || _busy ? null : () => _create(l)),
      _Step.biometric => button(const ValueKey('bio-yes'), l.biometricOfferYes, _busy ? null : () => _biometricAnswer(true)),
    };
  }

  /// The step after [from] in the list as it is now.
  void _next(_Step from) => _go(_steps[_steps.indexOf(from) + 1]);

  void _afterMode() {
    // A Top secret vault never shares a set kept in the cloud: it gets its own.
    if (_forcedOwn) {
      _ownKey = true;
      _chooseKeys();
    }
    _next(_Step.mode);
  }

  /// [_Step.keys] chose: with a set of its own, the words are made now, and shown.
  void _chooseKeys() => setState(() {
        _newWords = _ownKey;
        if (_ownKey && NewVaultScreen.debugWords == null) {
          _words = rust.secretKeyText(key: _freshKey ??= rust.newSecretKey()).split(' ');
        }
      });

  /// The key the words on screen spell.
  Future<Uint8List?> _shownKey() async {
    if (_ownKey && _freshKey != null) return _freshKey;
    final debug = kReleaseMode ? null : NewVaultScreen.debugWords;
    if (debug != null) {
      // Mockups: their fake core may not read words; any fixed key stands in.
      return Uint8List.fromList(rust.parseSecretKey(text: debug) ?? List.filled(32, 1));
    }
    return SecretKeyStore.read();
  }

  /// "Next" under the words: with the cloud copy, it is made, then the check (Skip goes on);
  /// when the store keeps nothing, the words are typed back as without it.
  Future<void> _wordsDone(AppLocalizations l) async {
    if (_cloudOn) {
      setState(() => _busy = true);
      final key = await _shownKey();
      final ok = key != null && await KeyBackup.save(key);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        _cloudKey = key;
      } else {
        showToast(context, KeyBackup.google ? l.wordsCloudFailedGoogle : l.wordsCloudFailed, icon: Icons.cloud_off_rounded);
        setState(() => _cloud = false);
      }
    }
    _checkOk = false;
    _ask = pickFourWords(fixed: NewVaultScreen.debugWords != null, not: _ask);
    _go(_Step.check);
  }

  /// Switched off after the copy was made (back from the password): it is taken out.
  Future<void> _cloudSwitch(bool on) async {
    setState(() => _cloud = on);
    final key = _cloudKey;
    if (!on && key != null) {
      _cloudKey = null;
      await KeyBackup.remove(key);
    }
  }

  /// Skip typing the four words back, after a card says what that risks.
  /// With the cloud copy on, the words are kept there too: Skip goes on, nothing asked.
  Future<void> _skipCheck(AppLocalizations l) async {
    if (_cloudOn) return _go(_Step.password);
    final yes = await showCard<bool>(context, title: l.wordsSkipTitle, builder: (context) {
      final c = CsColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.wordsSkipBody(settingsPath(l, SettingsSpot.keyCheck)),
              style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey('check-skip-no'),
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l.wordsCheckNow),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                key: const ValueKey('check-skip-yes'),
                style: FilledButton.styleFrom(backgroundColor: recordRed(context)),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l.wordsSkipConfirm),
              ),
            ),
          ]),
        ]),
      );
    });
    if (yes != true || !mounted) return;
    _checkSkipped = true;
    _go(_Step.password);
  }

  /// Everyday or Top Secret Mode: the two as choices, the differences under them.
  Widget _modeBody(AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget choice(bool topSecret, Widget mark, String title, String note) {
      final on = _topSecret == topSecret;
      final edge = topSecret ? topSecretRed : privateGreen;
      return Material(
        color: on ? Color.alphaBlend(edge.withValues(alpha: .12), Theme.of(context).cardColor) : Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          side: BorderSide(color: on ? edge : Colors.transparent, width: 2),
        ),
        child: InkWell(
          key: ValueKey(topSecret ? 'mode-top-secret' : 'mode-everyday'),
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          onTap: () => setState(() => _topSecret = topSecret),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              mark,
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(color: ink, fontSize: CsType.callout, fontWeight: FontWeight.w700)),
                  Text(note, style: TextStyle(color: ink.withValues(alpha: .65), fontSize: CsType.footnote, height: 1.3)),
                ]),
              ),
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? edge : ink.withValues(alpha: .4)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      choice(false, const PrivateMark(size: 30), l.modeEveryday, l.modeEverydayNote),
      const SizedBox(height: 10),
      choice(true, const TopSecretMark(size: 30), l.topSecretShort, l.modeTopSecretNote),
      // No table (owner 2026-11-03: hard to follow; five of its seven rows were the same
      // on both sides): each choice says what it does and whom it suits.
      const SizedBox(height: 14),
      Text('${l.topSecretPerVault} ${l.modeChangeLater}', style: TextStyle(color: ink.withValues(alpha: .6), fontSize: CsType.footnote, height: 1.35)),
    ]);
  }

  /// [_Step.keys] chose a set of its own: its key, made once.
  Uint8List? _freshKey;
  /// The library of a vault with its own words (api/run.rs), once its key is kept.
  String? _ownDir;

  /// Where the new vault goes: the device's library, or with its own words a new library
  /// beside it, whose key is kept first (under its own name, SecretKeyStore).
  Future<String> _libraryForNew() async {
    final key = _freshKey;
    if (!_ownKey || key == null || widget.first) return widget.libraryDir;
    final dir = _ownDir ??= run_api.newLibraryDir();
    if (dir == null) throw StateError('no library folder');
    await SecretKeyStore.write(key, dir);
    rust.setSecretKey(dir: dir, key: key);
    return dir;
  }

  /// A new set of 24 words for this vault, or the one this device already has.
  Widget _keysBody(AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget choice(bool own, IconData icon, String title, String note) {
      final on = _ownKey == own;
      return Material(
        color: on ? Color.alphaBlend(ink.withValues(alpha: .08), Theme.of(context).cardColor) : Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          side: BorderSide(color: on ? ink : Colors.transparent, width: 2),
        ),
        child: InkWell(
          key: ValueKey(own ? 'keys-new' : 'keys-device'),
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          onTap: () => setState(() => _ownKey = own),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(children: [
              Icon(icon, size: 30, color: ink),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(color: ink, fontSize: CsType.callout, fontWeight: FontWeight.w700)),
                  Text(note, style: TextStyle(color: ink.withValues(alpha: .65), fontSize: CsType.footnote, height: 1.3)),
                ]),
              ),
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? ink : ink.withValues(alpha: .4)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      choice(false, Icons.phone_iphone_rounded, l.keysDevice, l.keysDeviceNote),
      const SizedBox(height: 10),
      choice(true, Icons.key_rounded, l.keysNew, l.keysNewNote),
    ]);
  }

  /// The four words typed back are right.
  bool _checkOk = false;

  // "I wrote them down" sits in the bottom row, always in sight: on a small Android
  // phone it was below the fold (owner 2026-10-24). So does every step's main button.
  // The cloud copy is a button beside Copy and Save to file (owner 2026-11-18: the switch
  // under the words was below the fold, then "one row of three").
  Widget _wordsBody(AppLocalizations l) =>
      RecoveryWordsPanel(words: _words ?? const [], cloud: _cloudOffered ? _cloudButton(l) : null);

  /// The copy in the cloud, on by default: a button that is filled while on. What it does
  /// is said once it is turned on (the line that said it under a switch is gone).
  Widget _cloudButton(AppLocalizations l) {
    final google = KeyBackup.google;
    return WordsAction(
      key: const ValueKey('words-cloud'),
      icon: _cloud ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
      label: google ? 'Google' : 'iCloud',
      on: _cloud,
      onTap: () async {
        await _cloudSwitch(!_cloud);
        if (!mounted) return;
        showToast(context, _cloud ? (google ? l.wordsCloudNoteGoogle : l.wordsCloudNote) : l.wordsCloudOff,
            icon: _cloud ? Icons.cloud_done_rounded : Icons.cloud_off_rounded);
      },
    );
  }

  Widget _checkBody(AppLocalizations l) => Column(children: [
        RecoveryWordsCheck(
          key: ValueKey(_ask.join(',')),
          words: _words ?? const [],
          ask: _ask,
          onValid: (ok) => setState(() => _checkOk = ok),
          onShowAgain: () => _go(_Step.words),
        ),
        // Not for a Top secret vault: its words are always typed back.
        if (_topSecret != true) ...[
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('check-skip'),
            onPressed: () => _skipCheck(l),
            child: Text(l.wordsCheckSkip, style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600)),
          ),
        ],
      ]);

  Widget _passwordBody(AppLocalizations l) {
    final theme = Theme.of(context);
    // The system's password manager (ADR 0008): it may suggest a strong password, and
    // keeps it under the vault's code. Not for a Top secret vault.
    final hints = _topSecret == true ? null : const [AutofillHints.newPassword];
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The account the password is kept under, never shown: a password manager needs
        // one beside the password. Fixed before the vault exists (its draft's code).
        if (hints != null) _accountField(),
        SecretField(
          key: const ValueKey('new-password'),
          controller: _pw,
          label: l.password,
          autofillHints: hints,
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 8),
        PasswordStrength(password: _pw.text),
        const SizedBox(height: 12),
        SecretField(
          key: const ValueKey('new-password-again'),
          controller: _pwAgain,
          label: l.typeAgain,
          autofillHints: hints,
          errorText: _pwAgain.text.isNotEmpty && _pwAgain.text != _pw.text ? l.passwordsDiffer : null,
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
        ],
      ],
    );
    // The form is the one [_autofill] puts around this step and the review.
    return form;
  }

  Widget _accountField() => Offstage(
        child: ExcludeSemantics(
          child: TextField(
            key: const ValueKey('new-password-account'),
            controller: _account,
            autofillHints: const [AutofillHints.username],
            enableInteractiveSelection: false,
          ),
        ),
      );

  /// The last step: what was chosen, a line each, and a tap on a line goes back to choose
  /// it again (owner 2026-11-18); the look is chosen right here. "Create vault" makes it.
  Widget _reviewBody(AppLocalizations l) {
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final steps = _steps;
    // Where a line goes: the first of these steps the flow has.
    _Step? goTo(List<_Step> any) => any.where(steps.contains).firstOrNull;
    final where = KeyBackup.google ? 'Google' : 'iCloud Keychain';
    final words = !_newWords
        ? l.keysDevice
        : _cloudOn
            ? l.reviewWordsCloud(where)
            : _checkSkipped
                ? l.reviewWordsSkipped
                : l.reviewWordsChecked;
    Widget line(String key, Widget lead, String label, String? value, VoidCallback? onTap) => Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(Ui.groupRadius),
          child: InkWell(
            key: ValueKey(key),
            borderRadius: BorderRadius.circular(Ui.groupRadius),
            onTap: _busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(children: [
                SizedBox(width: 44, child: Center(child: lead)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: TextStyle(color: ink, fontSize: CsType.callout, fontWeight: FontWeight.w700)),
                    if (value != null)
                      Text(value, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.3)),
                  ]),
                ),
                if (onTap != null) Icon(Icons.chevron_right_rounded, color: ink.withValues(alpha: .45)),
              ]),
            ),
          ),
        );
    final mode = goTo([_Step.mode]);
    final keys = goTo([_Step.keys, _Step.words]);
    final top = _topSecret == true;
    final hidden = _topSecret != true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      line('review-look', VaultBadge(icon: vaultIcons[_icon].id, color: vaultColors[_color].id, size: 44), l.reviewLook, null,
          () => _go(_Step.look)),
      const SizedBox(height: 10),
      line('review-mode', Icon(top ? Icons.lock_rounded : Icons.photo_library_rounded, size: 28, color: top ? topSecretRed : privateGreen),
          l.reviewMode, top ? l.topSecretShort : l.modeEveryday, mode == null ? null : () => _go(mode)),
      const SizedBox(height: 10),
      line('review-words', Icon(_cloudOn ? Icons.cloud_done_rounded : Icons.key_rounded, size: 28, color: ink), l.reviewWords, words,
          keys == null ? null : () => _go(keys)),
      const SizedBox(height: 10),
      line('review-password', Icon(Icons.password_rounded, size: 28, color: ink), l.password, l.reviewPasswordSet,
          () => _go(_Step.password)),
      // The password fields stay in the password manager's form, hidden, so that it is
      // offered for saving once the vault is made.
      if (hidden)
        Offstage(
          child: ExcludeSemantics(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _accountField(),
              TextField(controller: _pw, obscureText: true, autofillHints: const [AutofillHints.newPassword]),
              TextField(controller: _pwAgain, obscureText: true, autofillHints: const [AutofillHints.newPassword]),
            ]),
          ),
        ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600)),
      ],
    ]);
  }
}

/// The vault's 24 words were not typed back when it was made (the check was skipped): a
/// tip on the vault's home reminds once (vault_home.dart); checking them clears it.
String wordsUncheckedPref(String vaultId) => 'words-unchecked.$vaultId';
