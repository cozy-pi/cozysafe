import 'package:flutter/material.dart';

import 'prefs.dart';

/// Light, dark, or follow the device (Settings → Display → Appearance).
abstract final class Appearance {
  static const pref = 'appearance';
  static const choices = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];

  /// What MaterialApp uses; follows the device until chosen.
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  static void load() => mode.value = choices.firstWhere((m) => m.name == Prefs.read(pref), orElse: () => ThemeMode.system);

  static void choose(ThemeMode m) {
    Prefs.write(pref, m.name);
    mode.value = m;
  }
}
