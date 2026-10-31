import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../vault_kind.dart';
import '../widgets/readable.dart';
import '../widgets/password_strength.dart';
import '../widgets/secret.dart';
import '../widgets/vault_bar.dart';
import 'common.dart';
import 'new_vault.dart';
import 'welcome.dart';

/// The two kinds of vault on screen (ADR 0005): the Private vault's page in a Top secret
/// run, switching from Settings, the page that asks to close the app on iPhone and iPad,
/// and a Private run's first screen.

/// Whether this device has a Private library yet. Read as a file, not through Rust: a
/// Top secret run may not open it.
Future<bool> privateLibraryExists() async {
  final support = (await getApplicationSupportDirectory()).path;
  return File(
    '${RunKind.libraryDir(VaultKind.private, support)}${Platform.pathSeparator}library.json',
  ).existsSync();
}

/// The short name of a kind, as said inside a sentence ("the Private vault").
String kindName(AppLocalizations l, VaultKind kind) =>
    kind == VaultKind.topSecret ? l.topSecretName : l.privateName;

/// Settings → Private vault, in a Top secret run (owner 2026-10-31). Before there is one:
/// what it is for, then "Create": the person sets the Private vault's own password (the
/// Private rule, 14 characters; four or five random words suggested in words only), the
/// app keeps it at once as a note in the open Top secret vault, then offers the switch.
/// The first Private start asks for it again. Once there is one: only the switch.
class PrivateVaultPage extends StatefulWidget {
  const PrivateVaultPage({super.key, required this.exists});

  /// A Private library is already on this device.
  final bool exists;

  /// Mockups: whether a Private library is there, instead of looking.
  static bool? debugExists;

  @override
  State<PrivateVaultPage> createState() => _PrivateVaultPageState();
}

enum _Stage { about, password, saved }

class _PrivateVaultPageState extends State<PrivateVaultPage> {
  late _Stage _stage = widget.exists ? _Stage.saved : _Stage.about;
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  /// Keep the password as a note in the open Top secret vault: the Private vault's only
  /// way back if it is forgotten (ADR 0005). The Private library itself is made by the
  /// first Private start; this run may not touch it.
  Future<void> _save(AppLocalizations l) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await rust.addNote(title: l.privatePasswordNoteTitle, text: _pw.text, createdMs: nowMs());
      _pw.clear();
      if (mounted) setState(() => _stage = _Stage.saved);
    } catch (_) {
      if (mounted) setState(() => _error = l.errorStorage);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final lead = TextStyle(color: ink.withValues(alpha: .8), fontSize: CsType.callout, height: 1.45);
    return FormColumn(
      actions: [
        switch (_stage) {
          _Stage.about => FilledButton(
              key: const ValueKey('create-private'),
              onPressed: () => setState(() => _stage = _Stage.password),
              child: Text(l.privateVaultCreate),
            ),
          _Stage.password => FilledButton(
              key: const ValueKey('save-private-password'),
              onPressed: !_busy && PasswordStrength.acceptable(_pw.text, private: true) ? () => _save(l) : null,
              child: Text(l.privatePasswordSave),
            ),
          _Stage.saved => FilledButton(
              key: const ValueKey('switch-to-private'),
              onPressed: () => switchKind(context, VaultKind.private),
              child: Text(l.switchToPrivate),
            ),
        },
      ],
      children: [
        if (_stage != _Stage.password) ...[
          const Icon(Icons.photo_library_rounded, size: 44),
          const SizedBox(height: 14),
        ],
        ...switch (_stage) {
          _Stage.about => [
              Text(l.privateVaultLead, textAlign: TextAlign.center, style: lead),
              const SizedBox(height: 20),
              _Points(points: [
                (Icons.perm_media_rounded, l.privateVaultPointWhat),
                (Icons.password_rounded, l.privateVaultPointOpens),
                (Icons.call_split_rounded, l.privateVaultPointApart),
              ]),
            ],
          _Stage.password => [
              Text(l.privatePasswordTitle,
                  style: TextStyle(color: ink, fontSize: CsType.title2, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(l.privatePasswordSetLead, style: lead),
              const SizedBox(height: 20),
              SecretField(
                key: const ValueKey('private-password'),
                controller: _pw,
                label: l.password,
                enabled: !_busy,
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 8),
              PasswordStrength(password: _pw.text, private: true),
            ],
          _Stage.saved => [
              Text(widget.exists ? l.privateVaultLead : l.privatePasswordSaved,
                  key: const ValueKey('private-password-saved'), textAlign: TextAlign.center, style: lead),
            ],
        },
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }
}

/// A few lines, each with its icon, in one rounded card.
class _Points extends StatelessWidget {
  const _Points({required this.points});
  final List<(IconData, String)> points;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: solidTint(context, ink.withValues(alpha: .06)),
        borderRadius: BorderRadius.circular(Ui.radius),
      ),
      child: Column(
        children: [
          for (final (icon, text) in points)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 22, color: ink.withValues(alpha: .75)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: ink,
                        fontSize: CsType.subhead,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Switch to the other kind, after a short card that says what happens. Nothing carries
/// over: the open vault locks, temporary files are wiped, then the app quits (Android,
/// computers) or asks to be closed (iPhone, iPad).
Future<void> switchKind(BuildContext context, VaultKind next) async {
  final l = AppLocalizations.of(context);
  final go = await showCard<bool>(
    context,
    title: l.switchToTitle(kindName(l, next)),
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            RunKind.closesItself
                ? l.switchQuitsBody(kindName(l, next))
                : l.switchClosesBody(kindName(l, next)),
            style: TextStyle(
              fontSize: CsType.subhead,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: .8),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('switch-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.switchGo),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final nav = Navigator.of(context, rootNavigator: true);
  await RunKind.switchTo(next);
  if (RunKind.closesItself) exit(0);
  nav.pushAndRemoveUntil(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => CloseAppPage(next: next),
    ),
    (_) => false,
  );
}

/// iPhone and iPad, after a switch: Apple asks apps not to quit by themselves, so this
/// page asks the person to close Cozy Safe; nothing else can be done on it.
class CloseAppPage extends StatelessWidget {
  const CloseAppPage({super.key, required this.next});
  final VaultKind next;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The only page left (pushAndRemoveUntil): there is nothing to go back to.
    return ChoicePage(
      key: const ValueKey('close-app'),
      title: l.closeAppTitle,
      lead: l.closeAppBody(kindName(l, next)),
      logo: true,
      choices: const [],
    );
  }
}

/// A Private run's first screen (no Private vault yet): make it with the five words kept
/// in the Top secret vault, or go back there.
class PrivateWelcomeScreen extends StatelessWidget {
  const PrivateWelcomeScreen({super.key, required this.libraryDir});
  final String libraryDir;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ChoicePage(
      title: l.privateVault,
      lead: l.privateWelcomeLead,
      logo: true,
      choices: [
        BigChoice(
          key: const ValueKey('private-welcome-new'),
          icon: Icons.add_rounded,
          title: l.privateVaultCreate,
          note: l.privateWelcomeNewNote,
          strong: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Readable(
                child: NewVaultScreen(libraryDir: libraryDir, first: true),
              ),
            ),
          ),
        ),
        BigChoice(
          key: const ValueKey('private-welcome-back'),
          icon: Icons.lock_rounded,
          title: l.switchToTopSecret,
          note: l.privateWelcomeBackNote,
          onTap: () => switchKind(context, VaultKind.topSecret),
        ),
      ],
    );
  }
}
