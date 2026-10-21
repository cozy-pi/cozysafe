import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';

/// The four sections of a vault, picked in the bottom capsule (docs/ui.md, vault bar;
/// docs/naming.md). A section shows items of some kinds: Library shows photos and
/// videos, the others one kind each.
enum VaultSection { note, library, audio, file }

/// The sections this device offers: voice memos need a phone's microphone.
List<VaultSection> vaultSections() => [
      VaultSection.note,
      VaultSection.library,
      if (Device.iOS || Device.android || debugVoice) VaultSection.audio,
      VaultSection.file,
    ];

/// For tests and the browser preview: offer voice memos on any platform.
bool debugVoice = false;

/// For tests and the browser preview: offer the camera in the Library's + menu.
bool debugCamera = false;

const _sectionPref = 'vault-section';

/// Which side the main action floats on: left (default, under the left thumb) or right.
const actionSidePref = 'action-side';
bool actionOnRight() => Prefs.read(actionSidePref) == 'right';

/// Notes list and search show only titles unless this is on: someone beside you should
/// not read a password off the list (docs/security.md, secrets on screen).
const notePreviewsPref = 'note-previews';
bool notePreviews() => Prefs.read(notePreviewsPref) == '1';

/// The section the vault opens on: the last one used (0.1.6 kept it as `vault-kind`).
VaultSection startSection() {
  final saved = Prefs.read(_sectionPref) ?? Prefs.read('vault-kind');
  return vaultSections().where((k) => k.name == saved).firstOrNull ?? VaultSection.library;
}

String sectionLabel(AppLocalizations l, VaultSection k) => switch (k) {
      VaultSection.note => l.modeNote,
      VaultSection.library => l.modeLibrary,
      VaultSection.audio => l.modeAudio,
      VaultSection.file => l.modeFile,
    };

/// Frosted glass, as in the system's own bars: a light blur of what scrolls under it.
/// With "Reduce transparency" on (or no blur available), a plain translucent fill.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, required this.radius});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final plain = MediaQuery.highContrastOf(context);
    // Neutral glass: the page colour, translucent, with a hairline of ink.
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final fill = Color.alphaBlend(ink.withValues(alpha: dark ? .12 : .04), page).withValues(alpha: dark ? .78 : .72);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: plain ? Color.alphaBlend(ink.withValues(alpha: dark ? .12 : .04), page) : fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ink.withValues(alpha: dark ? .14 : .08)),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 4))],
      ),
      child: child,
    );
    if (plain) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter.grouped(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: box),
    );
  }
}

/// A round glass button (lock, search, settings).
class GlassButton extends StatelessWidget {
  const GlassButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.size = Ui.circle, this.child});
  final IconData? icon;
  final Widget? child;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: GestureDetector(
            onTap: onTap,
            child: Glass(
              radius: size / 2,
              child: SizedBox.square(
                dimension: size,
                child: Center(child: child ?? Icon(icon, size: size * .44, color: Theme.of(context).colorScheme.onSurface)),
              ),
            ),
          ),
        ),
      );
}

/// The bottom row: the lock on the left, then the sections in a capsule. Tapping a section
/// switches; dragging along the capsule switches as the finger passes each one.
/// Only [sections] that hold something are offered; with one or none, no capsule.
class VaultBar extends StatelessWidget {
  const VaultBar({super.key, required this.section, required this.sections, required this.onSection, required this.lock});

  final VaultSection section;
  final List<VaultSection> sections;
  final ValueChanged<VaultSection> onSection;
  final Widget lock;

