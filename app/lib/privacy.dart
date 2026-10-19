import 'package:flutter/services.dart';
import 'platform.dart';

/// The iOS cover that hides the vault from the app switcher (AppDelegate.swift) goes up
/// whenever the app stops being active, and the Face ID prompt makes it inactive too.
/// Without this, the cover would hide the vault opening behind the prompt.
abstract final class PrivacyCover {
  static const _channel = MethodChannel('cozysafe/privacy');

  /// Run [ask] (a biometric prompt) without the cover coming up for it.
  static Future<T> whileAsking<T>(Future<T> Function() ask) async {
    await _set(true);
    try {
      return await ask();
    } finally {
      await _set(false);
    }
  }

  static Future<void> _set(bool suspended) async {
    if (!Device.iOS) return;
    try {
      await _channel.invokeMethod<void>('suspendCover', suspended);
    } catch (_) {}
  }
}
