import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../top_secret_mode.dart';
import 'welcome.dart' show ChoicePage;

/// Top Secret Mode's colour (owner 2026-10-31: red).
const topSecretRed = Color(0xFFE5383B);

/// The everyday (Private) mode's colour, next to Top Secret's red.
const privateGreen = Color(0xFF2E9E5B);

/// Top Secret Mode's mark: a red shield with a lock (ADR 0006). Shown only while the mode
/// is on, small, where it does not get in the way.
class TopSecretMark extends StatelessWidget {
  const TopSecretMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => _ShieldMark(
        size: size,
        colors: const [Color(0xFFFF6B5E), topSecretRed, Color(0xFFB71C2C)],
        inner: Icons.lock_rounded,
      );
}

/// The Private (everyday) mode's mark, the same shape: a green shield with a photo, as it
/// shows what is inside.
class PrivateMark extends StatelessWidget {
  const PrivateMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => _ShieldMark(
        size: size,
        colors: const [Color(0xFF5FD38D), privateGreen, Color(0xFF1E7A44)],
        inner: Icons.image_rounded,
      );
}

class _ShieldMark extends StatelessWidget {
  const _ShieldMark({required this.size, required this.colors, required this.inner});
  final double size;
  final List<Color> colors;
  final IconData inner;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Flat (owner 2026-10-31: no gradient): the middle of its colours.
            Icon(Icons.shield_rounded, size: size, color: colors[colors.length ~/ 2]),
            Padding(
              padding: EdgeInsets.only(top: size * .04),
              child: Icon(inner, size: size * .44, color: Colors.white),
            ),
          ],
        ),
      );
}

/// What changes with Top Secret Mode, side by side (owner 2026-10-31: people must see the
/// difference to choose). Every line is checked against the code: the gates are
/// `TopSecretMode.on` in the screens and `refuse_in_top_secret` in api/run.rs.
class TopSecretCompare extends StatelessWidget {
  const TopSecretCompare({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    final muted = ink.withValues(alpha: .6);
    Widget yes() => Icon(Icons.check_circle_rounded, size: 20, color: const Color(0xFF2E9E5B));
    Widget no() => Icon(Icons.remove_circle_rounded, size: 20, color: ink.withValues(alpha: .3));
    TableRow row(String what, bool everyday, bool topSecret) => TableRow(children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            // One line each (owner 2026-10-31): a long translation shrinks a little
            // instead of wrapping.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(what, maxLines: 1, softWrap: false, style: TextStyle(fontSize: CsType.subhead, color: ink)),
            ),
          ),
          Center(child: everyday ? yes() : no()),
          Center(child: topSecret ? yes() : no()),
        ]);
    final head = TextStyle(fontSize: CsType.footnote, fontWeight: FontWeight.w700, color: muted);
    return Container(
      key: const ValueKey('top-secret-compare'),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      decoration: BoxDecoration(
        color: solidTint(context, ink.withValues(alpha: .06)),
        borderRadius: BorderRadius.circular(Ui.radius),
      ),
      child: Table(
        columnWidths: const {0: FlexColumnWidth(), 1: IntrinsicColumnWidth(), 2: IntrinsicColumnWidth()},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            const SizedBox.shrink(),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(l.modeEveryday, style: head.copyWith(color: privateGreen), textAlign: TextAlign.center)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(l.topSecretShort, style: head.copyWith(color: topSecretRed), textAlign: TextAlign.center)),
          ]),
          // Both modes keep the same encryption (ADR 0001); said first so no one thinks
          // the everyday mode is less encrypted (owner 2026-10-31).
          row(l.compareEncrypted, true, true),
          row(l.compareLock, true, true),
          row(l.compareCapture, true, true),
          // Photos from the library and files from Files in one row (owner 2026-10-31).
          row(l.compareNotesFiles, true, true),
          row(l.compareView, true, false),
          row(l.compareThumbs, true, false),
        ],
      ),
    );
  }
}

/// Settings → Top Secret Mode: what it does, the difference, and the one button.
/// [verify] asks for the owner first (docs/security.md: either way changes how the vault
/// is protected).
class TopSecretModePage extends StatelessWidget {
  const TopSecretModePage({super.key, required this.verify});
  final Future<bool> Function() verify;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final on = TopSecretMode.on;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        const Center(child: TopSecretMark(size: 64)),
        const SizedBox(height: 12),
        Text(
          on ? l.topSecretIsOn : l.topSecretIsOff,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700, color: ink),
        ),
        const SizedBox(height: 8),
        Text(
          l.topSecretLead,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: CsType.subhead, height: 1.4, color: ink.withValues(alpha: .75)),
        ),
        const SizedBox(height: 18),
        const TopSecretCompare(),
        const SizedBox(height: 10),
        Text(
          '${l.topSecretPerVault} ${l.topSecretRestarts}',
          style: TextStyle(fontSize: CsType.footnote, height: 1.35, color: ink.withValues(alpha: .6)),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const ValueKey('top-secret-turn'),
          style: on ? null : FilledButton.styleFrom(backgroundColor: topSecretRed, foregroundColor: Colors.white),
          onPressed: () async {
            if (!await verify() || !context.mounted) return;
            await turnTopSecretMode(context, !on);
          },
          child: Text(on ? l.topSecretTurnOff : l.topSecretTurnOn),
        ),
      ],
    );
  }
}

