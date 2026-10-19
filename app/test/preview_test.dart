// Renders the real screens to PNG so they can be checked against the approved mockups
// without a phone. Off by default:
//   flutter test test/preview_test.dart --update-goldens --dart-define=PREVIEW=true
// Output: test/preview/*.png (not committed). Rust is a fake with sample items.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PictureRecorder, ImageByteFormat;

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/search.dart';
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

ItemInfo _item(String id, String kind, String name, int size,
        {int ago = 0, int? deleted, int? duration, String? folder, String? color}) =>
    ItemInfo(
      id: id.padRight(32, '_'),
      kind: kind,
      name: name,
      mime: kind == 'photo' ? 'image/jpeg' : (name.endsWith('.pdf') ? 'application/pdf' : 'text/plain'),
      createdMs: _now - ago,
      size: BigInt.from(size),
      deletedMs: deleted,
      durationMs: duration,
      folder: folder?.padRight(32, '_'),
      color: color,
    );

const _day = 86400000;

/// Realistic content: what people actually keep in a vault.
final _items = [
  for (var i = 0; i < 5; i++) _item('p$i', 'photo', 'IMG_${4810 + i}.HEIC', 2400000 + i * 90000, ago: i * 600000),
  _item('v1', 'video', 'Sinh nhật bé Na.MOV', 38400000, ago: 3600000, duration: 42000),
  for (var i = 5; i < 9; i++) _item('p$i', 'photo', 'IMG_${4790 + i}.HEIC', 2100000, ago: _day + i * 300000),
  _item('v2', 'video', 'Đi biển Quy Nhơn.MOV', 126000000, ago: _day * 2, duration: 3 * 60000 + 17000),
  for (var i = 9; i < 16; i++) _item('p$i', 'photo', 'IMG_${4700 + i}.HEIC', 1900000, ago: _day * (20 + i)),
  _item('n1', 'note', 'Wifi nhà bà ngoại', 120),
  _item('n2', 'note', 'Tài khoản ngân hàng', 640, ago: _day),
  _item('n3', 'note', 'Thuốc của mẹ', 420, ago: _day * 3),
  _item('n4', 'note', 'Hộ chiếu và visa', 260, ago: _day * 9, folder: 'd1'),
  _item('n5', 'note', 'Mật khẩu router và camera an ninh', 300, ago: _day * 15),
  _item('n6', 'note', 'Danh sách quà Tết', 90, ago: _day * 30),
  _item('n7', 'note', 'Mã két sắt', 40, ago: _day * 60),
  _item('n8', 'note', 'Thông tin bảo hiểm xe', 520, ago: _day * 75),
  _item('d1', 'folder', 'Giấy tờ tùy thân', 0, color: 'amber'),
  _item('d2', 'folder', 'Nhà cửa', 0, color: 'blue'),
  _item('d3', 'folder', 'Sức khoẻ', 0, color: 'red'),
  _item('d4', 'folder', 'Công việc', 0, color: 'violet'),
  _item('d5', 'folder', 'Xe máy và ô tô', 0, color: 'leaf'),
  _item('d6', 'folder', 'Hộ chiếu', 0, color: 'teal', folder: 'd1'),
  _item('g1', 'file', 'Ho-chieu-scan.pdf', 2300000, ago: _day * 220, folder: 'd1'),
  _item('g2', 'file', 'Giay-khai-sinh-Na.pdf', 640000, ago: _day * 290, folder: 'd1'),
  _item('g3', 'file', 'Bang-lai-xe.pdf', 1100000, ago: _day * 72, folder: 'd1'),
  _item('f1', 'file', 'Hop-dong-thue-nha-2026.pdf', 1240000),
  _item('f2', 'file', 'So-do-nha-scan.pdf', 4870000, ago: _day * 2),
  _item('f3', 'file', 'Chi tieu gia dinh 2026.xlsx', 86000, ago: _day * 4),
  _item('f4', 'file', 'Ket qua xet nghiem mau thang 9 - Benh vien Bach Mai.pdf', 732000, ago: _day * 11),
  _item('f5', 'file', 'Di-chuc-nhap.docx', 42000, ago: _day * 20),
  _item('f6', 'file', 'CCCD-mat-truoc.jpg', 1840000, ago: _day * 33, folder: 'd1'),
  _item('f7', 'file', 'Ho-so-xin-viec.zip', 15600000, ago: _day * 50),
  _item('f8', 'file', 'Ghi-am-cuoc-hop.m4a', 9300000, ago: _day * 64),
];

