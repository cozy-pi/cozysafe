
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';
import 'readable.dart';
import '../vault_kind.dart';

/// The four sections of a vault, picked in the bottom capsule (docs/ui.md, vault bar;
/// docs/naming.md). A section shows items of some kinds: Library shows photos and
/// videos, the others one kind each.
/// [home] is the overview of everything (owner 2026-10-21); it holds no items itself.
enum VaultSection { home, note, library, audio, file }

/// The sections this device offers: voice memos need a phone's microphone. Top secret
/// has no Library (ADR 0005: no picture is shown there); its photos and videos are rows
/// among the files.
List<VaultSection> vaultSections() => [
      VaultSection.home,
      if (!RunKind.topSecret) VaultSection.library,
      VaultSection.file,
      VaultSection.note,
      if (Device.iOS || Device.android || debugVoice) VaultSection.audio,
    ];

/// The sections with a tab in the bar: all but Voice (owner 2026-10-24: overview,
/// library, +, files, notes). Voice memos stay, reached from the overview and the +.
List<VaultSection> barSections(List<VaultSection> sections) =>
    [for (final s in sections) if (s != VaultSection.audio) s];

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

/// Where the main action sits (Settings): in the middle of the bar (default, owner
/// 2026-10-24: an edge is easy to hit by mistake), or floating on the left or right. Its ways stack up the edge it is
/// on; from the middle they fan out to both sides.
enum ActionSide { left, right, center }

