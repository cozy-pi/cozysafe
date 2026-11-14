// Secure items in the app (ADR 0009): adding one step by step (and QR codes), its page, copying through
// SecureClipboard, a live one-time code, recovery codes marked used, and Top Secret
// Mode opening a login in the app.

import 'dart:convert';
import 'dart:io';

import 'package:cozysafe/entries/entry.dart';
import 'package:cozysafe/entries/secure_clipboard.dart';
import 'package:cozysafe/entries/totp.dart';
import 'package:cozysafe/lock_guard.dart';
import 'package:cozysafe/lock_resume.dart';
import 'package:cozysafe/entries/qr.dart';
import 'package:cozysafe/screens/entry_editor.dart';
import 'package:cozysafe/screens/entry_steps.dart';
import 'package:cozysafe/widgets/secure_menu.dart';
import 'package:cozysafe/widgets/vault_bar.dart' show debugVoice;
import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/platform.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/entry_page.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/quick_look.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/history.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/top_secret_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';

ItemInfo _info(String id, String kind, String name, Map<String, Object?> doc) {
  final account = '${doc[kind == ItemKind.login ? 'username' : 'account'] ?? ''}';
  final urls = doc['urls'] is List ? (doc['urls'] as List).cast<String>() : const <String>[];
  return ItemInfo(
    id: id,
    kind: kind,
    name: name,
    mime: 'application/vnd.cozysafe.$kind+json',
    createdMs: PlatformInt64Util.from(1),
    sizeBytes: BigInt.from(200),
    tagIds: const [],
    isFavorite: false,
    modifiedMs: PlatformInt64Util.from(1),
    account: account,
    // As the core's summary: each web site's host.
    hosts: [for (final u in urls) Uri.parse(u.contains('://') ? u : 'https://$u').host],
  );
}

/// A pretend vault that keeps secure items as the core does: JSON documents, with the
/// summary (account, hosts) taken from them.
class _Fake implements RustLibApi {
  final docs = <String, Map<String, Object?>>{};
  final items = <ItemInfo>[];
  final updates = <String>[];
  final revs = <String, int>{};
  /// The next save finds the item changed on another device.
  bool changedElsewhere = false;
  /// An older version's document, by its revision.
  final versions = <String, String>{};
  final restored = <String>[];
  final trashed = <String>[];
  int _next = 1;

  void put(String id, String kind, String name, Map<String, Object?> doc) {
    docs[id] = {'v': 1, ...doc};
    items.add(_info(id, kind, name, docs[id]!));
  }

  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    T a<T>(String name) => call.namedArguments[Symbol(name)] as T;
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(List.of(items));
    if (n.contains('ListHeld') || n.contains('ListTrash')) return Future<List<ItemInfo>>.value(const []);
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('AddEntry')) {
      final id = 'e${_next++}';
      final doc = jsonDecode(a<String>('json')) as Map<String, Object?>;
      docs[id] = doc;
      final it = _info(id, a<String>('kind'), a<String>('name'), doc);
      items.add(it);
      return Future<ItemInfo>.value(it);
    }
    if (n.contains('UpdateEntry')) {
      final id = a<String>('id');
      if (changedElsewhere || a<String>('rev') != '${revs[id] ?? 0}') {
        changedElsewhere = false;
        revs[id] = (revs[id] ?? 0) + 1;
        return Future<ItemInfo>.error(VaultError.changed);
      }
      revs[id] = (revs[id] ?? 0) + 1;
      updates.add(a<String>('json'));
      final doc = jsonDecode(a<String>('json')) as Map<String, Object?>;
      docs[id] = doc;
      final at = items.indexWhere((i) => i.id == id);
      final it = _info(id, items[at].kind, a<String>('name'), doc);
      items[at] = it;
      return Future<ItemInfo>.value(it);
    }
    if (n.contains('TrashItem')) {
      trashed.add(a<String>('id'));
      items.removeWhere((i) => i.id == a<String>('id'));
      return Future<void>.value();
    }
    if (n.contains('ItemContent') || n.contains('ExportItem')) throw StateError('content read');
    if (n.contains('HistoryEntryJson')) return Future<String>.value(versions[a<String>('rev')]!);
    if (n.contains('EntryJson')) {
      final id = a<String>('id');
      return Future<EntryDoc>.value(EntryDoc(json: jsonEncode(docs[id]), rev: '${revs[id] ?? 0}'));
    }
    if (n.contains('ItemHistory')) {
      return Future<List<HistoryVersion>>.value([
        for (final r in versions.keys)
          HistoryVersion(rev: r, replacedMs: PlatformInt64Util.from(1), item: items.first, thisDevice: true, hasContent: true, sameContent: false),
      ]);
    }
    if (n.contains('HistorySettings')) return Future<HistorySettings>.value(HistorySettings(days: 30, maxBytes: BigInt.zero));
    if (n.contains('RestoreVersion')) {
      restored.add(a<String>('rev'));
      return Future<ItemInfo>.value(items.first);
    }
    if (n.contains('MinPasswordLength')) return 12;
    if (n.contains('PasswordScore')) return 4;
    if (n.contains('PasswordProblem')) return PasswordProblem.none;
    if (n.contains('BiometricEnabled') || n.contains('PinEnabled')) return false;
    return null;
  }
}

