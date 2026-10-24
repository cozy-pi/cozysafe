import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';

/// The four sections of a vault, picked in the bottom capsule (docs/ui.md, vault bar;
/// docs/naming.md). A section shows items of some kinds: Library shows photos and
/// videos, the others one kind each.
/// [home] is the overview of everything (owner 2026-10-21); it holds no items itself.
enum VaultSection { home, note, library, audio, file }

/// The sections this device offers: voice memos need a phone's microphone.
List<VaultSection> vaultSections() => [
      VaultSection.home,
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


/// No lock button in the bar: holding the home tab locks (owner 2026-10-22: on by
/// default). Settings can bring the lock button back. Where the bar has no home tab
/// (one kind of item, an empty vault) the lock button stays.
const holdHomePref = 'hold-home-lock';
bool holdHomeLocks() => Prefs.read(holdHomePref) != '0';

/// Where the main action floats (Settings): left (default, under the left thumb), right,
/// or in the middle above the bar (owner 2026-10-24). Its ways stack up the edge it is
/// on; from the middle they fan out to both sides.
enum ActionSide { left, right, center }

const actionSidePref = 'action-side';
ActionSide actionSide() => switch (Prefs.read(actionSidePref)) {
      'right' => ActionSide.right,
      'center' => ActionSide.center,
      _ => ActionSide.left,
    };
bool actionOnRight() => actionSide() == ActionSide.right;

/// How far the main action sits from the screen edge: lined up with the lock button.
const double actionEdge = 10;

/// The main action's left edge on screen.
double actionLeft(BuildContext context) => switch (actionSide()) {
      ActionSide.left => actionEdge,
      ActionSide.right => MediaQuery.sizeOf(context).width - actionEdge - Ui.primary,
      ActionSide.center => (MediaQuery.sizeOf(context).width - Ui.primary) / 2,
    };

/// The main action's bottom above the safe area: on an edge clear of the bar by 30 (a big
/// thumb would hit the lock); in the middle it sits inside the bar.
double actionLift() => actionSide() == ActionSide.center ? Ui.edge + 4 : Ui.actionLift;

/// Show the vault's icon on a plain page after unlocking (on by default; Settings).
const revealIconPref = 'reveal-icon';
bool revealIconOn() => Prefs.read(revealIconPref) != '0';

/// Notes list and search show only titles unless this is on: someone beside you should
/// not read a password off the list (docs/security.md, secrets on screen).
const notePreviewsPref = 'note-previews';
bool notePreviews() => Prefs.read(notePreviewsPref) == '1';

/// Thumbnails blurred in lists, for crowded places (Settings → Display; persona review
/// 2026-10-21). Opening an item still shows it clearly.
const blurThumbsPref = 'blur-thumbnails';
/// On unless turned off (owner 2026-10-21: blurred by default).
bool blurThumbnails() => Prefs.read(blurThumbsPref) != '0';

/// A thumbnail, blurred when [blurThumbnails] is on.
Widget privateThumb(Widget image) => blurThumbnails()
    ? ClipRect(child: ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: image))
    : image;

/// The section the vault opens on: the last one used (0.1.6 kept it as `vault-kind`).
VaultSection startSection() {
  final saved = Prefs.read(_sectionPref) ?? Prefs.read('vault-kind');
  return vaultSections().where((k) => k.name == saved).firstOrNull ?? VaultSection.home;
}