const actionSidePref = 'action-side';
ActionSide actionSide() => switch (Prefs.read(actionSidePref)) {
      'right' => ActionSide.right,
      'left' => ActionSide.left,
      _ => ActionSide.center,
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
double actionLift() =>
    actionSide() == ActionSide.center ? Ui.edge + (Ui.bar + 8 - centrePlusSize) / 2 : Ui.actionLift;

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

/// Drawn by [PrivateThumb] (widgets/private_thumb.dart).

/// The section the vault opens on: the last one used (0.1.6 kept it as `vault-kind`).
VaultSection startSection() {
  final saved = Prefs.read(_sectionPref) ?? Prefs.read('vault-kind');
  return vaultSections().where((k) => k.name == saved).firstOrNull ?? VaultSection.home;
}

/// A section's icon, as in the bar (and the wide window's sidebar).
IconData sectionIcon(VaultSection s) => switch (s) {
      VaultSection.home => Icons.home_rounded,
      VaultSection.note => Icons.edit_note_rounded,
      VaultSection.library => Icons.photo_library_rounded,
      VaultSection.audio => Icons.mic_none_rounded,
      VaultSection.file => Icons.folder_rounded,
    };

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
    this.tabsKey,
  });

  /// On the capsule of tabs (not the lock beside it): the quick tour points at it.
  final Key? tabsKey;

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
      // The vault's badge (the overview, hold to lock) is the first slot of the bar,
      // like any other section (owner 2026-10-24: a separate ringed button looked odd).
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (lock case final lock?) ...[lock, const SizedBox(width: 4)],
          Expanded(
            child: Glass(
              key: tabsKey,
              radius: Ui.bar / 2,
              child: SizedBox(
                height: Ui.bar + 8,
                child: _CentreTabs(
                  section: section,
                  sections: [
                    for (final s in sections.length < 2 ? const <VaultSection>[] : sections)
                      if (s != VaultSection.home || home != null) s,
                  ],
                  home: home,
                  onHoldHome: onHoldHome,
                  onPick: _pick,
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
            key: tabsKey,
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

/// The bar with the + in its middle: each section an icon (names for screen readers),
/// in equal slots, half on each side, so the + stays in the centre whatever the count.
class _CentreTabs extends StatelessWidget {
  const _CentreTabs({
    required this.section,
    required this.sections,
    required this.onPick,
    required this.centre,
    this.home,
    this.onHoldHome,
  });
  final VaultSection section;
  final List<VaultSection> sections;
  final ValueChanged<VaultSection> onPick;
  final Widget centre;
  final Widget? home;
  final VoidCallback? onHoldHome;

  static IconData _icon(VaultSection s) => switch (s) {
        VaultSection.home => Icons.home_rounded,
        VaultSection.note => Icons.edit_note_rounded,
        VaultSection.library => Icons.photo_library_rounded,
        VaultSection.audio => Icons.mic_none_rounded,
        VaultSection.file => Icons.folder_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget tab(VaultSection s) {
      final on = s == section;
      return Expanded(
        child: Tooltip(
          message: sectionLabel(l, s),
          child: Semantics(
            button: true,
            selected: on,
            label: sectionLabel(l, s),
            excludeSemantics: true,
            hint: s == VaultSection.home && onHoldHome != null ? l.holdToLock : null,
            child: GestureDetector(
              key: ValueKey(s == VaultSection.home ? 'home-tab' : 'tab-${s.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onPick(s),
              onLongPress: s != VaultSection.home || onHoldHome == null
                  ? null
                  : () {
                      HapticFeedback.heavyImpact();
                      onHoldHome!();
                    },
              child: Center(
                // A small pop as it becomes the one on show (the pill slides under it).
                child: AnimatedScale(
                  scale: on ? 1.08 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: s == VaultSection.home && home != null
                      ? home!
                      : Icon(_icon(s), size: 28, color: on ? primary : ink.withValues(alpha: .7)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Every slot the same width, the + one of them (owner 2026-10-24: with the home
    // badge in the bar an empty slot was left on one side).
    final at = centrePlusSlot(sections);
    final slots = sections.length + 1;
    return LayoutBuilder(builder: (context, box) {
      // Where the lit pill sits: under the section on show, sliding from one to the
      // next (owner 2026-10-24: "like Instagram").
      final slotW = box.maxWidth / slots;
      final i = sections.indexOf(section);
      final double? pillX = i < 0 ? null : (i < at ? i : i + 1) * slotW;
      const pillW = 52.0, pillH = Ui.bar - 12;
      return Stack(
        alignment: Alignment.center,
        children: [
          if (pillX != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              left: pillX + (slotW - pillW) / 2,
              top: (box.maxHeight - pillH) / 2,
              width: pillW,
              height: pillH,
              child: DecoratedBox(
                key: const ValueKey('tab-pill'),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(pillH / 2),
                ),
              ),
            ),
          Row(
            children: [
              for (final s in sections.take(at)) tab(s),
              Expanded(child: Center(child: centre)),
              for (final s in sections.skip(at)) tab(s),
            ],
          ),
        ],
      );
    });
  }
}

/// The + in the middle of the bar: a little smaller than the bar's other buttons.
const double centrePlusSize = 46;

/// Which slot of the middle bar holds the + (the sections fill the others): the middle
/// one, so overview and library sit left of it, files and notes right (owner 2026-10-24).
int centrePlusSlot(List<VaultSection> sections) => (sections.length + 1) ~/ 2;

/// The + button's centre across the middle bar, as a share of the bar's width.
double centrePlusShare(List<VaultSection> sections) =>
    (centrePlusSlot(sections) + .5) / (sections.length + 1);

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

  static const _style = TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w700);
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

    // `lit`: the tab draws its own pill (scrolling row); otherwise one pill slides
    // under the tabs.
    Widget tab(VaultSection s, {double? width, bool lit = true}) {
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
              color: on && lit ? primary.withValues(alpha: .14) : Colors.transparent,
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
      // Where the one pill sits (all tabs fit): it slides to the tab tapped, as in
      // Instagram's bar (owner 2026-10-24).
      Rect? pill;
      if (fits) {
        if (homeOn && widget.section == VaultSection.home) {
          pill = Rect.fromLTWH(0, 0, homeW, box.maxHeight);
        } else {
          final i = rest.indexOf(widget.section);
          if (i >= 0) {
            final x = need.take(i).fold<double>(0, (a, w) => a + w);
            pill = Rect.fromLTWH(homeW + x, 0, need[i], box.maxHeight);
          }
        }
      }
      final row = Row(
        mainAxisSize: fits ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (homeOn) tab(VaultSection.home, width: homeW, lit: !fits),
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
                        for (final (i, s) in rest.indexed)
                          Expanded(flex: (need[i] * 10).round(), child: tab(s, lit: false)),
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
      if (pill == null) return row;
      return Stack(
        children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: pill.left,
            top: 0,
            width: pill.width,
            height: pill.height,
            child: DecoratedBox(
              key: const ValueKey('tab-pill'),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular((Ui.bar - 8) / 2),
              ),
            ),
          ),
          row,
        ],
      );
    });
  }
}

/// The main action, floating above the lock (left thumb): one tap for notes and voice,
/// a small menu for the library and files.
class ActionButton extends StatefulWidget {
  const ActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.turns = 0,
    this.solid = false,
    this.size = Ui.primary,
  });
  /// In the middle of the bar: filled with the ink (black or white), smaller than the
  /// bar is tall, so it stands out as the one action (owner 2026-10-24).
  final bool solid;
  final double size;
  final IconData icon;
  /// The + turns into × by rotating an eighth of a turn, smoothly.
  final double turns;
  /// Voice: the record red with a white mic (theme.dart `recordRed`); otherwise glass,
  /// like the other round buttons (owner 2026-10-21), so the content shows through.
  final Color? color;
  final String tooltip;
  final VoidCallback onTap;

  /// A swipe passing over + is not a tap (owner 2026-10-24: with + on the left, swiping
  /// back from the edge kept opening it). A tap stays put (less than [stillPx] of
  /// travel); a brief touch that moved at all ([brushPx], under [minPress]) is a finger
  /// passing over; and none starts at the screen's edge, where the back swipe begins.
  static const stillPx = 8.0;
  static const brushPx = 3.0;
  static const minPress = Duration(milliseconds: 40);
  static const edgePx = 16.0;

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  Offset? _downAt;
  Duration _downTime = Duration.zero;
  Duration _press = Duration.zero;
  double _travel = 0;

  bool get _meantTap {
    final at = _downAt;
    if (at == null) return false;
    final width = MediaQuery.sizeOf(context).width;
    if (at.dx < ActionButton.edgePx || at.dx > width - ActionButton.edgePx) return false;
    if (_travel >= ActionButton.stillPx) return false;
    return !(_press < ActionButton.minPress && _travel >= ActionButton.brushPx);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final ink = InkWell(
      key: const ValueKey('vault-action'),
      customBorder: const CircleBorder(),
      onTap: () {
        if (!_meantTap) return;
        HapticFeedback.mediumImpact();
        w.onTap();
      },
      child: SizedBox.square(
        dimension: w.size,
        child: AnimatedRotation(
          turns: w.turns,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          child: Icon(w.icon,
              color: w.color != null
                  ? Colors.white
                  : w.solid
                      ? Theme.of(context).colorScheme.surface
                      : Theme.of(context).colorScheme.onSurface,
              size: 28),
        ),
      ),
    );
    final fill = w.color ?? (w.solid ? Theme.of(context).colorScheme.onSurface : null);
    final button = Tooltip(
      message: w.tooltip,
      child: fill != null
          ? Material(color: fill, shape: const CircleBorder(), elevation: 3, shadowColor: fill.withValues(alpha: .3), child: ink)
          : Glass(radius: w.size / 2, child: Material(type: MaterialType.transparency, child: ink)),
    );
    // Where the finger went down, how far it moved and how long it rested (a tap must
    // stay put); the drag up from + (in vault_home) is not affected.
    return Listener(
      onPointerDown: (e) {
        _downAt = e.position;
        _downTime = e.timeStamp;
        _travel = 0;
      },
      onPointerMove: (e) {
        final at = _downAt;
        if (at != null && (e.position - at).distance > _travel) _travel = (e.position - at).distance;
      },
      // Before the tap is decided (the arena closes after every listener has the up).
      onPointerUp: (e) => _press = e.timeStamp - _downTime,
      child: button,
    );
  }
}

/// The ways to add something to a vault.
enum AddWhat { note, photo, video, photos, voice, file }

/// Every way to add, in the fixed order (camera and voice only where the device has them).
List<(AddWhat, IconData, String)> addWays(AppLocalizations l, {required bool camera, required bool voice}) => [
      // Top secret takes nothing from the photo library and records no video (ADR 0005).
      if (!RunKind.topSecret) (AddWhat.photos, Icons.photo_library_rounded, l.addFromDevice),
      if (camera && !RunKind.topSecret) (AddWhat.video, Icons.videocam_rounded, l.recordVideo),
      if (camera) (AddWhat.photo, Icons.photo_camera_rounded, l.takePhoto),
      (AddWhat.note, Icons.edit_note_rounded, l.newNote),
      if (voice) (AddWhat.voice, Icons.mic_none_rounded, l.startRecording),
      (AddWhat.file, Icons.folder_rounded, l.addFiles),
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

/// What + offers: every kind of item, wherever you are (owner 2026-10-24: Voice has no tab
/// in the bar, so + is the way to it; one way per section felt like a lock-in). In the
/// owner's order (2026-10-24): add photos, record video, take photo, note, voice, then files.
List<(AddWhat, IconData, String)> addRowWays(AppLocalizations l, VaultSection section,
        {required bool camera, required bool voice}) =>
    [
      if (!RunKind.topSecret) (AddWhat.photos, Icons.photo_library_rounded, l.addRowAddPhotos),
      if (camera && !RunKind.topSecret) (AddWhat.video, Icons.videocam_rounded, l.recordVideo),
      if (camera) (AddWhat.photo, Icons.photo_camera_rounded, l.takePhoto),
      (AddWhat.note, Icons.edit_note_rounded, sectionLabel(l, VaultSection.note)),
      if (voice) (AddWhat.voice, Icons.mic_none_rounded, sectionLabel(l, VaultSection.audio)),
      (AddWhat.file, Icons.folder_rounded, sectionLabel(l, VaultSection.file)),
    ];

/// What + offers on the overview (owner 2026-10-31: the long list was slow to use and had
/// to be swiped): the two quick ones, camera and voice memo. Everything else is added from
/// its own tab ([addDirect]); an empty vault's tiles still show every way ([addWays]).
List<(AddWhat, IconData, String)> quickWays(AppLocalizations l, {required bool camera, required bool voice}) => [
      if (camera) (AddWhat.photo, Icons.photo_camera_rounded, l.takePhoto),
      if (voice) (AddWhat.voice, Icons.mic_none_rounded, l.startRecording),
    ];

/// In a tab, + does that tab's one thing at once (owner 2026-10-31): a new note, files, the
/// photo library, a voice memo. On the overview it offers [quickWays].
AddWhat? addDirect(VaultSection section, {required bool camera}) => switch (section) {
      VaultSection.home => null,
      VaultSection.note => AddWhat.note,
      VaultSection.file => AddWhat.file,
      VaultSection.library => AddWhat.photos,
      VaultSection.audio => AddWhat.voice,
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
    this.centreX,
  });
  final bool open;
  final List<(AddWhat, IconData, String)> ways;
  /// The row's bottom above the screen's bottom edge.
  final double bottom;
  /// Centred over this x (the + button's), kept on screen; the screen's middle if none.
  final double? centreX;
  final AddWhat? hovered;
  final ValueChanged<AddWhat> onPick;
  final VoidCallback onClose;
  final VoidCallback onGone;

  /// Room each way takes in the row.
  static const width = 80.0;
  /// The narrowest a way gets so that all of them fit side by side.
  static const minWidth = 52.0;

  @override
  State<AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<AddRow> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    reverseDuration: const Duration(milliseconds: 200),
  )..forward();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _hint();
  }

  /// Ways past the right edge (a very narrow screen): the row slides a little on opening
  /// and back, so the person sees it scrolls (owner 2026-10-25: hidden ways went unseen).
  Future<void> _hint() async {
    await Future<void>.delayed(const Duration(milliseconds: 420));
    if (!mounted || !_scroll.hasClients || _scroll.position.maxScrollExtent <= 0) return;
    await _scroll.animateTo(48, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
    if (!mounted || !_scroll.hasClients) return;
    await _scroll.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeOutBack);
  }

  @override
  void didUpdateWidget(AddRow old) {
    super.didUpdateWidget(old);
    if (old.open && !widget.open) _c.reverse().whenComplete(() => widget.onGone());
    if (!old.open && widget.open) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    final w = widget;
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
          // One row, side by side (owner 2026-10-24: two rows looked uneven). The ways
          // share the width so all of them show (owner 2026-10-25: the last ones hid off
          // the right edge and people did not know they were there); only a screen too
          // narrow for even the smallest buttons scrolls.
          child: LayoutBuilder(
            builder: (context, box) {
              final each = ((box.maxWidth - 24) / w.ways.length).clamp(AddRow.minWidth, AddRow.width);
              final overflows = each * w.ways.length + 24 > box.maxWidth;
              final row = SingleChildScrollView(
              key: const ValueKey('add-row'),
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth - 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, (what, icon, label)) in w.ways.indexed)
                      AnimatedBuilder(
                        animation: _c,
                        builder: (context, child) {
                          // Each way rises out of the bar in turn, with a small overshoot.
                          final start = i * .05;
                          final t = Curves.easeOutBack.transform(((_c.value - start) / (1 - start)).clamp(0.0, 1.0));
                          return Opacity(
                            opacity: t.clamp(0.0, 1.0),
                            child: Transform.translate(
                              offset: Offset(0, 36 * (1 - t)),
                              child: Transform.scale(scale: .5 + .5 * t, child: child),
                            ),
                          );
                        },
                        child: addWayButton(context, what, icon, label,
                            hovered: w.hovered == what, onTap: () => w.onPick(what), width: each),
                      ),
                  ],
                ),
              ),
            );
              // More to the right: the right edge fades, the last way half shows.
              return !overflows
                  ? row
                  : ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (r) => const LinearGradient(
                        colors: [Colors.white, Colors.white, Colors.transparent],
                        stops: [0, .85, 1],
                      ).createShader(r),
                      child: row,
                    );
            },
          ),
        ),
      ],
    );
  }
}

