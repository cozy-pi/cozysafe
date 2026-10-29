import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Colours that Material's ColorScheme has no slot for. Values match the
/// approved mockup (one design, light and dark only).
/// RED FOR RECORDING (owner 2026-10-20, replaces "recording is not red"): the voice button,
/// the video shutter and the running timers are the system red people know from every
/// phone, so it is obvious what records. Taking a photo stays ink (white/black), as in the
/// phone's own camera. iOS system red; a touch lighter in dark mode.
Color recordRed(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);

@immutable
class CsColors extends ThemeExtension<CsColors> {
  const CsColors({
    required this.muted,
    required this.soft,
    required this.border,
    required this.warnBg,
    required this.warnInk,
    required this.dock,
  });

  final Color muted;
  final Color soft;
  final Color border;
  final Color warnBg;
  final Color warnInk;
  /// The add dock at the bottom of a vault: the vault's colour, deepened.
  final Color dock;

  static CsColors of(BuildContext context) =>
      Theme.of(context).extension<CsColors>()!;

  @override
  CsColors copyWith({
    Color? muted,
    Color? soft,
    Color? border,
    Color? warnBg,
    Color? warnInk,
    Color? dock,
  }) =>
      CsColors(
        muted: muted ?? this.muted,
        soft: soft ?? this.soft,
        border: border ?? this.border,
        warnBg: warnBg ?? this.warnBg,
        warnInk: warnInk ?? this.warnInk,
        dock: dock ?? this.dock,
      );

  @override
  CsColors lerp(ThemeExtension<CsColors>? other, double t) {
    if (other is! CsColors) return this;
    return CsColors(
      muted: Color.lerp(muted, other.muted, t)!,
      soft: Color.lerp(soft, other.soft, t)!,
      border: Color.lerp(border, other.border, t)!,
      warnBg: Color.lerp(warnBg, other.warnBg, t)!,
      warnInk: Color.lerp(warnInk, other.warnInk, t)!,
      dock: Color.lerp(dock, other.dock, t)!,
    );
  }
}

/// Brand colours that stay the same in light and dark (design B2, docs/ui.md).
abstract final class Brand {
  static const green = Color(0xFF165B4C);
  static const deep = Color(0xFF0F3D33);
  static const night = Color(0xFF0B2B24);
  static const gold = Color(0xFFF3D08E);
  static const goldInk = Color(0xFF0F3D33);
  /// The add dock, identical on the lock screen and inside the vault.
  static const dock = Color(0xFF0A2A23);
}

/// The open vault's colour, or null while locked. The whole app takes it (design B,
/// docs/ui.md): set by the vault screen, cleared when it goes.
final vaultTint = ValueNotifier<Color?>(null);

/// WCAG contrast ratio between two colours (1 to 21).
double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

Color _mix(Color c, double amount, Color base) => Color.lerp(base, c, amount)!;

/// Move [c] toward [to] until it reads at [ratio] on every one of [bgs].
Color _readable(Color c, Color to, List<Color> bgs, double ratio) {
  var x = c;
  for (var i = 0; i < 40 && bgs.any((b) => contrast(x, b) < ratio); i++) {
    x = Color.lerp(x, to, .1)!;
  }
  return x;
}

/// [c] darkened just enough for white text on it (the Settings vault card).
Color deepForWhite(Color c) => _readable(c, const Color(0xFF000000), [const Color(0xFFFFFFFF)], 4.5);

/// Design B: the whole screen in the vault's colour, content on neutral cards. Light:
/// the colour mixed pale, dark text. Dark: the colour deepened, light text. Every
/// text colour is checked for 4.5:1 against what it sits on (test/theme_test.dart).
class VaultPalette {
  VaultPalette(Color c, Brightness brightness) : dark = brightness == Brightness.dark {
    const white = Color(0xFFFFFFFF), black = Color(0xFF000000), night = Color(0xFF141817);
    if (dark) {
      bg = _mix(c, .62, black);
      surface = _mix(c, .14, night);
      ink = const Color(0xFFEEF0EF);
      muted = _readable(const Color(0xFFA3ABA7), white, [surface, bg], 4.5);
      accent = _readable(_mix(c, .6, white), white, [surface], 4.5);
      onAccent = const Color(0xFF0B0E0D);
      dock = _mix(c, .42, black);
      soft = _mix(c, .26, night);
      border = _mix(c, .34, night);
    } else {
      bg = _mix(c, .30, white);
      surface = white;
      ink = const Color(0xFF16191B);
      muted = _readable(const Color(0xFF5C6369), black, [bg, surface], 4.5);
      accent = _readable(c, black, [white], 4.5);
      onAccent = white;
      dock = _mix(c, .82, black);
      soft = _mix(c, .14, white);
      border = _mix(c, .32, white);
    }
  }

