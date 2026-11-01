import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../biometric.dart';
import '../src/rust/api/vault.dart' as rust;
import '../sync/drive.dart' show driveAccount;
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

  /// For the mockup renders: these vaults instead of the library's, the open vault's item
  /// count and its Google Drive account.
  static List<rust.VaultSlot>? debugSlots;
  static int? debugItems;
  static rust.VaultInfo? debugOpen;
  static String? debugDrive;

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
        _open = VaultManagerScreen.debugOpen ?? rust.openVaultInfo();
        _testId = testId;
      });
    }
  }

  /// A tap on a vault shows everything known of it, then Delete or Close (owner
  /// 2026-11-01). A locked vault's name, mode and items stay sealed: only what the device
  /// knows without opening it shows.
  Future<void> _details(rust.VaultSlot s) async {
    final l = AppLocalizations.of(context);
    final open = s.isOpen ? _open : null;
    final test = s.id == _testId;
    final kind = s.hasBiometric ? await BiometricUnlock.available() : null;
    int? items;
    if (open != null && VaultManagerScreen.debugItems == null) {
      try {
        items = (await rust.listItems()).length;
      } catch (_) {}
    }
    items ??= open != null ? VaultManagerScreen.debugItems : null;
    if (!mounted) return;
    final ml = MaterialLocalizations.of(context);
    final unlock = [
      if (s.hasPassword) l.password,
      if (s.hasBiometric) kind == BiometricKind.face ? l.vaultInfoFace : l.vaultInfoFingerprint,
      if (s.hasPin) l.vaultInfoPin,
    ];
    final drive = VaultManagerScreen.debugDrive ?? driveAccount;
    String when(int ms) {
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      return '${ml.formatMediumDate(t)} ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
    }
    final rows = <(String, String)>[
      (l.vaultInfoName, open?.name ?? l.vaultInfoSealed),
      if (open != null) (l.vaultInfoMode, open.topSecret ? l.topSecretShort : l.modeEveryday),
      if (items != null) (l.vaultInfoItems, '$items'),
      (l.vaultInfoSize, fileSize(s.sizeBytes)),
      (l.vaultInfoCreated, switch (s.createdMs) {
        final ms? => ml.formatMediumDate(DateTime.fromMillisecondsSinceEpoch(ms.toInt())),
        null => l.vaultInfoUnknown,
      }),
      (l.vaultInfoUnlock, unlock.join(' · ')),
      (l.vaultInfoWords, s.libraryDir == widget.libraryDir ? l.vaultInfoWordsShared : l.vaultInfoWordsOwn),
      if (open != null) (l.vaultInfoDrive, drive ?? l.vaultInfoDriveOff),
      // Set to go with its password forgotten: when that was asked, and when it goes
      // (owner 2026-11-01). The wait is always [VaultManagerScreen.forgotWait].
      if (s.deleteAtMs case final at?) ...[
        (l.vaultInfoDeleteAsked, when(at.toInt() - VaultManagerScreen.forgotWait.inMilliseconds)),
        (l.vaultInfoDeletes, '${when(at.toInt())}\n${_left(l, at.toInt())}'),
      ],
      (l.vaultInfoId, '${s.id.substring(0, 6)}…'),
    ];
    final delete = await showCard<bool>(context, title: _title(l, s), builder: (context) {
      final c = CsColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: open != null
                ? VaultBadge(icon: open.icon, color: open.color, size: 56)
                : Icon(Icons.lock_rounded, color: c.muted, size: 44),
          ),
          const SizedBox(height: 14),
          if (test) ...[
            Text(l.testLoginNote, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
            const SizedBox(height: 10),
          ],
          Container(
            key: const ValueKey('vault-details'),
            decoration: BoxDecoration(color: c.muted.withValues(alpha: .08), borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: TextStyle(color: c.muted, fontSize: CsType.subhead)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: CsType.subhead,
                          fontWeight: FontWeight.w600,
                          color: label == l.vaultInfoDeletes || label == l.vaultInfoDeleteAsked ? recordRed(context) : null,
                        ),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('vault-details-delete'),
            style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.deleteVaultAction),
          ),
          const SizedBox(height: 6),
          TextButton(
            key: const ValueKey('vault-details-close'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.close),
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
