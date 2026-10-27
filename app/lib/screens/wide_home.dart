import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/identity.dart';
import '../widgets/vault_bar.dart';
import 'settings.dart' show SettingsScreen;

/// From this width the vault is three columns (iPad, computer; owner 2026-10-27: the
/// phone's page made bigger looked poor, and a big screen should show many devices'
/// worth of things at once): a sidebar, the list, and the item open beside it.
const wideFrom = 700.0;

/// From this width the open item has its own pane beside the list; narrower (an iPad held
/// upright) it opens over the page, as on a phone.
const paneFrom = 1100.0;

/// The sidebar's width, and the open item's pane.
const sidebarWidth = 264.0;
const paneWidth = 420.0;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideFrom;

bool hasPane(BuildContext context) => MediaQuery.sizeOf(context).width >= paneFrom;

/// The left column of a wide window: the vault, Add, how the sync stands (always in sight:
/// several devices is the point of a big screen), the sections, the groups, then Recently
/// deleted, Settings and Lock.
class WideSidebar extends StatefulWidget {
  const WideSidebar({
    super.key,
    required this.vault,
    required this.sections,
    required this.section,
    required this.groups,
    required this.groupId,
    required this.onSection,
    required this.onGroup,
    required this.onAdd,
    required this.onSync,
    required this.onTrash,
    required this.onSettings,
    required this.onLock,
  });

  final rust.VaultInfo vault;
  final List<VaultSection> sections;
  final VaultSection section;
  /// Groups with how many items each holds.
  final List<(rust.ItemInfo, int)> groups;
  final String? groupId;
  final ValueChanged<VaultSection> onSection;
  final ValueChanged<String> onGroup;
  final VoidCallback onAdd;
  final VoidCallback onSync;
  final VoidCallback onTrash;
  final VoidCallback onSettings;
  final VoidCallback onLock;

  @override
  State<WideSidebar> createState() => _WideSidebarState();
}

class _WideSidebarState extends State<WideSidebar> {
  DateTime? _lastSync;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// When this vault last synced fully, anywhere (as Settings says it).
  Future<void> _load() async {
    if (kIsWeb) return;
    try {
      final log = SettingsScreen.debugSyncLog ?? await sync.connectionLog();
      int? newest;
      for (final line in log) {
        final p = line.split('|');
        final ms = p.isNotEmpty ? int.tryParse(p[0]) : null;
        if (p.length > 3 && p[3] == 'ok' && ms != null && (newest == null || ms > newest)) newest = ms;
      }
      if (mounted) setState(() => _lastSync = newest == null ? null : DateTime.fromMillisecondsSinceEpoch(newest));
    } catch (_) {}
  }

  String _lastText(AppLocalizations l) {
    final at = _lastSync;
    if (at == null) return l.syncLastNever;
    final ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return l.syncLastJustNow;
    if (ago.inHours < 1) return l.syncLastMinutes(ago.inMinutes);
    if (ago.inDays < 1) return l.syncLastHours(ago.inHours);
    return l.syncLastDays(ago.inDays);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final w = widget;

    Widget row(Key key, IconData icon, String label, bool on, VoidCallback onTap, {String? trailing}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
          child: Material(
            color: on ? ink.withValues(alpha: .09) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: key,
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    Icon(icon, size: 21, color: ink),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: CsType.subhead, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
                    ),
                    if (trailing != null) Text(trailing, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                  ]),
                ),
              ),
            ),
          ),
        );

    Widget title(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 20, 6),
          child: Text(text, style: TextStyle(color: c.muted, fontSize: CsType.footnote, fontWeight: FontWeight.w600)),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The vault: its badge and name.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
          child: Row(children: [
            VaultBadge(icon: w.vault.icon, color: w.vault.color, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Text(w.vault.name.isEmpty ? 'Cozy Safe' : w.vault.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w800, letterSpacing: -.3)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            key: const ValueKey('wide-add'),
            onPressed: w.onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(l.addToVault),
          ),
        ),
        // How the sync stands, always in sight, with Sync now.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Material(
            color: ink.withValues(alpha: .05),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: const ValueKey('wide-sync'),
              borderRadius: BorderRadius.circular(12),
              onTap: w.onSync,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(children: [
                  Icon(Icons.sync_rounded, size: 20, color: ink),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.syncTitle, style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w700)),
                      Text(_lastText(l), style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                    ]),
                  ),
                  Icon(Icons.chevron_right, color: c.muted, size: 20),
                ]),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            children: [
              for (final s in w.sections)
                row(ValueKey('wide-section-${s.name}'), sectionIcon(s), sectionLabel(l, s),
                    w.groupId == null && s == w.section, () => w.onSection(s)),
              if (w.groups.isNotEmpty) ...[
                title(l.tagAction),
                for (final (g, n) in w.groups)
                  row(ValueKey('wide-group-${g.id}'), Icons.sell_rounded, g.name, w.groupId == g.id, () => w.onGroup(g.id),
                      trailing: '$n'),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 6),
        row(const ValueKey('wide-trash'), Icons.delete_outline_rounded, l.recentlyDeleted, false, w.onTrash),
        row(const ValueKey('wide-settings'), Icons.settings_rounded, l.settings, false, w.onSettings),
        row(const ValueKey('wide-lock'), Icons.lock_outline_rounded, l.lockVault, false, w.onLock),
        const SizedBox(height: 10),
      ],
    );
  }
}