late _Fake _fake;

const _vault = VaultInfo(
  code: '7F3A-9K2Q',
  libraryDir: '',
  id: 'v1',
  name: '',
  icon: 'home',
  color: 'green',
  hasPassword: true,
  topSecret: false,
);

Future<void> _settle(WidgetTester t, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await t.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ));
  await _settle(t, 8);
}

/// What the app put on the clipboard (no phone here: SecureClipboard falls back to it).
final _clipboard = <String>[];

void main() {
  setUpAll(() {
    Device.debugDesktop = false;
    RustLib.initMock(api: _fake = _Fake());
  });
  setUp(() {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Prefs.write('add-column-hint', '3');
    _fake.docs.clear();
    _fake.items.clear();
    _fake.updates.clear();
    _fake.revs.clear();
    _fake.versions.clear();
    _fake.restored.clear();
    _fake.changedElsewhere = false;
    _fake.trashed.clear();
    _clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        _clipboard.add((call.arguments as Map)['text'] as String);
      }
      if (call.method == 'Clipboard.getData') return {'text': _clipboard.isEmpty ? '' : _clipboard.last};
      return null;
    });
  });
  tearDown(() => TopSecretMode.on = false);

  testWidgets('the login page copies the password through SecureClipboard, and says for how long', (t) async {
    _fake.put('l1', ItemKind.login, 'GitHub', {
      'username': 'na@example.com',
      'password': 'pa55-Word!x',
      'urls': ['https://github.com'],
      'otp': {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'SHA1', 'digits': 6, 'period': 30},
    });
    await _pump(t, EntryScreen(item: _fake.items.single));
    expect(find.text('pa55-Word!x'), findsNothing, reason: 'masked until asked');
    expect(find.text('github.com'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('entry-copy-password')));
    await _settle(t, 2);
    expect(_clipboard.last, 'pa55-Word!x');
    expect(find.text('Copied · cleared in ${SecureClipboard.standard} s'), findsOneWidget);
    // The login's one-time code shows live, in two groups.
    final code = t.widget<Text>(find.byKey(const ValueKey('entry-code-value'))).data!;
    expect(code, matches(RegExp(r'^\d{3} \d{3}$')));
    await t.tap(find.byKey(const ValueKey('entry-reveal')));
    await t.pump();
    expect(find.text('pa55-Word!x'), findsOneWidget);
    // Its clearing timer runs out (the wipe itself compares the wall clock).
    await t.pump(const Duration(seconds: SecureClipboard.standard + 1));
  });

  testWidgets('a one-time code page shows a live 6-digit code; a tap copies it', (t) async {
    _fake.put('o1', ItemKind.otp, 'Google', {
      'secret': 'JBSWY3DPEHPK3PXP',
      'algo': 'SHA1',
      'digits': 6,
      'period': 30,
      'issuer': 'Google',
      'account': 'na@example.com',
    });
    Prefs.write(SecureClipboard.pref, '0'); // never cleared: no timer left behind
    await _pump(t, EntryScreen(item: _fake.items.single));
    final code = t.widget<Text>(find.byKey(const ValueKey('entry-code-value'))).data!;
    expect(code, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(find.text('Google'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('entry-otp')));
    await _settle(t, 2);
    expect(_clipboard.last, code.replaceAll(' ', ''));
    expect(find.text('Copied'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('recovery codes: marking one used saves the item', (t) async {
    _fake.put('c1', ItemKind.codes, 'GitHub codes', {
      'account': 'na@example.com',
      'codes': [
        {'code': 'aaaa-1111'},
        {'code': 'bbbb-2222'},
      ],
    });
    await _pump(t, EntryScreen(item: _fake.items.single));
    expect(find.text('2 of 2 unused'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('entry-used-1')));
    await _settle(t, 3);
    final saved = jsonDecode(_fake.updates.single) as Map<String, Object?>;
    expect(saved['codes'], [
      {'code': 'aaaa-1111'},
      {'code': 'bbbb-2222', 'used': true},
    ]);
    expect(saved['account'], 'na@example.com', reason: 'the rest of the document is kept');
    expect(find.text('1 of 2 unused'), findsOneWidget);
  });

  testWidgets('Top Secret: a login opens in the app, on its own page', (t) async {
    TopSecretMode.on = true;
    Prefs.write('vault-section', 'password');
    _fake.put('l1', ItemKind.login, 'Bank', {'username': 'na', 'password': 'x-very-secret', 'urls': ['bank.example']});
    await _pump(t, const VaultHomeScreen(libraryDir: '', vault: _vault));
    expect(find.text('na · bank.example'), findsOneWidget);
    await t.tap(find.text('Bank'));
    await _settle(t);
    expect(find.byKey(const ValueKey('entry-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('sealed-item')), findsNothing);
    expect(find.byType(QuickLook), findsNothing);
  });

  testWidgets('a kind from a newer version: a row that says so, opens nothing, offers only Delete', (t) async {
    Prefs.write('vault-section', 'file');
    _fake.items.add(_info('k1', 'card', 'Visa', const {}));
    await _pump(t, const VaultHomeScreen(libraryDir: '', vault: _vault));
    expect(find.text('Needs a newer version of Cozy Safe'), findsOneWidget);
    await t.tap(find.text('Visa'));
    await _settle(t, 3);
    expect(find.byType(QuickLook), findsNothing);
    expect(find.byKey(const ValueKey('menu-delete')), findsOneWidget);
    for (final k in ['menu-open', 'menu-send', 'menu-rename', 'menu-history', 'menu-info']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
    }
    await t.tap(find.byKey(const ValueKey('menu-delete')));
    await _settle(t, 3);
    await t.tap(find.byKey(const ValueKey('confirm-delete-go')));
    await _settle(t, 3);
    expect(_fake.trashed, ['k1']);
    await t.pump(const Duration(seconds: 6));
  });

  // ---- regressions from the security review ----

  final nav = GlobalKey<NavigatorState>();
  /// [page] pushed over a plain page, so it can pop.
  Future<void> pushed(WidgetTester t, Widget page) async {
    t.view.physicalSize = const Size(390, 844) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      navigatorKey: nav,
      theme: buildTheme(Brightness.light),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ));
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
    await _settle(t, 3);
  }

  // ---- the add card: second choices in place (owner 2026-11-07) ----

  /// A vault holding one note: the home page, the + button.
  Future<void> homeWithNote(WidgetTester t) async {
    _fake.put('n1', ItemKind.note, 'Shopping', const {});
    await _pump(t, const VaultHomeScreen(libraryDir: '', vault: _vault));
  }

  Future<void> openPlus(WidgetTester t) async {
    await t.tap(find.byTooltip('Add to vault'));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('add-card')), findsOneWidget);
  }

  testWidgets('the choices of a way replace the four ways in the same card: no new card, page or dimming', (t) async {
    debugVoice = true;
    addTearDown(() => debugVoice = false);
    // A phone's height: the test's default 600 squeezes the card to the same size either way.
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await homeWithNote(t);
    await openPlus(t);
    final route = ModalRoute.of(t.element(find.byKey(const ValueKey('add-card'))));
    final barriers = find.byType(ModalBarrier).evaluate().length;
    final blurs = find.byType(BackdropFilter).evaluate().length;
    final bottom = t.getRect(find.byKey(const ValueKey('add-card'))).bottom;
    final height = t.getRect(find.byKey(const ValueKey('add-card'))).height;
    Future<void> into(String way, List<String> choices, String title) async {
      await t.tap(find.byKey(ValueKey('add-card-$way')));
      await _settle(t, 3);
      for (final c in choices) {
        expect(find.byKey(ValueKey('add-choice-$c')), findsOneWidget, reason: '$way → $c');
      }
      expect(find.byKey(const ValueKey('add-card')), findsOneWidget);
      expect(find.byKey(ValueKey('add-card-$way')), findsNothing, reason: 'the four ways made room');
      expect(find.text(title), findsOneWidget);
      // The same card on the same page, where it was: no route, barrier or blur on top.
      expect(ModalRoute.of(t.element(find.byKey(const ValueKey('add-card')))), same(route));
      expect(find.byType(ModalBarrier).evaluate().length, barriers);
      expect(find.byType(BackdropFilter).evaluate().length, blurs);
      expect(find.byType(EntryWizard), findsNothing);
      expect(t.getRect(find.byKey(const ValueKey('add-card'))).bottom, closeTo(bottom, 1), reason: 'anchored by +');
      await t.pump(const Duration(seconds: 1)); // the card's resize runs a moment after
      await t.pump(const Duration(seconds: 1));
      // Owner 2026-11-14: the card shrinking to the fewer choices was unpleasant.
      expect(t.getRect(find.byKey(const ValueKey('add-card'))).height, closeTo(height, 1), reason: 'as tall as before');
      expect(find.byTooltip('Back'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('add-card-back')));
      await _settle(t, 3);
      expect(find.byKey(ValueKey('add-card-$way')), findsOneWidget, reason: 'back to the four ways');
      expect(find.byKey(ValueKey('add-choice-${choices.first}')), findsNothing);
    }

    await into('password', ['login', 'otp', 'codes'], 'What to add?');
    await into('device', ['photos', 'file'], 'Add from this device');
    await into('memo', ['note', 'voice'], 'Write or record?');
  });

  testWidgets('each kind of password opens the steps on its own first step; Back leaves', (t) async {
    await homeWithNote(t);
    for (final (kind, step) in [('login', 'site'), ('otp', 'otpSource'), ('codes', 'site')]) {
      await openPlus(t);
      await t.tap(find.byKey(const ValueKey('add-card-password')));
      await _settle(t, 3);
      await t.tap(find.byKey(ValueKey('add-choice-$kind')));
      await _settle(t, 4);
      expect(find.byType(EntryWizard), findsOneWidget, reason: kind);
      expect(find.byKey(ValueKey('steps-$step')), findsOneWidget, reason: kind);
      expect(find.byKey(const ValueKey('steps-chooser')), findsNothing, reason: 'chosen in the card already');
      expect(find.byKey(const ValueKey('add-card')), findsNothing, reason: 'the card closed');
      await t.tap(find.byKey(const ValueKey('step-back')));
      await _settle(t, 4);
      expect(find.byType(EntryWizard), findsNothing, reason: '$kind: Back from the first step leaves');
    }
  });

  testWidgets('without voice, Note opens a note at once', (t) async {
    await homeWithNote(t);
    await openPlus(t);
    expect(find.byKey(const ValueKey('add-card-memo')), findsNothing);
    await t.tap(find.byKey(const ValueKey('add-card-note')));
    await _settle(t, 4);
    expect(find.byKey(const ValueKey('add-choice-note')), findsNothing);
    expect(find.byType(NoteScreen), findsOneWidget);
  });

  testWidgets('an empty vault: the Password tile opens the add card on its three kinds', (t) async {
    await _pump(t, const VaultHomeScreen(libraryDir: '', vault: _vault));
    await t.tap(find.byKey(const ValueKey('add-password')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('add-card')), findsOneWidget);
    for (final k in ['login', 'otp', 'codes']) {
      expect(find.byKey(ValueKey('add-choice-$k')), findsOneWidget, reason: k);
    }
    expect(find.byType(EntryWizard), findsNothing);
  });

  testWidgets('the home page always shows Passwords, 0 included; it opens the section, which offers to add one', (t) async {
    await homeWithNote(t);
    final tile = find.byKey(const ValueKey('kind-row-password'));
    expect(tile, findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('0')), findsOneWidget);
    await t.tap(tile);
    await _settle(t, 3);
    expect(find.text('No passwords yet'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('empty-add-password')));
    await _settle(t, 3);
    expect(find.byKey(const ValueKey('add-choice-login')), findsOneWidget);    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('a vault with passwords counts them on the tile', (t) async {
    _fake.put('l0', ItemKind.login, 'GitHub', {'username': 'na', 'urls': ['https://github.com']});
    _fake.put('n1', ItemKind.note, 'Shopping', const {});
    await _pump(t, const VaultHomeScreen(libraryDir: '', vault: _vault));
    expect(find.descendant(of: find.byKey(const ValueKey('kind-row-password')), matching: find.text('1')), findsOneWidget);
  });

  testWidgets('a new login with taps only: a known site, an account used before, the password made, no 2FA', (t) async {
    _fake.put('l0', ItemKind.login, 'GitHub work', {'username': 'na@example.com', 'urls': ['https://github.com']});
    await pushed(t, const EntryWizard(debugPassword: 'gen-erated-1'));
    await t.tap(find.byKey(const ValueKey('steps-kind-login')));
    await _settle(t, 2);
    // The vault's own site first, then the common ones; letters, no logos.
    expect(find.text('In this vault'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('steps-site-github.com')).first);
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-account-0')));
    await _settle(t, 2);
    // Typing comes first; a strong one on request.
    expect(find.byKey(const ValueKey('steps-password-input')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('steps-password-make')));
    await t.pump();
    // Made on request, so shown at once (the person asked for it); the eye hides it.
    expect(find.text('gen-erated-1'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('steps-password-eye')));
    await t.pump();
    expect(find.text('gen-erated-1'), findsNothing);
    await t.tap(find.byKey(const ValueKey('steps-password-use')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-2fa-skip')));
    await _settle(t, 2);
    expect(t.widget<TextField>(find.byKey(const ValueKey('steps-name'))).controller!.text, 'github.com');
    expect(find.text('na@example.com'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('steps-save')));
    await _settle(t);
    final saved = _fake.items.last;
    expect(saved.kind, ItemKind.login);
    expect(saved.name, 'github.com');
    expect(_fake.docs[saved.id], {
      'v': 1,
      'username': 'na@example.com',
      'password': 'gen-erated-1',
      'urls': ['https://github.com'],
    });
  });

  testWidgets('a one-time code from a pasted otpauth link: service and account filled, the code shown live', (t) async {
    _clipboard.add('otpauth://totp/Acme:na@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme&digits=6');
    await pushed(t, const EntryWizard());
    await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-qr-paste')));
    await _settle(t, 2);
    expect(_clipboard.last, '', reason: 'the key leaves the clipboard');
    expect(t.widget<TextField>(find.byKey(const ValueKey('steps-issuer'))).controller!.text, 'Acme');
    expect(t.widget<TextField>(find.byKey(const ValueKey('steps-otp-account'))).controller!.text, 'na@example.com');
    expect(t.widget<Text>(find.byKey(const ValueKey('steps-code-preview'))).data, matches(RegExp(r'^\d{3} \d{3}$')));
    await t.tap(find.byKey(const ValueKey('steps-save')));
    await _settle(t);
    final saved = _fake.items.single;
    expect(saved.kind, ItemKind.otp);
    expect(saved.name, 'Acme');
    expect(_fake.docs[saved.id], containsPair('secret', 'JBSWY3DPEHPK3PXP'));
    expect(_fake.docs[saved.id], containsPair('issuer', 'Acme'));
    expect(_fake.docs[saved.id], containsPair('account', 'na@example.com'));
    await t.pump(const Duration(seconds: 2));
  });

  group('QR codes', () {
    final scans = <String?>[];
    setUp(() {
      QrCode.debugAvailable = (camera: true, photo: true);
      QrCode.debugScan = () async => scans.removeAt(0);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(QrCode.channel, (call) async {
        if (call.method == 'pickImage') return scans.removeAt(0);
        return null;
      });
    });
    tearDown(() {
      QrCode.debugAvailable = null;
      QrCode.debugScan = null;
      scans.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(QrCode.channel, null);
    });

    testWidgets('a scanned otpauth link fills the review; a QR code of anything else says so', (t) async {
      scans.addAll(['https://example.com/promo', '', 'otpauth://totp/GitHub:na?secret=JBSWY3DPEHPK3PXP&issuer=GitHub']);
      await pushed(t, const EntryWizard());
      await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      expect(find.text('This QR code is not a two-factor setup code'), findsOneWidget);
      expect(find.byKey(const ValueKey('steps-otpSource')), findsOneWidget, reason: 'stays on the step');
      await t.tap(find.byKey(const ValueKey('steps-qr-photo')));
      await _settle(t, 2);
      expect(find.text('No QR code found in this picture'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      expect(t.widget<TextField>(find.byKey(const ValueKey('steps-issuer'))).controller!.text, 'GitHub');
      expect(t.widget<TextField>(find.byKey(const ValueKey('steps-otp-account'))).controller!.text, 'na');
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a second scan brings its own service and account, unless typed over', (t) async {
      scans.addAll([
        'otpauth://totp/GitHub:na?secret=JBSWY3DPEHPK3PXP&issuer=GitHub',
        'otpauth://totp/GitLab:nb?secret=JBSWY3DPEHPK3PXQ&issuer=GitLab',
      ]);
      await pushed(t, const EntryWizard());
      await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      await t.enterText(find.byKey(const ValueKey('steps-otp-account')), 'mine');
      await t.tap(find.byKey(const ValueKey('step-back')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      expect(t.widget<TextField>(find.byKey(const ValueKey('steps-issuer'))).controller!.text, 'GitLab');
      expect(t.widget<TextField>(find.byKey(const ValueKey('steps-otp-account'))).controller!.text, 'mine');
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a scan that ends after the vault locked is dropped', (t) async {
      await pushed(t, const EntryWizard());
      QrCode.debugScan = () async {
        vaultLock.set(true);
        return 'otpauth://totp/GitHub:na?secret=JBSWY3DPEHPK3PXP&issuer=GitHub';
      };
      await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      vaultLock.set(false);
      await _settle(t, 2);
      expect(find.byKey(const ValueKey('steps-otpSource')), findsOneWidget, reason: 'the code did not land');
    });

    testWidgets('a login takes its 2FA from a scan; the review says so', (t) async {
      scans.add('otpauth://totp/Shop:na?secret=JBSWY3DPEHPK3PXP');
      await pushed(t, const EntryWizard(debugPassword: 'gen-erated-1'));
      await t.tap(find.byKey(const ValueKey('steps-kind-login')));
      await _settle(t, 2);
      await t.enterText(find.byKey(const ValueKey('steps-site-search')), 'shop.example');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('steps-site-typed')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-skip')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-password-make')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('steps-password-use')));
      await _settle(t, 2);
      await t.tap(find.byKey(const ValueKey('steps-qr-scan')));
      await _settle(t, 2);
      expect(t.widget<Text>(find.byKey(const ValueKey('steps-review-2fa'))).data, 'Added');
      await t.tap(find.byKey(const ValueKey('steps-save')));
      await _settle(t);
      final doc = _fake.docs.values.single;
      expect(doc['urls'], ['https://shop.example']);
      expect((doc['otp'] as Map)['secret'], 'JBSWY3DPEHPK3PXP');
    });
  });

  testWidgets('a pasted bare key shows its code first; Paste again or go on', (t) async {
    _clipboard.add('jbsw y3dp ehpk 3pxp');
    await pushed(t, const EntryWizard());
    await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-qr-paste')));
    await _settle(t, 2);
    expect(find.text('Does the site show this code?'), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const ValueKey('steps-code-preview'))).data, matches(RegExp(r'^\d{3} \d{3}$')));
    await t.tap(find.byKey(const ValueKey('steps-key-confirm')));
    await _settle(t, 2);
    expect(find.byKey(const ValueKey('steps-otpReview')), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
  });

  test('a malformed otpauth link is not a code, and never throws', () {
    expect(Totp.parse('otpauth://totp/a%E0?secret=JBSWY3DPEHPK3PXP'), isNull);
    // Dart keeps a stray % as it is: still a code, not an error.
    expect(Totp.parse('otpauth://totp/A?secret=JBSWY3DPEHPK3PXP&issuer=%ZZ')?.issuer, '%ZZ');
    expect(QrCode.read('otpauth://totp/a%E0?secret=JBSWY3DPEHPK3PXP'), isA<QrNotTotp>());
  });

  testWidgets('locked before anything could be saved: the steps go on after, and Save works', (t) async {
    await pushed(t, const EntryWizard(debugPassword: 'gen-erated-1'));
    await t.tap(find.byKey(const ValueKey('steps-kind-otp')));
    await _settle(t, 2);
    await LockGuard.beforeLock!();
    vaultLock.set(true);
    await t.pump();
    expect(_fake.items, isEmpty, reason: 'nothing to save yet');
    vaultLock.set(false);
    await _settle(t, 2);
    _clipboard.add('otpauth://totp/Acme:na?secret=JBSWY3DPEHPK3PXP&issuer=Acme');
    await t.tap(find.byKey(const ValueKey('steps-qr-paste')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-save')));
    await _settle(t);
    expect(_fake.items.single.name, 'Acme');
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('recovery codes from a pasted list: counted, saved under the service', (t) async {
    _clipboard.add('aaaa-1111\nbbbb-2222, cccc 3333');
    await pushed(t, const EntryWizard());
    await t.tap(find.byKey(const ValueKey('steps-kind-codes')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-site-google.com')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-codes-paste')));
    await _settle(t, 2);
    expect(find.text('3 codes'), findsOneWidget);
    expect(find.text('aaaa-1111'), findsNothing, reason: 'masked until the eye');
    expect(_clipboard.last, '', reason: 'the codes leave the clipboard');
    await t.tap(find.byKey(const ValueKey('steps-next')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-save')));
    await _settle(t);
    final saved = _fake.items.single;
    expect(saved.name, 'google.com');
    expect(_fake.docs[saved.id]!['codes'], [
      {'code': 'aaaa-1111'},
      {'code': 'bbbb-2222'},
      {'code': 'cccc 3333'},
    ]);
  });

  Map<String, Object?> lastDoc() => jsonDecode(_fake.updates.last) as Map<String, Object?>;

  EntryEditor editorOf(String id) {
    final it = _fake.items.firstWhere((i) => i.id == id);
    return EntryEditor(item: it, entry: Entry.decode(it.kind, jsonEncode(_fake.docs[id])), rev: '${_fake.revs[id] ?? 0}');
  }

  const otp = {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'SHA256', 'digits': 8, 'period': 60, 'issuer': 'Acme', 'account': 'na', 'x-new': 1};

  testWidgets('editing a one-time code item keeps its digits, period, algorithm and the rest', (t) async {
    _fake.put('o1', ItemKind.otp, 'Acme', otp);
    await pushed(t, editorOf('o1'));
    await t.enterText(find.byKey(const ValueKey('entry-name')), 'Acme work');
    await t.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(t);
    expect(lastDoc(), {'v': 1, ...otp});
    // A new bare secret keeps the code's parameters.
    await pushed(t, editorOf('o1'));
    await t.enterText(find.byKey(const ValueKey('entry-key')), 'JBSWY3DPEHPK3PXQ');
    await t.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(t);
    expect(lastDoc(), {'v': 1, ...otp, 'secret': 'JBSWY3DPEHPK3PXQ'});
  });

  testWidgets("editing a login's password keeps its one-time code as it was", (t) async {
    _fake.put('l1', ItemKind.login, 'Acme', {'username': 'na', 'password': 'old-one-1', 'otp': otp});
    await pushed(t, editorOf('l1'));
    await t.enterText(find.byKey(const ValueKey('entry-password-input')), 'new-one-2');
    await t.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(t);
    expect(lastDoc()['otp'], otp);
    expect(lastDoc()['password'], 'new-one-2');
  });

  test("Entry setters keep what this version doesn't know", () {
    final e = Entry(ItemKind.login, {
      'urls': ['a.com', {'url': 'b.com', 'match': 'exact'}],
      'otp': {...otp},
      'codes': [{'code': 'x1', 'note': 'kept'}, {'code': 'y2', 'used': true}],
    });
    e.urls = ['c.com'];
    expect(e.doc['urls'], ['c.com', {'url': 'b.com', 'match': 'exact'}]);
    e.totp = const Totp(secret: 'JBSWY3DPEHPK3PXQ');
    expect((e.doc['otp'] as Map)['x-new'], 1);
    e.codes = [(code: 'x1', used: true), (code: 'z3', used: false)];
    expect(e.doc['codes'], [
      {'code': 'x1', 'note': 'kept', 'used': true},
      {'code': 'z3'},
    ]);
    expect(Entry(ItemKind.login, {'v': 2}).newer, isTrue);
    expect(Entry(ItemKind.login, {'v': 1}).newer, isFalse);
  });

  test('otpauth links spell the algorithm either way', () {
    expect(Totp.parse('otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP&algorithm=SHA-256')?.algo, 'SHA256');
    expect(Totp.parse('otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP&algorithm=sha-512')?.algo, 'SHA512');
  });

  testWidgets("a newer version's document opens read only", (t) async {
    _fake.put('c1', ItemKind.codes, 'Codes', {'v': 2, 'codes': [{'code': 'aaaa-1111'}]});
    _fake.docs['c1']!['v'] = 2;
    await _pump(t, EntryScreen(item: _fake.items.single));
    expect(find.byKey(const ValueKey('entry-newer')), findsOneWidget);
    expect(t.widget<IconButton>(find.byKey(const ValueKey('entry-used-0'))).onPressed, isNull);
    final edit = find.descendant(of: find.byKey(const ValueKey('entry-edit')), matching: find.byType(IconButton));
    expect(t.widget<IconButton>(edit).onPressed, isNull);
  });

  testWidgets('recovery codes are masked until the eye; a code marked used elsewhere reloads', (t) async {
    _fake.put('c1', ItemKind.codes, 'Codes', {'codes': [{'code': 'aaaa-1111'}, {'code': 'bbbb-2222'}]});
    await _pump(t, EntryScreen(item: _fake.items.single));
    expect(find.text('aaaa-1111'), findsNothing);
    await t.tap(find.byKey(const ValueKey('entry-codes-reveal')));
    await t.pump();
    expect(find.text('aaaa-1111'), findsOneWidget);
    _fake.changedElsewhere = true;
    await t.tap(find.byKey(const ValueKey('entry-used-0')));
    await _settle(t, 3);
    expect(find.text('Changed on another device; reloaded'), findsOneWidget);
    await t.pump(const Duration(seconds: 31));
    expect(find.text('aaaa-1111'), findsNothing, reason: 'hidden again after 30 s');
  });

  testWidgets('the editor keeps what was typed when the item changed elsewhere', (t) async {
    _fake.put('l1', ItemKind.login, 'Acme', {'username': 'na', 'password': 'old-one-1'});
    await pushed(t, editorOf('l1'));
    await t.enterText(find.byKey(const ValueKey('entry-password-input')), 'typed-here');
    _fake.changedElsewhere = true;
    await t.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(t);
    expect(find.byKey(const ValueKey('entry-changed')), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await _settle(t, 2);
    expect(t.widget<TextField>(find.byKey(const ValueKey('entry-password-input'))).controller!.text, 'typed-here');
    // Still out of date: asked again; Save anyway reads the item as it is now first.
    await t.tap(find.byKey(const ValueKey('entry-save')));
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('entry-changed-save')));
    await _settle(t);
    expect(lastDoc()['password'], 'typed-here');
  });

  testWidgets('locking mid-way: what was chosen is saved, the secrets leave the screen, then come back', (t) async {
    await pushed(t, const EntryWizard(debugPassword: 'gen-erated-1'));
    await t.tap(find.byKey(const ValueKey('steps-kind-login')));
    await _settle(t, 2);
    // Typing filters the list.
    await t.enterText(find.byKey(const ValueKey('steps-site-search')), 'git');
    await t.pump();
    expect(find.byKey(const ValueKey('steps-site-google.com')), findsNothing);
    await t.tap(find.byKey(const ValueKey('steps-site-github.com')));
    await _settle(t, 2);
    await t.enterText(find.byKey(const ValueKey('steps-account-field')), 'na');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('steps-next')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-password-make')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('steps-password-eye')));
    await t.pump();
    await LockGuard.beforeLock!();
    vaultLock.set(true);
    await t.pump();
    final id = _fake.items.single.id;
    expect(_fake.docs[id]!['password'], 'gen-erated-1');
    expect(_fake.docs[id]!['username'], 'na');
    expect(find.text('gen-erated-1'), findsNothing, reason: 'no secret under the lock screen');
    vaultLock.set(false);
    await _settle(t, 3);
    await t.tap(find.byKey(const ValueKey('steps-password-eye')));
    await t.pump();
    expect(find.text('gen-erated-1'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('steps-password-use')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-2fa-skip')));
    await _settle(t, 2);
    await t.tap(find.byKey(const ValueKey('steps-save')));
    await _settle(t);
    expect(_fake.items, hasLength(1), reason: 'the same item, changed');
    expect(lastDoc()['password'], 'gen-erated-1');
  });

  testWidgets("a secret field's Copy goes through SecureClipboard", (t) async {
    final text = TextEditingController(text: 'hunter22');
    await _pump(t, Scaffold(body: TextField(controller: text, contextMenuBuilder: secureContextMenu)));
    await t.tap(find.byType(TextField));
    await t.pump();
    text.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
    await t.pump();
    t.state<EditableTextState>(find.byType(EditableText)).showToolbar();
    await t.pumpAndSettle();
    await t.tap(find.text('Copy'));
    await _settle(t, 2);
    expect(_clipboard.last, 'hunter22');
    await t.pump(const Duration(seconds: SecureClipboard.standard + 1));
  });

  testWidgets("an older version opens masked on the item's own page, with Restore", (t) async {
    _fake.put('l1', ItemKind.login, 'Acme', {'username': 'na', 'password': 'now-1'});
    _fake.versions['r1'] = jsonEncode({'v': 1, 'username': 'na', 'password': 'before-0'});
    final v = HistoryVersion(
        rev: 'r1', replacedMs: PlatformInt64Util.from(1), item: _fake.items.single, thisDevice: true, hasContent: true, sameContent: false);
    await pushed(t, EntryScreen(item: _fake.items.single, version: v));
    expect(find.text('before-0'), findsNothing);
    await t.tap(find.byKey(const ValueKey('entry-reveal')));
    await t.pump();
    expect(find.text('before-0'), findsOneWidget);
    expect(find.byKey(const ValueKey('entry-delete')), findsNothing);
    await t.tap(find.byKey(const ValueKey('history-restore')));
    await _settle(t);
    expect(_fake.restored, ['r1']);
  });

  testWidgets('keyboard Copy and Cut in a secret field go through SecureClipboard; masked, nothing', (t) async {
    final text = TextEditingController(text: 'hunter22');
    var shown = true;
    await _pump(t, Scaffold(body: SecureCopy(controller: text, allowed: () => shown, child: TextField(controller: text))));
    await t.tap(find.byType(TextField));
    await t.pump();
    text.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await t.pump();
    Future<void> chord(LogicalKeyboardKey key) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(key);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(t, 2);
    }

    await chord(LogicalKeyboardKey.keyC);
    expect(_clipboard, ['hunter']);
    await chord(LogicalKeyboardKey.keyX);
    expect(_clipboard.last, 'hunter');
    expect(text.text, '22');
    shown = false;
    text.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await t.pump();
    await chord(LogicalKeyboardKey.keyC);
    expect(_clipboard, ['hunter', 'hunter'], reason: 'a masked secret is not copied');
    await t.pump(const Duration(seconds: SecureClipboard.standard + 1));
  });

  testWidgets('saving on lock over a change made elsewhere keeps both, the typing as a new item', (t) async {
    _fake.put('l1', ItemKind.login, 'Acme', {'username': 'na', 'password': 'theirs-1'});
    await pushed(t, editorOf('l1'));
    await t.enterText(find.byKey(const ValueKey('entry-password-input')), 'mine-2');
    _fake.changedElsewhere = true;
    await LockGuard.beforeLock!();
    expect(_fake.docs['l1']!['password'], 'theirs-1', reason: 'the other change stays');
    final copy = _fake.items.firstWhere((i) => i.id != 'l1');
    expect(copy.name, 'Acme (unsaved)');
    expect(copy.kind, ItemKind.login);
    expect(_fake.docs[copy.id]!['password'], 'mine-2');
    expect(_fake.docs[copy.id]!['username'], 'na');
  });
}
