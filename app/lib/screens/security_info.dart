import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/brand.dart';

/// "How this vault is protected" (owner 2026-10-21: serious, so people understand). Six
/// short sections, each with a small drawing made of the app's own symbols; technical
/// details open at the end. Every claim is what the app does today (docs/security.md,
/// ADR 0001): nothing planned is described as done.
class SecurityInfoScreen extends StatelessWidget {
  const SecurityInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    Widget section(int i, String title, String body, Widget drawing, Color tint) => Padding(
          key: ValueKey('sec-$i'),
          padding: const EdgeInsets.only(top: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            // Title, then its drawing, then the words (owner 2026-10-21).
            children: [
              Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -.3)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
                decoration: BoxDecoration(color: tint.withValues(alpha: .12), borderRadius: BorderRadius.circular(Ui.radius + 4)),
                child: drawing,
              ),
              const SizedBox(height: 12),
              Text(body, style: TextStyle(fontSize: 16.5, height: 1.55, color: c.muted.withValues(alpha: 1))),
            ],
          ),
        );
    const green = Color(0xFF30D158), blue = Color(0xFF0A84FF), purple = Color(0xFFBF5AF2);
    const orange = Color(0xFFFF9F0A), red = Color(0xFFFF453A);
    return Scaffold(
      appBar: AppBar(title: Text(l.securityTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          Text(l.secIntro, style: const TextStyle(fontSize: 18, height: 1.5, fontWeight: FontWeight.w600)),
          // Plain words first (owner 2026-10-21: "clear and simple"); the technical
          // details stay folded at the end.
          section(1, l.sec1Title, l.sec1Body,
              _Flow([
                _Node(Icons.folder_outlined, l.secItem, blue),
                _Node(Icons.lock_rounded, l.secOwnKey, blue),
                _Node(Icons.cloud_off_rounded, l.secNoServer, blue, strong: true),
              ]),
              blue),
          section(2, l.secDailyTitle, l.secDailyBody,
              _Flow([
                _Node(Icons.dialpad_rounded, 'PIN', green),
                const _Or(),
                _NodeWidget(const FaceIdGlyph(size: 26, color: Colors.white), 'Face ID', green),
                _Node(Icons.smartphone_rounded, l.secThisPhone, green, strong: true),
              ]),
              green),
          section(3, l.secRecoverTitle, l.secRecoverBody,
              _Flow([
                _Node(Icons.insert_drive_file_outlined, l.secBackupFile, purple),
                const _Plus(),
                _Node(Icons.key_rounded, l.secKit, purple),
                const _Plus(),
                _Node(Icons.password_rounded, l.secPassword, purple),
                _Node(Icons.phonelink_setup_rounded, l.secNewPhone, purple, strong: true),
              ]),
              purple),
          section(4, l.sec5Title, l.sec5Body,
              _Flow([
                _NodeWidget(const LockGlyph(size: 24, color: Colors.white), l.secAutoLock, orange),
                _Node(Icons.visibility_off_rounded, l.secHidden, orange),
                _Node(Icons.content_paste_off_rounded, l.secClipboard, orange),
                _Node(Icons.screenshot_monitor_rounded, l.secNoCapture, orange),
              ], arrows: false),
              orange),
          section(5, l.secKeepTitle, l.secKeepBody,
              _Flow([_Node(Icons.cloud_off_rounded, l.secNoServer, red), _Node(Icons.key_rounded, l.secKit, red)], arrows: false),
              red),
          const SizedBox(height: 22),
          // Open, not folded (owner 2026-10-21): the details are for whoever reads this far.
          Text(l.secTech, key: const ValueKey('sec-tech'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SelectableText(l.secTechBody,
              style: TextStyle(fontSize: 14.5, height: 1.6, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

/// A row of symbols joined by arrows: what goes in, what comes out.
class _Flow extends StatelessWidget {
  const _Flow(this.items, {this.arrows = true});
  final List<Widget> items;
  final bool arrows;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface.withValues(alpha: .35);
    final out = <Widget>[];
    for (final (i, w) in items.indexed) {
      if (i > 0 && arrows && w is! _Plus && w is! _Or && items[i - 1] is! _Plus && items[i - 1] is! _Or) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Icon(Icons.arrow_forward_rounded, color: ink, size: 22),
        ));
      } else if (i > 0 && !arrows) {
        out.add(const SizedBox(width: 14));
      }
      out.add(w);
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: out),
    );
  }
}

class _Node extends StatelessWidget {
  const _Node(this.icon, this.label, this.color, {this.strong = false});
  final IconData icon;
  final String? label;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) =>
      _NodeWidget(Icon(icon, color: Colors.white, size: 26), label, color, strong: strong);
}

/// A coloured disc with a white symbol, and a short label under it.
class _NodeWidget extends StatelessWidget {
  const _NodeWidget(this.symbol, this.label, this.color, {this.strong = false});
  final Widget symbol;
  final String? label;
  final Color color;
  /// The result of the flow: a ring around it.
  final bool strong;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 84,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: strong ? Border.all(color: color.withValues(alpha: .35), width: 5, strokeAlign: BorderSide.strokeAlignOutside) : null,
                boxShadow: [BoxShadow(color: color.withValues(alpha: .3), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Center(child: symbol),
            ),
            if (label != null) ...[
              const SizedBox(height: 8),
              Text(label!, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
            ],
          ],
        ),
      );
}

class _Plus extends StatelessWidget {
  const _Plus();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Icon(Icons.add_rounded, size: 22, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .45)),
      );
}

class _Or extends StatelessWidget {
  const _Or();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 13, left: 2, right: 2),
        child: Text('/', style: TextStyle(fontSize: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .45))),
      );
}
