import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../test_login.dart';
import '../theme.dart';
import '../widgets/countdown.dart';
import '../widgets/identity.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart' show showCard;
import '../widgets/bottom_bar.dart' show PinnedAction;
import 'delete_vault.dart';
import 'unlock.dart';
import 'welcome.dart';
import '../platform.dart' show nowMs;
import 'file_view.dart' show fileSize;
import 'top_secret_page.dart' show TopSecretMark;

/// Settings → Vaults on this device (owner 2026-10-31): every vault here; making a new
/// one and deleting one live here and nowhere else.
/// Names, icons and modes stay sealed until a vault is opened, so the others show as
/// locked tiles with their size. Deleting takes that vault's password; a vault whose
/// password is forgotten can be set to go in seven days, after the phone's owner
/// confirms, and opening it with its password in the meantime keeps it. Only on this
/// device; Google Drive is a choice on the delete page.
class VaultManagerScreen extends StatefulWidget {
  const VaultManagerScreen({super.key, required this.libraryDir, this.onDeleteOpen, this.onNewVault});
  final String libraryDir;
  /// Delete the open vault (Settings' own flow, which locks and leaves it).
  final Future<void> Function()? onDeleteOpen;
  /// Make another vault (the vault page's flow: the owner first, this vault locks).
  final Future<void> Function()? onNewVault;

  /// For the mockup renders: these vaults instead of the library's.
  static List<rust.VaultSlot>? debugSlots;

  /// How long a vault whose password is forgotten waits before it goes.
  static const forgotWait = Duration(days: 7);

  @override
  State<VaultManagerScreen> createState() => _VaultManagerScreenState();
}

