import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Keeps the screen on while a sync runs, and (iPhone) asks for a little time to
/// finish if the person leaves the app (native: AppDelegate / MainActivity "cozysafe/awake").
abstract final class Awake {
  static const _channel = MethodChannel('cozysafe/awake');

  static Future<void> set(bool on) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('set', on);
    } catch (_) {
      // Desktop and tests have no such channel: nothing to keep awake.
    }
  }
}