/// What each way to add does, in one line, for [AddCard].
String addWayNote(AppLocalizations l, AddWhat what) => switch (what) {
      AddWhat.photos => l.addNotePhotos,
      AddWhat.video => l.addNoteVideo,
      AddWhat.photo => l.addNotePhoto,
      AddWhat.note => l.addNoteNote,
      AddWhat.voice => l.addNoteVoice,
      AddWhat.file => l.addNoteFile,
    };

/// Opened by + with the quick row (owner 2026-10-27: "a page to choose and understand",
/// the quick buttons stay): every way to add with its full name and a line on what it
/// does, in a card at eye level above the row. Tapping a line is the same as its button.
class AddCard extends StatefulWidget {
  const AddCard({super.key, required this.open, required this.ways, required this.onPick, this.hovered, this.drop = false});
  final bool open;
  /// Hangs from the top of its space (a menu under a computer's Add button), instead of
  /// standing on its bottom.
  final bool drop;
  /// The line under a finger sliding from + (each line is tagged for [AddColumn.wayAt]).
  final AddWhat? hovered;
  /// The ways with their full names ([addWays]).
  final List<(AddWhat, IconData, String)> ways;
  final ValueChanged<AddWhat> onPick;

  @override
  State<AddCard> createState() => _AddCardState();
}

