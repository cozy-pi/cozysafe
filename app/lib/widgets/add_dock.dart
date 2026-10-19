import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../theme.dart';

/// Ways to add something to a vault, in dock order.
enum AddMode { note, library, camera, audio, scan, file, paste }

/// The modes this build can actually do on this device. Anything not built yet is
/// left out of the dock entirely (no "coming soon"). Add a mode here when it works.
List<AddMode> availableAddModes() =>
    debugAddModes ??
    [
      AddMode.note,
      AddMode.library,
      if (Device.iOS || Device.android) AddMode.camera,
      if (Device.iOS || Device.android) AddMode.audio,
      AddMode.file,
    ];

/// For tests only: they run on a desktop OS and set the modes a phone would have.
List<AddMode>? debugAddModes;

/// Small per-device preferences (not secret), kept as files next to the library.
abstract final class Prefs {
  static String dir = '';

  static String? read(String name) {
    try {
      return File('$dir${Platform.pathSeparator}$name').readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  static void write(String name, String value) {
    try {
      File('$dir${Platform.pathSeparator}$name').writeAsStringSync(value);
    } catch (_) {}
  }
}

/// The add dock (docs/ui.md, "Add strip"): one component on the lock screen and inside
/// the vault, so the two can never drift apart. A strip of modes the thumb drags like
/// the iPhone Camera dial, one big button, and a round slot on each side.
class AddDock extends StatefulWidget {
  const AddDock({
    super.key,
    required this.modes,
    required this.leading,
    required this.trailing,
    required this.onAction,
    this.onModeChanged,
    this.recording = false,
  });

  /// The mode the vault opens in: the last one used, except the camera, which never
  /// starts by itself (it opens the library instead).
  static AddMode startMode(List<AddMode> modes) {
    final saved = Prefs.read(_AddDockState._prefKey);
    final m = modes.where((x) => x.name == saved).firstOrNull;
    return m == null || m == AddMode.camera ? AddMode.library : m;
  }

  /// Modes shown, in order. One mode: no strip, just the button. None: only the slots.
  final List<AddMode> modes;

  final Widget leading;
  final Widget trailing;
  final void Function(AddMode mode) onAction;

  /// The strip moved to another mode: while dragging, as soon as a label crosses the
  /// middle, not on release. The vault shows that kind of content.
  final void Function(AddMode mode)? onModeChanged;

  /// A voice memo is being recorded: the mic button shows Stop.
  final bool recording;

  @override
  State<AddDock> createState() => _AddDockState();
}

class _AddDockState extends State<AddDock> {
  static const _prefKey = 'add-mode';
  static const _gap = 22.0;
  static const _style = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: .8,
  );

  late int _mode;

  /// The mode last reported, so a drag reports each change once.
  late AddMode _current = widget.modes.isEmpty
      ? AddMode.library
      : widget.modes[_mode];
  double _drag = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.modes.indexOf(AddDock.startMode(widget.modes));
    if (_mode < 0) _mode = 0;
  }

  String _label(AppLocalizations l, AddMode m) => switch (m) {
    AddMode.note => l.modeNote,
    AddMode.library => l.modeLibrary,
    AddMode.camera => l.modeCamera,
    AddMode.audio => l.modeAudio,
    AddMode.scan => l.modeScan,
    AddMode.file => l.modeFile,
    AddMode.paste => l.modePaste,
  };

  IconData _icon(AddMode m) => switch (m) {
    AddMode.note => Icons.sticky_note_2_outlined,
    AddMode.library => Icons.photo_library_outlined,
    AddMode.camera => Icons.photo_camera,
    AddMode.audio => Icons.mic,
    AddMode.scan => Icons.document_scanner_outlined,
    AddMode.file => Icons.create_new_folder_outlined,
    AddMode.paste => Icons.content_paste,
  };

  /// The label to the button's action ("New note"), shown on the button itself.
  String _actionLabel(AppLocalizations l, AddMode m) => switch (m) {
    AddMode.note => l.actionNewNote,
    AddMode.library => l.actionPickPhotos,
    AddMode.file => l.actionPickFiles,
    _ => _label(l, m),
  };

  IconData _actionIcon(AddMode m) => switch (m) {
    AddMode.note => Icons.post_add_rounded, // a sheet with a +
    AddMode.library => Icons.add_photo_alternate_outlined, // a photo with a +
    AddMode.file => Icons.note_add_outlined, // a file with a +
    _ => _icon(m),
  };

