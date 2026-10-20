import 'dart:io';

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
