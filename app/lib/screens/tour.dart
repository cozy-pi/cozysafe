import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Which tour: right after a vault is made (every tip), or after restoring one on a new
/// device (owner 2026-10-25). A restored vault came from its second copy and was opened
/// with its 24 words and password a minute ago, so the tips about locking and a second
/// copy would tell the person what they just did: they get the ones about using it.
/// [guide] is the User guide (Settings, owner 2026-10-26): every tip on the vault's page,
/// then on into Settings for its own tips (settings.dart).
enum TourKind { created, restored, guide }

/// One stop of the quick tour: a real widget on the vault's page, and what to say about it.
class TourTip {
  const TourTip({
    required this.id,
    required this.target,
    required this.title,
    required this.body,
    this.note,
    this.prepare,
  });

  /// Names the bubble in tests (`tip-<id>`).
  final String id;
  /// Where the widget is now, in global coordinates; null puts the bubble in the middle.
  final Rect? Function() target;
  final String title;
  final String body;
  /// A second line with a key in front: what must not be lost.
  final String? note;
  /// Run before the tip shows, to bring its widget into view (a row far down Settings).
  final Future<void> Function()? prepare;
}

/// How the tour ended: Done ([done]) or Skip ([skipped]); null after Back. No tip has a
/// button of its own that leaves the tour (owner 2026-10-29: "Set up sync now" ended it
/// half-read).
enum TourEnd { done, skipped }

/// Coach marks over the real page (owner 2026-10-26: tips on the screen itself, not
/// picture cards): the page dims, the widget being explained stays lit in a cut-out, and
/// a bubble with an arrow says what it does. Next / Skip in the bubble; a tap anywhere
/// else does nothing, so a stray touch neither skips nor runs ahead. Back ends it.
///
/// A tour that goes on on another page (the User guide: the vault's page, then Settings)
/// counts on: [first] tips came before these, [total] in all.
Future<TourEnd?> showCoachTour(BuildContext context, List<TourTip> tips, {int first = 0, int? total}) =>
    Navigator.of(context).push<TourEnd>(PageRouteBuilder<TourEnd>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => CoachTour(tips: tips, first: first, total: total),
      transitionsBuilder: (context, animation, _, child) => MediaQuery.disableAnimationsOf(context)
          ? child
          : FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut), child: child),
    ));

class CoachTour extends StatefulWidget {
  const CoachTour({super.key, required this.tips, this.first = 0, this.total});
  final List<TourTip> tips;
  /// Tips shown before these, on another page; [total] counts them all.
  final int first;
  final int? total;

  /// For the mockup renders: open on this tip (0-based).
  static int debugStart = 0;

  @override
  State<CoachTour> createState() => _CoachTourState();
}

class _CoachTourState extends State<CoachTour> {
  late int _at = CoachTour.debugStart.clamp(0, widget.tips.length - 1);
  /// The lit widget's place, measured after a frame (never while building).
  Rect? _hole;
  /// What [_hole] was measured for: the tip and the screen's size.
  (int, Size)? _measured;
  /// Being measured now (its widget may first scroll into view).
  (int, Size)? _measuring;

  int get _total => widget.total ?? widget.first + widget.tips.length;

  void _next() {
    if (_at >= widget.tips.length - 1) return Navigator.of(context).pop(TourEnd.done);
    setState(() => _at++);
  }

