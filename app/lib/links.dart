import 'package:flutter/services.dart';

import 'language.dart';
import 'lock_guard.dart';
import 'platform.dart';

/// Opening our own web pages in the browser: the app hands the address to the system
/// and does nothing else (no network here). iPhone and Android only; elsewhere the
/// caller shows the address to copy. ("cozysafe/privacy" channel, AppDelegate.swift,
/// MainActivity.kt.)
abstract final class Links {
  static const _channel = MethodChannel('cozysafe/privacy');

  static bool get canOpen => Device.iOS || Device.android || debugCanOpen;

  /// Mockups: draw the phone version on any platform.
  static bool debugCanOpen = false;

  /// The feedback page in the app's language (safe.cozypi.com/<code>/feedback).
  static String feedback(String languageCode) {
    final site = languageCode == 'zh_Hant' ? 'zh-TW' : languageCode;
    final known = languages.any((x) => x.code == languageCode) && languageCode != 'en';
    return 'https://safe.cozypi.com/${known ? '$site/' : ''}feedback';
  }

  /// True when the system took it. Leaving for the browser does not lock the vault at
  /// once (60 seconds, as for the share sheet).
  static Future<bool> open(String url) async {
    if (!canOpen) return false;
    LockGuard.allowAway();
    try {
      return await _channel.invokeMethod<bool>('openUrl', url) ?? false;
    } catch (_) {
      return false;
    }
  }
}
