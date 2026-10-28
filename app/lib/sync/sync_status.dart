import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'auto_sync.dart';
import 'drive.dart';

/// How automatic sync with Google Drive is going, where people look (owner 2026-10-27):
/// a red dot on Settings and on the Sync rows when it failed, and a quiet line on the
/// home page saying when the vault last synced.

/// iPhone's red for the dot.
Color _red(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);

/// iPhone's green for "synced" (owner 2026-10-28: green when fine, red when not).
Color _green(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF30D158) : const Color(0xFF248A3D);

/// iPhone's blue for "syncing".
Color _blue(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);

/// Whether automatic sync is set up here, so its state is worth showing.
bool get _autoOn => driveAccount != null && AutoSync.enabled;

/// The red dot alone, as in a row before its value.
class SyncAlertDot extends StatelessWidget {
  const SyncAlertDot({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AutoSync.failed,
        builder: (context, failed, _) => failed && _autoOn
            ? Padding(
                key: const ValueKey('sync-alert-dot'),
                padding: const EdgeInsets.only(left: 8),
                child: Container(width: 10, height: 10, decoration: BoxDecoration(color: _red(context), shape: BoxShape.circle)),
              )
            : const SizedBox.shrink(),
      );
}

/// [child] with the red dot on its top right corner, as an iPhone app icon's badge.
class SyncAlertBadge extends StatelessWidget {
  const SyncAlertBadge({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AutoSync.failed,
        builder: (context, failed, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            child!,
            if (failed && _autoOn)
              Positioned(
                key: const ValueKey('settings-alert-dot'),
                top: 0,
                right: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _red(context),
                    shape: BoxShape.circle,
                    border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
                  ),
                ),
              ),
          ],
        ),
        child: child,
      );
}

/// Where Google Drive stands, as one small icon on the home page, no words (owner
/// 2026-10-28): not synced (no Drive set up, a change not sent yet, or cut off), syncing
/// (only while items go up or come down, not while it looks for changes), failed, or
/// synced. The words are the tooltip and what a screen reader says. A tap opens Sync.
class HomeSyncIcon extends StatelessWidget {
  const HomeSyncIcon({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([AutoSync.failed, AutoSync.lastOk, AutoSync.moving, AutoSync.pending]),
      builder: (context, _) {
        final (String key, Widget icon, String label) = switch (null) {
          _ when driveAccount == null => ('none', Icon(Icons.cloud_off_rounded, size: 20, color: c.muted), l.syncNotYet),
          _ when AutoSync.failed.value && AutoSync.enabled => ('failed', _FailedCloud(color: _red(context)), l.syncProblem),
          _ when AutoSync.moving.value => (
              'moving',
              Icon(Icons.cloud_sync_rounded, size: 20, color: _blue(context)),
              l.syncWorking
            ),
          _ when AutoSync.pending.value || AutoSync.lastOk.value == null =>
            ('none', Icon(Icons.cloud_off_rounded, size: 20, color: c.muted), l.syncNotYet),
          _ => ('ok', Icon(Icons.cloud_done_rounded, size: 20, color: _green(context)), l.syncedStatus),
        };
        return Tooltip(
          message: label,
          child: Semantics(
            button: true,
            label: label,
            child: InkResponse(
              key: ValueKey('home-sync-$key'),
              onTap: onTap,
              radius: 20,
              child: SizedBox.square(dimension: 32, child: Center(child: ExcludeSemantics(child: icon))),
            ),
          ),
        );
      },
    );
  }
}

/// A red cloud with a white "!" in it: no Material icon says "the cloud failed".
class _FailedCloud extends StatelessWidget {
  const _FailedCloud({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 20,
        child: Stack(alignment: Alignment.center, children: [
          Icon(Icons.cloud_rounded, size: 20, color: color),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.priority_high_rounded, size: 11, color: Colors.white),
          ),
        ]),
      );
}
