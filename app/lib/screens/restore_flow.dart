import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../secret_key_store.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../sync/consent.dart';
import '../sync/drive_join.dart';
import '../sync/find_page.dart';
import '../sync/progress.dart';
import '../sync/wifi.dart';
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show pushPage;
import 'common.dart';
import 'new_vault.dart';
import 'restore.dart';
import 'set_pin.dart';
import 'unlock.dart';
import 'tour.dart' show TourKind;
import 'vault_home.dart';
import 'welcome.dart';

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
      builder: (_) => RestoreSourceScreen(libraryDir: widget.libraryDir, words: _words.text, password: _password.text),
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
          Text(l.restoreKeysLead, style: TextStyle(color: c.muted, fontSize: 15, height: 1.5)),
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

  /// The vault is open here: keep the words on this device, give it a PIN, go in.
  Future<void> _opened(rust.VaultInfo vault) async {
    final key = rust.parseSecretKey(text: widget.words);
    if (key != null) await SecretKeyStore.write(Uint8List.fromList(key));
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SetPinScreen(skippable: true, forThisPhone: true)),
    );
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
          builder: (_) => VaultHomeScreen(libraryDir: widget.libraryDir, vault: vault, tour: TourKind.restored)),
      (_) => false,
    );
  }

  /// The old device shows six digits: ask once to look on this Wi-Fi, then find it with
  /// the 24 words (no vault here yet).
  Future<void> _fromDevice() async {
    final address = await localAddress();
    if (!mounted) return;
    if (address == null) {
      showToast(context, l10n.syncNoWifi, icon: Icons.wifi_off_rounded);
      return;
    }
    if (!await allowConnection(context, l10n.syncAllowFind(address)) || !mounted) return;
    await pushPage<void>(
      context,
      title: l10n.restoreFromDevice,
      builder: (_) => FindDevicePage(
        address: address,
        words: widget.words,
        lead: l10n.restoreScanLead,
        onFound: (context, code) => _restoreWithCode(context, code, ask: false),
        onScanned: _restoreWithCode,
      ),
    );
  }

  AppLocalizations get l10n => AppLocalizations.of(context);

  Future<void> _restoreWithCode(BuildContext context, String code, {bool ask = true}) async {
    final l = AppLocalizations.of(context);
    final address = sync.p2PCodeAddress(code: code);
    if (address == null) return;
    if (ask && !await allowConnection(context, l.syncAllowJoin(address))) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(l.restoreTitle), automaticallyImplyLeading: false),
        body: SafeArea(
          top: false,
          child: SyncProgress(
            restoring: true,
            events: sync.p2PRestore(dir: widget.libraryDir, code: code, words: widget.words, password: widget.password),
            onSynced: () {},
          ),
        ),
      ),
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
        await Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => RestoreScreen(libraryDir: widget.libraryDir, needFile: false)),
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
        await Navigator.of(context).pushAndRemoveUntil(
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
                builder: (_) => NewVaultScreen(libraryDir: widget.libraryDir, first: true),
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
        // Phones only, like Drive sync (no desktop sign-in client yet).
        if (RestoreSourceScreen.debugDrive || Device.iOS || Device.android)
          BigChoice(
            key: const ValueKey('restore-drive'),
            icon: Icons.cloud_download_outlined,
            title: l.restoreFromDrive,
            note: l.restoreFromDriveNote,
            onTap: _busy
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => DriveJoinScreen(libraryDir: widget.libraryDir, words: widget.words, password: widget.password),
                    )),
          ),
        BigChoice(
          key: const ValueKey('restore-file'),
          icon: Icons.insert_drive_file_outlined,
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
