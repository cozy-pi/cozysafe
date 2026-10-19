import 'package:flutter/material.dart';

/// Colours that Material's ColorScheme has no slot for. Values match the
/// approved mockup (one design, light and dark only).
@immutable
class CsColors extends ThemeExtension<CsColors> {
  const CsColors({
    required this.muted,
    required this.soft,
    required this.border,
    required this.warnBg,
    required this.warnInk,
  });

  final Color muted;
  final Color soft;
  final Color border;
  final Color warnBg;
  final Color warnInk;

  static CsColors of(BuildContext context) =>
      Theme.of(context).extension<CsColors>()!;

  @override
  CsColors copyWith({
    Color? muted,
    Color? soft,
    Color? border,
    Color? warnBg,
    Color? warnInk,
  }) =>
      CsColors(
        muted: muted ?? this.muted,
        soft: soft ?? this.soft,
        border: border ?? this.border,
        warnBg: warnBg ?? this.warnBg,
        warnInk: warnInk ?? this.warnInk,
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

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? Brand.night : const Color(0xFFF4F5F4);
  final surface = dark ? const Color(0xFF12342C) : const Color(0xFFFFFFFF);
  final ink = dark ? const Color(0xFFE9ECEB) : const Color(0xFF1A1D1F);
  // B2: green actions on light, gold actions on dark.
  final accent = dark ? Brand.gold : Brand.green;
  final accentInk = dark ? Brand.goldInk : const Color(0xFFFFFFFF);
  final danger = dark ? const Color(0xFFF0A196) : const Color(0xFFB3261E);
  final colors = CsColors(
    muted: dark ? const Color(0xFFA2AAA6) : const Color(0xFF5C6369),
    soft: dark ? const Color(0xFF184036) : const Color(0xFFE3E9E6),
    border: dark ? const Color(0xFF2C5047) : const Color(0xFFD6DDD9),
    warnBg: dark ? const Color(0xFF3A2F17) : const Color(0xFFFBF0DC),
    warnInk: dark ? const Color(0xFFF1D294) : const Color(0xFF6B4300),
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: accentInk,
    secondary: accent,
    onSecondary: accentInk,
    error: danger,
    onError: dark ? const Color(0xFF3A0D08) : const Color(0xFFFFFFFF),
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
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(44, 44),
        textStyle: label.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
  );
}
