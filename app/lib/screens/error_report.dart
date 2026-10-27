import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../error_log.dart';
import '../l10n/app_localizations.dart';
import '../links.dart';
import '../theme.dart';
import '../widgets/toast.dart';

/// Settings → Report a problem: the error log (codes and times only), Copy details and
/// Feedback (owner 2026-10-26: "logs đầy đủ" to tell what went wrong).
class ErrorReportScreen extends StatefulWidget {
  const ErrorReportScreen({super.key});

  /// For the mockup renders: entries without a file.
  static List<(DateTime, String, String)>? debugEntries;

  @override
  State<ErrorReportScreen> createState() => _ErrorReportScreenState();
}

class _ErrorReportScreenState extends State<ErrorReportScreen> {
  late final _entries = ErrorReportScreen.debugEntries ?? ErrorLog.entries();

  Future<void> _copy() async {
    final l = AppLocalizations.of(context);
    var version = '';
    try {
      final p = await PackageInfo.fromPlatform();
      version = '${p.version} (${p.buildNumber})';
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: ErrorLog.report(version: version)));
    if (mounted) showToast(context, l.detailsCopied, icon: Icons.check_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final tag = Localizations.localeOf(context).toLanguageTag();
    final when = DateFormat.MMMd(tag).add_Hm();
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            if (_entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(l.errorLogEmpty, key: const ValueKey('error-log-empty'), style: TextStyle(color: c.muted)),
              )
            else
              Material(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, (t, place, code)) in _entries.take(60).indexed) ...[
                    if (i > 0) Divider(height: 1, thickness: 1, indent: 14, color: c.border.withValues(alpha: .6)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                      child: Row(children: [
                        Expanded(child: Text(code, style: const TextStyle(fontSize: CsType.subhead, fontFeatures: [FontFeature.tabularFigures()]))),
                        Text('$place · ${when.format(t)}', style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
                      ]),
                    ),
                  ],
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(l.errorLogNote, style: TextStyle(color: c.muted, fontSize: CsType.footnote)),
            ),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(children: [
            if (Links.canOpen) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    final loc = Localizations.localeOf(context);
                    Links.open(Links.feedback(loc.scriptCode == 'Hant' ? 'zh_Hant' : loc.languageCode));
                  },
                  child: Text(l.feedback),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton(
                key: const ValueKey('error-copy'),
                onPressed: _copy,
                child: Text(l.copyDetails),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}