const _noteText = {
  'n1': 'Wifi nhà bà ngoại\nTên mạng: TP-Link_5G_BaNgoai\nMật khẩu: hoaMai2024@',
  'n2': 'Tài khoản ngân hàng\nVietcombank 0011 0023 4567 — Nguyễn Văn A, chi nhánh Hoàn Kiếm.\nTechcombank 1903 2211 4455 66 — tài khoản phụ, chỉ nhận lương.\nMB 0909 123 456 — tài khoản tiết kiệm của con.',
  'n3': 'Thuốc của mẹ\nSáng: Amlodipine 5mg sau ăn.\nTối: Metformin 500mg sau ăn.\nTái khám ngày 3/11, mang sổ khám và kết quả xét nghiệm lần trước.',
  'n4': 'Hộ chiếu và visa\nHộ chiếu C1234567, cấp 12/3/2021, hết hạn 12/3/2031.\nVisa Nhật Bản nhiều lần, hết hạn 5/2027.',
  'n5': 'Mật khẩu router và camera an ninh\nRouter: admin / Zx9!kq2Lm\nCamera cổng: app EZVIZ, mã thiết bị F7K2Q9',
  'n6': 'Danh sách quà Tết\nÔng bà nội: chè Thái, bánh. Bố mẹ vợ: rượu vang, hoa quả. Cô giáo của Na: hộp trà.',
  'n7': 'Mã két sắt\n4 vòng trái dừng 27, 2 vòng phải dừng 9.',
  'n8': 'Thông tin bảo hiểm xe\nBảo Việt, số hợp đồng BV-2026-118834, hết hạn 31/12/2026. Hotline giám định 1900 558 899.',
};

final Map<int, Uint8List> _photos = {};

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
    if (n.contains('ItemContent')) {
      final id = (call.namedArguments[#id] as String).replaceAll('_', '');
      return Future<Uint8List>.value(Uint8List.fromList(utf8.encode(_noteText[id] ?? '')));
    }
    if (n.contains('ItemThumbnail')) {
      final id = call.namedArguments[#id] as String;
      final it = _items.where((x) => x.id == id).firstOrNull;
      if (it == null || (it.kind != 'photo' && it.kind != 'video')) return Future<Uint8List>.value(Uint8List(0));
      final media = _items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
      return Future<Uint8List>.value(_photos[media.indexOf(it) % _photos.length] ?? _thumbs[0]);
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
  t.view.physicalSize = const Size(430, 932) * 2; // iPhone 15 Pro Max, the owner's phone
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

  setUp(() async {
    if (_thumbs.isEmpty) await _thumbsReady();
    // Free sample photos (picsum.photos / Unsplash), kept out of git.
    final dir = Directory('test/preview_assets');
    if (_photos.isEmpty && dir.existsSync()) {
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final (i, f) in files.indexed) {
        _photos[i] = f.readAsBytesSync();
      }
    }
  });

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
        onChangeIdentity: () async {},
        onOpenTrash: () async {},
        onNewVault: () async {},
      );

  testWidgets('lock', skip: !_enabled, (t) => _shot(t, 'lock', const UnlockScreen(libraryDir: '', askBiometricNow: false)));
  testWidgets('lock menu', skip: !_enabled, (t) async {
    await _shot(t, 'lock-menu', const UnlockScreen(libraryDir: '', askBiometricNow: false),
        act: (t) => t.tap(find.byKey(const ValueKey('more-button'))));
  });
  for (final mode in ['library', 'note', 'file']) {
    testWidgets('mode $mode', skip: !_enabled, (t) async {
      Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
      Prefs.write('add-mode', mode);
      await _shot(t, 'mode-$mode', VaultHomeScreen(libraryDir: '', vault: vault), vault: colorById('green').color);
    });
  }
  testWidgets('folder', skip: !_enabled, (t) async {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Prefs.write('add-mode', 'file');
    await _shot(t, 'folder', VaultHomeScreen(libraryDir: '', vault: vault), vault: colorById('green').color,
        act: (t) async {
      await t.tap(find.text('Giấy tờ tùy thân'));
    });
  });
  testWidgets('select', skip: !_enabled, (t) async {
    Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
    Prefs.write('add-mode', 'library');
    await _shot(t, 'select', const VaultHomeScreen(libraryDir: '', vault: VaultInfo(id: 'v', name: '', icon: 'home', color: 'plum', hasPassword: true)),
        b: Brightness.dark, vault: colorById('plum').color, act: (t) async {
      await t.longPress(find.byType(Image).at(2));
      await t.pump();
      await t.tap(find.byType(Image).at(4));
    });
  });
  testWidgets('search', skip: !_enabled, (t) async {
    await _shot(t, 'search', SearchScreen(items: _items, thumb: (id) async => _thumbs[0]!), vault: colorById('green').color,
        act: (t) async {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await t.enterText(find.byType(TextField), 'thuoc');
    });
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