class _AddCardState extends State<AddCard> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 160),
  )..forward();

  @override
  void didUpdateWidget(AddCard old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) widget.open ? _c.forward() : _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return Align(
      alignment: widget.drop ? Alignment.topLeft : Alignment.bottomCenter,
      child: FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: Offset(0, widget.drop ? -.04 : .04), end: Offset.zero).animate(a),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Material(
              key: const ValueKey('add-card'),
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(26),
              clipBehavior: Clip.antiAlias,
              elevation: 12,
              shadowColor: Colors.black38,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
                    child: Text(l.addToVault,
                        style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w800, letterSpacing: -.2)),
                  ),
                  for (final (what, icon, label) in widget.ways)
                    MetaData(
                      metaData: what,
                      behavior: HitTestBehavior.opaque,
                      child: InkWell(
                      key: ValueKey('add-card-${what.name}'),
                      onTap: () => widget.onPick(what),
                      child: Container(
                        color: widget.hovered == what ? ink.withValues(alpha: .08) : null,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                        child: Row(children: [
                          Container(
                            width: Ui.tap,
                            height: Ui.tap,
                            decoration: BoxDecoration(color: ink.withValues(alpha: .07), shape: BoxShape.circle),
                            child: Icon(icon, color: ink, size: 24),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(label, style: const TextStyle(fontSize: CsType.callout, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(addWayNote(l, what), style: TextStyle(fontSize: CsType.footnote, height: 1.3, color: c.muted)),
                            ]),
                          ),
                        ]),
                      ),
                    ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// + on an edge (owner 2026-10-27: the column beside the card looked broken): the card
/// alone, just above +, the page dimmed behind; its lines are the quick buttons, and a
/// finger sliding up from + picks one as on the column.
class AddCardOverlay extends StatelessWidget {
  const AddCardOverlay({
    super.key,
    required this.open,
    required this.ways,
    required this.bottom,
    required this.hovered,
    required this.onPick,
    required this.onClose,
    required this.onGone,
    this.dropFrom,
  });
  final bool open;
  final List<(AddWhat, IconData, String)> ways;
  /// The card's bottom above the screen's bottom edge.
  final double bottom;
  /// A computer's window: the card drops from this point (just under the sidebar's Add
  /// button, owner 2026-10-28: not at the bottom of the window), over a light dim.
  final Offset? dropFrom;
  final AddWhat? hovered;
  final ValueChanged<AddWhat> onPick;
  final VoidCallback onClose;
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: open ? 1 : 0),
      duration: Duration(milliseconds: open ? 260 : 160),
      onEnd: () {
        if (!open) onGone();
      },
      builder: (context, t, child) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: ColoredBox(color: page.withValues(alpha: (dropFrom != null ? .45 : .92) * t)),
          ),
        ),
        child!,
      ]),
      child: dropFrom != null
          ? Positioned(
              left: dropFrom!.dx,
              top: dropFrom!.dy,
              bottom: bottom,
              width: 440,
              child: AddCard(open: open, ways: ways, onPick: onPick, hovered: hovered, drop: true),
            )
          : Positioned(
              left: 16,
              right: 16,
              top: MediaQuery.paddingOf(context).top + 12,
              bottom: bottom,
              child: AddCard(open: open, ways: ways, onPick: onPick, hovered: hovered),
            ),
    );
  }
}

