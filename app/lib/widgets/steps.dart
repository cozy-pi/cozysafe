import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'bottom_bar.dart' show PinnedAction;
import 'vault_bar.dart' show GlassButton;

/// How far along the steps are: one short bar per step, the done ones in ink (create a
/// vault, add a password).
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.count, required this.at});
  final int count;
  /// The step on screen, from 0.
  final int at;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Row(
      key: const ValueKey('step-progress'),
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 4,
              decoration: BoxDecoration(
                color: i <= at ? ink : ink.withValues(alpha: .22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One way to go, as a big card to tap (docs/design-language.md, "kind chooser"): its
/// icon in a coloured rounded square, a title and one short line. What to add, which
/// kind of password, how to bring in a two-factor code.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({super.key, required this.icon, required this.color, required this.title, this.line, required this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String? line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final c = CsColors.of(context);
    return Semantics(
      button: true,
      child: Material(
        color: ink.withValues(alpha: .06),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(Ui.radius)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(14)),
                  child: Icon(icon, color: color, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700)),
                      if (line != null) ...[
                        const SizedBox(height: 2),
                        Text(line!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: CsType.footnote, height: 1.3, color: c.muted)),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: ink.withValues(alpha: .35)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A step of a flow, one question per screen (docs/design-language.md, Steps): Back and
/// the progress on top, the title big on the left, the main button at the bottom the
/// width of the page, a second choice as plain text under it.
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.title,
    this.lead,
    required this.body,
    this.count = 0,
    this.at = 0,
    required this.onBack,
    this.actions = const [],
    this.scroll = true,
  });
  final String title;
  final String? lead;
  final Widget body;
  /// Steps in the flow (none: no progress shown) and the one on screen.
  final int count;
  final int at;
  final VoidCallback onBack;
  /// The main button, then a quieter one ([StepTextButton]).
  final List<Widget> actions;
  /// The body scrolls with the title; false where it holds its own list.
  final bool scroll;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final head = [
      Text(title,
          key: const ValueKey('step-title'),
          style: const TextStyle(fontSize: CsType.title1, fontWeight: FontWeight.w800, letterSpacing: -.4, height: 1.15)),
      if (lead != null) ...[
        const SizedBox(height: 6),
        Text(lead!, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.35)),
      ],
      const SizedBox(height: 18),
    ];
    final content = scroll
        ? SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Ui.side, 8, Ui.side, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, body]),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(Ui.side, 8, Ui.side, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, Expanded(child: body)]),
          );
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ui.side - 4, 8, Ui.side, 4),
            child: Row(
              children: [
                GlassButton(key: const ValueKey('step-back'), icon: Icons.arrow_back_rounded, tooltip: l.back, onTap: onBack),
                const SizedBox(width: 16),
                Expanded(child: count > 1 ? StepProgress(count: count, at: at) : const SizedBox()),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: actions.isEmpty
                    ? SafeArea(top: false, child: SizedBox.expand(child: content))
                    : PinnedAction(padding: Ui.side, actions: actions, child: content),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The second choice under a step's main button: plain text, thumb height.
class StepTextButton extends StatelessWidget {
  const StepTextButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, Ui.tap),
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w600)),
        ),
      );
}

/// The main button of a step, the width of the page.
class StepMainButton extends StatelessWidget {
  const StepMainButton({super.key, required this.label, required this.onTap, this.icon});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(minimumSize: const Size(0, 54), shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: 8)],
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
}
