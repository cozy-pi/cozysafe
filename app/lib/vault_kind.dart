import 'dart:io';

import 'package:flutter/painting.dart';

import 'src/rust/api/run.dart' as rust;
import 'src/rust/api/run.dart' show VaultKind;
import 'temp_files.dart';

export 'src/rust/api/run.dart' show VaultKind;

/// One kind of vault per app run (ADR 0005, "Nothing shared"). The kind is read once at
/// start from a small file outside both libraries and stays fixed in memory until the
/// app ends; Rust refuses any library call for the other kind ([rust.startRun]).
///
/// Top secret keeps every place it had before this split (the `library` folder, the
/// preferences next to it, the keystore names), so nothing on a device moves. Private
/// gets its own: `private/library`, preferences in `private/`, keystore names with
/// `private` in them.
abstract final class RunKind {
  /// The start file, in the app's support folder: `top-secret` or `private`; missing
  /// means Top secret.
  static const startFile = 'next-vault-kind';

  /// This run's kind; set by [start].
  static VaultKind current = VaultKind.topSecret;

  static String _support = '';

  static bool get topSecret => current == VaultKind.topSecret;

  /// Read the start file, fix the kind for this run and hand it to Rust. Returns this
  /// run's library folder.
  static String start(String support) {
    _support = support;
    current = read(support);
    final dir = libraryDir(current);
    rust.startRun(kind: current, libraryDir: dir);
    return dir;
  }

  /// The kind the start file names (Top secret when it is missing or unreadable).
  static VaultKind read(String support) {
    try {
      final v = File(_join(support, startFile)).readAsStringSync().trim();
      return v == _name(VaultKind.private) ? VaultKind.private : VaultKind.topSecret;
    } catch (_) {
      return VaultKind.topSecret;
    }
  }

  /// Where a kind keeps its preferences (and logs): Top secret in the support folder as
  /// before, Private in its own folder.
  static String prefsDir(VaultKind kind, [String? support]) {
    final root = support ?? _support;
    return kind == VaultKind.topSecret ? root : _join(root, 'private');
  }

  /// A kind's library folder.
  static String libraryDir(VaultKind kind, [String? support]) => _join(prefsDir(kind, support), 'library');

  /// A keystore account or service name for this run's kind: `cozysafe.<name>` for Top
  /// secret (the names it always had), `cozysafe.private.<name>` for Private.
  static String account(String name) => topSecret ? 'cozysafe.$name' : 'cozysafe.private.$name';

  /// A key name inside a keystore entry for this run's kind: the name as it always was
  /// for Top secret, `private-<name>` for Private (Windows and Linux keep every key of
  /// the app in one store, so the name itself must differ).
  static String key(String name) => topSecret ? name : 'private-$name';

  /// The Android keystore namespace for this run's kind, as [account].
  static String namespace(String name) => topSecret ? 'cozysafe_$name' : 'cozysafe_private_$name';

  /// Switch to the other kind on the next start (owner 2026-10-30: either way, nothing
  /// carries over): Rust locks, forgets its keys and refuses every library call; every
  /// temporary file is wiped and decoded pictures dropped; then the start file names the
  /// other kind. The caller then quits the app, or on iPhone and iPad shows the page
  /// asking the person to close it ([closesItself]).
  static Future<void> switchTo(VaultKind next) async {
    rust.endRun();
    await clearTemp();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final f = File(_join(_support, startFile));
    final part = File('${f.path}.part');
    part.writeAsStringSync(_name(next), flush: true);
    part.renameSync(f.path);
  }

  /// Whether the app may quit by itself after [switchTo]. Apple asks apps not to (App
  /// Review may treat it as a crash), so on iPhone and iPad the person closes it.
  static bool get closesItself => !Platform.isIOS;

  static String _name(VaultKind kind) => kind == VaultKind.topSecret ? 'top-secret' : 'private';

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';
}