  final bool dark;
  late final Color bg, surface, ink, muted, accent, onAccent, dock, soft, border;
}

/// Text sizes by role, the iPhone's own scale (Apple's Human Interface Guidelines,
/// default size). New text takes one of these, not a size of its own.
abstract final class CsType {
  static const largeTitle = 34.0;
  static const title1 = 28.0;
  static const title2 = 22.0;
  static const title3 = 20.0;
  /// Bold or semibold 17: a page title in the bar, a heading.
  static const headline = 17.0;
  /// A row's name and value, running text.
  static const body = 17.0;
  static const callout = 16.0;
  static const subhead = 15.0;
  /// The line under a group, a note.
  static const footnote = 13.0;
  static const caption1 = 12.0;
  static const caption2 = 11.0;
}

/// The big title on the left for a top page (Settings), on every platform.
TextStyle? largeTitle(BuildContext context) =>
    Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: CsType.title3, fontWeight: FontWeight.w700);

/// The phone's grouped list in light mode: a pale grey page and the groups on white, so
/// each group stands out as a card. Dark mode is already black with grey groups.
Widget groupedPage(BuildContext context, Widget child) {
  final t = Theme.of(context);
  if (t.brightness == Brightness.dark) return child;
  final grey = t.cardColor;
  return Theme(
    data: t.copyWith(
      scaffoldBackgroundColor: grey,
      cardColor: t.scaffoldBackgroundColor,
      appBarTheme: t.appBarTheme.copyWith(backgroundColor: grey),
    ),
    child: child,
  );
}