  Future<void> _measure() async {
    if (!mounted) return;
    final at = _at;
    final key = (at, MediaQuery.sizeOf(context));
    if (_measuring == key) return;
    _measuring = key;
    if (widget.tips[at].prepare case final prepare?) {
      await prepare();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _at != at) return;
    }
    final hole = widget.tips[at].target()?.inflate(_pad);
    _measured = key;
    _measuring = null;
    setState(() => _hole = hole);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tip = widget.tips[_at];
    // A new tip or a turned screen: measure again once this frame is laid out.
    if (_measured != (_at, MediaQuery.sizeOf(context))) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
    final hole = _hole;
    // Dark: a deep bubble, so the app's soft grey buttons stand out on it.
    final bubbleColor = dark ? const Color(0xFF1C1C1E) : Colors.white;
    Widget layer(Rect? rect) => Stack(
          fit: StackFit.expand,
          children: [
            // The dim with its window; it takes every touch, so the page under it rests.
            GestureDetector(
              key: const ValueKey('tour-dim'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: CustomPaint(painter: _Dim(hole: rect, color: Colors.black.withValues(alpha: dark ? .72 : .6))),
            ),
            CustomMultiChildLayout(
              delegate: _BubbleLayout(hole: rect, safe: MediaQuery.paddingOf(context)),
              children: [
                LayoutId(
                  id: _Part.bubble,
                  child: AnimatedSwitcher(
                    duration: still ? Duration.zero : const Duration(milliseconds: 160),
                    child: KeyedSubtree(key: ValueKey(_at), child: _bubble(context, tip, bubbleColor)),
                  ),
                ),
                LayoutId(id: _Part.up, child: CustomPaint(size: _arrow, painter: _Arrow(color: bubbleColor, up: true))),
                LayoutId(id: _Part.down, child: CustomPaint(size: _arrow, painter: _Arrow(color: bubbleColor, up: false))),
              ],
            ),
          ],
        );
    // Unseen until the first widget is measured, so the bubble does not jump into place.
    // Back (or a swipe back) ends the tour, as Skip.
    return Opacity(
      opacity: _measured == null ? 0 : 1,
      child: hole == null
          ? layer(null)
          // The window slides from one widget to the next.
          : TweenAnimationBuilder<Rect?>(
              tween: RectTween(end: hole),
              duration: still ? Duration.zero : const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, rect, _) => layer(rect),
            ),
    );
  }

  Widget _bubble(BuildContext context, TourTip tip, Color color) {
    final l = AppLocalizations.of(context);
    final muted = CsColors.of(context).muted;
    // The last of all (no page follows).
    final end = widget.first + _at == _total - 1;
    final n = widget.first + _at + 1;
    return Material(
      key: ValueKey('tip-${tip.id}'),
      color: color,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Ui.radius),
        side: Theme.of(context).brightness == Brightness.dark
            ? BorderSide(color: Colors.white.withValues(alpha: .1))
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(tip.title, style: const TextStyle(fontSize: CsType.body, fontWeight: FontWeight.w700, height: 1.25)),
                  ),
                  const SizedBox(width: 10),
                  // Where we are: 2/6.
                  Semantics(
                    label: l.tourStep(n, _total),
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('$n/$_total',
                          key: const ValueKey('tip-count'),
                          style: TextStyle(fontSize: CsType.footnote, fontWeight: FontWeight.w600, color: muted)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(tip.body, style: const TextStyle(fontSize: CsType.subhead, height: 1.35)),
            ),
            if (tip.note case final note?) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(Icons.key_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(note, style: const TextStyle(fontSize: CsType.subhead, height: 1.35, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                // Skip on every tip but the very last, where Done ends it anyway.
                // A real button, not grey words (owner 2026-10-27: it went unseen).
                if (!end)
                  OutlinedButton(
                    key: const ValueKey('tip-skip'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(88, Ui.tap),
                      shape: const StadiumBorder(),
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                    ),
                    onPressed: () => Navigator.of(context).pop(TourEnd.skipped),
                    child: Text(l.tourSkip),
                  ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('tip-next'),
                  style: FilledButton.styleFrom(minimumSize: const Size(88, Ui.tap), shape: const StadiumBorder()),
                  onPressed: _next,
                  child: Text(end ? l.tourDone : l.tourNext),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Room around the lit widget, so its own edge and shadow show.
const _pad = 6.0;
const _arrow = Size(22, 11);

enum _Part { bubble, up, down }

/// The page dimmed, with a rounded window over [hole] and a thin light ring around it.
class _Dim extends CustomPainter {
  _Dim({required this.hole, required this.color});
  final Rect? hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final all = Path()..addRect(Offset.zero & size);
    final hole = this.hole;
    if (hole == null) return canvas.drawPath(all, Paint()..color = color);
    final r = RRect.fromRectAndRadius(hole, Radius.circular((hole.shortestSide / 2).clamp(0, 24)));
    canvas.drawPath(Path.combine(PathOperation.difference, all, Path()..addRRect(r)), Paint()..color = color);
    canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: .85));
  }

  @override
  bool shouldRepaint(_Dim old) => old.hole != hole || old.color != color;
}

/// The bubble's point, towards the lit widget.
class _Arrow extends CustomPainter {
  _Arrow({required this.color, required this.up});
  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final p = up
        ? (Path()
          ..moveTo(0, size.height)
          ..lineTo(size.width / 2, 0)
          ..lineTo(size.width, size.height))
        : (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width / 2, size.height)
          ..lineTo(size.width, 0));
    canvas.drawPath(p..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Arrow old) => old.color != color || old.up != up;
}

/// Puts the bubble below the lit widget when it fits there, else above (whichever side
/// has more room when neither does), inside the safe area, with its arrow under the
/// widget's middle.
class _BubbleLayout extends MultiChildLayoutDelegate {
  _BubbleLayout({required this.hole, required this.safe});
  final Rect? hole;
  final EdgeInsets safe;

  static const _side = 16.0;
  static const _gap = 4.0;
  static const _maxWidth = 380.0;

  @override
  void performLayout(Size size) {
    final top = safe.top + 12;
    final bottom = size.height - safe.bottom - 12;
    final width = (size.width - 2 * _side).clamp(0.0, _maxWidth);
    final b = layoutChild(_Part.bubble, BoxConstraints(maxWidth: width, maxHeight: (bottom - top).clamp(0.0, double.infinity)));
    layoutChild(_Part.up, BoxConstraints.tight(_arrow));
    layoutChild(_Part.down, BoxConstraints.tight(_arrow));
    const away = Offset(-1000, -1000);
    final hole = this.hole;
    final left = ((size.width - b.width) / 2).clamp(_side, size.width - _side - b.width).toDouble();
    if (hole == null) {
      positionChild(_Part.bubble, Offset(left, (size.height - b.height) / 2));
      positionChild(_Part.up, away);
      positionChild(_Part.down, away);
      return;
    }
    final below = bottom - (hole.bottom + _gap + _arrow.height);
    final above = hole.top - _gap - _arrow.height - top;
    final under = b.height <= below || (b.height > above && below >= above);
    final x = (hole.center.dx - b.width / 2).clamp(_side, size.width - _side - b.width).toDouble();
    final y = (under ? hole.bottom + _gap + _arrow.height : hole.top - _gap - _arrow.height - b.height)
        .clamp(top, (bottom - b.height).clamp(top, double.infinity))
        .toDouble();
    positionChild(_Part.bubble, Offset(x, y));
    // The point stays clear of the bubble's rounded corners.
    final ax = hole.center.dx.clamp(x + Ui.radius + _arrow.width / 2, x + b.width - Ui.radius - _arrow.width / 2) -
        _arrow.width / 2;
    positionChild(_Part.up, under ? Offset(ax, y - _arrow.height + .5) : away);
    positionChild(_Part.down, under ? away : Offset(ax, y + b.height - .5));
  }

  @override
  bool shouldRelayout(_BubbleLayout old) => old.hole != hole || old.safe != safe;
}
