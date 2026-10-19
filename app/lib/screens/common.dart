import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;

String vaultErrorText(AppLocalizations l, rust.VaultError e) => switch (e) {
      rust.VaultError.weakPassword => l.errorWeakPassword,
      rust.VaultError.passwordInUse => l.errorPasswordInUse,
      rust.VaultError.emptyName => l.errorEmptyName,
      rust.VaultError.locked => l.errorLocked,
      rust.VaultError.wrongSecretKey => l.errorWrongSecretKey,
      rust.VaultError.badBackup => l.errorBadBackup,
      rust.VaultError.libraryExists => l.errorLibraryExists,
      rust.VaultError.storage => l.errorStorage,
    };

/// A centred, width-limited, scrollable column: phones fill the width, desktops
/// get a comfortable reading column, and the keyboard never hides the button.
class FormColumn extends StatelessWidget {
  const FormColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
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
      ),
    );
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
