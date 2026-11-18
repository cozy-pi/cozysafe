import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'bottom_bar.dart' show PinnedAction;
import 'vault_bar.dart' show RoundBack;

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
        color: Theme.of(context).cardColor,
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

/// A step of a flow, one question per screen (docs/design-language.md, Steps): the
/// progress on top, the title big on the left, and at the bottom one row that never moves
/// between steps: Back and the main button, half the width each (owner 2026-11-18: Back
/// on top and a Cancel that came and went made the buttons jump; then "split in two, as
/// Face ID's"). A second choice, as plain text, and [pinned] sit above that row; with no
/// Back, a two-way question's answers take the two halves.
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.title,
    this.lead,
    required this.body,
    this.count = 0,
    this.at = 0,
    this.onBack,
    this.actions = const [],
    this.pinned,
    this.scroll = true,
  });
  final String title;
  final String? lead;
  final Widget body;
  /// Steps in the flow (none: no progress shown) and the one on screen.
  final int count;
  final int at;
  /// Null: no Back (a page with nothing under it, or one that must be finished).
  final VoidCallback? onBack;
  /// The main button, then a quieter one ([StepTextButton], or [StepSideButton]).
  final List<Widget> actions;
  /// Kept in sight above the buttons, out of the scrolling body (a switch the step's
  /// button depends on).
  final Widget? pinned;
  /// The body scrolls with the title; false where it holds its own list.
  final bool scroll;

  @override
  Widget build(BuildContext context) {
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
    // The body in the middle of the room under the title (owner 2026-11-18: "the content
    // must be in the middle", on every page): the column is at least the room's height
    // and shares what is left above and under the body; a long body simply scrolls.
    final content = scroll
        ? LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Ui.side, 8, Ui.side, 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - 24)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: head),
                    body,
                    // The third child, so the space is shared above and under the body.
                    const SizedBox(height: 0),
                  ],
                ),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(Ui.side, 8, Ui.side, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, Expanded(child: body)]),
          );
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // Back sits with the main button; on top only when the page has no button.
          if ((onBack != null && actions.isEmpty) || count > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ui.groupSide, 8, Ui.side, 4),
              child: Row(
                children: [
                  if (onBack != null && actions.isEmpty)
                    RoundBack(key: const ValueKey('step-back'), onTap: onBack)
                  else
                    const SizedBox(height: Ui.circle),
                  const SizedBox(width: 16),
                  Expanded(child: count > 1 ? StepProgress(count: count, at: at) : const SizedBox()),
                  const SizedBox(width: 8),
                ],
              ),
            )
          else
            const SizedBox(height: 12),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: actions.isEmpty
                    ? SafeArea(top: false, child: SizedBox.expand(child: content))
                    : PinnedAction(padding: Ui.side, actions: _bottom(context), child: content),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Above, what is pinned and the quieter choices; last, one row in the same place on
  /// every step: Back (or a two-way question's other answer) and the main button, half
  /// the width each.
  List<Widget> _bottom(BuildContext context) {
    final side = onBack == null && actions.length == 2 && actions[1] is StepSideButton;
    final left = onBack != null
        ? StepSideButton(
            key: const ValueKey('step-back'),
            label: AppLocalizations.of(context).back,
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: onBack,
          )
        : side
            ? actions[1]
            : null;
    return [
      if (pinned != null) ...[pinned!, const SizedBox(height: 10)],
      if (!side && actions.length > 1) ...[...actions.skip(1), const SizedBox(height: 6)],
      Row(children: [
        if (left != null) ...[Expanded(child: left), const SizedBox(width: 12)],
        // Only a quiet way on (Skip): it takes the half as an outlined button, so the row
        // stays balanced.
        Expanded(
          child: switch (actions.first) {
            final StepTextButton t => StepSideButton(key: t.key, label: t.label, onTap: t.onTap),
            final first => first,
          },
        ),
      ]),
    ];
  }
}

/// The left half of a step's bottom row, outlined: Back, or the other answer of a
/// two-way question on a step with no Back.
class StepSideButton extends StatelessWidget {
  const StepSideButton({super.key, required this.label, required this.onTap, this.icon});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: _tapped(onTap),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54), shape: const StadiumBorder()),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 6)],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      );
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
          onPressed: _tapped(onTap),
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
  const StepMainButton({super.key, required this.label, required this.onTap, this.icon, this.busyLabel});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  /// While a slow call runs (Argon2id): a spinner and these words in place of [label].
  final String? busyLabel;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: _tapped(onTap),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 54), shape: const StadiumBorder()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busyLabel != null) ...[
              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.4)),
              const SizedBox(width: 12),
            ] else if (icon != null) ...[
              Icon(icon, size: 22),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(busyLabel ?? label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
}

/// What went wrong in a step, under its fields: red, with the code to copy.
class StepError extends StatelessWidget {
  const StepError(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: CsType.subhead, fontWeight: FontWeight.w600, height: 1.35)),
      );
}

/// A step's buttons (Back, Next, Later…) tap the hand lightly (owner 2026-11-18).
VoidCallback? _tapped(VoidCallback? onTap) => onTap == null
    ? null
    : () {
        HapticFeedback.lightImpact();
        onTap();
      };