class _VaultManagerScreenState extends State<VaultManagerScreen> {
  List<rust.VaultSlot>? _slots;
  rust.VaultInfo? _open;
  /// The test vault of Android test builds, when one is here (lib/test_login.dart).
  String? _testId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final debug = VaultManagerScreen.debugSlots;
    if (debug == null) {
      try {
        await rust.purgeDueVaults(dir: widget.libraryDir, nowMs: nowMs());
      } catch (_) {}
    }
    final slots = debug ?? await rust.listVaults(dir: widget.libraryDir);
    final testId = await TestLogin.vaultId();
    if (mounted) {
      setState(() {
        _slots = slots;
        _open = rust.openVaultInfo();
        _testId = testId;
      });
    }
  }

  /// A tap on a vault shows what is known of it, with Delete under it (owner 2026-11-01).
  Future<void> _details(rust.VaultSlot s) async {
    final l = AppLocalizations.of(context);
    final open = _open;
    final test = s.id == _testId;
    final delete = await showCard<bool>(context, title: _title(l, s), closeButton: true, builder: (context) {
      final c = CsColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: s.isOpen && open != null
                ? VaultBadge(icon: open.icon, color: open.color, size: 56)
                : Icon(Icons.lock_rounded, color: c.muted, size: 44),
          ),
          const SizedBox(height: 14),
          Text(
            [
              fileSize(s.sizeBytes),
              if (s.hasBiometric) l.vaultManagerBiometric,
              '${s.id.substring(0, 6)}…',
            ].join(' · '),
            key: const ValueKey('vault-details'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: CsType.subhead),
          ),
          if (test) ...[
            const SizedBox(height: 6),
            Text(l.testLoginNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
          ],
          if (s.deleteAtMs case final at?) ...[
            const SizedBox(height: 6),
            Text(_left(l, at.toInt()),
                textAlign: TextAlign.center, style: TextStyle(color: recordRed(context), fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('vault-details-delete'),
            style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.deleteVaultAction),
          ),
        ]),
      );
    });
    if (delete != true || !mounted) return;
    if (test) return _deleteTest(s);
    await _menu(s);
  }

  /// The test vault goes without its password (owner 2026-11-01), after the countdown.
  Future<void> _deleteTest(rust.VaultSlot s) async {
    final l = AppLocalizations.of(context);
    if (!await confirmCountdown(context, title: l.deleteVaultTitle) || !mounted) return;
    final gone = await TestLogin.delete(widget.libraryDir, s.id);
    if (!mounted) return;
    if (gone && s.isOpen) {
      // The open one went: to the lock screen, or the first screen when none is left.
      final any = rust.hasVaults(dir: widget.libraryDir);
      await Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => any ? UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false) : WelcomeScreen(libraryDir: widget.libraryDir),
        ),
        (_) => false,
      );
      return;
    }
    if (gone) showToast(context, l.vaultDeleted, icon: Icons.check_rounded);
    await _load();
  }

  String _title(AppLocalizations l, rust.VaultSlot s) =>
      s.id == _testId ? l.testVault : (s.isOpen ? l.vaultThis : l.vaultLocked);

  /// Delete: the open vault by Settings' own flow; another on its delete screen (its
  /// password, or "Forgot the password").
  Future<void> _menu(rust.VaultSlot slot) async {
    if (slot.isOpen) {
      await widget.onDeleteOpen?.call();
      if (mounted) await _load();
      return;
    }
    final gone = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DeleteVaultScreen(
        libraryDir: widget.libraryDir,
        otherId: slot.id,
        deleteAtMs: slot.deleteAtMs?.toInt(),
        sizeText: fileSize(slot.sizeBytes),
      ),
    ));
    if (gone == true && mounted) showToast(context, AppLocalizations.of(context).vaultDeleted, icon: Icons.check_rounded);
    await _load();
  }

  String _left(AppLocalizations l, int atMs) {
    final ms = atMs - DateTime.now().millisecondsSinceEpoch;
    final days = ms <= 0 ? 0 : (ms / Duration.millisecondsPerDay).ceil();
    return l.vaultDeletesIn(days);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final slots = _slots;
    final open = _open;
    return Scaffold(
      appBar: AppBar(title: Text(l.vaultManagerTitle)),
      body: slots == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: PinnedAction(
              actions: [
                if (widget.onNewVault != null)
                  FilledButton.icon(
                    key: const ValueKey('vaults-new'),
                    onPressed: widget.onNewVault,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(l.newVault),
                  ),
              ],
              child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                  child: Text(l.vaultsLead, style: TextStyle(color: c.muted, fontSize: CsType.subhead, height: 1.4)),
                ),
                // The open vault first, then the others.
                for (final s in [...slots.where((s) => s.isOpen), ...slots.where((s) => !s.isOpen)])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      key: ValueKey('vault-slot-${s.id}'),
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(Ui.radius),
                      clipBehavior: Clip.antiAlias,
                      child: Builder(
                        builder: (tile) => InkWell(
                          onTap: () => _details(s),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                            child: Row(children: [
                              if (s.isOpen && open != null)
                                VaultBadge(icon: open.icon, color: open.color, size: 40)
                              else
                                SizedBox(width: 40, height: 40, child: Icon(Icons.lock_rounded, color: c.muted, size: 26)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Flexible(
                                      child: Text(
                                        _title(l, s),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    if (s.isOpen && (open?.topSecret ?? false)) ...[
                                      const SizedBox(width: 6),
                                      const TopSecretMark(size: 18),
                                    ],
                                  ]),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      fileSize(s.sizeBytes),
                                      if (s.hasBiometric) l.vaultManagerBiometric,
                                      if (!s.isOpen) '${s.id.substring(0, 6)}…',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: c.muted, fontSize: CsType.footnote),
                                  ),
                                  if (s.deleteAtMs case final at?) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      _left(l, at.toInt()),
                                      key: ValueKey('vault-deletes-${s.id}'),
                                      style: TextStyle(color: recordRed(context), fontSize: CsType.footnote, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ]),
                              ),
                              Icon(Icons.more_horiz_rounded, color: c.muted),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            ),
            ),
    );
  }
}
