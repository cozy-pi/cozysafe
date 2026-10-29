import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../hidden_features.dart';
import 'item_menu.dart';

/// Hold, then drag across items to select a run of them, as in the iPhone's Photos
/// (owner 2026-10-26, "bấm giữ rồi quẹt"). A long press that stays put still opens the
/// item's menu; once the finger moves, select mode starts, and every item between where
/// the finger came down and where it is now is selected. Dragging back gives the ones left
/// behind their old state again. Starting on a selected item deselects instead. Near the
/// top or bottom edge the list scrolls on by itself. A light tick for each change.
///
/// The menu waits for the finger: it opens when the finger lifts without having moved, or
/// after [DragSelect.menuDelay] held still. Opening it at once would end the touch (a new
/// route cancels the pointers under it), and no drag could follow.
///
/// The screen owns one [DragSelect]; each item is wrapped in a [DragSelectItem]; the
/// scrolling area in a [DragSelectArea], which follows the finger even when the item it
/// started on has scrolled away.

/// The selection while dragging: [base] (what was selected before) with the items from
/// [anchor] to [over] in [order] added ([adding]) or taken out.
Set<String> dragRange({
  required List<String> order,
  required Set<String> base,
  required String anchor,
  required String over,
  required bool adding,
}) {
  final a = order.indexOf(anchor);
  final b = order.indexOf(over);
  if (a < 0 || b < 0) return Set.of(base);
  final run = order.sublist(a < b ? a : b, (a < b ? b : a) + 1);
  return adding ? {...base, ...run} : (Set.of(base)..removeAll(run));
}

class DragSelect {
  DragSelect({
    required this.order,
    required this.selected,
    required this.onChanged,
    required this.onBegin,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  /// The items' ids in the order they show.
  final List<String> Function() order;
  final Set<String> Function() selected;
  final ValueChanged<Set<String>> onChanged;
  /// The drag became a selection: select mode on.
  final VoidCallback onBegin;
  /// Parts of the scrolling area covered by floating bars: the edge zones start past them.
  double topInset;
  double bottomInset;

  /// How far the finger moves before a held item turns into a drag.
  static const slop = 10.0;
  /// Held still this long after the long press: the menu opens without waiting for the lift.
  static const menuDelay = Duration(milliseconds: 650);
  static const _edge = 64.0, _maxSpeed = 18.0;

  final Map<String, BuildContext> _items = {};
  String? _pressed;
  bool _pressedWasSelected = false;
  Offset? _down;
  ScrollableState? _scrollable;
  /// The held item's: the drag started, its menu must not open.
  VoidCallback? _onDragStart;

  String? _anchor;
  String? _over;
  Set<String> _base = const {};
  bool _adding = true;
  Offset? _last;
  Timer? _scroll;
  double _speed = 0;

  bool get active => _anchor != null;

  void _register(String id, BuildContext context) => _items[id] = context;
  void _unregister(String id, BuildContext context) {
    if (identical(_items[id], context)) _items.remove(id);
  }

  /// A long press landed on [id]; [onDragStart] if it turns into a drag.
  void press(String id, Offset at, BuildContext context, VoidCallback onDragStart) {
    _onDragStart = onDragStart;
    _pressed = id;
    _pressedWasSelected = selected().contains(id);
    _down = at;
    _scrollable = Scrollable.maybeOf(context);
  }

  /// The finger moved (from [DragSelectArea]).
  void pointerMove(Offset at) {
    if (_anchor == null) {
      final id = _pressed, down = _down;
      // Hidden for the beta (hidden_features.dart): a held item only opens its menu.
      if (!selectShown || id == null || down == null || (at - down).distance < slop) return;
      _begin(id);
    }
    _last = at;
    final id = _hit(at);
    if (id != null && id != _over) {
      _over = id;
      _apply();
    }
    _autoScroll(at);
  }

  /// The finger left the screen.
  void release() {
    _onDragStart = null;
    _pressed = null;
    _down = null;
    _anchor = null;
    _over = null;
    _last = null;
    _stopScroll();
  }

  void dispose() => release();

  void _begin(String id) {
    _onDragStart?.call();
    _onDragStart = null;
    dismissItemMenu();
    onBegin();
    final now = Set.of(selected());
    _pressedWasSelected ? now.add(id) : now.remove(id);
    _base = now;
    _adding = !_pressedWasSelected;
    _anchor = id;
    _over = id;
    _apply();
  }

  void _apply() {
    final anchor = _anchor, over = _over;
    if (anchor == null || over == null) return;
    final next = dragRange(order: order(), base: _base, anchor: anchor, over: over, adding: _adding);
    if (setEquals(next, selected())) return;
    HapticFeedback.selectionClick();
    onChanged(next);
  }

  String? _hit(Offset at) {
    for (final e in _items.entries) {
      final box = e.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (box.size.contains(box.globalToLocal(at))) return e.key;
    }
    return null;
  }

  void _autoScroll(Offset at) {
    final view = _scrollable?.context.findRenderObject();
    if (view is! RenderBox || !view.attached) return _stopScroll();
    final top = view.localToGlobal(Offset.zero).dy + topInset;
    final bottom = view.localToGlobal(Offset(0, view.size.height)).dy - bottomInset;
    if (at.dy < top + _edge) {
      _speed = -_maxSpeed * ((top + _edge - at.dy) / _edge).clamp(.2, 1);
    } else if (at.dy > bottom - _edge) {
      _speed = _maxSpeed * ((at.dy - bottom + _edge) / _edge).clamp(.2, 1);
    } else {
      return _stopScroll();
    }
    _scroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _step());
  }

  void _step() {
    final s = _scrollable;
    if (s == null || !s.mounted || _anchor == null) return _stopScroll();
    final p = s.position;
    final to = (p.pixels + _speed).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to == p.pixels) return;
    p.jumpTo(to);
    // What is under the finger now, once the list has moved.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final at = _last;
      if (at == null || _anchor == null) return;
      final id = _hit(at);
      if (id != null && id != _over) {
        _over = id;
        _apply();
      }
    });
  }

  void _stopScroll() {
    _scroll?.cancel();
    _scroll = null;
    _speed = 0;
  }
}

