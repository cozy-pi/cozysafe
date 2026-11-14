import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/countdown.dart';
import '../l10n/app_localizations.dart';
import '../lock_guard.dart';
import '../lock_resume.dart';
import '../secret_key_store.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;

import '../biometric.dart' show confirmOwnerForSetting;
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../sync/drive.dart' show driveAccount, driveErrorCode, driveSignInQuietly;
import '../theme.dart';
import '../widgets/secret.dart';
import '../widgets/identity.dart';
import 'common.dart';
import 'unlock.dart';
import '../widgets/bottom_bar.dart';
import '../widgets/toast.dart';
import '../widgets/working_card.dart';
import 'vault_manager.dart' show VaultFacts, VaultManagerScreen;
import 'welcome.dart';

/// Delete a vault from this device, confirmed with its own password (no PIN since
/// 2026-10-28): the open one ([vault]), or another one from Vaults on this device
/// ([otherId], which pops true when it went). Its copy in Google Drive goes too only when
/// the person ticks it (owner 2026-10-31). In the opposite brightness (light when the app
/// is dark, and the reverse), so it is never taken for the lock screen. Wrong passwords
/// count towards the same waits as the lock screen.
class DeleteVaultScreen extends StatefulWidget {
  const DeleteVaultScreen({
    super.key,
    required this.libraryDir,
    this.vault,
    this.otherId,
    this.deleteAtMs,
    required this.sizeText,
    this.slot,
  }) : assert((vault == null) != (otherId == null));

  /// What is known of the vault, shown as on its card in Manage vaults (owner
  /// 2026-11-01); looked up when not given.
  final rust.VaultSlot? slot;

  /// [otherId] is already set to be deleted then (ms since the epoch).
  final int? deleteAtMs;

  final String libraryDir;
  final rust.VaultInfo? vault;
  /// A vault that is not open.
  final String? otherId;

  /// Mockups: act as if a Google account were added.
  static bool debugDrive = false;
  /// "214 MB · 86 items", what goes with it.
  final String sizeText;

  @override
  State<DeleteVaultScreen> createState() => _DeleteVaultScreenState();
}

class _DeleteVaultScreenState extends State<DeleteVaultScreen> with VaultLockAware {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;
  /// Also delete its copy in Google Drive (only offered with a Google account here).
  bool _alsoDrive = false;

  String get _id => widget.vault?.id ?? widget.otherId!;

  late rust.VaultSlot? _slot = widget.slot;

  @override
  void initState() {
    super.initState();
    if (_slot == null) {
      rust.listVaults(dir: widget.libraryDir).then((all) {
        final s = all.where((s) => s.id == _id).firstOrNull;
        if (mounted && s != null) setState(() => _slot = s);
      }, onError: (Object _) {});
    }
  }

  /// The password typed is not kept while the vault is locked (the countdown, if open,
  /// closes as Cancel).
  @override
  void vaultLocking() => setState(_pw.clear);

