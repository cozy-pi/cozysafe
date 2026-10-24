import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Number pad for the PIN: digits only, no letters (they mean nothing for a PIN).
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.enabled = true,
  });

  final void Function(String digit) onDigit;
  final VoidCallback onDelete;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget key(String d) => _Key(
      onTap: enabled ? () => onDigit(d) : null,
      child: Text(
        d,
        style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w500,
          color: ink,
        ),
      ),
    );
    const blank = SizedBox(width: 64, height: 64);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ]) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              key(row[0]),
              const SizedBox(width: 30),
              key(row[1]),
              const SizedBox(width: 30),
              key(row[2]),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            blank,
            const SizedBox(width: 30),
            key('0'),
            const SizedBox(width: 30),
            Semantics(
              button: true,
              label: l.pinDelete,
              child: _Key(
                ghost: true,
                onTap: enabled ? onDelete : null,
                child: Icon(
                  Icons.backspace_outlined,
                  color: ink,
                  size: 26,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.child, this.onTap, this.ghost = false});

  final Widget child;
  final VoidCallback? onTap;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ghost ? Colors.transparent : solidTint(context, Theme.of(context).colorScheme.onSurface.withValues(alpha: .1)),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        child: SizedBox(width: 64, height: 64, child: Center(child: child)),
      ),
    );
  }
}

/// One dot per digit typed so far, nothing else: no empty placeholders and no count,
/// so someone looking over a shoulder does not learn how long the PIN is.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.filled, required this.color});

  final int filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final shown = filled.clamp(0, 20);
    final dot = shown > 12 ? 9.0 : (shown > 8 ? 11.0 : 14.0);
    final gap = shown > 12 ? 3.0 : (shown > 8 ? 5.0 : 7.0);
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < shown; i++)
            Container(
              margin: EdgeInsets.symmetric(horizontal: gap),
              width: dot,
              height: dot,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
        ],
      ),
    );
  }
}