String sectionLabel(AppLocalizations l, VaultSection k) => switch (k) {
      VaultSection.home => l.modeHome,
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
  const VaultBar({
    super.key,
    required this.section,
    required this.sections,
    required this.onSection,
    this.lock,
    this.home,
    this.onHoldHome,
    this.centre,
  });

  /// The + in the middle of the bar (Settings → Middle, owner 2026-10-24): the sections
  /// become icons with a small word and share the two sides of it.
  final Widget? centre;

  final VaultSection section;
  /// What the home tab shows instead of a word: the vault's own badge.
  final Widget? home;
  final List<VaultSection> sections;
  final ValueChanged<VaultSection> onSection;
  /// None when holding the home tab locks: the sections take the whole row.
  final Widget? lock;
  /// Holding the home tab locks the vault.
  final VoidCallback? onHoldHome;

  void _pick(VaultSection s) {
    if (s == section) return;
    HapticFeedback.selectionClick();
    Prefs.write(_sectionPref, s.name);
    onSection(s);
  }

  @override
  Widget build(BuildContext context) {
    final centre = this.centre;
    if (centre != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (lock case final lock?) ...[lock, const SizedBox(width: 4)],
          Expanded(
            child: Glass(
              radius: Ui.bar / 2,
              child: SizedBox(
                height: Ui.bar + 8,
                child: _CentreTabs(
                  section: section,
                  sections: sections.length < 2 ? const [] : sections,
                  home: home,
                  onPick: _pick,
                  onHoldHome: onHoldHome,
                  centre: centre,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (sections.length < 2) return Row(mainAxisAlignment: MainAxisAlignment.center, children: [?lock]);
    // As wide as its tabs and centred (owner 2026-10-24: with one kind of item, a capsule
    // stretched across the screen around one word looked odd); full width when they
    // need it all.
    final capsule = Flexible(
          child: Glass(
            radius: Ui.bar / 2,
            child: SizedBox(
              height: Ui.bar,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: _Tabs(section: section, sections: sections, home: home, onPick: _pick, onHoldHome: onHoldHome),
              ),
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [if (lock case final lock?) ...[lock, const SizedBox(width: 4)], capsule],
    );
  }
}

/// The bar with the + in its middle: each section an icon over a small word, half of them
/// on each side, so the + stays in the centre whatever the count.
class _CentreTabs extends StatelessWidget {
  const _CentreTabs({
    required this.section,
    required this.sections,
    required this.home,
    required this.onPick,
    required this.onHoldHome,
    required this.centre,
  });
  final VaultSection section;
  final List<VaultSection> sections;
  final Widget? home;
  final ValueChanged<VaultSection> onPick;
  final VoidCallback? onHoldHome;
  final Widget centre;

  static IconData _icon(VaultSection s) => switch (s) {
        VaultSection.home => Icons.home_outlined,
        VaultSection.note => Icons.sticky_note_2_outlined,
        VaultSection.library => Icons.photo_library_outlined,
        VaultSection.audio => Icons.mic_none_rounded,
        VaultSection.file => Icons.description_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget tab(VaultSection s) {
      final on = s == section;
      final color = on ? primary : ink.withValues(alpha: .7);
      final hold = s == VaultSection.home ? onHoldHome : null;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: sectionLabel(l, s),
          hint: hold == null ? null : l.holdToLock,
          child: GestureDetector(
            key: s == VaultSection.home ? const ValueKey('home-tab') : ValueKey('tab-${s.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onPick(s),
            onLongPress: hold == null
                ? null
                : () {
                    HapticFeedback.heavyImpact();
                    hold();
                  },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                s == VaultSection.home && home != null
                    ? SizedBox(height: 26, child: FittedBox(child: home!))
                    : Icon(_icon(s), size: 24, color: color),
                const SizedBox(height: 3),
                Text(sectionLabel(l, s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, fontWeight: on ? FontWeight.w700 : FontWeight.w600, color: color)),
              ],
            ),
          ),
        ),
      );
    }

    final half = (sections.length + 1) ~/ 2;
    return Row(
      children: [
        Expanded(child: Row(children: [for (final s in sections.take(half)) tab(s)])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: centre),
        Expanded(child: Row(children: [for (final s in sections.skip(half)) tab(s)])),
      ],
    );
  }
}

/// The tabs inside the capsule. The home tab stays put on the left; the others share
/// the rest equally when their words fit, and scroll sideways (no loop) when they do not
/// — long labels ("Bibliothèque", "Медиатека") or a small phone (owner 2026-10-21).
class _Tabs extends StatefulWidget {
  const _Tabs({required this.section, required this.sections, required this.home, required this.onPick, this.onHoldHome});
  final VoidCallback? onHoldHome;
  final VaultSection section;
  final List<VaultSection> sections;
  final Widget? home;
  final ValueChanged<VaultSection> onPick;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  final _keys = <VaultSection, GlobalKey>{};

  @override
  void didUpdateWidget(_Tabs old) {
    super.didUpdateWidget(old);
    if (old.section != widget.section) _reveal();
  }

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  /// Bring the chosen tab into view when the row scrolls.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[widget.section]?.currentContext;
        if (ctx != null && mounted) {
          Scrollable.maybeOf(ctx)?.position.ensureVisible(ctx.findRenderObject()!,
              alignment: .5, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
        }
      });

  static const _style = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
  static const _pad = 16.0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onSurface;
    final homeOn = widget.sections.contains(VaultSection.home) && widget.home != null;
    final rest = widget.sections.where((s) => !(homeOn && s == VaultSection.home)).toList();
    final scale = MediaQuery.textScalerOf(context);
    // Measure in the font the tabs are drawn in.
    final base = DefaultTextStyle.of(context).style;

    Widget tab(VaultSection s, {double? width}) {
      final on = s == widget.section;
      final hold = s == VaultSection.home ? widget.onHoldHome : null;
      return Semantics(
        button: true,
        selected: on,
        label: sectionLabel(l, s),
        hint: hold == null ? null : l.holdToLock,
        child: GestureDetector(
          key: _keys.putIfAbsent(s, GlobalKey.new),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onPick(s),
          onLongPress: hold == null
              ? null
              : () {
                  HapticFeedback.heavyImpact();
                  hold();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: width,
            padding: width == null ? const EdgeInsets.symmetric(horizontal: _pad) : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: on ? primary.withValues(alpha: .14) : Colors.transparent,
              borderRadius: BorderRadius.circular((Ui.bar - 8) / 2),
            ),
            alignment: Alignment.center,
            child: s == VaultSection.home && widget.home != null
                ? KeyedSubtree(key: const ValueKey('home-tab'), child: widget.home!)
                : Text(
                    sectionLabel(l, s),
                    maxLines: 1,
                    softWrap: false,
                    style: _style.copyWith(
                      fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                      color: on ? primary : ink.withValues(alpha: .75),
                    ),
                  ),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, box) {
      final homeW = homeOn ? Ui.bar : 0.0;
      final room = box.maxWidth - homeW;
      final need = [
        for (final s in rest)
          (TextPainter(text: TextSpan(text: sectionLabel(l, s), style: base.merge(_style)), textDirection: TextDirection.ltr, textScaler: scale)
                    ..layout())
                  .width +
              _pad * 2,
      ];
      final total = need.fold<double>(0, (a, w) => a + w);
      final fits = total <= room;
      return Row(
        mainAxisSize: fits ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (homeOn) tab(VaultSection.home, width: homeW),
          SizedBox(
            width: fits ? total : room,
            child: fits
                // Everything fits: each tab gets room in proportion to its word, and a
                // finger sliding along picks as before.
                ? LayoutBuilder(builder: (context, b) {
                    VaultSection at(double x) {
                      var edge = 0.0;
                      for (final (i, w) in need.indexed) {
                        edge += w / total * b.maxWidth;
                        if (x < edge) return rest[i];
                      }
                      return rest.last;
                    }
                    return GestureDetector(
                      onHorizontalDragUpdate: (d) => widget.onPick(at(d.localPosition.dx)),
                      child: Row(children: [
                        for (final (i, s) in rest.indexed) Expanded(flex: (need[i] * 10).round(), child: tab(s)),
                      ]),
                    );
                  })
                // Too long: each tab as wide as its word, the row scrolls (no loop).
                : ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0, .9, 1],
                    ).createShader(r),
                    blendMode: BlendMode.dstIn,
                    child: ListView(
                      key: const ValueKey('tab-scroll'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(right: 12),
                      children: [for (final s in rest) tab(s)],
                    ),
                  ),
          ),
        ],
      );
    });
  }
}

