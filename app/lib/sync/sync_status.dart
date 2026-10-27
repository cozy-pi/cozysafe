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

/// "Synced · 5 minutes ago", "Syncing", or the red dot and "Couldn't sync"; nothing when
/// automatic sync is off. A tap opens Sync.
class HomeSyncLine extends StatelessWidget {
  const HomeSyncLine({super.key, required this.onTap});
  final VoidCallback onTap;

  static String ago(AppLocalizations l, DateTime? at) {
    if (at == null) return l.syncLastNever;
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return l.syncLastJustNow;
    if (d.inHours < 1) return l.syncLastMinutes(d.inMinutes);
    if (d.inDays < 1) return l.syncLastHours(d.inHours);
    return l.syncLastDays(d.inDays);
  }

  @override
  Widget build(BuildContext context) {
    if (!_autoOn) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([AutoSync.failed, AutoSync.lastOk, AutoSync.running]),
      builder: (context, _) {
        final failed = AutoSync.failed.value;
        final (Widget mark, String text) = AutoSync.running.value
            ? (SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.muted)), l.syncWorking)
            : failed
                ? (Container(width: 8, height: 8, decoration: BoxDecoration(color: _red(context), shape: BoxShape.circle)), l.syncProblem)
                : (Icon(Icons.cloud_done_rounded, size: 15, color: _green(context)), '${l.syncedStatus} · ${ago(l, AutoSync.lastOk.value)}');
        return InkWell(
          key: const ValueKey('home-sync-line'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              mark,
              const SizedBox(width: 5),
              Flexible(
                child: Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AutoSync.running.value ? c.muted : (failed ? _red(context) : _green(context)),
                        fontSize: CsType.footnote)),
              ),
            ]),
          ),
        );
      },
    );
  }
}
