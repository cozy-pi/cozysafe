import 'dart:math' as math;

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

ThemeData buildTheme(Brightness brightness, {Color? vault}) {
  final dark = brightness == Brightness.dark;
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
    muted: p?.muted ?? tone(.6),
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

  OutlineInputBorder field(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c, width: 1.5),
      );

  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    cardColor: surface,
    extensions: [colors],
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: ThemeData(brightness: brightness).textTheme.titleLarge!.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: field(colors.border),
      enabledBorder: field(colors.border),
      focusedBorder: field(accent),
      errorBorder: field(danger),
      focusedErrorBorder: field(danger),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: label.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
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
