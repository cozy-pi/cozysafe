// Renders the real screens to PNG for the website and store listings.
// Off by default; the screenshots workflow runs:
//   flutter test test/screenshots_test.dart --update-goldens --dart-define=SCREENSHOTS=true
// Rust is replaced by a fake API, so no vault or password is involved.
import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');

/// Answers every bridge call the screens make, by name.
class _FakeRust implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final name = call.memberName.toString();
    if (name.contains('MinPasswordLength')) return 8;
    if (name.contains('MinPinLength')) return 6;
    if (name.contains('MinPasswordScore')) return 3;
    if (name.contains('PasswordScore')) return 4;
    if (name.contains('HasVaults')) return true;
    if (name.contains('ListItems')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListHeld')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('ListTrash')) return Future<List<ItemInfo>>.value(const []);
    if (name.contains('PurgeExpired')) return Future<int>.value(0);
    if (name.contains('HasBiometricUnlock')) return false;
    if (name.contains('PinLengths')) return Uint32List.fromList([4]);
    if (name.contains('AnyPassword')) return false;
    if (name.contains('PinEnabled')) return false;
    if (name.contains('Unlock')) return Future<VaultInfo?>.value(null);
    if (name.contains('BiometricEnabled')) return false;
    return null;
  }
}

Future<void> _loadFonts() async {
  final dir = Directory('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts');
  Future<ByteData> bytes(File f) async => ByteData.view((await f.readAsBytes()).buffer);
  final roboto = FontLoader('Roboto');
  for (final f in dir.listSync().whereType<File>()) {
    final n = f.uri.pathSegments.last;
    if (n.startsWith('Roboto-') && n.endsWith('.ttf')) roboto.addFont(bytes(f));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(bytes(File('${dir.path}/MaterialIcons-Regular.otf')))).load();
}

Future<void> _shoot(
  WidgetTester tester, {
  required String file,
  required Locale locale,
  required Brightness brightness,
  required Widget home,
  Future<void> Function(WidgetTester)? act,
  Size size = const Size(390, 844), // phone; desktop shots pass 1280 × 800
}) async {
  tester.view.physicalSize = size * 2; // rendered at 2×
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: locale,
    theme: buildTheme(brightness),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ));
  await tester.pumpAndSettle();
  if (act != null) {
    await act(tester);
    await tester.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$file.png'));
}

void main() {
  setUpAll(() async {
    RustLib.initMock(api: _FakeRust());
    EditableText.debugDeterministicCursor = true;
    await _loadFonts();
  });

  for (final lang in ['vi', 'en']) {
    final locale = Locale(lang);

    testWidgets('$lang create', skip: !_enabled, (tester) async {
      await _shoot(
        tester,
        file: '$lang-create',
        locale: locale,
        brightness: Brightness.light,
        home: const NewVaultScreen(libraryDir: '', first: true),
      );
    });

    testWidgets('$lang unlock', skip: !_enabled, (tester) async {
      await _shoot(
        tester,
        file: '$lang-unlock',
        locale: locale,
        brightness: Brightness.light,
        home: const UnlockScreen(libraryDir: ''),
        act: (t) async => FocusManager.instance.primaryFocus?.unfocus(),
      );
    });

    testWidgets('$lang home dark', skip: !_enabled, (tester) async {
      await _shoot(
        tester,
        file: '$lang-home-dark',
        locale: locale,
        brightness: Brightness.dark,
        home: VaultHomeScreen(
          libraryDir: '',
          vault: VaultInfo(id: 'preview', name: '', icon: 'home', color: 'green', hasPassword: true),
        ),
      );
    });

    testWidgets('$lang desktop unlock', skip: !_enabled, (tester) async {
      await _shoot(
        tester,
        file: '$lang-desktop-unlock',
        locale: locale,
        brightness: Brightness.light,
        size: const Size(1280, 800),
        home: const UnlockScreen(libraryDir: ''),
        act: (t) async => FocusManager.instance.primaryFocus?.unfocus(),
      );
    });

    testWidgets('$lang desktop create dark', skip: !_enabled, (tester) async {
      await _shoot(
        tester,
        file: '$lang-desktop-create-dark',
        locale: locale,
        brightness: Brightness.dark,
        size: const Size(1280, 800),
        home: const NewVaultScreen(libraryDir: '', first: true),
      );
    });
  }
}