/// The main action, floating above the lock (left thumb): one tap for notes and voice,
/// a small menu for the library and files.
class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.color, this.turns = 0});
  final IconData icon;
  /// The + turns into × by rotating an eighth of a turn, smoothly.
  final double turns;
  /// Voice: the record red with a white mic (theme.dart `recordRed`); otherwise glass,
  /// like the other round buttons (owner 2026-10-21), so the content shows through.
  final Color? color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = InkWell(
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
          child: Icon(icon, color: color != null ? Colors.white : Theme.of(context).colorScheme.onSurface, size: 28),
        ),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: color != null
          ? Material(color: color, shape: const CircleBorder(), elevation: 2, shadowColor: color!.withValues(alpha: .25), child: ink)
          : Glass(radius: Ui.primary / 2, child: Material(type: MaterialType.transparency, child: ink)),
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
      VaultSection.home => {},
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

/// What + offers, as a row (owner 2026-10-24, after looking at how other apps add):
/// on the overview every kind; in the library its two ways (the camera takes photos and
/// videos); elsewhere none, because + does that section's one thing straight away.
/// Empty: no row.
List<(AddWhat, IconData, String)> addRowWays(AppLocalizations l, VaultSection section,
    {required bool camera, required bool voice}) {
  final photos = (AddWhat.photos, Icons.photo_library_outlined, l.addRowPhotos);
  final cam = (AddWhat.photo, Icons.photo_camera_outlined, l.addRowCamera);
  return switch (section) {
    VaultSection.home => [
        photos,
        if (camera) cam,
        (AddWhat.note, Icons.edit_note_rounded, sectionLabel(l, VaultSection.note)),
        if (voice) (AddWhat.voice, Icons.mic_none_rounded, sectionLabel(l, VaultSection.audio)),
        (AddWhat.file, Icons.description_outlined, sectionLabel(l, VaultSection.file)),
      ],
    VaultSection.library => camera ? [photos, cam] : const [],
    _ => const [],
  };
}