/// Around the scrolling area of a screen that uses [DragSelect]: follows the finger.
class DragSelectArea extends StatelessWidget {
  const DragSelectArea({super.key, required this.drag, required this.child});
  final DragSelect drag;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: (e) => drag.pointerMove(e.position),
        onPointerUp: (_) => drag.release(),
        onPointerCancel: (_) => drag.release(),
        child: child,
      );
}

/// One item of a list or grid that can be drag-selected: a long press opens its menu
/// ([onMenu]) and may turn into a drag.
class DragSelectItem extends StatefulWidget {
  const DragSelectItem({super.key, required this.id, required this.drag, required this.onMenu, required this.child});
  final String id;
  final DragSelect? drag;
  final VoidCallback? onMenu;
  final Widget child;

  @override
  State<DragSelectItem> createState() => _DragSelectItemState();
}

class _DragSelectItemState extends State<DragSelectItem> {
  /// The menu is waiting: the finger is held still on this item.
  Timer? _menuTimer;
  bool _lifted = false;

  @override
  void initState() {
    super.initState();
    widget.drag?._register(widget.id, context);
  }

  @override
  void didUpdateWidget(DragSelectItem old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.drag != widget.drag) {
      old.drag?._unregister(old.id, context);
      widget.drag?._register(widget.id, context);
    }
  }

  @override
  void dispose() {
    _menuTimer?.cancel();
    widget.drag?._unregister(widget.id, context);
    super.dispose();
  }

  void _settle() {
    _menuTimer?.cancel();
    _menuTimer = null;
    if (_lifted && mounted) setState(() => _lifted = false);
  }

  /// Open the menu now, if it is still waiting.
  void _menuNow() {
    final waiting = _menuTimer != null;
    _settle();
    if (waiting) widget.onMenu?.call();
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.onMenu;
    final drag = widget.drag;
    if (menu == null && drag == null) return widget.child;
    return GestureDetector(
      onLongPressStart: (d) {
        if (drag == null) return menu?.call();
        drag.press(widget.id, d.globalPosition, context, _settle);
        // The item gives a little under the finger with a tick: it is held.
        HapticFeedback.selectionClick();
        setState(() => _lifted = true);
        _menuTimer = Timer(DragSelect.menuDelay, _menuNow);
      },
      onLongPressEnd: (_) => _menuNow(),
      child: AnimatedScale(
        scale: _lifted ? .96 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