  void _pick(VaultSection s) {
    if (s == section) return;
    HapticFeedback.selectionClick();
    Prefs.write(_sectionPref, s.name);
    onSection(s);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onSurface;
    if (sections.length < 2) return Row(children: [lock]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        lock,
        const SizedBox(width: 4),
        Expanded(
          child: Glass(
            radius: Ui.bar / 2,
            child: LayoutBuilder(
              builder: (context, box) {
                VaultSection at(double x) => sections[(x / (box.maxWidth / sections.length)).floor().clamp(0, sections.length - 1)];
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _pick(at(d.localPosition.dx)),
                  onHorizontalDragUpdate: (d) => _pick(at(d.localPosition.dx)),
                  child: SizedBox(
                    height: Ui.bar,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          for (final s in sections)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: s == section,
                                label: sectionLabel(l, s),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  decoration: BoxDecoration(
                                    color: s == section ? primary.withValues(alpha: .14) : Colors.transparent,
                                    borderRadius: BorderRadius.circular((Ui.bar - 8) / 2),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    sectionLabel(l, s),
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: s == section ? FontWeight.w700 : FontWeight.w600,
                                      color: s == section ? primary : ink.withValues(alpha: .75),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The main action, floating above the lock (left thumb): one tap for notes and voice,
/// a small menu for the library and files.
class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.color, this.turns = 0});
  final IconData icon;
  /// The + turns into × by rotating an eighth of a turn, smoothly.
  final double turns;
  /// Voice: the record red with a white mic (theme.dart `recordRed`); otherwise ink.
  final Color? color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c,
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: c.withValues(alpha: .25),
        child: InkWell(
          key: const ValueKey('vault-action'),
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.mediumImpact();
            onTap();
          },
          child: SizedBox.square(
            dimension: Ui.primary,
            child: AnimatedRotation(
              turns: turns,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Icon(icon, color: color != null ? Colors.white : Theme.of(context).colorScheme.onPrimary, size: 30),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ways to add something to a vault.
enum AddWhat { note, photo, video, photos, voice, file }

/// Every way to add, in the fixed order (camera and voice only where the device has them).
List<(AddWhat, IconData, String)> addWays(AppLocalizations l, {required bool camera, required bool voice}) => [
      (AddWhat.note, Icons.edit_note_rounded, l.newNote),
      (AddWhat.photos, Icons.photo_library_outlined, l.addFromDevice),
      if (camera) (AddWhat.photo, Icons.photo_camera_outlined, l.takePhoto),
      if (camera) (AddWhat.video, Icons.videocam_outlined, l.recordVideo),
      if (voice) (AddWhat.voice, Icons.mic_none_rounded, l.startRecording),
      (AddWhat.file, Icons.description_outlined, l.addFiles),
    ];

/// The ways that fill [section], nearest the + button in the add column.
Set<AddWhat> addWaysOf(VaultSection section) => switch (section) {
      VaultSection.note => {AddWhat.note},
      VaultSection.library => {AddWhat.photos, AddWhat.photo, AddWhat.video},
      VaultSection.audio => {AddWhat.voice},
      VaultSection.file => {AddWhat.file},
    };

/// Every way to add, nearest the + button first: [section]'s own ways, then the rest
/// in the fixed order (owner's design, 2026-10-21).
List<(AddWhat, IconData, String)> addColumnOrder(AppLocalizations l, VaultSection section,
    {required bool camera, required bool voice}) {
  final mine = addWaysOf(section);
  final all = addWays(l, camera: camera, voice: voice);
  return [...all.where((w) => mine.contains(w.$1)), ...all.where((w) => !mine.contains(w.$1))];
}

/// The + button's column: the page dims and the ways to add stack above the button,
/// nearest first. Tap one, or keep the finger down from + and slide to one and let go
/// ([hovered] is the one under the finger). [keys] let the screen find each row.
class AddColumn extends StatefulWidget {
  const AddColumn({
    super.key,
    required this.open,
    required this.ways,
    required this.mine,
    required this.columnKey,
    required this.scroll,
    required this.right,
    required this.side,
    required this.bottom,
    required this.hovered,
    required this.onPick,
    required this.onClose,
    required this.onGone,
  });
  /// false: play the closing motion, then call [onGone] so the screen can drop it.
  final bool open;
  final List<(AddWhat, IconData, String)> ways;
  final Set<AddWhat> mine;
  /// The column's box and its scroll position: the screen finds the way under a
  /// sliding finger from them ([wayAt]).
  final GlobalKey columnKey;
  final ScrollController scroll;
  final bool right;
  final double side;
  final double bottom;
  final AddWhat? hovered;
  final ValueChanged<AddWhat> onPick;
  final VoidCallback onClose;
  final VoidCallback onGone;

  /// One way's height in the column: the circle and the gap above it.
  static const row = Ui.bar + 10;

  /// Room under the nearest way for the bottom fade.
  static const fade = 18.0;

  /// Which way is level with [at] (a point on screen), counting from the button and
  /// round the loop; null when outside the column.
  static AddWhat? wayAt(Offset at, GlobalKey columnKey, ScrollController scroll, List<(AddWhat, IconData, String)> ways) {
    final box = columnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !scroll.hasClients) return null;
    final local = box.globalToLocal(at);
    if (local.dy < 0 || local.dy > box.size.height) return null;
    final fromBottom = box.size.height - local.dy + scroll.offset - fade;
    if (fromBottom < 0) return null;
    return ways[(fromBottom ~/ row) % ways.length].$1;
  }

  @override
  State<AddColumn> createState() => _AddColumnState();
}

class _AddColumnState extends State<AddColumn> with SingleTickerProviderStateMixin {
  static const _fade = AddColumn.fade;

  // Opening: each way pops out of the + in turn, nearest first, with a small overshoot.
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void didUpdateWidget(AddColumn old) {
    super.didUpdateWidget(old);
    if (old.open && !widget.open) _c.reverse().whenComplete(() => widget.onGone());
    if (!old.open && widget.open) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final w = widget;
    final n = w.ways.length;
    final dim = CurvedAnimation(parent: _c, curve: const Interval(0, .5, curve: Curves.easeOut));
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: w.onClose,
            child: FadeTransition(opacity: dim, child: ColoredBox(color: page.withValues(alpha: .82))),
          ),
        ),
        Positioned(
          left: w.right ? null : w.side,
          right: w.right ? w.side : null,
          bottom: w.bottom,
          // A list that rolls: drag it down and the far ways (Add files…) come down to
          // the thumb, the near ones slip away under the button.
          child: SizedBox(
            key: w.columnKey,
            width: MediaQuery.sizeOf(context).width - w.side * 2,
            height: AddColumn.row * n + _fade,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [Colors.white, Colors.white, Colors.transparent],
                stops: [0, 1 - _fade / r.height, 1],
              ).createShader(r),
              // A loop: rolling down never ends, the ways come round again (owner
              // 2026-10-21), like the iPhone's time picker.
              child: ListView.builder(
                key: const ValueKey('add-column'),
                controller: w.scroll,
                reverse: true, // nearest way at the bottom, by the button
                physics: const ClampingScrollPhysics(),
                clipBehavior: Clip.none,
                // Bottom: room for the fade, so only ways rolled past it fade out.
                padding: const EdgeInsets.only(bottom: _fade),
                itemExtent: AddColumn.row,
                itemBuilder: (context, i) {
                  final (what, icon, label) = w.ways[i % n];
                  return _Pop(
                      animation: CurvedAnimation(
                        parent: _c,
                        curve: Interval((i * .07).clamp(0, .45), (i * .07 + .55).clamp(0, 1), curve: Curves.easeOutBack),
                        reverseCurve: Curves.easeIn,
                      ),
                      // From the button: the i-th way travels i+1 rows up.
                      travel: AddColumn.row * (i + 1),
                      right: w.right,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _AddWay(
                          key: ValueKey('add-${what.name}'),
                          icon: icon,
                          label: label,
                          near: w.mine.contains(what),
                          hovered: w.hovered == what,
                          right: w.right,
                          onTap: () => w.onPick(what),
                        ),
                      ),
                    );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One way popping out of the + button: up from it, growing, fading in.
class _Pop extends AnimatedWidget {
  const _Pop({required Animation<double> animation, required this.travel, required this.right, required this.child})
      : super(listenable: animation);
  final double travel;
  final bool right;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    return Align(
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, travel * (1 - t)),
          child: Transform.scale(
            scale: .4 + .6 * t,
            alignment: right ? Alignment.centerRight : Alignment.centerLeft,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AddWay extends StatelessWidget {
  const _AddWay({super.key, required this.icon, required this.label, required this.near, required this.hovered, required this.right, required this.onTap});
  final IconData icon;
  final String label;
  /// One of the current section's ways: filled, the others glass.
  final bool near;
  /// Under the finger while sliding from +: grows a little.
  final bool hovered;
  final bool right;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final circle = Container(
      width: Ui.bar,
      height: Ui.bar,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: near ? ink : Color.alphaBlend(ink.withValues(alpha: .08), page),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Icon(icon, size: 26, color: near ? page : ink),
    );
    final text = Text(label, style: TextStyle(fontSize: 16.5, fontWeight: near ? FontWeight.w700 : FontWeight.w600));
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedScale(
          scale: hovered ? 1.12 : 1,
          duration: const Duration(milliseconds: 120),
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
          padding: EdgeInsets.only(left: right ? 0 : (Ui.primary - Ui.bar) / 2, right: right ? (Ui.primary - Ui.bar) / 2 : 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.only(left: right ? 18 : 0, right: right ? 0 : 18),
            decoration: BoxDecoration(
              color: hovered ? ink.withValues(alpha: .12) : Colors.transparent,
              borderRadius: BorderRadius.circular(Ui.bar / 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: right
                  ? [text, const SizedBox(width: 12), circle]
                  : [circle, const SizedBox(width: 12), text],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// The ways to add, as big tiles: the add sheet and the empty vault (docs/ui.md,
/// design language). Camera and voice only where the device has them.
class AddTiles extends StatelessWidget {
  const AddTiles({super.key, required this.camera, required this.voice, required this.onPick});
  final bool camera;
  final bool voice;
  final ValueChanged<AddWhat> onPick;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final tiles = addWays(AppLocalizations.of(context), camera: camera, voice: voice);
    final cols = tiles.length == 4 ? 2 : 3;
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: cols == 3 ? 1 : 1.5,
      children: [
        for (final (what, icon, label) in tiles)
          Material(
            key: ValueKey('add-${what.name}'),
            color: ink.withValues(alpha: .06),
            shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(Ui.radius)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onPick(what),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 32, color: ink),
                    const SizedBox(height: 8),
                    Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
