import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'platform.dart';

/// Where the app puts a file for a moment: a video decrypted for the player, a copy for
/// the share sheet, a backup on its way out. Phones and the Mac give each app its own
/// temporary folder, which pickers also copy into (photos and files being imported).
/// Windows and Linux share one temporary folder between every program of the user, so
/// there the app keeps its own, next to the vault, readable by the user only.
Future<Directory> privateTemp() async {
  if (!Device.windows && !Device.linux) return getTemporaryDirectory();
  final d = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}tmp');
  if (!d.existsSync()) {
    d.createSync(recursive: true);
    if (Device.linux) await Process.run('chmod', ['700', d.path]);
  }
  return d;
}

/// Empty [privateTemp] (owner 2026-10-30): at start, before anything else, and when the
/// vault locks. A crash or a kill in the middle of an import, a share or a playback
/// leaves plain copies behind otherwise; only a playback copy used to be swept.
Future<void> clearTemp() async {
  try {
    final d = await privateTemp();
    if (!d.existsSync()) return;
    for (final e in d.listSync(followLinks: false)) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {} // in use (a picker still writing): the next sweep takes it
    }
  } catch (_) {}
}
