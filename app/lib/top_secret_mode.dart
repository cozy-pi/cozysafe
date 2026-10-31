import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/run.dart' as rust;
import 'src/rust/api/run.dart' show RunMode;
import 'src/rust/api/vault.dart' show VaultInfo, setTopSecret;
import 'temp_files.dart';

/// Top Secret Mode (ADR 0007): what the app does with what is in a vault, never how the
/// vault is locked (the password and the 24 words are the same either way). On: nothing
/// in the vault is decoded in the app (no photo, video, PDF or thumbnail; files open in
/// another app); photos come in from the library as sealed files, never looked at.
///
/// Each vault has its own mode, sealed in it (owner 2026-10-31). A run starts in Top
/// Secret Mode and takes the mode of the vault that opens ([opened]); Rust refuses an
/// everyday-only call in Top Secret Mode ([rust.startRun]). A Top secret vault after an
/// everyday one in the same run needs the app to start again
/// (`VaultError.restartForMode`), and so does turning a vault's mode on or off.
abstract final class TopSecretMode {
  /// The start file of ADR 0006 (one mode for the whole device), removed at start.
  static const _oldStartFile = 'top-secret-mode';

  /// Whether the open vault is in Top Secret Mode; set by [opened].
  static bool on = false;

  /// This run's library folder, set by [start].
  static String libraryDir = '';

  /// Hand the library folder to Rust, in Top Secret Mode until a vault opens. Returns
  /// the library folder.
  static String start(String support) {
    try {
      File('$support${Platform.pathSeparator}$_oldStartFile').deleteSync();
    } catch (_) {}
    final dir = '$support${Platform.pathSeparator}library';
    libraryDir = dir;
    rust.startRun(mode: RunMode.topSecret, libraryDir: dir);
    return dir;
  }

  /// A vault opened: the screens follow its mode.
  static void opened(VaultInfo vault) => on = vault.topSecret;

  /// End this run before the app starts again: Rust locks, forgets its keys and refuses
  /// every library call; temporary files are wiped and decoded pictures dropped. The
  /// caller then quits the app, or on iPhone and iPad shows the page asking the person to
  /// close it ([closesItself]).
  static Future<void> endRun() async {
    rust.endRun();
    await clearTemp();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  /// Turn the open vault's mode on or off, then end the run.
  static Future<void> turn(bool next) async {
    await setTopSecret(topSecret: next);
    await endRun();
  }

  /// After [endRun] on Android and computers: Android starts the app again in a fresh
  /// process; a computer quits (the person opens it again).
  static Future<void> quit() async {
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('cozysafe/device').invokeMethod<void>('restart');
      } catch (_) {}
    }
    exit(0);
  }

  /// Whether the app may quit by itself after [endRun]. Apple asks apps not to (App Review
  /// may treat it as a crash), so on iPhone and iPad the person closes it.
  static bool get closesItself => debugClosesItself ?? !Platform.isIOS;

  /// Mockups: act as a platform that quits by itself (or as iPhone, which does not).
  static bool? debugClosesItself;
}
