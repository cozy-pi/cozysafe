import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../key_backup.dart';
import '../secret_key_store.dart';
import '../src/rust/api/run.dart' as run_api;
import '../src/rust/api/vault.dart' as rust;
import '../sync/drive_join.dart';
import '../sync/drive.dart' show driveOffered;
import '../sync/invite_page.dart';
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/words_input.dart';
import '../widgets/toast.dart';
import 'common.dart';
import 'new_vault.dart';
import 'restore.dart';
import 'unlock.dart';
import 'tour.dart' show TourKind;
import 'vault_home.dart';
import 'welcome.dart';
import '../widgets/readable.dart';
import '../top_secret_mode.dart';
import 'top_secret_page.dart' show restartForMode;

/// Where a restored vault goes: this device's library while it holds no vault, otherwise
/// a new library beside it, for the vault's own 24 words (api/run.rs).
String restoreTarget(String libraryDir) =>
    rust.libraryHasVaults(dir: libraryDir) ? (run_api.newLibraryDir() ?? libraryDir) : libraryDir;

/// The vault is open here and its words kept: offer Face ID, go in.
Future<void> openRestored(BuildContext context, String libraryDir, rust.VaultInfo vault) async {
  TopSecretMode.opened(vault);
  await offerBiometric(context);
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
    MaterialPageRoute<void>(builder: (_) => VaultHomeScreen(libraryDir: libraryDir, vault: vault, tour: TourKind.restored)),
    (_) => false,
  );
}

/// Restore, step 1 (owner 2026-11-01: the source first): where the vault is, all choices
/// alike (none lit up). Another device: scan its code, then the password only. Google Drive or a backup file:
/// the 24 words and the password, then it goes. Works on a device that holds vaults too
/// (the restored one gets a library of its own).
class RestorePickScreen extends StatefulWidget {
  const RestorePickScreen({super.key, required this.libraryDir});
  final String libraryDir;

  /// For the mockup renders: offer Google Drive on any platform.
  static bool debugDrive = false;

  @override
  State<RestorePickScreen> createState() => _RestorePickScreenState();
}

class _RestorePickScreenState extends State<RestorePickScreen> {
  /// The file first (owner 2026-11-01: the source before the secrets, as for another
  /// device), then the words and the password.
  Future<void> _file() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Readable(child: RestoreKeysScreen(libraryDir: widget.libraryDir, filePath: file.path, fileName: file.name)),
    ));
  }

  void _nothingLeft() {
    final l = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.restoreNoneTitle),
        content: Text(l.restoreNoneBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l.cancel)),
          FilledButton(
            key: const ValueKey('restore-none-new'),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Readable(child: NewVaultScreen(libraryDir: widget.libraryDir, first: !rust.hasVaults(dir: widget.libraryDir))),
              ));
            },
            child: Text(l.welcomeNew),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ChoicePage(
      title: l.welcomeRestore,
      lead: l.restoreChooseLead,
      back: true,
      choices: [
        BigChoice(
          key: const ValueKey('restore-device'),
          icon: Icons.devices_rounded,
          title: l.restoreFromDevice,
          note: l.restoreFromDeviceInviteNote,
          // The old device: Sync → Local network → Set up a new device (ADR 0003, 11).
          onTap: () async {
            final vault = await restoreByCode(context, dir: restoreTarget(widget.libraryDir));
            if (vault != null && context.mounted) await openRestored(context, widget.libraryDir, vault);
          },
        ),
        // Where Drive sync is offered (phones; computers with the desktop client).
        if (RestorePickScreen.debugDrive || driveOffered)
          BigChoice(
            key: const ValueKey('restore-drive'),
            icon: Icons.cloud_download_rounded,
            title: l.restoreFromDrive,
            note: l.restoreFromDriveNote,
            // Signed in first, then the words and the password, on that page.
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Readable(child: DriveJoinScreen(libraryDir: widget.libraryDir)),
            )),
          ),
        BigChoice(
          key: const ValueKey('restore-file'),
          icon: Icons.insert_drive_file_rounded,
          title: l.restoreFromFile,
          note: l.restoreFromFileNote,
          onTap: _file,
        ),
        TextButton(
          key: const ValueKey('restore-none'),
          onPressed: _nothingLeft,
          child: Text(l.restoreNoneLink),
        ),
      ],
    );
  }
}

