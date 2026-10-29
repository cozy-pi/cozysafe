import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../key_backup.dart';
import '../secret_key_store.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../sync/consent.dart';
import '../sync/drive_join.dart';
import '../sync/device_name.dart';
import '../sync/drive.dart' show driveOffered;
import '../sync/join_page.dart';
import '../sync/nearby_page.dart';
import '../sync/progress.dart';
import '../sync/wifi.dart';
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/toast.dart';
import 'common.dart';
import 'new_vault.dart';
import 'restore.dart';
import 'unlock.dart';
import 'tour.dart' show TourKind;
import 'vault_home.dart';
import 'welcome.dart';
import '../widgets/readable.dart';

/// Restore, step 1 (owner 2026-10-24): the two secrets first, pasted or typed, the
/// same for every way the vault can come back.
class RestoreKeysScreen extends StatefulWidget {
  const RestoreKeysScreen({super.key, required this.libraryDir});
  final String libraryDir;

  @override
  State<RestoreKeysScreen> createState() => _RestoreKeysScreenState();
}

class _RestoreKeysScreenState extends State<RestoreKeysScreen> {
  final _words = TextEditingController();
  final _password = TextEditingController();
  String? _error;
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Readable(child: RestoreSourceScreen(libraryDir: widget.libraryDir, words: _words.text, password: _password.text)),
    ));
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
            onPressed: _words.text.trim().isEmpty || _password.text.isEmpty ? null : _next,
            child: Text(l.restoreContinue),
          ),
        ],
        children: [
          Text(l.restoreTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(l.restoreKeysLead, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.5)),
          const SizedBox(height: 24),
          SecretField(
            key: const ValueKey('restore-words'),
            controller: _words,
            multiline: true,
            paste: true,
            label: l.secretKeyLabel,
            hint: l.recoveryWordsHint,
            onChanged: (_) => setState(() => _error = null),
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

/// Restore, step 2: where the vault is. Another device first, the way that needs no
/// cloud and no file.
class RestoreSourceScreen extends StatefulWidget {
  const RestoreSourceScreen({super.key, required this.libraryDir, required this.words, required this.password});
  final String libraryDir;
  final String words;
  final String password;

  /// For the mockup renders: offer Google Drive on any platform.
  static bool debugDrive = false;

  @override
  State<RestoreSourceScreen> createState() => _RestoreSourceScreenState();
}

class _RestoreSourceScreenState extends State<RestoreSourceScreen> {
  bool _busy = false;

  /// The vault is open here: keep the words on this device, offer Face ID, go in.
  Future<void> _opened(rust.VaultInfo vault) async {
    final key = rust.parseSecretKey(text: widget.words);
    if (key != null) await SecretKeyStore.write(Uint8List.fromList(key));
    if (!mounted) return;
    await offerBiometric(context);
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute<void>(
          builder: (_) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault, tour: TourKind.restored)),
      (_) => false,
    );
  }

  /// The old device waits on its Sync screen with "Help a new device restore" on: ask
  /// once to look on this Wi-Fi, then find it with the 24 words (no vault here yet); its
  /// person allows this device, comparing a number. The QR stays for networks that block
  /// looking.
  Future<void> _fromDevice() async {
    final address = await localAddress();
    if (!mounted) return;
    if (address == null) {
      showToast(context, l10n.syncNoWifi, icon: Icons.wifi_off_rounded);
      return;
    }
    if (!await allowConnection(context, l10n.syncAllowFindRestore) || !mounted) return;
    final name = await deviceName();
    if (!mounted) return;
    final l = l10n;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Readable(child: Scaffold(
        appBar: AppBar(title: Text(l.restoreFromDevice)),
        body: SafeArea(
          top: false,
          child: SyncProgress(
            restoring: true,
            events: sync.p2PRestoreNearby(dir: widget.libraryDir, ip: address, words: widget.words, password: widget.password, name: name),
            onSynced: () {},
            waiting: NearbyLooking(
              lead: l.restoreNearbyLead,
              restoring: true,
              // Looking ends with this page; the scanner takes its place.
              onScan: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
                builder: (_) => Readable(child: Scaffold(
                  appBar: AppBar(title: Text(l.syncScanCode)),
                  body: SafeArea(top: false, child: ScanCodePage(onSynced: () {}, onCode: _restoreWithCode)),
                )),
              )),
            ),
          ),
 )       ),
      ),
    ));
    final vault = rust.openVaultInfo();
    if (vault != null && mounted) await _opened(vault);
  }

  AppLocalizations get l10n => AppLocalizations.of(context);

  Future<void> _restoreWithCode(BuildContext context, String code) async {
    final l = AppLocalizations.of(context);
    final address = sync.p2PCodeAddress(code: code);
    if (address == null) return;
    if (!await allowConnection(context, l.syncAllowJoin)) return;
    final name = await deviceName();
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Readable(child: Scaffold(
        appBar: AppBar(title: Text(l.restoreTitle), automaticallyImplyLeading: false),
        body: SafeArea(
          top: false,
          child: SyncProgress(
            restoring: true,
            events: sync.p2PRestore(dir: widget.libraryDir, code: code, words: widget.words, password: widget.password, name: name),
            onSynced: () {},
          ),
        ),
      )),
    ));
    final vault = rust.openVaultInfo();
    if (vault != null && mounted) await _opened(vault);
  }

  Future<void> _fromFile() async {
    final l = AppLocalizations.of(context);
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await rust.importBackup(path: file.path, dir: widget.libraryDir);
      final key = Uint8List.fromList(rust.parseSecretKey(text: widget.words)!);
      if (!mounted) return;
      if (!rust.secretKeyFits(dir: widget.libraryDir, key: key)) {
        // The file is in; these words are not its own. Ask for them again.
        await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => Readable(child: RestoreScreen(libraryDir: widget.libraryDir, needFile: false))),
          (_) => false,
        );
        return;
      }
      await SecretKeyStore.write(key);
      rust.setSecretKey(key: key);
      final vault = await rust.unlock(dir: widget.libraryDir, password: widget.password);
      if (!mounted) return;
      if (vault == null) {
        // Right words, another password: the unlock screen asks for it.
        await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
          (_) => false,
        );
        return;
      }
      await _opened(vault);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e));
    } catch (_) {
      if (mounted) showToast(context, l.errorBadBackup);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
                builder: (_) => Readable(child: NewVaultScreen(libraryDir: widget.libraryDir, first: true)),
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
          icon: Icons.phonelink_rounded,
          title: l.restoreFromDevice,
          note: l.restoreFromDeviceNote,
          strong: true,
          onTap: _busy ? null : _fromDevice,
        ),
        // Where Drive sync is offered (phones; computers with the desktop client).
        if (RestoreSourceScreen.debugDrive || driveOffered)
          BigChoice(
            key: const ValueKey('restore-drive'),
            icon: Icons.cloud_download_rounded,
            title: l.restoreFromDrive,
            note: l.restoreFromDriveNote,
            onTap: _busy
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Readable(child: DriveJoinScreen(libraryDir: widget.libraryDir, words: widget.words, password: widget.password)),
                    )),
          ),
        BigChoice(
          key: const ValueKey('restore-file'),
          icon: Icons.insert_drive_file_rounded,
          title: l.restoreFromFile,
          note: l.restoreFromFileNote,
          onTap: _busy ? null : _fromFile,
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
