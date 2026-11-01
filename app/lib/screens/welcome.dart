import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/brand.dart';
import 'new_vault.dart';
import 'restore_flow.dart';
import '../widgets/readable.dart';
import '../test_login.dart';

/// The first screen on a device with no vault (owner 2026-10-24): two choices, nothing
/// else to read. "Restore" asks where the vault is first. A new vault on a device that
/// has vaults starts here too, as on a fresh install (owner 2026-11-01), with Back.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.libraryDir, this.adding = false});
  final String libraryDir;
  /// Another vault on a device that has one (Vault manager → New vault): Back returns.
  final bool adding;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ChoicePage(
      title: 'Cozy Safe',
      lead: l.welcomeLead,
      logo: true,
      back: adding,
      choices: [
        // Not set apart from the others (owner 2026-11-01).
        BigChoice(
          key: const ValueKey('welcome-new'),
          icon: Icons.add_rounded,
          title: l.welcomeNew,
          note: l.welcomeNewNote,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => Readable(child: NewVaultScreen(libraryDir: libraryDir, first: !rust.hasVaults(dir: libraryDir))),
          )),
        ),
        BigChoice(
          key: const ValueKey('welcome-restore'),
          icon: Icons.settings_backup_restore_rounded,
          title: l.welcomeRestore,
          note: l.welcomeRestoreNote,
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => Readable(child: RestorePickScreen(libraryDir: libraryDir)),
          )),
        ),
        // Android test builds (owner 2026-11-01): one tap to a vault made for trying.
        if (TestLogin.shown)
          BigChoice(
            key: const ValueKey('welcome-test-login'),
            icon: Icons.bolt_rounded,
            title: l.testLogin,
            note: l.testLoginNote,
            onTap: () => TestLogin.run(context, libraryDir),
          ),
      ],
    );
  }
}

/// A title, a line, and a few large choices over the vault backdrop.
class ChoicePage extends StatelessWidget {
  const ChoicePage({super.key, required this.title, required this.lead, required this.choices, this.logo = false, this.back = false, this.mark});
  final String title;
  final String lead;
  final List<Widget> choices;
  final bool logo;
  /// In the logo's place: a kind of vault's mark (vault_kinds.dart).
  final Widget? mark;
  final bool back;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          const Positioned.fill(child: VaultBackdrop()),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      if (back)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        ),
                      const Spacer(flex: 3),
                      if (mark != null) ...[
                        mark!,
                        const SizedBox(height: 22),
                      ] else if (logo) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Image.asset('assets/icon.png', width: 88, height: 88, filterQuality: FilterQuality.medium),
                        ),
                        const SizedBox(height: 20),
                      ],
                      Text(title,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ink, fontSize: CsType.title1, fontWeight: FontWeight.w800, letterSpacing: -.4)),
                      const SizedBox(height: 8),
                      Text(lead,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ink.withValues(alpha: .75), fontSize: CsType.callout, height: 1.4)),
                      const Spacer(flex: 2),
                      for (final c in choices) ...[c, const SizedBox(height: 12)],
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A large choice: icon, a short title, one line under it.
class BigChoice extends StatelessWidget {
  const BigChoice({super.key, required this.icon, required this.title, required this.note, required this.onTap, this.strong = false});
  final IconData icon;
  final String title;
  final String note;
  final VoidCallback? onTap;
  /// The main way: filled with the ink.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = strong ? scheme.surface : scheme.onSurface;
    final fill = strong ? scheme.onSurface : solidTint(context, scheme.onSurface.withValues(alpha: .08));
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            children: [
              Icon(icon, size: 30, color: ink),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: ink, fontSize: CsType.body, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(note, style: TextStyle(color: ink.withValues(alpha: .7), fontSize: CsType.subhead, height: 1.3)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: ink.withValues(alpha: .6)),
            ],
          ),
        ),
      ),
    );
  }
}