/// One way to add as a round button, findable under a sliding finger ([AddColumn.wayAt]).
/// Used by [AddRow]. No word under it (owner 2026-10-27): the card above says what each
/// does; the word stays for screen readers.
Widget addWayButton(BuildContext context, AddWhat what, IconData icon, String label,
    {required bool hovered, required VoidCallback onTap, double width = AddRow.width}) {
  final circle = (width - 4).clamp(44.0, Ui.bar);
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
          width: width,
          child: AnimatedScale(
            scale: hovered ? 1.14 : 1,
            duration: const Duration(milliseconds: 120),
            child: Center(
              child: Container(
                width: circle,
                height: circle,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hovered ? ink : Color.alphaBlend(ink.withValues(alpha: .1), page),
                  boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 3))],
                ),
                child: Icon(icon, size: 26, color: hovered ? page : ink),
              ),
            ),
          ),
        ),
      ),
    ),
  );
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
    if (widget.ways.length <= 6) return; // nothing to roll
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
                // No rolling loop (with two ways the loop showed a repeat and slid one
                // under the ×). Every way is offered now (six), more than a small screen
                // holds beside the button: the column scrolls (owner 2026-10-25).
                itemCount: n,
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
    final text = Text(label, style: TextStyle(fontSize: CsType.body, fontWeight: near ? FontWeight.w700 : FontWeight.w600));
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
                        style: const TextStyle(fontSize: CsType.subhead, fontWeight: FontWeight.w600, height: 1.2)),
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
/// Like every page, it stays under the lock screen (lib/lock_resume.dart).
/// The title bar of a page opened from another: on an iPhone the iPhone's own, the
/// title centred, 17 semibold, beside the "‹" back (owner 2026-10-27).
AppBar pageBar(BuildContext context, String title) => AppBar(title: Text(title));

