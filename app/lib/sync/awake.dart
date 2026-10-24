import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Keeps a sync alive while it runs (native: AppDelegate / MainActivity "cozysafe/awake").
/// The screen stays on; on Android a foreground service with a notification keeps the
/// app running when the phone is locked; on iPhone, iOS lends a little time to finish
/// if the person leaves the app.
abstract final class Awake {
  /// The Android service that keeps a sync going with the phone locked: off until Google
  /// Play's declaration is filed (MainActivity.kt SYNC_SERVICE, AndroidManifest.xml).
  static const androidSyncService = false;

  static const _channel = MethodChannel('cozysafe/awake');

  static Future<void> set(bool on) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('set', on);
    } catch (_) {
      // Desktop and tests have no such channel: nothing to keep awake.
    }
  }

  /// What the Android notification says while the sync runs: [title] over [text], and a
  /// bar [done] of [total] (no number yet when [total] is 0). [channel] names the kind of
  /// notification in the phone's settings. The first call shows it; iPhone ignores it.
  static Future<void> progress({required String title, required String text, required String channel, int done = 0, int total = 0}) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('progress', {'title': title, 'text': text, 'channel': channel, 'done': done, 'total': total});
    } catch (_) {
      // Desktop and tests have no such channel.
    }
  }
}
