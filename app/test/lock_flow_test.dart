// Flows that can lock someone out of their vault if they break: PIN, wrong tries,
// waits after wrong tries, password fallback, type-to-unlock, an add action picked while locked, setting a PIN,
// the Emergency Kit confirmation, pages kept under the lock. The Rust core is replaced by a fake with state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/lock_guard.dart';
import 'package:cozysafe/lock_resume.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/kit_password.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/secret_key_store.dart';
import 'package:cozysafe/screens/set_pin.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/sync/awake.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/sync/status.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _pin = '2468';
const _password = 'orange kettle whispers at dawn';

class _Fake implements RustLibApi {
  int pinLength = 4;
  bool anyPassword = true;
  String? enabledPin;
  int unlockCalls = 0;
  bool biometric = false;
  int biometricCalls = 0;
  int notesAdded = 0;
  int notesUpdated = 0;
  int syncCancels = 0;

  T _arg<T>(Invocation c, String name) => c.namedArguments[Symbol(name)] as T;

  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('P2PCancel')) {
      syncCancels++;
      return null;
    }
    if (name.contains('MinPasswordLength')) return 8;
    if (name.contains('MinPinLength')) return 6;
    final vault = VaultInfo(id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: anyPassword);
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordProblem')) return PasswordProblem.none;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return true;
    if (name.contains('ListItems')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListHeld')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListTrash')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('PurgeExpired')) return Future<int>.value(0);
    if (name.contains('HasBiometricUnlock')) return biometric;
    if (name.contains('UnlockWithBiometric')) {
      biometricCalls++;
      return Future<VaultInfo?>.value(null);
    }
    if (name.contains('ForgetBiometricUnlock')) return Future<void>.value();
    final note = ItemInfo(
      id: 'n1', kind: 'note', name: '', mime: 'text/plain', createdMs: 0,
      sizeBytes: BigInt.zero, tagIds: const [], isFavorite: false, modifiedMs: 0,
    );
    if (name.contains('AddNote')) {
      notesAdded++;
      return Future<ItemInfo>.value(note);
    }
    if (name.contains('UpdateNote')) {
      notesUpdated++;
      return Future<ItemInfo>.value(note);
    }
    if (name.contains('BiometricEnabled')) return false;
    if (name.contains('PinLengths')) return Uint32List.fromList(pinLength == 0 ? [] : [pinLength]);
    if (name.contains('AnyPassword')) return anyPassword;
    if (name.contains('PinEnabled')) return true; // the open vault has a PIN here
    if (name.contains('UnlockWithPin')) {
      final ok = _arg<String>(call, 'pin') == _pin;
      return Future<VaultInfo?>.value(ok ? vault : null);
    }
    if (name.contains('EnablePin')) {
      enabledPin = _arg<String>(call, 'pin');
      return Future<void>.value();
    }
    if (name.contains('NewSecretKey')) return Uint8List.fromList(List.filled(16, 3));
    if (name.contains('Unlock')) {
      unlockCalls++;
      return Future<VaultInfo?>.value(_arg<String>(call, 'password') == _password ? vault : null);
    }
    if (name.contains('Lock')) return null;
    return null;
  }
}

late _Fake _fake;

Widget _app(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// A phone-sized screen (iPhone 14), not the 800 × 600 test default.
Future<void> _pump(WidgetTester t, Widget app) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(app);
}

Future<void> _tapDigits(WidgetTester t, String digits) async {
  for (final d in digits.split('')) {
    await t.tap(find.text(d).last);
    await t.pump();
  }
}

/// Let async storage + bridge calls and the unlock animation finish.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
  await t.pumpAndSettle();
}

