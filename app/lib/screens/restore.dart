import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../key_backup.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/run.dart' as run_api;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/steps.dart';
import '../widgets/recovery_words.dart' show WordsAction;
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show showCard;
import '../widgets/words_input.dart';
import 'common.dart';
import 'unlock.dart';

/// The vaults are on this device but their 24 words are not (after a reinstall, or a
/// backup file restored with another vault's words): type them. Restoring from a backup
/// file, Drive or another device is `RestorePickScreen` (restore_flow.dart), on a new
/// device and from the lock screen alike: this page used to pick a backup file too, into
/// the device's own library, which the core refuses once a vault is there
/// (`LibraryExists`), so from the lock screen it could only ever fail.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key, required this.libraryDir});

  final String libraryDir;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;
  /// The words came from the iCloud Keychain or Block Store.
  bool _found = false;

  /// The person asks for the set kept in the cloud: only one that fits a vault here.
  Future<void> _fromCloud() async {
    final dirs = run_api.libraryDirs();
    final picked = await pickCloudWords(context, fits: (c) => dirs.any((d) => rust.secretKeyFits(dir: d, key: c.key)));
    if (picked == null || !mounted) return;
    setState(() {
      _key.text = rust.secretKeyText(key: picked.key);
      _found = true;
      _error = null;
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _useKey() async {
    final l = AppLocalizations.of(context);
    final parsed = rust.parseSecretKey(text: _key.text);
    if (parsed == null) {
      setState(() => _error = l.secretKeyTypo);
      return;
    }
    final key = Uint8List.fromList(parsed);
    // The library these words belong to (each set has its own, api/run.rs).
    final dir = run_api.libraryDirs().where((d) => rust.secretKeyFits(dir: d, key: key)).firstOrNull;
    if (dir == null) {
      setState(() => _error = l.errorWrongSecretKey);
      return;
    }
    setState(() => _busy = true);
    try {
      await SecretKeyStore.write(key, dir);
      rust.setSecretKey(dir: dir, key: key);
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
        (_) => false,
      );
    } catch (e) {
      if (mounted) setState(() => _error = withCode(l, l.errorStorage, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The steps' frame (docs/design-language.md, Steps). This page is the app's first
    // one when the words are missing: nothing is under it, so no Back.
    return Scaffold(
      body: StepPage(
        title: l.restoreTitle,
        lead: l.restoreLeadKey,
        onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null,
        actions: [
          StepMainButton(
            label: l.restoreContinue,
            busyLabel: _busy ? l.restoring : null,
            onTap: _busy || _key.text.trim().isEmpty ? null : _useKey,
          ),
        ],
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          RecoveryKeyInput(
            key: const ValueKey('restore-key'),
            controller: _key,
            enabled: !_busy,
            cloud: cloudWordsAction(found: _found, onTap: _busy ? null : _fromCloud),
            onChanged: () => setState(() => _error = null),
          ),
          if (_found) const CloudWordsFound(),
          if (_error != null) StepError(_error!),
        ]),
      ),
    );
  }
}

/// The third button under the 24 words when restoring, where the cloud button is when
/// they are saved: the set kept in the iCloud Keychain / Google Block Store, asked for in
/// plain sight (owner 2026-11-18: kept there but not visibly taken back reads as no
/// restore at all). Lit once a set was taken from there. Null off phones.
Widget? cloudWordsAction({required bool found, required VoidCallback? onTap}) => !KeyBackup.supported
    ? null
    : WordsAction(
        key: const ValueKey('restore-cloud'),
        icon: found ? Icons.cloud_done_rounded : Icons.cloud_download_rounded,
        label: KeyBackup.google ? 'Google' : 'iCloud',
        on: found,
        onTap: onTap,
      );

/// Under the words once a set came from the cloud: where from.
class CloudWordsFound extends StatelessWidget {
  const CloudWordsFound({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(KeyBackup.google ? l.keyBackupFoundGoogle : l.keyBackupFound,
          key: const ValueKey('restore-words-found'), style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
    );
  }
}

/// The sets of 24 words kept in the iCloud Keychain / Google Block Store (ADR 0008: one
/// per set), asked for by the person, never filled in on their own (owner 2026-11-18:
/// there can be several, the person picks). One: that one. Several: a card lists each
/// with the vaults it opens. None: said, and the words are typed. [fits] keeps only the
/// sets that open something here.
Future<KeyCopy?> pickCloudWords(BuildContext context, {bool Function(KeyCopy)? fits}) async {
  final l = AppLocalizations.of(context);
  var all = await KeyBackup.findAll();
  if (fits != null) all = all.where(fits).toList();
  if (!context.mounted) return null;
  if (all.isEmpty) {
    showToast(context, KeyBackup.google ? l.keyBackupNoneGoogle : l.keyBackupNone, icon: Icons.cloud_off_rounded);
    return null;
  }
  if (all.length == 1) return all.single;
  return showCard<KeyCopy>(
    context,
    title: l.keyBackupPickTitle,
    closeButton: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (i, copy) in all.indexed)
          ListTile(
            key: ValueKey('cloud-set-$i'),
            leading: const Icon(Icons.key_rounded),
            title: Text(l.keyBackupSet(rust.secretKeyFingerprint(key: copy.key).toUpperCase())),
            subtitle: Text(copy.vaults.isEmpty ? l.keyBackupSetNoVault : l.keyBackupSetVaults(copy.vaults.join(', '))),
            onTap: () => Navigator.pop(context, copy),
          ),
      ]),
    ),
  );
}
