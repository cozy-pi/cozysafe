import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'platform.dart';

/// The iOS cover that hides the vault from the app switcher (AppDelegate.swift) goes up
/// whenever the app stops being active, and the Face ID prompt makes it inactive too.
/// Without this, the cover would hide the vault opening behind the prompt.
abstract final class PrivacyCover {
  static const _channel = MethodChannel('cozysafe/privacy');

  /// Called after the person takes a screenshot (iOS tells us; it cannot be stopped).
  static void Function()? onScreenshot;

  /// Start listening to the platform side (main, once).
  static void listen() {
    if (!Device.iOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'screenshot') onScreenshot?.call();
    });
    // Back in the app the cover stays up until a new frame is on screen (AppDelegate):
    // Flutter draws nothing in the background, so the screen still holds the vault as it
    // was left. Two frames: the first builds the lock screen, the second is sure to have
    // been shown (owner 2026-10-29: the vault flashed before the lock).
    _resume = AppLifecycleListener(onResume: () async {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      try {
        await _channel.invokeMethod<void>('uncover');
      } catch (_) {}
    });
  }

  // ignore: unused_field
  static AppLifecycleListener? _resume;

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
