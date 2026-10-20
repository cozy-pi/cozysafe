import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/secret.dart';
import 'common.dart';
import 'unlock.dart';

/// Bring vaults back onto this device: pick a backup file (skipped when the library is
/// already here but its Secret Key is not, e.g. after a reinstall), then type the
/// Secret Key from the Emergency Kit.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key, required this.libraryDir, required this.needFile});

  final String libraryDir;
  final bool needFile;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _key = TextEditingController();
  late bool _needFile = widget.needFile;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _pickBackup() async {
    final l = AppLocalizations.of(context);
    final file = await openFile();
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await rust.importBackup(path: file.path, dir: widget.libraryDir);
      if (mounted) setState(() => _needFile = false);
    } on rust.VaultError catch (e) {
      if (mounted) setState(() => _error = vaultErrorText(l, e));
    } catch (_) {
      if (mounted) setState(() => _error = l.errorBadBackup);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useKey() async {
    final l = AppLocalizations.of(context);
    final parsed = rust.parseSecretKey(text: _key.text);
    if (parsed == null) {
      setState(() => _error = l.secretKeyTypo);
      return;
    }
    final key = Uint8List.fromList(parsed);
    if (!rust.secretKeyFits(dir: widget.libraryDir, key: key)) {
      setState(() => _error = l.errorWrongSecretKey);
      return;
    }
    setState(() => _busy = true);
    try {
      await SecretKeyStore.write(key);
      rust.setSecretKey(key: key);
      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
        (_) => false,
      );
    } catch (_) {
      if (mounted) setState(() => _error = l.errorStorage);
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
      appBar: widget.needFile ? AppBar() : null,
      body: FormColumn(
        children: [
          if (!widget.needFile) ...[const BrandHeader(), const SizedBox(height: 28)],
          Text(l.restoreTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            _needFile ? l.restoreLeadFile : l.restoreLeadKey,
            style: TextStyle(color: c.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          if (_needFile)
            FilledButton.icon(
              onPressed: _busy ? null : _pickBackup,
              icon: const Icon(Icons.file_open_outlined),
              label: BusyLabel(busy: _busy, idle: l.restorePick, working: l.restoring),
            )
          else ...[
            SecretField(
              controller: _key,
              enabled: !_busy,
              capitalization: TextCapitalization.characters,
              label: l.secretKeyLabel,
              hint: 'CS1-XXXX-XXXX-…',
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _useKey(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _key.text.trim().isEmpty ? null : _useKey,
              child: BusyLabel(busy: _busy, idle: l.restoreContinue, working: l.restoring),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
