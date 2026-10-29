import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';

/// "Suggest a password": a small chip over the password field, not a main button (owner
/// 2026-10-29: the theme's page-wide, 52-high button made it the biggest thing there).
class SuggestPasswordButton extends StatelessWidget {
  const SuggestPasswordButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('suggest-password'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, Ui.chip),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: ink.withValues(alpha: .08),
          foregroundColor: ink,
          shape: const StadiumBorder(),
        ),
        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
        label: Text(AppLocalizations.of(context).suggestPassword,
            style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// How strong a new vault password is: four bars and a word, from the same zxcvbn score
/// the vault uses, and why it would be refused (2026-10-25, NIST SP 800-63B): under
/// [rust.minPasswordLength] characters, one of the most common passwords, or easy to
/// guess without being a phrase of four words. The way out is said with it.
class PasswordStrength extends StatelessWidget {
  const PasswordStrength({super.key, required this.password});

  final String password;

  /// Whether [password] may be saved as a new password (the vault checks it again).
  static bool acceptable(String password) =>
      password.isNotEmpty && rust.passwordProblem(password: password) == rust.PasswordProblem.none;

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
    final problem = short ? rust.PasswordProblem.tooShort : rust.passwordProblem(password: password);
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
