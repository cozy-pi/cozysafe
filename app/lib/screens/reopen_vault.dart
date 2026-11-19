import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../key_backup.dart';
import '../l10n/app_localizations.dart';
import '../secret_key_store.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/toast.dart';
import 'settings.dart' show SettingsGroup, SettingsHue, SettingsRow;

/// What opens this vault again on a new phone, all in one place (owner 2026-11-18: the
/// cloud copy said nothing of what it kept nor how to find it later, and the vault's code
/// showed only at the end of Settings). Its 24-word set and whether the cloud holds it,
/// where the password manager keeps its password, its code, and the steps on a new phone.
/// Read only; the switches stay in Settings.
class ReopenVaultScreen extends StatefulWidget {
  const ReopenVaultScreen({
    super.key,
    required this.vault,
    required this.mainLibrary,
    required this.cloudOn,
    required this.onShowWords,
    required this.onPassword,
  });

  final rust.VaultInfo vault;
  /// The device's own library: a vault in it shares the device's set of words.
  final String mainLibrary;
  final bool cloudOn;
  final VoidCallback? onShowWords;
  final VoidCallback onPassword;

  /// Mockups: the set's fingerprint and how many vaults use it, without a real library.
  static ({String set, int vaults, DateTime? savedAt})? debugFacts;

  @override
  State<ReopenVaultScreen> createState() => _ReopenVaultScreenState();
}

class _ReopenVaultScreenState extends State<ReopenVaultScreen> {
  String? _set;
  int? _vaults;
  DateTime? _savedAt;

  @override
  void initState() {
    super.initState();
    if (ReopenVaultScreen.debugFacts case final f?) {
      _set = f.set;
      _vaults = f.vaults;
      _savedAt = f.savedAt;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final key = await SecretKeyStore.readOpen();
    final library = widget.vault.libraryDir.isEmpty ? widget.mainLibrary : widget.vault.libraryDir;
    int? count;
    try {
      count = (await rust.listVaults(dir: widget.mainLibrary)).where((s) => s.libraryDir == library).length;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (key != null) {
        _set = rust.secretKeyFingerprint(key: key).toUpperCase();
        _savedAt = KeyBackup.savedAt(key);
      }
      _vaults = count;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ml = MaterialLocalizations.of(context);
    final v = widget.vault;
    final google = KeyBackup.google;
    final where = google ? 'Google' : 'iCloud Keychain';
    final cloud = KeyBackup.supported && !v.topSecret;
    // The phones' password managers; the same test as the cloud copy (mockups set it).
    final passwordManager = KeyBackup.supported;

    Widget note(String text, {Key? key}) => Padding(
          key: key,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(text, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.4)),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(Ui.groupSide, 8, Ui.groupSide, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(l.reopenLead, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
        ),
        // 1. The 24 words: which set, shared or not, and the cloud copy.
        SettingsGroup(rows: [
          SettingsRow(
            key: const ValueKey('reopen-set'),
            icon: Icons.key_rounded,
            color: SettingsHue.yellow,
            title: l.vaultInfoWords,
            value: _set ?? '…',
            chevron: false,
          ),
          if (cloud)
            SettingsRow(
              key: const ValueKey('reopen-cloud'),
              icon: Icons.cloud_rounded,
              color: SettingsHue.sky,
              title: l.reopenCloudRow(where),
              value: !widget.cloudOn
                  ? l.reopenCloudOff
                  : _savedAt == null
                      ? l.reopenCloudOn
                      : l.reopenCloudSince(ml.formatCompactDate(_savedAt!)),
              chevron: false,
            ),
          if (widget.onShowWords case final show?)
            SettingsRow(
              key: const ValueKey('reopen-show-words'),
              icon: Icons.medical_services_rounded,
              color: SettingsHue.red,
              title: l.showKit,
              onTap: show,
            ),
        ]),
        if (_vaults case final n?) note(l.reopenWordsShared(n)),
        if (cloud && widget.cloudOn) note(google ? l.reopenCloudNoteGoogle : l.reopenCloudNote, key: const ValueKey('reopen-cloud-note')),
        // 2. The password, and where the system keeps it.
        SettingsGroup(rows: [
          SettingsRow(
            icon: Icons.password_rounded,
            color: SettingsHue.orange,
            title: l.backupPasswordLabel,
            value: v.hasPassword ? l.isSet : l.notSet,
            onTap: widget.onPassword,
          ),
        ]),
        if (passwordManager && v.hasPassword && !v.topSecret && v.code.isNotEmpty)
          note(google ? l.reopenPasswordNoteGoogle(v.code) : l.reopenPasswordNote(v.code)),
        // 3. The code: the vault's name outside the app.
        if (v.code.isNotEmpty) ...[
          SettingsGroup(rows: [
            SettingsRow(
              key: const ValueKey('vault-code-row'),
              icon: Icons.tag_rounded,
              color: SettingsHue.indigo,
              title: l.vaultCode,
              value: v.code,
              onTap: () {
                Clipboard.setData(ClipboardData(text: v.code));
                showToast(context, l.vaultCodeCopied, icon: Icons.copy_rounded);
              },
            ),
          ]),
          note(l.reopenCodeNote),
        ],
        // 4. The steps on a new phone: the words and the password open, the contents come
        // from a copy (Drive, a backup file, another device).
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
          child: Text(l.reopenStepsTitle, style: const TextStyle(fontSize: CsType.headline, fontWeight: FontWeight.w600)),
        ),
        for (final (i, step) in [
          l.reopenStep1,
          cloud && widget.cloudOn ? l.reopenStep2Cloud(where) : l.reopenStep2,
          l.reopenStep3,
        ].indexed)
          Padding(
            key: ValueKey('reopen-step-$i'),
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 24, child: Text('${i + 1}.', style: const TextStyle(fontSize: CsType.body))),
              Expanded(child: Text(step, style: const TextStyle(fontSize: CsType.body, height: 1.35))),
            ]),
          ),
      ],
    );
  }
}
