import 'package:flutter/material.dart';

import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'file_view.dart' show fileSize;
import '../widgets/countdown.dart';
import '../widgets/toast.dart';

/// Debug → Vaults on this device (owner 2026-10-25). Everyday use never lists vaults, so
/// a second one stays unseen; with Debug on, the owner sees them all and can delete one
/// whose password and PIN are forgotten, without opening it. Names stay sealed until a
/// vault is opened, so the others show as locked tiles with the start of their id.
class VaultManagerScreen extends StatefulWidget {
  const VaultManagerScreen({super.key, required this.libraryDir});
  final String libraryDir;

  /// For the mockup renders: these vaults instead of the library's.
  static List<rust.VaultSlot>? debugSlots;

  @override
  State<VaultManagerScreen> createState() => _VaultManagerScreenState();
}

class _VaultManagerScreenState extends State<VaultManagerScreen> {
  List<rust.VaultSlot>? _slots;
  rust.VaultInfo? _open;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final debug = VaultManagerScreen.debugSlots;
    final slots = debug ?? await rust.listVaults(dir: widget.libraryDir);
    if (mounted) {
      setState(() {
        _slots = slots;
        _open = rust.openVaultInfo();
      });
    }
  }

  Future<void> _delete(rust.VaultSlot slot) async {
    final l = AppLocalizations.of(context);
    // The phone's owner first: knowing the open vault's PIN is not enough to erase another.
    if (!await confirmOwner(l.vaultManagerDeleteTitle) || !mounted) return;
    final typed = TextEditingController();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(l.vaultManagerDeleteTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.vaultManagerDeleteBody(l.vaultManagerDeleteWord)),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('vault-delete-word'),
              controller: typed,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => set(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l.cancel)),
            FilledButton(
              key: const ValueKey('vault-delete-confirm'),
              style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
              onPressed: typed.text.trim().toUpperCase() == l.vaultManagerDeleteWord.toUpperCase()
                  ? () => Navigator.of(ctx).pop(true)
                  : null,
              child: Text(l.deleteVaultAction),
            ),
          ],
        ),
      ),
    );
    typed.dispose();
    if (yes != true || !mounted) return;
    if (!await confirmCountdown(context, title: l.vaultManagerDeleteTitle) || !mounted) return;
    try {
      final done = await rust.deleteVaultUnopened(dir: widget.libraryDir, vaultId: slot.id);
      if (!mounted) return;
      showToast(context, done ? l.vaultManagerDeleted : l.changeKeyFailed);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, '${l.changeKeyFailed} (${e.name})');
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final slots = _slots;
    return Scaffold(
      appBar: AppBar(title: Text(l.vaultManagerTitle)),
      body: slots == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                  child: Text(l.vaultManagerLead, style: TextStyle(color: c.muted, fontSize: 14.5, height: 1.4)),
                ),
                for (final s in slots)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      key: ValueKey('vault-slot-${s.id}'),
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(Ui.radius),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                        child: Row(children: [
                          Icon(s.isOpen ? Icons.lock_open_rounded : Icons.lock_rounded, color: s.isOpen ? null : c.muted),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(
                                s.isOpen && (_open?.name.isNotEmpty ?? false) ? _open!.name : '${s.id.substring(0, 8)}…',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [
                                  fileSize(s.sizeBytes),
                                  if (s.isOpen) l.vaultManagerOpen,
                                  if (s.hasPassword) l.vaultManagerPassword,
                                  if (s.hasPin) l.vaultManagerPin,
                                  if (s.hasBiometric) l.vaultManagerBiometric,
                                ].join(' · '),
                                style: TextStyle(color: c.muted, fontSize: 13.5),
                              ),
                            ]),
                          ),
                          if (!s.isOpen)
                            IconButton(
                              key: ValueKey('vault-delete-${s.id}'),
                              tooltip: l.vaultManagerDelete,
                              icon: const Icon(Icons.delete_outline_rounded, color: dangerRed),
                              onPressed: () => _delete(s),
                            ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
