import 'prefs.dart';
import 'src/rust/api/vault.dart' as rust;

/// The Debug page's log (owner 2026-10-22: copy it and paste it to the developer):
/// timings and error kinds from Dart and from Rust, only while debug mode is on, the
/// last 500 lines, in memory only. Never names, contents, keys or passwords.
abstract final class DebugLog {
  static final List<(DateTime, String)> _lines = [];

  static bool get on => Prefs.read('debug-mode') == '1';

  /// Tell the Rust side whether to keep lines (at start, and when debug mode changes).
  static void sync() {
    try {
      rust.setDebugLog(on_: on);
    } catch (_) {}
    if (!on) _lines.clear();
  }

  static void add(String line) {
    if (!on) return;
    _keep(DateTime.now(), line);
  }

  static void _keep(DateTime at, String line) {
    _lines.add((at, line));
    if (_lines.length > 500) _lines.removeRange(0, _lines.length - 500);
  }

  /// Everything kept, oldest first, as text to copy.
  static List<String> lines() {
    try {
      for (final raw in rust.takeDebugLog()) {
        final bar = raw.indexOf('|');
        final ms = int.tryParse(bar < 0 ? '' : raw.substring(0, bar));
        _keep(ms == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(ms), bar < 0 ? raw : raw.substring(bar + 1));
      }
    } catch (_) {}
    _lines.sort((a, b) => a.$1.compareTo(b.$1));
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      for (final (t, l) in _lines)
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')} $l',
    ];
  }

  static void clear() {
    lines();
    _lines.clear();
  }
}
