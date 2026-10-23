import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';

/// How strong a vault password is, shown and never enforced (owner 2026-10-23): four
/// bars and a word, from the same zxcvbn score the vault uses. The only rule is the
/// length ([rust.minPasswordLength]); a weak password gets a note on what keeps it safe.
class PasswordStrength extends StatelessWidget {
  const PasswordStrength({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final min = rust.minPasswordLength();
    final short = password.characters.length < min;
    final score = password.isEmpty ? 0 : rust.passwordScore(password: password).clamp(0, 4);
    // 0–1 weak, 2 fair, 3 good, 4 strong; a short one shows no bars.
    final bars = short ? 0 : score.clamp(1, 4);
    final strong = Theme.of(context).colorScheme.primary;
    final color = switch (bars) { 0 || 1 => recordRed(context), 2 => c.warnInk, _ => strong };
    final word = short
        ? l.passwordMinLength(min)
        : switch (bars) { 1 => l.strengthLabelWeak, 2 => l.strengthLabelFair, 3 => l.strengthLabelGood, _ => l.strengthLabelStrong };
    return Column(
      key: const ValueKey('password-strength'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < bars ? color : c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(word, style: TextStyle(color: short ? c.muted : color, fontSize: 13, fontWeight: FontWeight.w600)),
        if (!short && bars <= 2) ...[
          const SizedBox(height: 4),
          Text(l.strengthLabelWeakNote, style: TextStyle(color: c.muted, fontSize: 13, height: 1.4)),
        ],
      ],
    );
  }
}
