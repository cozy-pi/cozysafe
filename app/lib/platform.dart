import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64, PlatformInt64Util;

/// Which platform the app runs on, safe to ask on the web too (the browser preview,
/// `lib/preview_main.dart`), where `dart:io`'s `Platform` throws.
abstract final class Device {
  static bool get iOS => !kIsWeb && Platform.isIOS;
  static bool get android => !kIsWeb && Platform.isAndroid;
  static bool get macOS => !kIsWeb && Platform.isMacOS;
  static bool get windows => !kIsWeb && Platform.isWindows;
  static bool get linux => !kIsWeb && Platform.isLinux;
  static bool get desktop => debugDesktop ?? (macOS || windows || linux);

  /// For tests: act as a computer (or not).
  static bool? debugDesktop;
}

/// The bridge's 64-bit integers are `int` on phones and computers but `BigInt` on the
/// web; these keep the same code working on both.
PlatformInt64 nowMs() => PlatformInt64Util.from(DateTime.now().millisecondsSinceEpoch);
PlatformInt64 i64(int v) => PlatformInt64Util.from(v);
DateTime dateOf(PlatformInt64 ms) => DateTime.fromMillisecondsSinceEpoch(ms.toInt());