/// Restore from a backup file, once it is chosen: the two secrets, pasted or typed; then
/// it goes.
class RestoreKeysScreen extends StatefulWidget {
  const RestoreKeysScreen({super.key, required this.libraryDir, required this.filePath, required this.fileName});
  final String libraryDir;
  final String filePath;
  /// Shown, so the person sees which file.
  final String fileName;

  @override
  State<RestoreKeysScreen> createState() => _RestoreKeysScreenState();
}

class _RestoreKeysScreenState extends State<RestoreKeysScreen> {
  final _words = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  /// The words came from the iCloud Keychain or Block Store (Settings on the old phone).
  bool _found = false;

  @override
  void initState() {
    super.initState();
    KeyBackup.find().then((key) {
      if (key == null || !mounted || _words.text.isNotEmpty) return;
      setState(() {
        _words.text = rust.secretKeyText(key: key);
        _found = true;
      });
    });
  }

  @override
  void dispose() {
    _words.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _next() {
    final l = AppLocalizations.of(context);
    if (rust.parseSecretKey(text: _words.text) == null) {
      setState(() => _error = l.secretKeyTypo);
      return;
    }
    _fromFile();
  }

  Future<void> _fromFile() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    final target = restoreTarget(widget.libraryDir);
    try {
      await rust.importBackup(path: widget.filePath, dir: target);
      final key = Uint8List.fromList(rust.parseSecretKey(text: _words.text)!);
      if (!mounted) return;
      if (!rust.secretKeyFits(dir: target, key: key)) {
        // The file is in; these words are not its own. Ask for them again.
        await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => Readable(child: RestoreScreen(libraryDir: widget.libraryDir, needFile: false))),
          (_) => false,
        );
        return;
      }
      await SecretKeyStore.write(key, target);
      rust.setSecretKey(dir: target, key: key);
      final vault = await rust.unlock(dir: widget.libraryDir, password: _password.text);
      if (!mounted) return;
      if (vault == null) {
        // Right words, another password: the unlock screen asks for it.
        await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
          (_) => false,
        );
        return;
      }
      await openRestored(context, widget.libraryDir, vault);
    } on rust.VaultError catch (e) {
      // Restored, but a Top secret vault cannot open after an everyday one in this run.
      if (e == rust.VaultError.restartForMode && mounted) return restartForMode(context);
      if (mounted) showToast(context, vaultErrorText(l, e));
    } catch (e) {
      if (mounted) showToast(context, withCode(l, l.errorBadBackup, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: FormColumn(
        actions: [
          FilledButton(
            key: const ValueKey('restore-next'),
            onPressed: _busy || _words.text.trim().isEmpty || _password.text.isEmpty ? null : _next,
            child: BusyLabel(busy: _busy, idle: l.restoreContinue, working: l.restoring),
          ),
        ],
        children: [
          Text(l.restoreFromFile, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.insert_drive_file_rounded, size: 18, color: c.muted),
            const SizedBox(width: 6),
            Expanded(child: Text(widget.fileName, key: const ValueKey('restore-file-name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),
          Text(l.restoreKeysLead, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.5)),
          const SizedBox(height: 24),
          RecoveryKeyInput(
            key: const ValueKey('restore-words'),
            controller: _words,
            onChanged: () => setState(() => _error = null),
          ),
          if (_found)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(KeyBackup.google ? l.keyBackupFoundGoogle : l.keyBackupFound, key: const ValueKey('restore-words-found'), style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
            ),
          const SizedBox(height: 12),
          SecretField(
            key: const ValueKey('restore-password'),
            controller: _password,
            label: l.backupPasswordLabel,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _next(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