  @override
  void dispose() {
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final until = await PinStore.passwordWaitUntil();
      if (until != null && until.isAfter(DateTime.now())) {
        final m = until.difference(DateTime.now()).inSeconds;
        setState(() {
          _busy = false;
          _error = l.pinWait(m <= 60 ? 1 : (m / 60).ceil());
        });
        return;
      }
      // The password first (owner 2026-11-01): a wrong one never reaches the countdown.
      final right = widget.otherId != null
          ? await rust.vaultPasswordOpens(dir: widget.libraryDir, vaultId: _id, password: _pw.text)
          : await rust.checkPassword(dir: widget.libraryDir, password: _pw.text);
      if (!right) {
        await PinStore.addPasswordFail();
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _busy = false;
            _error = l.wrongPassword;
          });
        }
        return;
      }
      await PinStore.resetPasswordFails();
      // Then ten seconds to change one's mind (owner 2026-10-25).
      if (!mounted) return;
      if (!await confirmCountdown(context, title: l.deleteVaultTitle) || !mounted) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final id = _id;
      // Its library (each set of 24 words has one, api/run.rs): its words go with its last
      // vault.
      final own = (await rust.listVaults(dir: widget.libraryDir)).where((s) => s.id == id).firstOrNull?.libraryDir;
      final ok = widget.otherId != null
          ? await rust.deleteOtherVault(dir: widget.libraryDir, vaultId: id, password: _pw.text)
          : await rust.deleteVault(dir: widget.libraryDir, password: _pw.text);
      if (!ok) {
        await PinStore.addPasswordFail();
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _busy = false;
            _error = l.wrongPassword;
          });
        }
        return;
      }
      await PinStore.resetPasswordFails();
      _pw.clear();
      // The cloud copy of the 24 words goes only with the vault's copy in Google Drive:
      // a copy left there (or a backup file) opens with those words and nothing else.
      var driveGone = false;
      if (_alsoDrive && mounted) {
        final failure = await whileWorking(context, l.driveDeleting, () => _deleteFromDrive(id));
        driveGone = failure == null;
        if (failure != null && mounted) showToast(context, withCode(l, l.deleteDriveFailed, failure), icon: Icons.error_outline_rounded);
      }
      final any = rust.hasVaults(dir: widget.libraryDir);
      // The last vault of its library, open or not: its 24 words go too, and the next
      // vault starts afresh (owner 2026-10-24: keeping the old key after deleting the
      // vault was not safe).
      try {
        if (own != null && !rust.libraryHasVaults(dir: own) && await rust.resetEmptyLibrary(dir: own)) {
          await SecretKeyStore.delete(own, !driveGone);
        }
        if (!any) {
          await PinStore.resetFails();
          await PinStore.resetPasswordFails();
        }
      } catch (_) {
        // The new-vault screen still starts afresh from an empty library.
      }
      if (!mounted) return;
      if (widget.otherId != null) {
        // Only this page: the vault may have locked meanwhile and put its lock screen on top.
        if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop(true);
        return;
      }
      await LockGuard.clearCopied();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => any
              ? UnlockScreen(libraryDir: widget.libraryDir, askBiometricNow: false)
              : WelcomeScreen(libraryDir: widget.libraryDir),
        ),
        (_) => false,
      );
      showToast(context, l.vaultDeleted, icon: Icons.check_rounded);
    } on rust.VaultError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = vaultErrorText(l, e);
        });
      }
    }
  }

  /// Password forgotten: the phone's owner, then a confirmation, then the vault is set
  /// to be deleted in [VaultManagerScreen.forgotWait] unless opened with its password.
  Future<void> _schedule() async {
    final l = AppLocalizations.of(context);
    if (!await confirmOwnerForSetting(l.vaultScheduleTitle, context: context) || !mounted) return;
    final yes = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ui.side, 20, Ui.side, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.vaultScheduleTitle, style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(l.vaultScheduleBody, style: TextStyle(fontSize: CsType.subhead, height: 1.4, color: CsColors.of(context).muted)),
            const SizedBox(height: 20),
            FilledButton(
              key: const ValueKey('vault-schedule-go'),
              style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.vaultScheduleAction),
            ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          ]),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    try {
      final at = DateTime.now().add(VaultManagerScreen.forgotWait).millisecondsSinceEpoch;
      await rust.scheduleVaultDelete(dir: widget.libraryDir, vaultId: _id, atMs: PlatformInt64Util.from(at));
      if (!mounted) return;
      showToast(context, l.vaultScheduled, icon: Icons.schedule_rounded);
      Navigator.of(context).pop(false);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _keep() async {
    final l = AppLocalizations.of(context);
    try {
      await rust.cancelVaultDelete(dir: widget.libraryDir, vaultId: _id);
      if (!mounted) return;
      showToast(context, l.vaultKept, icon: Icons.check_rounded);
      Navigator.of(context).pop(false);
    } on rust.VaultError catch (e) {
      if (mounted) showToast(context, vaultErrorText(l, e), icon: Icons.error_outline_rounded);
    }
  }

  /// Null once deleted, else what stopped it (for the code under the message).
  Future<Object?> _deleteFromDrive(String id) async {
    try {
      final session = await driveSignInQuietly();
      if (session == null) return 'drive-sign-in';
      await sync.driveDeleteVault(token: session.token, vaultId: id);
      return null;
    } catch (e) {
      return driveErrorCode(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inverted = Theme.of(context).brightness == Brightness.dark ? Brightness.light : Brightness.dark;
    return Theme(data: buildTheme(inverted), child: Builder(builder: _page));
  }

  Widget _page(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: ink),
      // Delete, red, pinned at the bottom (owner 2026-10-25: buttons within the thumb's reach).
      body: SafeArea(
        bottom: false,
        child: PinnedAction(
          actions: [
            FilledButton(
              key: const ValueKey('delete-vault-go'),
              style: FilledButton.styleFrom(backgroundColor: dangerRed, foregroundColor: Colors.white),
              onPressed: _pw.text.isNotEmpty && !_busy ? _confirm : null,
              child: Text(l.deleteVaultAction),
            ),
            // Another vault: its password forgotten, it can still go, in seven days
            // (owner 2026-10-31: both ways on this one screen); or, set already, kept.
            if (widget.otherId != null)
              TextButton(
                key: ValueKey(widget.deleteAtMs == null ? 'vault-forgot' : 'vault-keep'),
                onPressed: _busy ? null : (widget.deleteAtMs == null ? _schedule : _keep),
                child: Text(widget.deleteAtMs == null ? l.vaultForgotPassword : l.vaultKeep),
              ),
          ],
          child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                children: [
                  if (widget.vault case final v?)
                    VaultBadge(icon: v.icon, color: v.color, size: 64)
                  else
                    Icon(Icons.lock_rounded, size: 56, color: ink.withValues(alpha: .7)),
                  const SizedBox(height: 14),
                  Text(l.deleteVaultTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, fontSize: CsType.title2, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    l.deleteVaultBody(widget.sizeText),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink.withValues(alpha: .85), height: 1.45),
                  ),
                  if (_slot case final s?) ...[
                    const SizedBox(height: 14),
                    VaultFacts(slot: s, open: widget.vault, mainLibrary: widget.libraryDir),
                  ],
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: ink.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error ?? l.deleteVaultPassword,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: ink,
                            fontWeight: _error != null ? FontWeight.w600 : FontWeight.w400)),
                  ),
                  const SizedBox(height: 16),
                  SecretField(
                    key: const ValueKey('delete-vault-password'),
                    controller: _pw,
                    label: l.password,
                    enabled: !_busy,
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _pw.text.isNotEmpty && !_busy ? _confirm() : null,
                  ),
                  if (driveAccount != null || DeleteVaultScreen.debugDrive) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      key: const ValueKey('delete-also-drive'),
                      value: _alsoDrive,
                      onChanged: _busy ? null : (v) => setState(() => _alsoDrive = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.deleteAlsoDrive, style: TextStyle(color: ink, fontSize: CsType.subhead)),
                      subtitle: Text(l.deleteDriveNote, style: TextStyle(color: ink.withValues(alpha: .7), fontSize: CsType.footnote)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
