// Renders the real screens to PNG so they can be checked against the approved mockups
// without a phone. Off by default:
//   flutter test test/preview_test.dart --update-goldens --dart-define=PREVIEW=true
// Output: test/preview/*.png (not committed). Rust is a fake with sample items.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PictureRecorder, ImageByteFormat;

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/trash.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/add_dock.dart';
import 'package:cozysafe/widgets/identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('PREVIEW');
final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, int size, {int ago = 0, int? deleted}) => ItemInfo(
      id: id.padRight(32, '0'),
      kind: kind,
      name: name,
      mime: kind == 'photo' ? 'image/jpeg' : (name.endsWith('.pdf') ? 'application/pdf' : 'text/plain'),
      createdMs: _now - ago,
      size: BigInt.from(size),
      deletedMs: deleted,
    );

final _items = [
  for (var i = 0; i < 7; i++) _item('a$i', 'photo', 'IMG_$i.jpg', 2400000),
  _item('n1', 'note', 'Mã wifi nhà bà ngoại', 320),
  _item('f1', 'file', 'Hop-dong-thue-nha.pdf', 1200000),
  for (var i = 0; i < 4; i++) _item('b$i', 'photo', 'IMG_b$i.jpg', 1800000, ago: 86400000),
];

/// Small solid-colour PNGs stand in for photo thumbnails.
final _thumbs = <int, Uint8List>{};

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('MinPasswordScore')) return 3;
    if (n.contains('PasswordScore')) return 4;
    if (n.contains('HasVaults')) return true;
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(_items);
    if (n.contains('ListTrash')) {
      return Future<List<ItemInfo>>.value([
        _item('t1', 'photo', 'a.jpg', 900000, deleted: _now - 86400000),
        _item('t2', 'photo', 'b.jpg', 900000, deleted: _now - 18 * 86400000),
        _item('t3', 'file', 'Bao-gia-sua-nha.pdf', 300000, deleted: _now - 27 * 86400000),
      ]);
    }
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('ItemThumbnail')) {
      final id = (call.namedArguments[#id] as String).hashCode;
      return Future<Uint8List>.value(_thumbs[id % 4]);
    }
    if (n.contains('PinLengths')) return Uint32List.fromList([4]);
    if (n.contains('AnyPassword')) return true;
    if (n.contains('HasBiometricUnlock')) return false;
    if (n.contains('BiometricEnabled')) return true;
    if (n.contains('PinEnabled')) return true;
    if (n.contains('Unlock')) return Future<VaultInfo?>.value(null);
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

Future<void> _thumbsReady() async {
  const colors = [Color(0xFF7FA79A), Color(0xFFD9A07A), Color(0xFF9CC4DE), Color(0xFFA77FB0)];
  for (var i = 0; i < colors.length; i++) {
    final rec = PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = colors[i]);
    final img = await rec.endRecording().toImage(32, 32);
    _thumbs[i] = (await img.toByteData(format: ImageByteFormat.png))!.buffer.asUint8List();
  }
}

Future<void> _shot(WidgetTester t, String file, Widget home, {Brightness b = Brightness.light, Color? vault,
    Future<void> Function(WidgetTester)? act}) async {
  t.view.physicalSize = const Size(390, 844) * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('vi'),
    theme: buildTheme(b, vault: vault),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ));
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 100));
  }
  if (act != null) {
    await act(t);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/$file.png'));
}

void main() {
  setUpAll(() async {
    RustLib.initMock(api: _Fake());
    FlutterSecureStorage.setMockInitialValues({});
    debugAddModes = [AddMode.note, AddMode.library, AddMode.camera, AddMode.file];
    await _loadFonts();
  });

  setUp(() async => _thumbs.isEmpty ? await _thumbsReady() : null);

  const vault = VaultInfo(id: 'v', name: '', icon: 'home', color: 'green', hasPassword: true);
  Widget settings(VaultInfo v) => SettingsScreen(
        libraryDir: '',
        vault: () => v,
        canBiometric: true,
        biometricOn: () => true,
        onToggleBiometric: () async {},
        onPassword: () async {},
        onShowKit: () async {},
        onBackup: () async {},
        lastBackup: () => 'Lần cuối: 12 ngày trước',
      );

  testWidgets('lock', skip: !_enabled, (t) => _shot(t, 'lock', const UnlockScreen(libraryDir: '', askBiometricNow: false)));
  testWidgets('lock menu', skip: !_enabled, (t) async {
    await _shot(t, 'lock-menu', const UnlockScreen(libraryDir: '', askBiometricNow: false),
        act: (t) => t.tap(find.byKey(const ValueKey('more-button'))));
  });
  for (final (color, b) in [('green', Brightness.light), ('plum', Brightness.dark), ('amber', Brightness.light), ('amber', Brightness.dark)]) {
    final v = VaultInfo(id: 'v', name: '', icon: 'home', color: color, hasPassword: false);
    final tint = colorById(color).color;
    testWidgets('home $color ${b.name}', skip: !_enabled,
        (t) => _shot(t, 'home-$color-${b.name}', VaultHomeScreen(libraryDir: '', vault: v), b: b, vault: tint));
    testWidgets('settings $color ${b.name}', skip: !_enabled,
        (t) => _shot(t, 'settings-$color-${b.name}', settings(v), b: b, vault: tint));
  }
  testWidgets('trash', skip: !_enabled,
      (t) => _shot(t, 'trash', const TrashScreen(), vault: colorById(vault.color).color));
}
