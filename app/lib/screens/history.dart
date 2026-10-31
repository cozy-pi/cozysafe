import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../item_kind.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/history.dart' as hist;
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import '../widgets/confirm_delete.dart';
import '../widgets/toast.dart';
import '../widgets/vault_bar.dart';
import 'file_view.dart' show fileSize;

/// How much (owner 2026-10-27, space first to keep versions as long as possible):
/// 500 MB · 1 GB · 5 GB · no limit, or Off; 1 GB unless changed. Under it nothing goes;
/// once full, versions older than [historyKeptDays] go first (core/cs-core/src/history.rs).
const historyKeptDays = 30;
final historySizeChoices = [
  BigInt.from(500) * BigInt.from(1 << 20),
  BigInt.from(1 << 30),
  BigInt.from(5) * BigInt.from(1 << 30),
  BigInt.zero,
];

String historySizeText(AppLocalizations l, BigInt bytes) {
  if (bytes == BigInt.zero) return l.historyNoLimit;
  // Round choices read round: "500 MB", "1 GB", not "500.0 MB".
  final mb = bytes ~/ BigInt.from(1 << 20);
  return mb >= BigInt.from(1024) && mb % BigInt.from(1024) == BigInt.zero ? '${mb ~/ BigInt.from(1024)} GB' : '$mb MB';
}

/// One item's older versions, newest first (owner 2026-10-27: "like git", any change can
/// be undone). Opening one shows it; Restore makes it the current version.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.item, this.onRestored});

  final rust.ItemInfo item;
  final ValueChanged<rust.ItemInfo>? onRestored;

  /// For the mockup renders: versions, their content and the days kept, without a vault.
  static List<hist.HistoryVersion>? debugVersions;
  static Uint8List Function(String rev)? debugContent;
  static int? debugDays;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<hist.HistoryVersion>? _versions;
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = HistoryScreen.debugVersions ?? await hist.itemHistory(id: widget.item.id);
      final days = HistoryScreen.debugDays ?? (await hist.historySettings()).days;
      if (mounted) {
        setState(() {
          _versions = v;
          _days = days;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _versions = const []);
    }
  }

  Future<void> _clear() async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDelete(
      context,
      title: l.historyClearItem,
      action: l.historyClearItem,
      name: widget.item.name,
      body: l.historyClearBody,
    );
    if (!ok) return;
    try {
      await hist.clearItemHistory(id: widget.item.id);
    } catch (_) {}
    _load();
  }

  Future<void> _open(hist.HistoryVersion v) async {
    final restored = await pushPage<rust.ItemInfo>(
      context,
      title: _when(context, v.replacedMs),
      builder: (_) => _VersionPage(item: widget.item, version: v),
    );
    if (restored == null || !mounted) return;
    widget.onRestored?.call(restored);
    showToast(context, AppLocalizations.of(context).historyRestored, icon: Icons.check_rounded);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final versions = _versions;
    if (versions == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (versions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              _days == 0 ? l.historyIsOff : l.historyEmptyAny,
              key: const ValueKey('history-empty'),
              style: TextStyle(color: c.muted, height: 1.4),
            ),
          )
        else ...[
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, v) in versions.indexed) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, indent: 14, color: c.border.withValues(alpha: .6)),
                  _VersionRow(
                    key: ValueKey('history-${v.rev}'),
                    version: v,
                    current: widget.item,
                    onTap: v.hasContent ? () => _open(v) : null,
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(l.historyNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.35)),
          ),
          const SizedBox(height: 28),
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('history-clear-item'),
              onTap: _clear,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
                child: Text(
                  l.historyClearItem,
                  style: TextStyle(color: recordRed(context), fontSize: CsType.callout),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _when(BuildContext context, int ms) {
  final tag = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.yMMMd(tag).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(ms));
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({super.key, required this.version, required this.current, this.onTap});
  final hist.HistoryVersion version;
  final rust.ItemInfo current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final v = version;
    final what = !v.hasContent
        ? l.historyNoContent
        : v.sameContent
        ? l.historySameContent
        : fileSize(v.item.sizeBytes);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_when(context, v.replacedMs), style: const TextStyle(fontSize: CsType.callout)),
                  if (v.item.name != current.name) ...[
                    const SizedBox(height: 2),
                    Text(
                      v.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: CsType.subhead),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    '${v.thisDevice ? l.historyThisDevice : l.historyOtherDevice} · $what',
                    style: TextStyle(color: c.muted, fontSize: CsType.footnote),
                  ),
                ],
              ),
            ),
            if (onTap != null) Icon(Icons.chevron_right, color: c.muted, size: 20),
          ],
        ),
      ),
    );
  }
}

/// An older version, as it was, with Restore at the thumb.
class _VersionPage extends StatefulWidget {
  const _VersionPage({required this.item, required this.version});
  final rust.ItemInfo item;
  final hist.HistoryVersion version;

  @override
  State<_VersionPage> createState() => _VersionPageState();
}

class _VersionPageState extends State<_VersionPage> {
  Uint8List? _content;
  bool _busy = false;