/// [grouped]: a page of grouped rows (Settings-like), on the phone's grey (see [groupedPage]).
Future<T?> pushPage<T>(BuildContext context, {required String title, bool grouped = false, required WidgetBuilder builder}) =>
    Navigator.of(context).push<T>(MaterialPageRoute(
      builder: (context) {
        Widget page(BuildContext context) => Readable(child: Scaffold(
              appBar: pageBar(context, title),
              body: SafeArea(top: false, child: builder(context)),
            ));
        return grouped ? groupedPage(context, Builder(builder: page)) : page(context);
      },
    ));

/// Short content in a card in the middle of the screen, at eye level, the vault dimmed
/// and blurred behind (owner 2026-10-21: a page for a few lines felt empty, a sheet at
/// the bottom too far from the eye). A tap outside closes; no × on top (owner 2026-10-25:
/// every button within the thumb's reach): a card without buttons of its own sets
/// [closeButton] for a Close at its bottom. Long scrolling lists stay pages ([pushPage]);
/// actions for the thumb stay bottom sheets.
Future<T?> showCard<T>(BuildContext context, {String? title, bool closeButton = false, required WidgetBuilder builder}) =>
    showGeneralDialog<T>(
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
                          padding: const EdgeInsets.fromLTRB(22, 20, 22, 10),
                          child: Text(title ?? '',
                              style: const TextStyle(fontSize: CsType.title3, fontWeight: FontWeight.w800, letterSpacing: -.2)),
                        ),
                        Flexible(child: builder(context)),
                        if (closeButton)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                            child: OutlinedButton(
                              key: const ValueKey('card-close'),
                              onPressed: () => Navigator.of(context).pop(),
                              style: OutlinedButton.styleFrom(minimumSize: const Size(0, Ui.circle), shape: const StadiumBorder()),
                              child: Text(AppLocalizations.of(context).close),
                            ),
                          ),
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
