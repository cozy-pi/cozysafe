import 'dart:io';

import '../prefs.dart';

/// What automatic sync did and why, always on and kept across starts (owner 2026-10-28:
/// "synced just now" showed six hours ago, and nothing told why): the last [keep] steps
/// as time, kind and a short fixed code — why a run started, why one was skipped, how it
/// ended (counts and time). Never names, contents, accounts or network data, so it is as
/// safe to copy as the error log, and goes with it in "Copy details".
abstract final class SyncLog {
  static const keep = 300;
  static const _file = 'sync-log';

  static String get _path => '${Prefs.dir}${Platform.pathSeparator}$_file';

  static String _word(String s) {
    final w = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final t = w.length > 60 ? w.substring(0, 60) : w;
    return t.isEmpty ? 'unknown' : t;
  }

  static List<String> _read() {
    try {
      return File(_path)
          .readAsLinesSync()
          .where((l) => l.split('|').length == 4)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Note a step. The same step again right after (the every-minute look finding
  /// nothing) only moves the time and counts, so an hour of quiet is one line.
  static void add(String kind, String code) {
    final k = _word(kind), c = _word(code);
    final lines = _read();
    var times = 1;
    if (lines.isNotEmpty) {
      final last = lines.last.split('|');
      if (last[1] == k && last[2] == c) {
        times = (int.tryParse(last[3]) ?? 1) + 1;
        lines.removeLast();
      }
    }
    lines.add('${DateTime.now().millisecondsSinceEpoch}|$k|$c|$times');
    final kept = lines.length > keep
        ? lines.sublist(lines.length - keep)
        : lines;
    try {
      File(_path).writeAsStringSync('${kept.join('\n')}\n');
    } catch (_) {}
  }

  /// Newest first, one line each in the phone's time: "28/10 08:02:03 run done-r2-s0-x0-4100ms ×3".
  static List<String> lines() {
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      for (final l in _read().reversed)
        if (l.split('|') case [final ms, final kind, final code, final times])
          if (DateTime.fromMillisecondsSinceEpoch(int.tryParse(ms) ?? 0) case final t)
            '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} $kind $code'
                '${times == '1' ? '' : ' ×$times'}',
    ];
  }

  static void clear() {
    try {
      File(_path).deleteSync();
    } catch (_) {}
  }
}