/// The one thing + does at once where it offers no row.
AddWhat? addDirect(VaultSection section, {required bool camera}) => switch (section) {
      VaultSection.note => AddWhat.note,
      VaultSection.audio => AddWhat.voice,
      VaultSection.file => AddWhat.file,
      VaultSection.library when !camera => AddWhat.photos,
      _ => null,
    };

/// The + button's row: the page dims and the ways to add spread out sideways from the
/// button, centred just above it. Tap one, or keep the finger down from + and slide to
/// one and let go ([hovered] is the one under the finger, found with [AddColumn.wayAt]).
class AddRow extends StatefulWidget {
  const AddRow({
    super.key,
    required this.open,
    required this.ways,
    required this.bottom,
    required this.hovered,
    required this.onPick,
    required this.onClose,
    required this.onGone,
  });
  final bool open;
  final List<(AddWhat, IconData, String)> ways;
  /// The row's bottom above the screen's bottom edge.
  final double bottom;
  final AddWhat? hovered;
  final ValueChanged<AddWhat> onPick;
  final VoidCallback onClose;
  final VoidCallback onGone;

  /// Room each way takes in the row.
  static const width = 72.0;

  @override
  State<AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<AddRow> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    reverseDuration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void didUpdateWidget(AddRow old) {
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
    final dim = CurvedAnimation(parent: _c, curve: const Interval(0, .6, curve: Curves.easeOut));
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: w.onClose,
            // Denser than the column's veil: the labels sit over whatever is behind.
            child: FadeTransition(opacity: dim, child: ColoredBox(color: page.withValues(alpha: .92))),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: w.bottom,
          child: Center(
            child: Row(
              key: const ValueKey('add-row'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, (what, icon, label)) in w.ways.indexed)
                  AnimatedBuilder(
                    animation: _c,
                    builder: (context, child) {
                      // Each way slides out of the + (in the middle) to its place, the
                      // nearer ones first, with a small overshoot.
                      final start = (i - (n - 1) / 2).abs() * .06;
                      final t = Curves.easeOutBack.transform(
                          ((_c.value - start) / (1 - start)).clamp(0.0, 1.0));
                      final fromCentre = ((n - 1) / 2 - i) * AddRow.width;
                      return Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(fromCentre * (1 - t), 36 * (1 - t)),
                          child: Transform.scale(scale: .5 + .5 * t, child: child),
                        ),
                      );
                    },
                    child: addWayButton(context, what, icon, label, hovered: w.hovered == what, onTap: () => w.onPick(what)),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One way to add as a round button with its word under it, findable under a sliding
/// finger ([AddColumn.wayAt]). Used by [AddRow] and [AddFan].
Widget addWayButton(BuildContext context, AddWhat what, IconData icon, String label,
    {required bool hovered, required VoidCallback onTap}) {
  final page = Theme.of(context).scaffoldBackgroundColor;
  final ink = Theme.of(context).colorScheme.onSurface;
  return MetaData(
    metaData: what,
    behavior: HitTestBehavior.opaque,
    child: Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('add-${what.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: AddRow.width,
          child: AnimatedScale(
            scale: hovered ? 1.14 : 1,
            duration: const Duration(milliseconds: 120),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: Ui.bar,
                  height: Ui.bar,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered ? ink : Color.alphaBlend(ink.withValues(alpha: .1), page),
                    boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 3))],
                  ),
                  child: Icon(icon, size: 26, color: hovered ? page : ink),
                ),
                const SizedBox(height: 6),
                Text(label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The + in the middle: its ways fan out on a half circle around it, out to both sides
/// (owner 2026-10-24: a column rising from the middle looked heavy). Two ways sit level
/// on either side; five spread over the arc. Same tap / slide as the column.
class AddFan extends StatefulWidget {
  const AddFan({
    super.key,
    required this.open,
    required this.ways,
    required this.centre,
    required this.hovered,
    required this.onPick,
    required this.onClose,
    required this.onGone,
  });
  final bool open;
  final List<(AddWhat, IconData, String)> ways;
  /// The + button's centre, in this widget's box.
  final Offset centre;
  final AddWhat? hovered;
  final ValueChanged<AddWhat> onPick;
  final VoidCallback onClose;
  final VoidCallback onGone;

  @override
  State<AddFan> createState() => _AddFanState();
}

class _AddFanState extends State<AddFan> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void didUpdateWidget(AddFan old) {
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
    // The + sits in the bar, so even the lowest ways rise clear of it (with their words);
    // wider for more ways.
    // The arc turns round a point above the +, so it can open wide (words clear of each
    // other) and still sit above the bar.
    final radius = n <= 2 ? 100.0 : 142.0;
    final from = n <= 2 ? 160.0 : 170.0, to = 180 - from;
    final pivot = w.centre - Offset(0, n <= 2 ? 40 : 58);
    final dim = CurvedAnimation(parent: _c, curve: const Interval(0, .6, curve: Curves.easeOut));
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: w.onClose,
            child: FadeTransition(opacity: dim, child: ColoredBox(color: page.withValues(alpha: .92))),
          ),
        ),
        for (final (i, (what, icon, label)) in w.ways.indexed)
          AnimatedBuilder(
            key: ValueKey('fan-$i'),
            animation: _c,
            builder: (context, child) {
              final start = i * .05;
              final t = Curves.easeOutBack.transform(((_c.value - start) / (1 - start)).clamp(0.0, 1.0));
              final deg = n == 1 ? 90.0 : from - (from - to) * i / (n - 1);
              // Out along its own ray, turning a little as it goes.
              final a = (deg + (1 - t) * 20) * math.pi / 180;
              // From the + itself out to its place on the arc.
              final x = w.centre.dx + (pivot.dx + radius * math.cos(a) - w.centre.dx) * t;
              final y = w.centre.dy + (pivot.dy - radius * math.sin(a) - w.centre.dy) * t;
              return Positioned(
                left: x - AddRow.width / 2,
                top: y - Ui.bar / 2,
                child: Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.scale(scale: .5 + .5 * t, alignment: Alignment.topCenter, child: child),
                ),
              );
            },
            child: addWayButton(context, what, icon, label, hovered: w.hovered == what, onTap: () => w.onPick(what)),
          ),
      ],
    );
  }
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
  static AddWhat? wayAt(Offset at) {
    // Whatever row lies under the point, whatever the scroll and spacing (each row is
    // tagged with its way, across the whole width).
    final result = HitTestResult();
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return null;
    WidgetsBinding.instance.hitTestInView(result, at, view.viewId);
    for (final e in result.path) {
      final target = e.target;
      if (target is RenderMetaData && target.metaData is AddWhat) return target.metaData as AddWhat;
    }
    return null;
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
  )..forward().whenComplete(_nudge);

  /// The first few openings, the column dips a little and springs back: it can be dragged.
  static const _hintPref = 'add-column-hint';
  Future<void> _nudge() async {
    final shown = int.tryParse(Prefs.read(_hintPref) ?? '') ?? 0;
    if (shown >= 3 || !mounted || !widget.scroll.hasClients) return;
    Prefs.write(_hintPref, '${shown + 1}');
    await widget.scroll.animateTo(AddColumn.row * .7, duration: const Duration(milliseconds: 360), curve: Curves.easeOut);
    if (!mounted || !widget.scroll.hasClients) return;
    await widget.scroll.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeOutBack);
  }

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
            width: MediaQuery.sizeOf(context).width - w.side - 10,
            height: AddColumn.row * n + _fade,
            // Rows may spill sideways and below (the pop from +), never above: a row half
            // past the top drew sharp outside the fade and cut by it inside, a dark band
            // across it (owner 2026-10-21).
            child: ClipRect(
              clipper: const _NoSpillAbove(),
              child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // Fading at the top says there is more above; at the bottom, ways slip
                // away under the button.
                colors: const [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                stops: [0, 28 / r.height, 1 - _fade / r.height, 1],
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
                itemBuilder: (context, i) {
                  final (what, icon, label) = w.ways[i % n];
                  final round = i ~/ n;
                  final pop = _Pop(
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
                  final row = MetaData(metaData: what, behavior: HitTestBehavior.opaque, child: pop);
                  if (round == 0 || i % n != 0) return row;
                  // Where the loop starts again: a thin line with room above and below,
                  // nothing else (owner 2026-10-21: no ↻, no dimmed repeats).
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [row, _LoopMark(key: const ValueKey('add-loop'), right: w.right)],
                  );
                },
              ),
            ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Clips only at the top edge.
class _NoSpillAbove extends CustomClipper<Rect> {
  const _NoSpillAbove();
  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, 0, size.width * 2, size.height * 4);
  @override
  bool shouldReclip(_NoSpillAbove old) => false;
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

/// Where the add column starts its loop again: a short faint line, room on both sides.
class _LoopMark extends StatelessWidget {
  const _LoopMark({super.key, required this.right});
  final bool right;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 26,
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 96,
            height: 1.5,
            margin: EdgeInsets.only(left: right ? 0 : 6, right: right ? 6 : 0, top: 10),
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .22),
          ),
        ),
      );
}

