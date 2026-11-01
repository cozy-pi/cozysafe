import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../widgets/bottom_bar.dart';

String vaultErrorText(AppLocalizations l, rust.VaultError e) => switch (e) {
      rust.VaultError.weakPassword => l.errorWeakPassword,
      rust.VaultError.passwordInUse => l.errorPasswordInUse,
      rust.VaultError.emptyName => l.errorEmptyName,
      rust.VaultError.locked => l.errorLocked,
      rust.VaultError.badPin => l.errorBadPin,
      rust.VaultError.pinInUse => l.errorPinInUse,
      rust.VaultError.wrongSecretKey => l.errorWrongSecretKey,
      rust.VaultError.badBackup => l.errorBadBackup,
      rust.VaultError.libraryExists => l.errorLibraryExists,
      rust.VaultError.weakKdf => l.errorWeakKdf,
      rust.VaultError.restartForMode => l.closeAppBodyVault,
      rust.VaultError.storage => l.errorStorage,
    };

/// A centred, width-limited, scrollable column: phones fill the width, desktops
/// get a comfortable reading column, and the keyboard never hides the button.
class FormColumn extends StatelessWidget {
  const FormColumn({super.key, required this.children, this.actions = const []});

  final List<Widget> children;
  /// The form's main button (and a quieter one under it), pinned to the bottom above
  /// the keyboard ([PinnedAction]) rather than under the fields.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final form = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
    if (actions.isEmpty) return SafeArea(child: form);
    return SafeArea(bottom: false, child: PinnedAction(actions: actions, child: form));
  }
}

/// Button label with a spinner while a slow call (Argon2id) runs.
class BusyLabel extends StatelessWidget {
  const BusyLabel({super.key, required this.busy, required this.idle, required this.working});

  final bool busy;
  final String idle;
  final String working;

  @override
  Widget build(BuildContext context) {
    if (!busy) return Text(idle);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(width: 12),
        Text(working),
      ],
    );
  }
}

/// App icon + name, at the top of the screens shown before a vault is open.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key, this.center = false});

  final bool center;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.asset('assets/icon.png', width: 36, height: 36, filterQuality: FilterQuality.medium),
        ),
        const SizedBox(width: 10),
        Text(
          'Cozy Safe',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        ),
      ],
    );
  }
}

/// A page that fades in over the current one instead of sliding: for the pages with the
/// lock screen's background (creating a vault, setting a PIN), so a plain page and that
/// background never sit side by side during the move (owner 2026-10-24: the slide showed
/// half light, half dark, and flashed).
PageRoute<T> fadeRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (context, animation, _, child) {
        final a = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: .97, end: 1.0).animate(a), child: child),
        );
      },
    );
