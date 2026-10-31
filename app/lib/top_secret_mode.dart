import 'dart:io';

import 'package:flutter/painting.dart';

import 'src/rust/api/run.dart' as rust;
import 'src/rust/api/run.dart' show RunMode;
import 'temp_files.dart';

/// Top Secret Mode (ADR 0006): what the app does with what is in the vault, never how the
/// vault is locked (the password and the 24 words are the same either way). On: nothing
/// in the vault is decoded in the app (no photo, video, PDF or thumbnail; files open in
/// another app), and nothing comes in from the photo library or another app's Share.
///
/// The mode is read once at start from a small file next to the library and handed to
/// Rust, which refuses decoding calls in Top Secret Mode ([rust.startRun]). It may change
/// until a vault opens (making the first vault asks for it); after that turning it on or
/// off ends the run and the app starts again.
abstract final class TopSecretMode {
  /// The start file, in the app's support folder: `on` or `off`; missing means off.
  static const startFile = 'top-secret-mode';

  /// Whether this run is in Top Secret Mode; set by [start].
  static bool on = false;

  static String _support = '';

  /// Read the start file, fix the mode for this run and hand it to Rust. Returns the
  /// library folder.
  static String start(String support) {
    _support = support;
    on = read(support);
    final dir = '$support${Platform.pathSeparator}library';
    rust.startRun(mode: _mode(on), libraryDir: dir);
    return dir;
  }

  /// The mode the start file names (off when it is missing or unreadable).
  static bool read(String support) {
    try {
      return File('$support${Platform.pathSeparator}$startFile').readAsStringSync().trim() == 'on';
    } catch (_) {
      return false;
    }
  }

  /// Making the first vault: the mode it starts in, before any vault opens.
  static void choose(bool next) {
    if (!rust.chooseMode(mode: _mode(next))) return;
    on = next;
    _write(next);
  }

  /// Turn the mode on or off for the next start: Rust locks, forgets its keys and
  /// refuses every library call; temporary files are wiped and decoded pictures dropped.
  /// The caller then quits the app, or on iPhone and iPad shows the page asking the
  /// person to close it ([closesItself]).
  static Future<void> turn(bool next) async {
    rust.endRun();
    await clearTemp();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    _write(next);
  }

  /// Whether the app may quit by itself after [turn]. Apple asks apps not to (App Review
  /// may treat it as a crash), so on iPhone and iPad the person closes it.
  static bool get closesItself => debugClosesItself ?? !Platform.isIOS;

  /// Mockups: act as a platform that quits by itself (or as iPhone, which does not).
  static bool? debugClosesItself;

  static RunMode _mode(bool on) => on ? RunMode.topSecret : RunMode.everyday;

  static void _write(bool next) {
    if (_support.isEmpty) return;
    final f = File('$_support${Platform.pathSeparator}$startFile');
    final part = File('${f.path}.part');
    part.writeAsStringSync(next ? 'on' : 'off', flush: true);
    part.renameSync(f.path);
  }
}