/// Reading, or choosing among many, opens a page: the content sits at eye level, not
/// at the bottom edge (owner 2026-10-21; docs/ui.md: read → page, a few choices → a menu
/// at the row, actions → a bottom sheet).
Future<T?> pushPage<T>(BuildContext context, {required String title, required WidgetBuilder builder}) =>
    Navigator.of(context).push<T>(MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(top: false, child: builder(context)),
      ),
    ));

/// Short content in a card in the middle of the screen, at eye level, the vault dimmed
/// and blurred behind (owner 2026-10-21: a page for a few lines felt empty, a sheet at
/// the bottom too far from the eye). A tap outside or × closes. Long scrolling lists
/// stay pages ([pushPage]); actions for the thumb stay bottom sheets.
Future<T?> showCard<T>(BuildContext context, {String? title, required WidgetBuilder builder}) => showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context).close,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) {
        final page = Theme.of(context).scaffoldBackgroundColor;
        final size = MediaQuery.sizeOf(context);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                  child: ColoredBox(color: page.withValues(alpha: .55)),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 440, maxHeight: size.height * .8),
                  child: Material(
                    key: const ValueKey('card'),
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(26),
                    clipBehavior: Clip.antiAlias,
                    elevation: 12,
                    shadowColor: Colors.black45,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 14, 10, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(title ?? '',
                                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.2)),
                              ),
                              IconButton(
                                key: const ValueKey('card-close'),
                                tooltip: AppLocalizations.of(context).close,
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                        Flexible(child: builder(context)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: .95, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
      ),
    );
