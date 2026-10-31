import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../top_secret_mode.dart';
import 'welcome.dart' show ChoicePage;

/// Top Secret Mode's colour (owner 2026-10-31: red).
const topSecretRed = Color(0xFFE5383B);

/// Top Secret Mode's mark: a red shield with a lock (ADR 0006). Shown only while the mode
/// is on, small, where it does not get in the way.
class TopSecretMark extends StatelessWidget {
  const TopSecretMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFF6B5E), topSecretRed, Color(0xFFB71C2C)],
              ).createShader(r),
              child: Icon(Icons.shield_rounded, size: size),
            ),
            Padding(
              padding: EdgeInsets.only(top: size * .04),
              child: Icon(Icons.lock_rounded, size: size * .44, color: Colors.white),
            ),
          ],
        ),
      );
}

/// The mark with the mode's short name, in a soft red pill.
class TopSecretBadge extends StatelessWidget {
  const TopSecretBadge({super.key, this.compact = false});
  /// The mark alone in the pill, no name.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const ValueKey('top-secret-badge'),
      padding: EdgeInsets.fromLTRB(5, 3, compact ? 5 : 9, 3),
      decoration: BoxDecoration(
        color: topSecretRed.withValues(alpha: dark ? .22 : .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TopSecretMark(size: 16),
          if (!compact) ...[
            const SizedBox(width: 4),
            Text(
              AppLocalizations.of(context).topSecretShort,
              style: TextStyle(
                fontSize: CsType.caption1,
                fontWeight: FontWeight.w700,
                color: dark ? const Color(0xFFFF8A80) : const Color(0xFFC62828),
              ),
            ),
          ],
        ],
      ),
    );
  }
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
            child: Text(what, style: TextStyle(fontSize: CsType.subhead, color: ink, height: 1.3)),
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
        columnWidths: const {0: FlexColumnWidth(), 1: FixedColumnWidth(74), 2: FixedColumnWidth(74)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            const SizedBox.shrink(),
            Center(child: Text(l.modeEveryday, style: head, textAlign: TextAlign.center)),
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const TopSecretMark(size: 18),
                Text(l.topSecretShort, style: head.copyWith(color: topSecretRed), textAlign: TextAlign.center),
              ]),
            ),
          ]),
          row(l.compareLock, true, true),
          row(l.compareCapture, true, true),
          row(l.compareNotesFiles, true, true),
          row(l.compareView, true, false),
          row(l.compareThumbs, true, false),
          row(l.compareLibrary, true, false),
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
          l.topSecretRestarts,
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
  if (TopSecretMode.closesItself) exit(0);
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
  const CloseAppPage({super.key, required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The only page left (pushAndRemoveUntil): there is nothing to go back to.
    return ChoicePage(
      key: const ValueKey('close-app'),
      title: l.closeAppTitle,
      lead: on ? l.closeAppBodyOn : l.closeAppBodyOff,
      mark: on ? const TopSecretMark(size: 72) : null,
      logo: !on,
      choices: const [],
    );
  }
}

/// Where the mark shows while Top Secret Mode is on (owner 2026-10-31: somewhere that
/// does not bother; the mockup compares the places before one is chosen).
enum TopSecretPlace {
  /// Next to the vault page's big title.
  title,
  /// A small badge on the Settings button's corner, where the mode is changed.
  settings,
  /// On the corner of the lock screen's dial.
  lock,
}

abstract final class TopSecretPlaces {
  /// The places in use.
  static Set<TopSecretPlace> shown = {TopSecretPlace.settings, TopSecretPlace.lock};

  static bool show(TopSecretPlace place) => TopSecretMode.on && shown.contains(place);
}

/// [child] with the mark on its bottom-right corner, ringed in [ring] to stand off it.
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