ThemeData buildTheme(Brightness brightness, {Color? vault}) {
  final dark = brightness == Brightness.dark;
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final p = vault == null ? null : VaultPalette(vault, brightness);
  // Black and white (docs/ui.md, Black and white): one ink, black or white, and the page
  // the other way round; everything else is that ink at an opacity. No other colour.
  final page = dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  final pen = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  Color tone(double alpha) => Color.alphaBlend(pen.withValues(alpha: alpha), page);
  final bg = p?.bg ?? page;
  final surface = p?.surface ?? tone(dark ? .09 : .045);
  final ink = p?.ink ?? pen;
  final accent = p?.accent ?? pen;
  final accentInk = p?.onAccent ?? page;
  final danger = pen;
  final colors = CsColors(
    muted: p?.muted ?? tone(.68), // .6 was hard to read for older eyes (user testing)
    soft: p?.soft ?? tone(dark ? .14 : .08),
    border: p?.border ?? tone(dark ? .18 : .12),
    dock: p?.dock ?? pen,
    warnBg: tone(dark ? .12 : .06),
    warnInk: pen,
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: accentInk,
    secondary: accent,
    onSecondary: accentInk,
    error: danger,
    onError: page,
    surface: surface,
    onSurface: ink,
    outline: colors.border,
    outlineVariant: colors.border,
    surfaceContainerHighest: colors.soft,
  );

  // Button labels derive from the theme's own type scale so they keep its font.
  final label = ThemeData(brightness: brightness).textTheme.labelLarge!;

  // One field look everywhere (docs/design-language.md, owner 2026-10-29): a soft grey
  // rounded field, no outline at rest (the label sits inside, at its top); a ring of ink
  // only while typing, red on an error.
  OutlineInputBorder field(Color? c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: c == null ? BorderSide.none : BorderSide(color: c, width: 1.5),
      );

  return ThemeData(
    // Back on every page is a round button like the header's own (docs/design-language.md,
    // owner 2026-10-29), not a bare arrow: a [Ui.circle] disc in the ink's tone.
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (context) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: tone(dark ? .14 : .06),
          border: Border.all(color: pen.withValues(alpha: dark ? .14 : .08)),
        ),
        child: SizedBox.square(dimension: Ui.circle, child: Icon(Icons.arrow_back_ios_new_rounded, size: 19, color: ink)),
      ),
    ),
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    cardColor: surface,
    extensions: [colors],
    appBarTheme: AppBarTheme(
      // Room for the round Back ([actionIconTheme]) at the page's side margin.
      toolbarHeight: Ui.circle + 16,
      leadingWidth: Ui.circle + 32,
      backgroundColor: bg,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      // iPhone: the title centred at 17 semibold beside ‹, as in the phone's own apps.
      // A top page that wants the big title on the left sets [largeTitle] itself.
      centerTitle: ios,
      titleTextStyle: ThemeData(brightness: brightness).textTheme.titleLarge!.copyWith(
        fontSize: ios ? CsType.headline : CsType.title3,
        fontWeight: ios ? FontWeight.w600 : FontWeight.w700,
        color: ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.soft,
      border: field(null),
      enabledBorder: field(null),
      focusedBorder: field(accent),
      errorBorder: field(danger),
      focusedErrorBorder: field(danger),
    ),
    // A selection mark is round everywhere, as on a photo (docs/design-language.md).
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide(color: colors.muted, width: 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Dark mode: a soft grey with white text, not a white slab that glares (owner
        // 2026-10-21). Light mode keeps black with white text.
        backgroundColor: dark ? tone(.2) : null,
        foregroundColor: dark ? pen : null,
        // Opaque when off too (the default is see-through over the lock's picture).
        disabledBackgroundColor: tone(dark ? .12 : .08),
        disabledForegroundColor: tone(.38),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: label.copyWith(fontSize: CsType.callout, fontWeight: FontWeight.w700),
      ),
    ),
    // The quieter button (Cancel, Not now) as tall as the main one, same corners and
    // type (owner 2026-10-27: Cancel looked lower than our buttons; Material's default
    // is 40). Its own width, so it still fits in a row.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: pen,
        side: BorderSide(color: colors.border, width: 1.5),
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: label.copyWith(fontSize: CsType.callout, fontWeight: FontWeight.w600),
      ),
    ),
    // Messages float with a margin, rounded, never flush against the bottom bar.
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(12, 0, 12, 10),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(44, 44),
        textStyle: label.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// The design language's sizes, shared by every screen (docs/ui.md, design language).
/// Nothing a finger has to hit is smaller than [tap]; Apple's minimum is 44 points.
abstract final class Ui {
  /// Smallest touch target.
  static const double tap = 48;
  /// Round glass buttons (back, search, settings, close, flip).
  static const double circle = 44;
  /// The main action (+, record), always within the thumb's reach: as big as the lock
  /// button (owner 2026-10-21: smaller, so it hides less of the content).
  static const double primary = bar;
  /// The bottom glass bar: lock and sections.
  static const double bar = 62;
  /// One action of an item (Close, Send, Delete…), each its own circle as big as the
  /// iPhone's own bottom buttons (owner 2026-10-29: as big as Photos' search, 62; header
  /// buttons stay [circle]).
  static const double action = bar;
  /// The page's side margin, as the iPhone's own apps (20).
  static const double side = 20;
  /// Chips (groups) and segmented switches.
  static const double chip = 40;
  /// Large add tiles (the add sheet, an empty vault).
  static const double tile = 96;
  /// Corner radius of cards and tiles; buttons are round or stadium-shaped.
  static const double radius = 24;
  /// Space between the bottom bar, the main action and the screen edge.
  static const double edge = 10;
  /// The main action's bottom above the safe area when on an edge: clear of the bottom bar
  /// by 30, so a big thumb does not hit the lock instead (owner 2026-10-21). In the
  /// middle it sits lower ([actionLift] in vault_bar.dart).
  static const double actionLift = edge + bar + 30;
}

/// [color] laid on the page, as one opaque colour. Keys, fields and buttons sit over the
/// blurred vault picture on the lock and new-vault screens; a see-through tint let the
/// picture show through and was hard to read (owner 2026-10-24).
Color solidTint(BuildContext context, Color color) =>
    Color.alphaBlend(color, Theme.of(context).scaffoldBackgroundColor);
