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

/// iPhone's amber for "waiting, nothing to do" (on mobile data, or no network).
Color _amber(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFFB340) : const Color(0xFFC27C00);

/// Where Google Drive stands, as one small icon on the home page, no words. Each state
/// its own picture (owner 2026-10-30, mockup approved): the grey crossed-out cloud only
/// while sync is not set up; changes waiting (a blue cloud with an arrow up); syncing
/// (a blue cloud filling up as items move); synced (green tick); waiting for Wi-Fi or
/// for a connection (amber, Wi-Fi sign or three dots: it goes on by itself); failed, or
/// something to do such as a full Drive (red "!"). The words are the tooltip and what a
/// screen reader says. A tap opens Sync.
class HomeSyncIcon extends StatelessWidget {
  const HomeSyncIcon({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([AutoSync.failed, AutoSync.lastOk, AutoSync.moving, AutoSync.pending, AutoSync.waiting, AutoSync.progress]),
      builder: (context, _) {
        final waitingChanges = AutoSync.pending.value || AutoSync.lastOk.value == null;
        final (String key, Widget icon, String label) = switch (null) {
          _ when driveAccount == null => ('none', Icon(Icons.cloud_off_rounded, size: 20, color: c.muted), l.syncNotSetUp),
          _ when AutoSync.failed.value && AutoSync.enabled =>
            ('failed', _MarkedCloud(color: _red(context), mark: Icons.priority_high_rounded), l.syncProblem),
          _ when AutoSync.moving.value => ('moving', _FillingCloud(color: _blue(context), progress: AutoSync.progress.value), l.syncWorking),
          _ when waitingChanges && AutoSync.waiting.value == SyncWait.wifi =>
            ('wifi', _MarkedCloud(color: _amber(context), mark: Icons.wifi_rounded), l.syncWaitWifi),
          _ when waitingChanges && AutoSync.waiting.value == SyncWait.network =>
            ('offline', _MarkedCloud(color: _amber(context), mark: Icons.more_horiz_rounded, markSize: 14), l.syncWaitNetwork),
          _ when waitingChanges => ('pending', _MarkedCloud(color: _blue(context), mark: Icons.arrow_upward_rounded), l.syncPendingStatus),
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

/// A cloud with a small white sign in it: no Material icon says "the cloud failed" or
/// "the cloud waits for Wi-Fi".
class _MarkedCloud extends StatelessWidget {
  const _MarkedCloud({required this.color, required this.mark, this.markSize = 11});
  final Color color;
  final IconData mark;
  final double markSize;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 20,
        child: Stack(alignment: Alignment.center, children: [
          Icon(Icons.cloud_rounded, size: 20, color: color),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(mark, size: markSize, color: Colors.white),
          ),
        ]),
      );
}

/// A pale cloud that fills with colour from the bottom as the items move (owner
/// 2026-10-30: chosen over turning arrows). Eased between steps; nothing loops, so it
/// is the same with less motion.
class _FillingCloud extends StatelessWidget {
  const _FillingCloud({required this.color, required this.progress});
  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: progress.clamp(0.0, 1.0)),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        builder: (context, p, _) => SizedBox.square(
          dimension: 20,
          child: Stack(children: [
            Icon(Icons.cloud_rounded, size: 20, color: color.withValues(alpha: 0.28)),
            // A sliver from the start, so a run that has just begun already reads as blue.
            ClipRect(clipper: _FromBottom(0.12 + 0.88 * p), child: Icon(Icons.cloud_rounded, size: 20, color: color)),
          ]),
        ),
      );
}

/// The lower [part] of the cloud: the icon's cloud runs from 4/24 to 20/24 of its height.
class _FromBottom extends CustomClipper<Rect> {
  const _FromBottom(this.part);
  final double part;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, size.height * (20 - 16 * part) / 24, size.width, size.height);

  @override
  bool shouldReclip(_FromBottom old) => old.part != part;
}