/// Turn the mode on or off: the vault locks, temporary files are wiped, then the app
/// quits (Android, computers) or asks to be closed (iPhone, iPad).
Future<void> turnTopSecretMode(BuildContext context, bool next) async {
  final nav = Navigator.of(context, rootNavigator: true);
  await TopSecretMode.turn(next);
  nav.pushAndRemoveUntil(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => CloseAppPage(on: next),
    ),
    (_) => false,
  );
}

/// iPhone and iPad, after turning the mode on or off: Apple asks apps not to quit by
/// themselves, so this page asks the person to close Cozy Safe; nothing else can be done
/// on it.
class CloseAppPage extends StatelessWidget {
  const CloseAppPage({super.key, required this.on, this.forVault = false});
  final bool on;
  /// A Top secret vault was asked to open after an everyday one ([restartForMode]).
  final bool forVault;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The only page left (pushAndRemoveUntil): there is nothing to go back to.
    return ChoicePage(
      key: const ValueKey('close-app'),
      title: TopSecretMode.closesItself && (Platform.isAndroid || TopSecretMode.debugClosesItself == true)
          ? l.restartingTitle
          : l.closeAppTitle,
      lead: TopSecretMode.closesItself
          ? (Platform.isAndroid || TopSecretMode.debugClosesItself == true ? l.restartCountdownLead : l.closeCountdownLead)
          : forVault
              ? l.closeAppBodyVault
              : on
                  ? l.closeAppBodyOn
                  : l.closeAppBodyOff,
      mark: on ? const TopSecretMark(size: 72) : null,
      logo: !on,
      choices: [
        // Android and computers: 3, 2, 1, then Android starts again by itself and a
        // computer closes (owner 2026-10-31: not closing out of the blue).
        if (TopSecretMode.closesItself) const _QuitCountdown(),
      ],
    );
  }
}

class _QuitCountdown extends StatefulWidget {
  const _QuitCountdown();

  @override
  State<_QuitCountdown> createState() => _QuitCountdownState();
}

class _QuitCountdownState extends State<_QuitCountdown> {
  int _left = 3;
  Timer? _tick;

  /// Mockups: hold at 3 instead of quitting.
  static bool get _hold => TopSecretMode.debugClosesItself != null;

  @override
  void initState() {
    super.initState();
    if (_hold) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left <= 1) {
        t.cancel();
        TopSecretMode.quit();
        return;
      }
      setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Text(
          '$_left',
          key: const ValueKey('quit-countdown'),
          style: TextStyle(fontSize: CsType.largeTitle * 2, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface),
        ),
      );
}

/// A Top secret vault asked to open in a run that opened an everyday one
/// (`VaultError.restartForMode`): nothing opened; the run ends and the person starts the
/// app again, then unlocks that vault.
Future<void> restartForMode(BuildContext context) async {
  final nav = Navigator.of(context, rootNavigator: true);
  await TopSecretMode.endRun();
  nav.pushAndRemoveUntil(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const CloseAppPage(on: true, forVault: true),
    ),
    (_) => false,
  );
}

/// Top Secret Mode's sign on the vault's page: the page colour washed with a little red
/// at the top, fading out by about two fifths of the way down. Light enough to read through,
/// strong enough to tell the mode at a glance.
class TopSecretWash extends StatelessWidget {
  const TopSecretWash({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      key: const ValueKey('top-secret-wash'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // About two fifths of the screen (owner 2026-10-31), fading out gently.
          stops: const [0, .2, .42],
          colors: [
            topSecretRed.withValues(alpha: dark ? .22 : .13),
            topSecretRed.withValues(alpha: dark ? .13 : .08),
            topSecretRed.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// [child] with Top Secret Mode's mark on its bottom-right corner, ringed in [ring] to
/// stand off it.
class TopSecretCorner extends StatelessWidget {
  const TopSecretCorner({super.key, required this.child, required this.ring, this.size = 18, this.offset = -3});
  final Widget child;
  final Color ring;
  final double size;
  final double offset;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            right: offset,
            bottom: offset,
            child: Container(
              key: const ValueKey('top-secret-corner'),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
              child: TopSecretMark(size: size),
            ),
          ),
        ],
      );
}