void main() {
  // A phone unless a test says otherwise (tests run on a computer).
  setUpAll(() => Device.debugDesktop = false);
  setUpAll(() => RustLib.initMock(api: _fake = _Fake()));

  setUp(() {
    _fake
      ..pinLength = 4
      ..anyPassword = true
      ..enabledPin = null
      ..unlockCalls = 0
      ..biometric = false
      ..biometricCalls = 0
      ..notesAdded = 0
      ..notesUpdated = 0
      ..syncCancels = 0;
    BiometricUnlock.debugKind = null;
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
    });
  });

  testWidgets('right PIN opens the vault', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    expect(find.text('Enter PIN'), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('wrong PIN says so and clears the dots', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, '1111');
    await _settle(t);
    expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
    expect(find.byType(VaultHomeScreen), findsNothing);
  });

  testWidgets('the fifth wrong PIN makes you wait, and never locks the PIN out', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    for (var i = 0; i < 5; i++) {
      await _tapDigits(t, '9999');
      await _settle(t);
    }
    expect(find.text('Too many tries. Wait 1 minute.'), findsOneWidget);
    // While waiting, digits are ignored, even the right PIN.
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsNothing);
    expect(PinStore.waitFor(5), const Duration(minutes: 1));
    expect(PinStore.waitFor(8) > PinStore.waitFor(6), isTrue);
  });

  testWidgets('without a backup password there is no password option', (t) async {
    _fake.anyPassword = false;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    expect(find.text('Use password'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the right password opens without pressing Enter', (t) async {
    _fake.pinLength = 0;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), _password);
    await t.pump(const Duration(milliseconds: 400)); // past the typing pause
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
  });

  testWidgets('a wrong password typed quietly says nothing; Enter says it is wrong', (t) async {
    _fake.pinLength = 0;
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), 'not the password');
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsNothing);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _settle(t);
    expect(find.text('No vault opens with this password.'), findsOneWidget);
  });

  testWidgets('locking by hand does not ask for Face ID again at once', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(VaultHomeScreen), findsOneWidget);
    await t.tap(find.byTooltip('Lock'));
    await _settle(t);
    final lock = t.widget<UnlockScreen>(find.byType(UnlockScreen));
    expect(lock.askBiometricNow, isFalse);
  });

  testWidgets('locking on Settings comes back to Settings, and Back cannot skip the lock', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    await t.tap(find.byTooltip('Settings'));
    await _settle(t);
    expect(find.byType(SettingsScreen), findsOneWidget);
    // Leaving the app locks it.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsOneWidget);
    // Back (Android) or a swipe: still the lock.
    await t.binding.handlePopRoute();
    await _settle(t);
    expect(find.byType(UnlockScreen), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('a sync keeps going behind the lock screen, which shows how far it is', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    final events = StreamController<SyncEvent>();
    // The sync page animates without end: pump a while instead of settling.
    Future<void> busy() async {
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
    }
    SyncEvent ev(SyncStep k, int done, int total) => SyncEvent(kind: k, check: 0, name: '', peers: const [], peerIds: const [], received: 0, sent: 0, removed: 0, copies: 0, done: done, total: total, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0, repaired: 0, unrepaired: 0, code: '');
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: SyncProgress(place: SyncPlace.drive, events: events.stream, onSynced: () {}, retry: () => const Stream.empty()))));
    await busy();
    events.add(ev(SyncStep.receiving, 2, 5));
    await t.pump();
    // What locking does (vault_home.dart _lock): the pages are told, the lock screen covers them.
    vaultLock.set(true);
    nav.push(PageRouteBuilder<VaultInfo>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const UnlockScreen(libraryDir: 'lib', askBiometricNow: false, resumeVaultId: 'v1')));
    await busy();
    expect(find.byType(UnlockScreen), findsOneWidget);
    expect(find.text('Syncing 40%'), findsOneWidget);
    expect(_fake.syncCancels, 0);
    expect(Awake.busy, isTrue, reason: 'the screen stays on');
    events.add(ev(SyncStep.sending, 3, 4));
    await busy();
    expect(find.text('Syncing 75%'), findsOneWidget);
    events.add(ev(SyncStep.done, 0, 0));
    await busy();
    expect(find.text('Up to date'), findsOneWidget);
    expect(Awake.busy, isFalse);
    // Opening again: back on the finished sync, nothing left on the lock screen.
    await _tapDigits(t, _pin);
    await busy();
    vaultLock.set(false);
    await busy();
    expect(find.byType(UnlockScreen), findsNothing);
    expect(syncStatus.value, isNull);
    expect(find.byKey(const ValueKey('sync-close')), findsOneWidget);
  });

  testWidgets('setting a PIN needs the same digits twice', (t) async {
    await _pump(t, _app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '123456');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '123457');
    await t.pump();
    expect(find.text("The PINs didn't match. Start again."), findsOneWidget);
    expect(_fake.enabledPin, isNull);
    await _tapDigits(t, '123456');
    await t.tap(find.text('Next'));
    await t.pump();
    await _tapDigits(t, '123456');
    await _settle(t);
    expect(_fake.enabledPin, '123456');
  });

  testWidgets('a PIN shorter than 6 digits cannot go on', (t) async {
    await _pump(t, _app(const SetPinScreen()));
    await t.pump();
    await _tapDigits(t, '12345');
    final next = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'));
    expect(next.onPressed, isNull);
  });

  testWidgets('Emergency Kit goes on only with the last 4 characters', (t) async {
    var done = false;
    const key = 'CS1-ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345';
    await _pump(t, _app(EmergencyKitScreen(keyText: key, confirm: true, onDone: () => done = true)));
    await t.pump();
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, "I've saved it"));
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2344');
    await t.pump();
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), '2345');
    await t.pump();
    await t.ensureVisible(find.widgetWithText(FilledButton, "I've saved it"));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, "I've saved it"));
    expect(done, isTrue);
  });

  testWidgets('Recovery Key (24 words) goes on only with the asked word', (t) async {
    var done = false;
    const words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm frown notice actor mom surround nurse feature ski gadget volume cousin cancel';
    await _pump(t, _app(EmergencyKitScreen(keyText: words, confirm: true, onDone: () => done = true)));
    await t.pump();
    final label = t.widget<TextField>(find.byType(TextField)).decoration!.labelText!;
    final n = int.parse(RegExp(r'\d+').firstMatch(label)!.group(0)!);
    final want = words.split(' ')[n - 1];
    FilledButton button() => t.widget<FilledButton>(find.widgetWithText(FilledButton, "I've saved it"));
    await t.enterText(find.byType(TextField), want == 'zoo' ? 'abandon' : 'zoo');
    await t.pump();
    expect(button().onPressed, isNull);
    await t.enterText(find.byType(TextField), want.toUpperCase());
    await t.pump();
    await t.ensureVisible(find.widgetWithText(FilledButton, "I've saved it"));
    await t.tap(find.widgetWithText(FilledButton, "I've saved it"));
    expect(done, isTrue);
  });

  Future<void> leaveAndComeBack(WidgetTester t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
  }

  testWidgets('a note being written stays open with its text through a lock, written once', (t) async {
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
    await t.pump();
    await _tapDigits(t, _pin);
    await _settle(t);
    Navigator.of(t.element(find.byType(VaultHomeScreen))).push(MaterialPageRoute<void>(builder: (_) => const NoteScreen()));
    await _settle(t);
    await t.enterText(find.byType(TextField), 'Shopping list');
    await t.pump();
    await leaveAndComeBack(t);
    // Written before the key went, then the lock over the editor.
    expect(_fake.notesAdded, 1);
    expect(find.byType(UnlockScreen), findsOneWidget);
    await _tapDigits(t, _pin);
    await _settle(t);
    expect(find.byType(UnlockScreen), findsNothing);
    expect(find.byType(NoteScreen), findsOneWidget);
    expect(find.text('Shopping list'), findsOneWidget);
    // More typing updates the same note, never a second one.
    await t.enterText(find.byType(TextField), 'Shopping list\nmilk');
    await t.pump(const Duration(seconds: 2));
    await _settle(t);
    expect(_fake.notesAdded, 1);
    expect(_fake.notesUpdated, 1);
  });

  testWidgets('shown words are hidden again when the vault locks', (t) async {
    const words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm frown notice actor mom surround nurse feature ski gadget volume cousin cancel';
    addTearDown(() => vaultLock.set(false));
    await _pump(t, _app(const EmergencyKitScreen(keyText: words, confirm: false)));
    await t.pump();
    expect(find.text('bounce'), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('secret-show')));
    await t.tap(find.byKey(const ValueKey('secret-show')));
    await t.pump();
    expect(find.text('bounce'), findsOneWidget);
    vaultLock.set(true);
    await t.pump();
    expect(find.text('bounce'), findsNothing);
    vaultLock.set(false);
    await t.pump();
    expect(find.text('bounce'), findsNothing);
  });

  testWidgets('a password typed before the lock is gone after it', (t) async {
    addTearDown(() => vaultLock.set(false));
    await _pump(t, _app(const KitPasswordScreen(libraryDir: 'lib')));
    await t.pump();
    await t.enterText(find.byType(TextField), _password);
    await t.pump();
    vaultLock.set(true);
    await t.pump();
    vaultLock.set(false);
    await t.pump();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('Face ID is not asked on return while something covers the lock screen', (t) async {
    _fake.biometric = true;
    BiometricUnlock.debugKind = BiometricKind.face;
    FlutterSecureStorage.setMockInitialValues({
      'pin-device-key': base64Encode(List.filled(16, 7)),
      'pin-fails': '0',
      'vault-unlock-key': base64Encode(List.filled(32, 5)),
    });
    await _pump(t, _app(const UnlockScreen(libraryDir: 'lib', askBiometricNow: false)));
    await _settle(t);
    // A New vault or Restore opened from the lock screen, half done.
    Navigator.of(t.element(find.byType(UnlockScreen)))
        .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('half done'))));
    await _settle(t);
    await leaveAndComeBack(t);
    expect(_fake.biometricCalls, 0);
    expect(find.text('half done'), findsOneWidget);
    // On the lock screen itself, coming back asks.
    Navigator.of(t.element(find.text('half done'))).pop();
    await _settle(t);
    await leaveAndComeBack(t);
    expect(_fake.biometricCalls, 1);
  });

  group('Lock as soon as I leave the app', () {
    // The clocks AwayClock reads, moved by hand: a monotonic one and the wall clock.
    var mono = Duration.zero;
    var wall = DateTime(2026, 10, 26, 9);
    setUp(() {
      Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
      mono = Duration.zero;
      wall = DateTime(2026, 10, 26, 9);
      AwayClock.monotonic = () => mono;
      AwayClock.wall = () => wall;
    });
    tearDown(() {
      Prefs.dir = '';
      AwayClock.monotonic = () => Duration.zero;
      AwayClock.wall = DateTime.now;
      debugOwnerConfirmed = false;
      SettingsScreen.debugSyncLog = null;
    });

    Future<void> leave(WidgetTester t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
    }

    Future<void> comeBack(WidgetTester t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(t);
    }

    Future<void> open(WidgetTester t) async {
      await _pump(t, _app(const UnlockScreen(libraryDir: 'lib')));
      await t.pump();
      await _tapDigits(t, _pin);
      await _settle(t);
      expect(find.byType(VaultHomeScreen), findsOneWidget);
    }

    // A computer's window goes hidden for a moment while resized, tiled or made full
    // screen (owner 2026-10-28: every resize asked for the PIN).
    testWidgets('on, a computer: a window hidden for a moment stays open, hidden longer locks', (t) async {
      Device.debugDesktop = true;
      addTearDown(() => Device.debugDesktop = false);
      await open(t);
      for (final size in const [Size(1280, 800), Size(390, 844), Size(1440, 900)]) {
        t.view.physicalSize = size * 3;
        await leave(t);
        mono += const Duration(seconds: 1);
        await comeBack(t);
        expect(find.byType(UnlockScreen), findsNothing, reason: 'locked at $size');
      }
      await leave(t);
      mono += const Duration(seconds: 4);
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('on, a computer: hidden for good still locks by itself', (t) async {
      Device.debugDesktop = true;
      addTearDown(() => Device.debugDesktop = false);
      await open(t);
      await leave(t);
      await t.pump(const Duration(seconds: 4));
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('on (the default): leaving locks at once', (t) async {
      expect(Settings.lockOnLeave, isTrue);
      await open(t);
      await leave(t);
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('off: back within the auto-lock time stays open; away that long locks before anything shows', (t) async {
      Settings.lockOnLeave = false;
      Settings.autoLockMinutes = 2;
      await open(t);
      await leave(t);
      mono += const Duration(minutes: 1, seconds: 50);
      wall = wall.add(const Duration(minutes: 1, seconds: 50));
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsNothing);
      expect(find.byType(VaultHomeScreen), findsOneWidget);
      // Time away is counted from leaving, not from the last touch.
      await leave(t);
      mono += const Duration(minutes: 2);
      wall = wall.add(const Duration(minutes: 2));
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('off: setting the clock back does not keep it open', (t) async {
      Settings.lockOnLeave = false;
      Settings.autoLockMinutes = 1;
      await open(t);
      await leave(t);
      mono += const Duration(minutes: 3);
      wall = wall.subtract(const Duration(hours: 5));
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('off: still locks at the auto-lock time while the app runs in the background', (t) async {
      Settings.lockOnLeave = false;
      Settings.autoLockMinutes = 1;
      await open(t);
      await leave(t);
      await t.pump(const Duration(minutes: 1));
      // Both clocks stand still here: only the timer can have locked it.
      await comeBack(t);
      expect(find.byType(UnlockScreen), findsOneWidget);
    });

    testWidgets('turning it off asks for the owner; turning it on does not', (t) async {
      SettingsScreen.debugSyncLog = const [];
      // The owner's phone (iPhone 15 Pro Max): the Left | Middle | Right switch needs its width.
      t.view.physicalSize = const Size(430, 932) * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          _app(SettingsScreen(
            libraryDir: 'lib',
            vault: () => const VaultInfo(id: 'v1', name: '', icon: 'home', color: 'green', hasPassword: true),
            canBiometric: false,
            biometricOn: () => false,
            onToggleBiometric: () async {},
            onPassword: () async {},
            onShowKit: () async {},
            onBackup: () async {},
            lastBackup: () => '',
            onChangeIdentity: () async {},
            onOpenTrash: () async {},
            onNewVault: () async {},
          )));
      await _settle(t);
      final row = find.byKey(const ValueKey('lock-on-leave-row'));
      await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await t.pumpAndSettle();
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      // The owner check fails (no Face ID here): it stays on.
      await t.tap(toggle);
      await _settle(t);
      expect(Settings.lockOnLeave, isTrue);
      // Confirmed: it goes off.
      debugOwnerConfirmed = true;
      await t.tap(toggle);
      await _settle(t);
      expect(Settings.lockOnLeave, isFalse);
      expect(t.widget<Switch>(toggle).value, isFalse);
      // On again: no check needed.
      debugOwnerConfirmed = false;
      await t.tap(toggle);
      await _settle(t);
      expect(Settings.lockOnLeave, isTrue);
    });
  });
}
