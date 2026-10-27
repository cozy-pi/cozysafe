import 'package:flutter/material.dart';
import '../theme.dart' show CsType;

import 'vault_bar.dart';

/// Short messages ("Moved to Recently deleted · Undo", "Copied", errors): a glass capsule in
/// the app's black-and-white language (docs/ui.md), never the Material default box.
///
/// At the top of the screen, just under the status bar (owner 2026-10-25: at the bottom
/// they sat over the bar and the + and did not look right). It slides down, stays 3 s
/// (5 s with an action such as Undo), and a swipe up closes it early. One at a time: a
/// new message replaces the one showing. [besideAction] is from when it sat by the +
/// button and is no longer needed.
void showToast(
  BuildContext context,
  String text, {
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  bool besideAction = false,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  _current?.close();
  late final _TopToast toast;
  toast = _TopToast(
    overlay: overlay,
    text: text,
    icon: icon,
    actionLabel: actionLabel,
    onAction: onAction,
    shown: Duration(seconds: actionLabel == null ? 3 : 5),
    onGone: () {
      if (identical(_current, toast)) _current = null;
    },
  );
  _current = toast;
  toast.show();
}

_TopToast? _current;

/// For the mockup renders: messages stay until the picture is taken.
bool debugHoldToasts = false;

/// One message on its overlay entry; [close] slides it away.
class _TopToast {
  _TopToast({
    required this.overlay,
    required this.text,
    required this.icon,
    required this.actionLabel,
    required this.onAction,
    required this.shown,
    required this.onGone,
  });

  final OverlayState overlay;
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration shown;
  final VoidCallback onGone;
  OverlayEntry? _entry;
  final _closing = ValueNotifier<bool>(false);

  void show() {
    _entry = OverlayEntry(
      builder: (_) => _TopToastView(
        text: text,
        icon: icon,
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                close();
                onAction!();
              },
        shown: shown,
        closing: _closing,
        onGone: _remove,
      ),
    );
    overlay.insert(_entry!);
  }

  void close() => _closing.value = true;

  void _remove() {
    _entry?.remove();
    _entry = null;
    _closing.dispose();
    onGone();
  }
}

class _TopToastView extends StatefulWidget {
  const _TopToastView({
    required this.text,
    required this.icon,
    required this.actionLabel,
    required this.onAction,
    required this.shown,
    required this.closing,
    required this.onGone,
  });

  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration shown;
  final ValueNotifier<bool> closing;
  final VoidCallback onGone;

  @override
  State<_TopToastView> createState() => _TopToastViewState();
}

class _TopToastViewState extends State<_TopToastView> with TickerProviderStateMixin {
  // Slide in and out; a second controller times the stay (a ticker, not a Timer, so
  // nothing is left pending when a page or a test ends).
  late final _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final _stay = AnimationController(vsync: this, duration: widget.shown);
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    widget.closing.addListener(_leave);
    _slide.forward().whenComplete(() {
      if (mounted && !_leaving && !debugHoldToasts) _stay.forward().whenComplete(_leave);
    });
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _stay.stop();
    _slide.reverse().whenComplete(widget.onGone);
  }

  @override
  void dispose() {
    widget.closing.removeListener(_leave);
    _slide.dispose();
    _stay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 8;
    final curve = CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: AnimatedBuilder(
              animation: curve,
              builder: (context, child) => FractionalTranslation(
                translation: Offset(0, -1.6 * (1 - curve.value)),
                child: Opacity(opacity: curve.value.clamp(0, 1), child: child),
              ),
              child: GestureDetector(
                // A swipe up puts it away early.
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < -100) _leave();
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: _Toast(
                    text: widget.text,
                    icon: widget.icon,
                    actionLabel: widget.actionLabel,
                    onAction: widget.onAction,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text, this.icon, this.actionLabel, this.onAction});
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    return Glass(
      radius: 26,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: EdgeInsets.fromLTRB(icon == null ? 18 : 14, 6, actionLabel == null ? 18 : 6, 6),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: ink), const SizedBox(width: 10)],
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ink, fontSize: CsType.subhead, fontWeight: FontWeight.w600, height: 1.25),
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                // The one thing to tap: a solid ink capsule with page-coloured words.
                Semantics(
                  button: true,
                  child: Material(
                    color: ink,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: onAction,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 40, minWidth: 64),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Center(
                            widthFactor: 1,
                            child: Text(actionLabel!, style: TextStyle(color: page, fontSize: CsType.subhead, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
