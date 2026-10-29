import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform.dart';
import '../screens/settings.dart' show Settings;
import '../sync/awake.dart';

/// Around a screen that shows the 24 words, so they can be copied out by hand (owner
/// 2026-10-30): the screen stays on and the vault does not lock for lack of touches for
/// [awake] after the last touch, then both go back to normal. Screenshots and screen
/// recordings are blocked while it is up, whatever Settings says.
class WordsAwake extends StatefulWidget {
  const WordsAwake({super.key, required this.child});
  final Widget child;

  /// Writing 24 words down takes 3–5 minutes; each touch starts the time again.
  static const awake = Duration(minutes: 3);

  static const _holder = 'words';

  @override
  State<WordsAwake> createState() => _WordsAwakeState();
}

class _WordsAwakeState extends State<WordsAwake> {
  static const _privacy = MethodChannel('cozysafe/privacy');
  Timer? _timer;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    _poke();
    _secure(true);
  }

  void _poke() {
    _timer?.cancel();
    _hold(true);
    _timer = Timer(WordsAwake.awake, () => _hold(false));
  }

  void _hold(bool on) {
    if (_held == on) return;
    _held = on;
    Awake.set(on, who: WordsAwake._holder);
  }

  Future<void> _secure(bool on) async {
    if (!Device.android && !Device.iOS) return;
    if (!on) return Settings.apply();
    try {
      await _privacy.invokeMethod<void>('setSecure', true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hold(false);
    _secure(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => _poke(), child: widget.child);
}
