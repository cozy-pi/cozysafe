// Text copied out of a note is wiped from the clipboard after a minute and when the
// vault locks (docs/security.md). On Android an app that is not in front reads an empty
// clipboard, and the vault locks as the app leaves: the compare never matched, the text
// was forgotten and it stayed for good. Now it is emptied natively there, or, where that
// cannot be done, wiped once the app is back in front.

import 'package:cozysafe/entries/secure_clipboard.dart';
import 'package:cozysafe/lock_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// What the system clipboard holds.
  String? clip;
  /// The app is not in front: Android shows it nothing.
  var hidden = false;
  /// The native door (MainActivity, `clearClipboard`) is there.
  var native = false;
  var nativeClears = 0;

  void mock(WidgetTester t) {
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return hidden || clip == null ? null : {'text': clip};
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('cozysafe/privacy'), (call) async {
      if (call.method == 'clearClipboard' && native) {
        nativeClears++;
        clip = null;
        return true;
      }
      if (call.method == 'copySecret') return false;
      throw MissingPluginException();
    });
    // The tests run on a computer: a Mac's own door for a copied password is not there.
    messenger.setMockMethodCallHandler(const MethodChannel('cozysafe/clipboard'), (call) async => false);
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('cozysafe/clipboard'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(const MethodChannel('cozysafe/privacy'), null);
      LockGuard.debugAndroid = null;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  void away(WidgetTester t) {
    hidden = true;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }

  void back(WidgetTester t) {
    hidden = false;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  setUp(() {
    clip = null;
    hidden = false;
    native = false;
    nativeClears = 0;
  });

  testWidgets('in front: wiped when it is still there, left alone when replaced', (t) async {
    mock(t);
    LockGuard.debugAndroid = true;
    native = true;
    clip = 'note text';
    LockGuard.copied('note text');
    await LockGuard.clearCopied();
    expect(clip, '');
    expect(nativeClears, 0);

    clip = 'note text';
    LockGuard.copied('note text');
    clip = 'something from another app';
    await LockGuard.clearCopied();
    expect(clip, 'something from another app');
    expect(nativeClears, 0);
    // Forgotten: coming back later wipes nothing.
    clip = 'note text';
    back(t);
    await t.pump();
    expect(clip, 'note text');
  });

  testWidgets('Android, the app left: the clipboard cannot be read, so it is emptied natively', (t) async {
    mock(t);
    LockGuard.debugAndroid = true;
    native = true;
    clip = 'note text';
    LockGuard.copied('note text');
    away(t);
    await LockGuard.clearCopied(); // the vault locks as the app leaves
    expect(nativeClears, 1);
    expect(clip, isNull);
  });

  testWidgets('no native door: the wipe waits, and is done when the app is back', (t) async {
    mock(t);
    LockGuard.debugAndroid = true;
    clip = 'note text';
    LockGuard.copied('note text');
    away(t);
    await LockGuard.clearCopied();
    expect(clip, 'note text'); // nothing could be done yet
    back(t);
    await t.pump();
    await t.pump();
    expect(clip, '');
  });

  testWidgets('waiting, and something else was copied meanwhile: it is left alone', (t) async {
    mock(t);
    LockGuard.debugAndroid = true;
    clip = 'note text';
    LockGuard.copied('note text');
    away(t);
    await LockGuard.clearCopied();
    clip = 'copied in another app';
    back(t);
    await t.pump();
    await t.pump();
    expect(clip, 'copied in another app');
  });

  testWidgets('a password copied after note text is not taken by the note\'s wipe', (t) async {
    mock(t);
    LockGuard.debugAndroid = true;
    native = true;
    clip = 'note text';
    LockGuard.copied('note text');
    await SecureClipboard.copy('hunter2-password', lasting: 0);
    expect(clip, 'hunter2-password');
    away(t);
    await LockGuard.clearCopied(); // the vault locks as the person goes to paste it
    expect(nativeClears, 0);
    expect(clip, 'hunter2-password');
  });
}