  bool get _previewable => widget.version.item.kind == ItemKind.note || widget.version.item.kind == ItemKind.photo;

  @override
  void initState() {
    super.initState();
    if (_previewable) _read();
  }

  Future<void> _read() async {
    try {
      final rev = widget.version.rev;
      final bytes = HistoryScreen.debugContent?.call(rev) ?? await hist.historyContent(id: widget.item.id, rev: rev);
      if (mounted) setState(() => _content = bytes);
    } catch (_) {}
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final restored = HistoryScreen.debugVersions != null
          ? widget.item
          : await hist.restoreVersion(id: widget.item.id, rev: widget.version.rev);
      if (mounted) Navigator.of(context).pop(restored);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _preview(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final v = widget.version.item;
    final bytes = _content;
    if (_previewable && bytes == null) return const SizedBox.shrink();
    if (v.kind == ItemKind.note) {
      String text;
      try {
        text = utf8.decode(bytes!);
      } catch (_) {
        text = String.fromCharCodes(bytes!);
      }
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(14)),
        child: SelectableText(
          text,
          key: const ValueKey('history-text'),
          style: const TextStyle(fontSize: CsType.callout, height: 1.45),
        ),
      );
    }
    if (v.kind == ItemKind.photo) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.memory(bytes!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        l.historyNoPreview,
        textAlign: TextAlign.center,
        style: TextStyle(color: c.muted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final v = widget.version;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              Text(v.item.name, style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${v.thisDevice ? l.historyThisDevice : l.historyOtherDevice} · '
                '${v.sameContent ? l.historySameContent : fileSize(v.item.sizeBytes)}',
                style: TextStyle(color: c.muted, fontSize: CsType.footnote),
              ),
              const SizedBox(height: 14),
              _preview(context),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.historyRestoreNote,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: CsType.footnote),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: const ValueKey('history-restore'),
                  onPressed: _busy ? null : _restore,
                  child: Text(l.historyRestore),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Settings → Version history: how long, how much, how much it takes now, Clear all.
/// This device's own (owner 2026-10-27, choice a): not synced.
class HistorySettingsScreen extends StatefulWidget {
  const HistorySettingsScreen({super.key, this.onChanged});
  final VoidCallback? onChanged;

  /// For the mockup renders.
  static (int, BigInt, BigInt)? debugState;

  @override
  State<HistorySettingsScreen> createState() => _HistorySettingsScreenState();
}

class _HistorySettingsScreenState extends State<HistorySettingsScreen> {
  int _days = 30;
  BigInt _max = BigInt.from(1 << 30);
  BigInt? _used;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (HistorySettingsScreen.debugState case (final d, final m, final u)) {
      setState(() {
        _days = d;
        _max = m;
        _used = u;
      });
      return;
    }
    try {
      final s = await hist.historySettings();
      final used = await hist.historyBytes();
      if (mounted) {
        setState(() {
          _days = s.days;
          _max = s.maxBytes;
          _used = used;
        });
      }
    } catch (_) {}
  }

  Future<void> _set(int days, BigInt max) async {
    setState(() {
      _days = days;
      _max = max;
    });
    if (HistorySettingsScreen.debugState != null) return;
    try {
      await hist.setHistorySettings(days: days, maxBytes: max, nowMs: DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    widget.onChanged?.call();
    _load();
  }

  Future<void> _clearAll() async {
    final l = AppLocalizations.of(context);
    final ok = await confirmDelete(
      context,
      title: l.historyClearAll,
      action: l.historyClearAll,
      body: l.historyClearBody,
    );
    if (!ok) return;
    try {
      await hist.clearAllHistory();
    } catch (_) {}
    widget.onChanged?.call();
    _load();
  }

  Widget _group(BuildContext context, String title, List<Widget> rows) {
    final c = CsColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(title, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
        ),
        Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, r) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, thickness: 1, indent: 14, color: c.border.withValues(alpha: .6)),
                r,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _choice(BuildContext context, String key, String label, bool on, VoidCallback onTap) => InkWell(
    key: ValueKey(key),
    onTap: onTap,
    child: SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: CsType.callout))),
            if (on) Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.primary, size: 22),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final used = _used;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        // One choice (owner 2026-10-27): how much; how long follows from it.
        _group(context, l.historyKeepUntil, [
          for (final m in historySizeChoices)
            _choice(context, 'history-max-$m', historySizeText(l, m), _days != 0 && _max == m,
                () => _set(historyKeptDays, m)),
          _choice(context, 'history-days-0', l.historyOff, _days == 0, () => _set(0, _max)),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            [if (used != null) l.historyUsing(fileSize(used)), l.historyRule].join(' '),
            style: TextStyle(color: c.muted, fontSize: CsType.footnote, height: 1.35),
          ),
        ),
        if (used != null && used > BigInt.zero) ...[
          const SizedBox(height: 28),
          Material(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('history-clear-all'),
              onTap: _clearAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
                child: Text(
                  l.historyClearAll,
                  style: TextStyle(color: recordRed(context), fontSize: CsType.callout),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
