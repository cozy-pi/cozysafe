import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';

/// How strong a new vault password is: four bars and a word, from the vault's own rule
/// (owner 2026-10-31, NIST SP 800-63B): at least [rust.minPasswordLength] characters and
/// not one of the most common passwords; longer is stronger. Why it would be refused is
/// said with the way out.
class PasswordStrength extends StatelessWidget {
  const PasswordStrength({super.key, required this.password, this.private = false});

  final String password;
  /// By the Private vault's rule (ADR 0005), whatever this run's kind: a Top secret run
  /// sets the Private vault's password.
  final bool private;

  static rust.PasswordProblem _problem(String password, bool private) =>
      private ? rust.privatePasswordProblem(password: password) : rust.passwordProblem(password: password);

  /// Whether [password] may be saved as a new password (the vault checks it again).
  static bool acceptable(String password, {bool private = false}) =>
      password.isNotEmpty && _problem(password, private) == rust.PasswordProblem.none;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final min = private ? rust.minPrivatePasswordLength() : rust.minPasswordLength();
    final short = password.characters.length < min;
    final score = password.isEmpty ? 0 : rust.passwordScore(password: password).clamp(0, 4);
    // 0–1 weak, 2 fair, 3 good, 4 strong; a short one shows no bars.
    final bars = short ? 0 : score.clamp(1, 4);
    final strong = Theme.of(context).colorScheme.primary;
    final color = switch (bars) { 0 || 1 => recordRed(context), 2 => c.warnInk, _ => strong };
    final problem = short ? rust.PasswordProblem.tooShort : _problem(password, private);
    final common = problem == rust.PasswordProblem.common;
    final word = short
        ? l.passwordMinLength(min)
        : common
            ? l.passwordCommon
            : switch (bars) { 1 => l.strengthLabelWeak, 2 => l.strengthLabelFair, 3 => l.strengthLabelGood, _ => l.strengthLabelStrong };
    final why = switch (problem) {
      rust.PasswordProblem.common => l.passwordCommonFix,
      rust.PasswordProblem.guessable => l.passwordGuessable,
      _ => null,
    };
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
                    color: i < (common ? 1 : bars) ? (common ? recordRed(context) : color) : c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(word,
            key: const ValueKey('password-strength-word'),
            style: TextStyle(color: short ? c.muted : (common ? recordRed(context) : color), fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
        if (!short && why != null) ...[
          const SizedBox(height: 4),
          Text(why, key: const ValueKey('password-refused'), style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.4)),
        ],
      ],
    );
  }
}
