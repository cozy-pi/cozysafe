import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform.dart';
import '../prefs.dart';
import '../top_secret_mode.dart';

/// Copying a password or a one-time code (docs/adr/0009-secure-items.md, owner
/// 2026-11-06): it must outlive the vault locking when the person switches to the app
/// that asks for it, so it is not wiped on lock as other copied text is
/// (`LockGuard.copied`). Instead the system forgets it after [seconds]: on iOS the
/// pasteboard's own expiry (and never to other devices through Universal Clipboard); on
/// Android it is marked sensitive (hidden in the preview, not kept by keyboards) and
/// cleared on time while the app runs, else when it comes back; on a Mac concealed,
/// transient and this Mac only, cleared natively if unchanged. Elsewhere a timer.
abstract final class SecureClipboard {
  static const _channel = MethodChannel('cozysafe/privacy');
  static const _mac = MethodChannel('cozysafe/clipboard');

  /// Settings → copied passwords are cleared after: seconds, 0 for never.
  static const pref = 'secret-clipboard-seconds';
  static const choices = [30, 90, 180, 0];
  static const standard = 90;

  /// How long a copy lasts in this vault. Top Secret Mode keeps the standard time,
  /// whatever the setting.
  static int get seconds {
    if (TopSecretMode.on) return standard;
    final v = int.tryParse(Prefs.read(pref) ?? '');
    return choices.contains(v) ? v! : standard;
  }

  static String? _copied;
  static DateTime? _until;
  static Timer? _timer;
  static _Resume? _resume;

  /// [lasting]: a fixed time instead of the setting's (the 24 words: never "never").
  static Future<void> copy(String text, {int? lasting}) async {
    final s = lasting ?? seconds;
    var native = false;
    final channel = Device.iOS || Device.android ? _channel : (Device.macOS ? _mac : null);
    if (channel != null) {
      try {
        native = await channel.invokeMethod<bool>('copySecret', {'text': text, 'seconds': s}) ?? false;
      } catch (_) {}
    }
    if (!native) await Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    // The system clears it on iPhone and Mac: reading the clipboard back to check would
    // only ask "Allow Paste" there. Android's process may die first, so it checks on
    // return; other computers have only this timer. Never cleared: nothing kept here.
    if (s == 0 || (native && (Device.iOS || Device.macOS))) {
      _copied = null;
      _until = null;
      return;
    }
    _copied = text;
    _until = DateTime.now().add(Duration(seconds: s));
    _timer = Timer(Duration(seconds: s), sweep);
    _resume ??= _Resume()..listen();
  }

  /// Wipe the copy once its time is up, unless something else was copied since.
  static Future<void> sweep() async {
    final mine = _copied, until = _until;
    if (mine == null || until == null || DateTime.now().isBefore(until)) return;
    _copied = null;
    _timer?.cancel();
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == mine) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {}
  }
}

class _Resume with WidgetsBindingObserver {
  void listen() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SecureClipboard.sweep();
  }
}