  void _select(int i) {
    final next = i.clamp(0, widget.modes.length - 1);
    setState(() {
      _mode = next;
      _drag = 0;
      _dragging = false;
    });
    _changed(next);
  }

  void _changed(int i) {
    Prefs.write(_prefKey, widget.modes[i].name);
    widget.onModeChanged?.call(widget.modes[i]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final labels = [for (final m in widget.modes) _label(l, m).toUpperCase()];
    final widths = [
      for (final t in labels)
        (TextPainter(
              text: TextSpan(text: t, style: _style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
            )..layout()).width +
            4,
    ];
    // Each label owns its gap too (half each side), so a tap between two labels
    // still lands on one of them.
    double slot(int i) => widths[i] + _gap;
    double centerOf(int i) {
      var x = 0.0;
      for (var j = 0; j < i; j++) {
        x += slot(j);
      }
      return x + slot(i) / 2;
    }

    void dragUpdate(DragUpdateDetails d) {
      // Switch as soon as another label crosses the middle, while the finger is
      // still down (docs/ui.md, vault content).
      final x = centerOf(_mode) - (_drag + d.delta.dx);
      var best = _mode;
      var bestD = double.infinity;
      for (var i = 0; i < labels.length; i++) {
        final dd = (centerOf(i) - x).abs();
        if (dd < bestD) {
          bestD = dd;
          best = i;
        }
      }
      setState(() {
        _drag += d.delta.dx;
        if (best != _mode) {
          // Keep the strip where the finger has it: move the offset with the mode.
          _drag += centerOf(best) - centerOf(_mode);
          _mode = best;
        }
      });
      if (best != widget.modes.indexOf(_current)) {
        HapticFeedback.selectionClick();
        _current = widget.modes[best];
        _changed(best);
      }
    }

    final mode = widget.modes.isEmpty
        ? null
        : widget.modes[_mode.clamp(0, widget.modes.length - 1)];
    final bottom = MediaQuery.paddingOf(context).bottom;
    // A sideways swipe anywhere on the dock moves the strip, not only on the thin
    // line of labels: that is where the thumb rests. Taps still reach the buttons.
    final draggable = widget.modes.length > 1;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: draggable
          ? (_) => setState(() => _dragging = true)
          : null,
      onHorizontalDragUpdate: draggable ? dragUpdate : null,
      onHorizontalDragEnd: draggable
          ? (_) => setState(() {
              _drag = 0;
              _dragging = false;
            })
          : null,
      child: Material(
        color: CsColors.of(context).dock,
        child: Padding(
          padding: EdgeInsets.only(top: 12, bottom: 14 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.modes.length > 1)
                SizedBox(
                  // 48 tall to touch, though the labels look like a thin line.
                  height: 48,
                  child: LayoutBuilder(
                    builder: (context, box) => Builder(
                      // Labels fade out towards the edges, like the Camera app's mode dial,
                      // so a half-cut word never shows.
                      builder: (context) => ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (r) => const LinearGradient(
                          colors: [
                            Color(0x00FFFFFF),
                            Color(0xFFFFFFFF),
                            Color(0xFFFFFFFF),
                            Color(0x00FFFFFF),
                          ],
                          stops: [0, .22, .78, 1],
                        ).createShader(r),
                        child: ClipRect(
                          child: Stack(
                            children: [
                              AnimatedPositioned(
                                duration: _dragging
                                    ? Duration.zero
                                    : const Duration(milliseconds: 280),
                                curve: Curves.easeOutCubic,
                                left:
                                    box.maxWidth / 2 - centerOf(_mode) + _drag,
                                top: 0,
                                bottom: 0,
                                child: Row(
                                  children: [
                                    for (var i = 0; i < labels.length; i++) ...[
                                      Semantics(
                                        button: true,
                                        selected: i == _mode,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            if (i != _mode) {
                                              HapticFeedback.selectionClick();
                                            }
                                            _current = widget.modes[i];
                                            _select(i);
                                          },
                                          child: SizedBox(
                                            width: slot(i),
                                            child: Center(
                                              child: Text(
                                                labels[i],
                                                // The chosen mode is white and bold; no yellow.
                                                style: _style.copyWith(
                                                  color: i == _mode
                                                      ? Colors.white
                                                      : const Color(0x80E9ECEB),
                                                  fontWeight: i == _mode
                                                      ? FontWeight.w800
                                                      : FontWeight.w600,
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: widget.leading,
                      ),
                    ),
                    if (mode == null)
                      const SizedBox(width: 72, height: 72)
                    else
                      Semantics(
                        button: true,
                        label: _label(l, mode),
                        child: GestureDetector(
                          key: const ValueKey('add-dock-action'),
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            widget.onAction(mode);
                          },
                          // Only the camera is a round shutter; every other mode is a button
                          // that says what it does, with that kind's symbol.
                          child: mode == AddMode.audio
                              // Voice memos: the same white ring, a red core and a
                              // microphone; Stop while recording.
                              ? Container(
                                  width: 72,
                                  height: 72,
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 4,
                                    ),
                                  ),
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFFE5484D),
                                    ),
                                    child: Icon(
                                      widget.recording
                                          ? Icons.stop_rounded
                                          : Icons.mic,
                                      color: Colors.white,
                                      size: widget.recording ? 30 : 28,
                                    ),
                                  ),
                                )
                              : mode == AddMode.camera
                              ? Container(
                                  width: 72,
                                  height: 72,
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 4,
                                    ),
                                  ),
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                    ),
                                  ),
                                )
                              : SizedBox(
                                  height: 72,
                                  child: Center(
                                    // A plain white button, no ring around it.
                                    child: Container(
                                      height: 48,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _actionIcon(mode),
                                            color: Brand.deep,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            _actionLabel(l, mode),
                                            style: const TextStyle(
                                              color: Brand.deep,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: widget.trailing,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 46 px round slot beside the big button (lock, search, biometrics…).
class DockSlot extends StatelessWidget {
  const DockSlot({
    super.key,
    this.icon,
    this.glyph,
    required this.label,
    this.onTap,
    this.outlined = false,
  });

  final IconData? icon;

  /// A drawn symbol instead of an icon (the Face ID glyph).
  final Widget? glyph;
  final String label;
  final VoidCallback? onTap;

  /// A state indicator (the closed lock on the lock screen), not a button.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: outlined ? Colors.transparent : const Color(0x24FFFFFF),
        border: outlined
            ? Border.all(color: const Color(0x47FFFFFF), width: 1.5)
            : null,
      ),
      child: Center(
        child:
            glyph ??
            Icon(icon, size: 22, color: outlined ? Brand.gold : Colors.white),
      ),
    );
    if (onTap == null) return Semantics(label: label, child: child);
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(onTap: onTap, radius: 30, child: child),
      ),
    );
  }
}

/// Number pad for the PIN: digits only, no letters (they mean nothing for a PIN).
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.enabled = true,
  });

  final void Function(String digit) onDigit;
  final VoidCallback onDelete;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget key(String d) => _Key(
      onTap: enabled ? () => onDigit(d) : null,
      child: Text(
        d,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    );
    const blank = SizedBox(width: 64, height: 64);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ]) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              key(row[0]),
              const SizedBox(width: 30),
              key(row[1]),
              const SizedBox(width: 30),
              key(row[2]),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            blank,
            const SizedBox(width: 30),
            key('0'),
            const SizedBox(width: 30),
            Semantics(
              button: true,
              label: l.pinDelete,
              child: _Key(
                ghost: true,
                onTap: enabled ? onDelete : null,
                child: const Icon(
                  Icons.backspace_outlined,
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.child, this.onTap, this.ghost = false});

  final Widget child;
  final VoidCallback? onTap;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ghost ? Colors.transparent : const Color(0x29FFFFFF),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        child: SizedBox(width: 64, height: 64, child: Center(child: child)),
      ),
    );
  }
}

/// One dot per digit typed so far, nothing else: no empty placeholders and no count,
/// so someone looking over a shoulder does not learn how long the PIN is.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.filled, required this.color});

  final int filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final shown = filled.clamp(0, 20);
    final dot = shown > 12 ? 9.0 : (shown > 8 ? 11.0 : 14.0);
    final gap = shown > 12 ? 3.0 : (shown > 8 ? 5.0 : 7.0);
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < shown; i++)
            Container(
              margin: EdgeInsets.symmetric(horizontal: gap),
              width: dot,
              height: dot,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
        ],
      ),
    );
  }
}
