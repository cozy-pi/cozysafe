import 'dart:io';

import 'package:flutter/foundation.dart';

import 'prefs.dart';
import 'src/rust/api/errors.dart' as rust;

/// The error log, always on (owner 2026-10-26: Drive failed and nobody could tell why):
/// the last [keep] failures as time, place and a short fixed code, in a small file next
/// to the preferences. Never names, contents, keys, passwords or network data, so it is
/// safe to copy into a message. Settings → Report a problem shows and copies it.
abstract final class ErrorLog {
  static const keep = 200;
  static const _file = 'error-log';

  /// Note a failure seen on the Dart side. [place] and [code] are reduced to letters,
  /// digits and '-' (what a code is made of), so nothing else can slip in.
  static void add(String place, String code) => _append([_line(DateTime.now().millisecondsSinceEpoch, place, code)]);

  static String _word(String s) {
    final w = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    final t = w.length > 60 ? w.substring(0, 60) : w;
    return t.isEmpty ? 'unknown' : t;
  }

  static String _line(int ms, String place, String code) => '$ms|${_word(place)}|${_word(code)}';

  static String get _path => '${Prefs.dir}${Platform.pathSeparator}$_file';

  static List<String> _read() {
    try {
      return File(_path).readAsLinesSync().where((l) => l.split('|').length == 3).toList();
    } catch (_) {
      return [];
    }
  }

  static void _append(List<String> lines) {
    if (lines.isEmpty) return;
    final all = [..._read(), ...lines];
    final kept = all.length > keep ? all.sublist(all.length - keep) : all;
    try {
      File(_path).writeAsStringSync('${kept.join('\n')}\n');
    } catch (_) {}
  }

  /// Bring in what the core noted since last time.
  static void takeFromCore() {
    try {
      _append([
        for (final raw in rust.takeErrors())
          if (raw.split('|') case [final ms, final place, final code]) _line(int.tryParse(ms) ?? 0, place, code),
      ]);
    } catch (_) {} // the mockup renders run without the Rust side
  }

  /// Newest first: (when, place, code).
  static List<(DateTime, String, String)> entries() {
    takeFromCore();
    return [
      for (final l in _read().reversed)
        if (l.split('|') case [final ms, final place, final code])
          (DateTime.fromMillisecondsSinceEpoch(int.tryParse(ms) ?? 0), place, code),
    ];
  }

  static void clear() {
    takeFromCore();
    try {
      File(_path).deleteSync();
    } catch (_) {}
  }

  /// The text "Copy details" puts on the clipboard: the app and the device kind, then
  /// the codes, newest first.
  static String report({required String version, String? now}) {
    final os = kIsWeb ? 'web' : '${Platform.operatingSystem} ${Platform.operatingSystemVersion.split(' ').first}';
    return [
      'Cozy Safe $version · $os',
      ?now,
      for (final (t, place, code) in entries()) '${t.toUtc().toIso8601String()} $place $code',
    ].join('\n');
  }
}
