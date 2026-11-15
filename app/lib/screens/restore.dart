import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../key_backup.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/run.dart' as run_api;
import '../src/rust/api/vault.dart' as rust;
import '../widgets/steps.dart';
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

  @override
  void initState() {
    super.initState();
    // The vaults are here without their words: a set kept in the iCloud Keychain / Google
    // Block Store that fits one of the libraries fills the field (ADR 0008).
    KeyBackup.findAll().then((all) {
      final dirs = run_api.libraryDirs();
      final fits = all.where((c) => dirs.any((d) => rust.secretKeyFits(dir: d, key: c.key))).firstOrNull;
      if (fits == null || !mounted || _key.text.isNotEmpty) return;
      setState(() => _key.text = rust.secretKeyText(key: fits.key));
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
            onChanged: () => setState(() => _error = null),
          ),
          if (_error != null) StepError(_error!),
        ]),
      ),
    );
  }
}
