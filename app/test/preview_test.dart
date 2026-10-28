// Renders the real screens to PNG, every one in dark and light. This is also how UI
// mockups are made (docs/ui.md, mockups): change the code, then run tool/mockup.sh,
// which runs this file and builds test/preview/index.html from manifest.json.
// Off by default:
//   flutter test test/preview_test.dart --update-goldens --dart-define=PREVIEW=true
// Output: test/preview/*.png (not committed). Rust is a fake with sample items.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PictureRecorder, ImageByteFormat;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;

import 'package:cozysafe/links.dart';
import 'package:cozysafe/widgets/private_thumb.dart';
import 'package:cozysafe/widgets/selectable_row.dart';
import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/camera.dart';
import 'package:cozysafe/screens/backup_password.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/screens/kit_password.dart';
import 'package:cozysafe/screens/change_key.dart';
import 'package:cozysafe/screens/debug.dart';
import 'package:cozysafe/screens/delete_vault.dart';
import 'package:cozysafe/screens/file_view.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/search.dart';
import 'package:cozysafe/screens/security_info.dart';
import 'package:cozysafe/screens/set_pin.dart';
import 'package:cozysafe/key_backup.dart';
import 'package:cozysafe/screens/error_report.dart';
import 'package:cozysafe/screens/key_check.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/tour.dart';
import 'package:cozysafe/screens/trash.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/quick_look.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/screens/welcome.dart';
import 'package:cozysafe/screens/restore_flow.dart';
import 'package:cozysafe/screens/vault_manager.dart';
import 'package:cozysafe/widgets/second_place.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/api/sync.dart';
import 'package:cozysafe/sync/auto_sync.dart';
import 'package:cozysafe/sync/drive_check.dart';
import 'package:cozysafe/sync/sync_log.dart';
import 'package:cozysafe/sync/drive_join.dart';
import 'package:cozysafe/sync/join_page.dart';
import 'package:cozysafe/sync/nearby_page.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/sync/qr_view.dart';
import 'package:cozysafe/sync/status.dart';
import 'package:cozysafe/sync/sync_screen.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/privacy.dart';
import 'package:cozysafe/screens/overview.dart';
import 'package:cozysafe/widgets/brand.dart';
import 'package:cozysafe/widgets/identity.dart';
import 'package:cozysafe/widgets/readable.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:cozysafe/widgets/toast.dart';
import 'package:cozysafe/widgets/countdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cozysafe/screens/history.dart';
import 'package:cozysafe/src/rust/api/history.dart' show HistoryVersion;

const _enabled = bool.fromEnvironment('PREVIEW');
final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, int sizeBytes,
        {int ago = 0, int? deleted, int? duration, List<String> tags = const [], bool fav = false}) =>
    ItemInfo(
      id: id.padRight(32, '_'),
      kind: kind,
      name: name,
      mime: switch (kind) {
        ItemKind.photo => 'image/jpeg',
        ItemKind.audio => 'audio/mp4',
        ItemKind.file => mimeOf(name),
        _ => 'text/plain',
      },
      createdMs: _now - ago,
      sizeBytes: BigInt.from(sizeBytes),
      deletedMs: deleted,
      durationMs: duration,
      tagIds: [for (final t in tags) t.padRight(32, '_')],
      isFavorite: fav,
      modifiedMs: _now - ago,
    );

const _day = 86400000;

/// Realistic content: what people actually keep in a vault, in groups that cross
/// sections ("Hộ chiếu": a photo, a scan, a note).
/// What the vault holds in this shot (null: [_items]).
List<ItemInfo>? _itemsNow;

final _items = [
  _item('t1', ItemKind.tag, 'Giấy tờ tùy thân', 0),
  _item('t2', ItemKind.tag, 'Hộ chiếu', 0),
  _item('t3', ItemKind.tag, 'Du lịch', 0),
  _item('t4', ItemKind.tag, 'Gia đình', 0),
  _item('t5', ItemKind.tag, 'Sức khoẻ', 0),
  _item('t6', ItemKind.tag, 'Nhà cửa', 0),
  _item('t7', ItemKind.tag, 'Mật khẩu', 0),
  _item('t8', ItemKind.tag, 'Công việc', 0),
  for (var i = 0; i < 5; i++)
    _item('p$i', ItemKind.photo, 'IMG_${4810 + i}.HEIC', 2400000 + i * 90000, ago: i * 600000,
        tags: i == 2 ? ['t1', 't2'] : (i < 2 ? ['t4'] : [])),
  _item('v1', ItemKind.video, 'Sinh nhật bé Na.MOV', 38400000, ago: 3600000, duration: 42000, tags: ['t4']),
  for (var i = 5; i < 9; i++) _item('p$i', ItemKind.photo, 'IMG_${4790 + i}.HEIC', 2100000, ago: _day + i * 300000),
  _item('v2', ItemKind.video, 'Đi biển Quy Nhơn.MOV', 126000000, ago: _day * 2, duration: 3 * 60000 + 17000, tags: ['t3', 't4']),
  for (var i = 9; i < 16; i++)
    _item('p$i', ItemKind.photo, 'IMG_${4700 + i}.HEIC', 1900000, ago: _day * (20 + i), tags: i < 13 ? ['t3'] : []),
  _item('a1', ItemKind.audio, 'Cuộc họp với luật sư.m4a', 6100000, ago: 7200000, duration: 768000, tags: ['t8']),
  _item('a2', ItemKind.audio, 'Bác sĩ dặn về thuốc của mẹ.m4a', 1500000, ago: _day, duration: 185000, tags: ['t5']),
  _item('a3', ItemKind.audio, 'Thoả thuận đặt cọc nhà.m4a', 11600000, ago: _day * 8, duration: 1450000, tags: ['t6']),
  _item('n1', ItemKind.note, 'Wifi nhà bà ngoại', 120, tags: ['t7']),
  _item('n2', ItemKind.note, 'Tài khoản ngân hàng', 640, ago: _day, fav: true),
  _item('n3', ItemKind.note, 'Thuốc của mẹ', 420, ago: _day * 3, tags: ['t5']),
  _item('n4', ItemKind.note, 'Hộ chiếu và visa', 260, ago: _day * 9, tags: ['t1', 't2', 't3']),
  _item('n5', ItemKind.note, 'Mật khẩu router và camera an ninh', 300, ago: _day * 15, tags: ['t7', 't6']),
  _item('n6', ItemKind.note, 'Danh sách quà Tết', 90, ago: _day * 30, tags: ['t4']),
  _item('n7', ItemKind.note, 'Mã két sắt', 40, ago: _day * 60, tags: ['t7', 't6']),
  _item('n8', ItemKind.note, 'Thông tin bảo hiểm xe', 520, ago: _day * 75),
  _item('g1', ItemKind.file, 'Ho-chieu-scan.pdf', 2300000, ago: _day * 220, tags: ['t1', 't2'], fav: true),
  _item('g2', ItemKind.file, 'Giay-khai-sinh-Na.pdf', 640000, ago: _day * 290, tags: ['t1', 't4']),
  _item('g3', ItemKind.file, 'Bang-lai-xe.pdf', 1100000, ago: _day * 72, tags: ['t1']),
  _item('f1', ItemKind.file, 'Hop-dong-thue-nha-2026.pdf', 1240000, tags: ['t6']),
  _item('f2', ItemKind.file, 'So-do-nha-scan.pdf', 4870000, ago: _day * 2, tags: ['t6']),
  _item('f3', ItemKind.file, 'Chi tieu gia dinh 2026.xlsx', 86000, ago: _day * 4, tags: ['t4']),
  _item('f4', ItemKind.file, 'Ket qua xet nghiem mau thang 9 - Benh vien Bach Mai.pdf', 732000, ago: _day * 11, tags: ['t5']),
  _item('f5', ItemKind.file, 'Di-chuc-nhap.docx', 42000, ago: _day * 20),
  _item('f6', ItemKind.file, 'CCCD-mat-truoc.jpg', 1840000, ago: _day * 33, tags: ['t1']),
  _item('f7', ItemKind.file, 'Ho-so-xin-viec.zip', 15600000, ago: _day * 50, tags: ['t8']),
  _item('f8', ItemKind.file, 'Ghi-am-cuoc-hop.m4a', 9300000, ago: _day * 64, tags: ['t8']),
];

/// A note with Markdown marks (format bar, checklist, links), shown only in its own shots.
final _formatted = _item('n9', ItemKind.note, 'Chuẩn bị đi Đà Lạt', 400, ago: 60000);

const _noteText = {
  'n9': 'Chuẩn bị đi Đà Lạt\n## Hành lý\n- [x] **Hộ chiếu** và căn cước\n- [x] Sạc dự phòng\n- [ ] Áo khoác ấm\n- [ ] Thuốc say xe\n## Đặt chỗ\nKhách sạn: *nhận phòng sau 14h*, mã đặt **DL-58213**\nVé xe: https://vexere.com/vi-VN/ve-xe-sai-gon-da-lat\nBản đồ: www.google.com/maps.\nQuà cho bạn: https://bücher.de/geschenke',
  'j1': '{"router":{"ssid":"TP-Link_5G_BaNgoai","password":"hoaMai2024@","channel":36},"camera":{"app":"EZVIZ","device":"F7K2Q9","admin":true}}',
  'm1': '# Gia hạn hộ chiếu\n\nMang theo **bản gốc** và nộp ở *Phòng Quản lý xuất nhập cảnh*.\n\n## Giấy tờ\n\n- Hộ chiếu cũ\n- Căn cước công dân\n- 2 ảnh 4x6 nền trắng\n- Tờ khai `TK01` điền sẵn\n\n## Lệ phí\n\n1. Nộp 200.000 đ tại quầy\n2. Giữ biên lai để nhận hộ chiếu\n\n> Hẹn lấy sau 8 ngày làm việc.\n\n```\nSĐT tổng đài: 1900 1234\nMã hồ sơ: HC-2026-55821\n```',
  'tx1': 'Wifi nhà ngoại đổi mật khẩu ngày 12/10.\n\nMạng 5G: TP-Link_5G_BaNgoai\nMật khẩu mới: hoaMai2024@\n\nNếu camera cổng mất kết nối thì rút điện 10 giây rồi cắm lại, đợi đèn xanh.',
  'n1': 'Wifi nhà bà ngoại\nTên mạng: TP-Link_5G_BaNgoai\nMật khẩu: hoaMai2024@',
  'x5': 'Mật khẩu wifi cũ\nTên mạng: TP-Link_BaNgoai\nMật khẩu: matKhauCu2023',
  'n2': 'Tài khoản ngân hàng\nVietcombank 0011 0023 4567 — Nguyễn Văn A, chi nhánh Hoàn Kiếm.\nTechcombank 1903 2211 4455 66 — tài khoản phụ, chỉ nhận lương.\nMB 0909 123 456 — tài khoản tiết kiệm của con.',
  'n3': 'Thuốc của mẹ\nSáng: Amlodipine 5mg sau ăn.\nTối: Metformin 500mg sau ăn.\nTái khám ngày 3/11, mang sổ khám và kết quả xét nghiệm lần trước.',
  'n4': 'Hộ chiếu và visa\nHộ chiếu C1234567, cấp 12/3/2021, hết hạn 12/3/2031.\nVisa Nhật Bản nhiều lần, hết hạn 5/2027.',
  'n5': 'Mật khẩu router và camera an ninh\nRouter: admin / Zx9!kq2Lm\nCamera cổng: app EZVIZ, mã thiết bị F7K2Q9',
  'n6': 'Danh sách quà Tết\nÔng bà nội: chè Thái, bánh. Bố mẹ vợ: rượu vang, hoa quả. Cô giáo của Na: hộp trà.',
  'n7': 'Mã két sắt\n4 vòng trái dừng 27, 2 vòng phải dừng 9.',
  'n8': 'Thông tin bảo hiểm xe\nBảo Việt, số hợp đồng BV-2026-118834, hết hạn 31/12/2026. Hotline giám định 1900 558 899.',
};

/// Recently deleted: every kind, a video with its thumbnail, and items deleted for good on
/// another device (held here).
final _trash = [
  _item('x1', ItemKind.photo, 'IMG_4721.HEIC', 2300000, ago: _day * 40, deleted: _now - _day),
  _item('x2', ItemKind.video, 'Đi chợ Tết.MOV', 48000000, ago: _day * 60, duration: 64000, deleted: _now - 3 * _day),
  _item('x3', ItemKind.photo, 'IMG_4702.HEIC', 2100000, ago: _day * 90, deleted: _now - 18 * _day),
  _item('x5', ItemKind.note, 'Mật khẩu wifi cũ', 180, ago: _day * 70, deleted: _now - 5 * _day),
  _item('x6', ItemKind.audio, 'Ghi âm 12-10-2026 09.14.22.m4a', 1400000, ago: _day * 14, duration: 95000, deleted: _now - 9 * _day),
  _item('t3', ItemKind.file, 'Bao-gia-sua-nha.pdf', 300000, ago: _day * 120, deleted: _now - 27 * _day),
];
final _trashHeld = [
  _item('x4', ItemKind.photo, 'IMG_4655.HEIC', 1900000, ago: _day * 100, deleted: _now - 2 * _day),
  _item('t4', ItemKind.file, 'Hop-dong-thue-nha-cu.pdf', 420000, ago: _day * 200, deleted: _now - 2 * _day),
];
/// Recently deleted is empty in this shot.
bool _noTrash = false;
/// Which sample photo each deleted photo or video shows.
const _trashPictures = {'x1': 5, 'x2': 6, 'x3': 7, 'x4': 2};

final Map<int, Uint8List> _photos = {};

/// Small solid-colour PNGs stand in for photo thumbnails.
final _thumbnails = <int, Uint8List>{};

/// A real pairing code (192.168.1.37:51234) and its QR, from the Rust encoder.
const _qrText = 'cozysafe:p2p:2:60N00JBJ120XDWG3A2';
const _qrBits = '1111111000011001111010111111110000010000000000110001000001101110101000101010110010111011011101011100000111000101110110111010100101110000101011101100000101010111110100010000011111111010101010101010111111100000000110111010001000000000101111100111001101110011111001110110001011001100010101010110001010010010000110011011000001001011100001010100110110110110111110010000011011010111100101100100011110001001110001100000110001011100100100011000000110101001100001000001100110101011010100111000110100101101100000011100001010010100111000111011010001101001101100010110100110100110011111011001101001100111100100011111101100000000010000111101010001101111111110001111111000101010100100000101011110000111000110001011101011101011100011111011010111010111011000000010101011101110101010001111000011110101000001000100100100110000001011111110110110010000011001100';

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('MinPasswordScore')) return 3;
    if (n.contains('MinPasswordLength')) return 8;
    if (n.contains('MinPinLength')) return 6;
    if (n.contains('PasswordProblem')) {
      final pw = call.namedArguments[#password] as String;
      if (pw.length < 8) return PasswordProblem.tooShort;
      // A common one with a year added, for the "password refused" mockup.
      if (pw.toLowerCase().startsWith('sunshine')) return PasswordProblem.common;
      return pw.length < 12 ? PasswordProblem.guessable : PasswordProblem.none;
    }
    if (n.contains('PasswordScore')) return (call.namedArguments[#password] as String).length < 12 ? 1 : 4;
    if (n.contains('HasVaults')) return true;
    if (n.contains('QrMatrix')) return QrMatrix(size: 29, dark: [for (final c in _qrBits.split('')) c == '1']);
    if (n.contains('P2PCodeAddress')) return '192.168.1.37';
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(_itemsNow ?? _items);
    if (n.contains('ListHeld')) return Future<List<ItemInfo>>.value(_noTrash ? const [] : _trashHeld);
    if (n.contains('ListTrash')) return Future<List<ItemInfo>>.value(_noTrash ? const [] : _trash);
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('ItemContent')) {
      final full = call.namedArguments[#id] as String;
      final media = _items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
      final m = media.indexWhere((x) => x.id == full);
      if (m >= 0) return Future<Uint8List>.value(_photos[m % _photos.length] ?? _thumbnails[0]);
      final id = full.replaceAll('_', '');
      // Deleted photos and videos, and a picture added from Files.
      final picture = {..._trashPictures, 'f6': 3}[id];
      if (picture != null) return Future<Uint8List>.value(_photos[picture] ?? _thumbnails[1]);
      return Future<Uint8List>.value(Uint8List.fromList(utf8.encode(_noteText[id] ?? '')));
    }
    if (n.contains('ItemThumbnail')) {
      final id = call.namedArguments[#id] as String;
      final bare = id.replaceAll('_', '');
      // Recently deleted: photos and videos (held ones too) have their thumbnails.
      if (_trashPictures[bare] case final p?) return Future<Uint8List>.value(_photos[p] ?? _thumbnails[p % 4]);
      final it = _items.where((x) => x.id == id).firstOrNull;
      if (it == null || (it.kind != 'photo' && it.kind != 'video')) return Future<Uint8List>.value(Uint8List(0));
      final media = _items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
      return Future<Uint8List>.value(_photos[media.indexOf(it) % _photos.length] ?? _thumbnails[0]);
    }
    if (n.contains('PinLengths')) return Uint32List.fromList([4]);
    if (n.contains('AnyPassword')) return true;
    if (n.contains('HasBiometricUnlock')) return true;
    if (n.contains('BiometricEnabled')) return true;
    if (n.contains('PinEnabled')) return true;
    if (n.contains('Unlock')) return Future<VaultInfo?>.value(null);
    return null;
  }
}

Future<void> _loadFonts() async {
  final dir = Directory('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts');
  Future<ByteData> bytes(File f) async => ByteData.view((await f.readAsBytes()).buffer);
  // The iPhone's own font (SF Pro): the app sets none, so on an iPhone its text is SF.
  // The Mac's copy stands in; Roboto only where it is missing.
  final sf = File('/System/Library/Fonts/SFNS.ttf');
  final roboto = FontLoader('Roboto');
  if (sf.existsSync()) {
    roboto.addFont(bytes(sf));
    // The names Flutter gives the iPhone's system font when the platform is iOS.
    for (final name in ['CupertinoSystemDisplay', 'CupertinoSystemText']) {
      await (FontLoader(name)..addFont(bytes(sf))).load();
    }
  } else {
    for (final f in dir.listSync().whereType<File>()) {
      final n = f.uri.pathSegments.last;
      if (n.startsWith('Roboto-') && n.endsWith('.ttf')) roboto.addFont(bytes(f));
    }
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(bytes(File('${dir.path}/MaterialIcons-Regular.otf')))).load();
  // `monospace` (the Secret Key): the Mac's SF Mono stands in for the phone's.
  final mono = File('/System/Library/Fonts/SFNSMono.ttf');
  if (mono.existsSync()) await (FontLoader('monospace')..addFont(bytes(mono))).load();
}

Future<void> _thumbnailsReady() async {
  const colors = [Color(0xFF7FA79A), Color(0xFFD9A07A), Color(0xFF9CC4DE), Color(0xFFA77FB0)];
  for (var i = 0; i < colors.length; i++) {
    final rec = PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = colors[i]);
    final img = await rec.endRecording().toImage(32, 32);
    _thumbnails[i] = (await img.toByteData(format: ImageByteFormat.png))!.buffer.asUint8List();
  }
}

/// The owner's phone, the default for every shot.
const _phone = Size(430, 932);

Future<List<List<double>>> _shot(WidgetTester t, String file, Widget home, {Brightness b = Brightness.light,
    Future<void> Function(WidgetTester)? act, int after = 6, List<Finder Function()> marks = const [],
    Size size = _phone}) async {
  t.view.physicalSize = size * 2; // iPhone 15 Pro Max, the owner's phone, unless a bigger screen
  t.view.devicePixelRatio = 2;
  // The phone's safe areas (status bar with the Dynamic Island, home indicator), so
  // content sits where it does on the device; the mockup page draws the frame on top.
  // An iPad or a computer window: a thin status bar on top only.
  final (top, bottom) = size == _phone ? (59.0, 34.0) : (24.0, 0.0);
  t.view.padding = FakeViewPadding(top: top * 2, bottom: bottom * 2);
  t.view.viewPadding = FakeViewPadding(top: top * 2, bottom: bottom * 2);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('vi'),
    // The app-wide vault colour is off (docs/ui.md); `vault` is kept for when it returns.
    theme: buildTheme(b),
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
    for (var i = 0; i < after; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // decode new images
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  // Where the changed parts are, in points, for the page to outline (docs/ui.md, mockups).
  final rects = [
    for (final m in marks)
      for (final e in m().evaluate())
        if (e.renderObject case final RenderBox box when box.hasSize)
          [for (final v in [box.localToGlobal(Offset.zero).dx, box.localToGlobal(Offset.zero).dy, box.size.width, box.size.height]) v],
  ];
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('preview/$file.png'));
  return rects;
}

/// Tap a chip in the horizontal row, scrolling it into view first.
Future<void> _tapChip(WidgetTester t, String label) async {
  final row = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right).first;
  await t.scrollUntilVisible(find.text(label), 120, scrollable: row);
  await t.pump();
  await t.tap(find.text(label).first);
}

/// The screens, in the order the mockup page shows them: (file name, caption).
final _manifest = <Map<String, Object>>[];

/// One screen, rendered dark and light (`<name>-dark.png`, `<name>-light.png`).
/// [change] says what is new on this screen, [marks] finds the parts to outline.
const _wideAll = bool.fromEnvironment('WIDE');

void _screen(String name, String caption, Widget Function() home,
    {String? section, Future<void> Function(WidgetTester)? act, int after = 6, void Function()? setup,
    String? change, List<Finder Function()> marks = const [], Size size = _phone}) {
  // --dart-define=WIDE=true: every phone screen on a MacBook window instead, to look
  // for pages left empty on a computer.
  if (_wideAll && size == _phone) size = const Size(1440, 900);
  final entry = <String, Object>{'name': name, 'caption': caption, 'change': ?change};
  // An iPad or computer screen is drawn in its own frame, at its own shape.
  if (size != _phone) entry['size'] = [size.width, size.height];
  _manifest.add(entry);
  for (final b in [Brightness.dark, Brightness.light]) {
    testWidgets('$name ${b.name}', skip: !_enabled, (t) async {
      Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
      AutoSync.failed.value = false; // a screen's sync state never spills into the next
      AutoSync.lastOk.value = null;
      AutoSync.moving.value = false;
      AutoSync.pending.value = false;
      if (section != null) Prefs.write('vault-section', section);
      Prefs.write('add-column-hint', '3'); // the drag hint has been seen; no mid-nudge shots
      debugCamera = false;
      CameraView.debugPreview = null;
      CameraView.debugLast = null;
      QuickLook.debugVideo = null;
      NewVaultScreen.debugWords = null;
      DebugScreen.debugNetworkBlocked = null;
      _itemsNow = null;
      _noTrash = false;
      SyncScreen.debugLog = null;
      SettingsScreen.debugSyncLog = null;
      SyncScreen.debugAddress = null;
      SyncScreen.debugDrive = false;
      SyncScreen.debugAccount = null;
      SyncScreen.debugSession = null;
      ErrorReportScreen.debugEntries = null;
      HistoryScreen.debugVersions = null;
      HistoryScreen.debugContent = null;
      HistoryScreen.debugDays = null;
      HistorySettingsScreen.debugState = null;
      SettingsScreen.debugHistoryBytes = null;
      KeyBackup.debugSupported = null;
      KeyBackup.debugGoogle = null;
      syncStatus.value = null;
      KeyCheckScreen.debugResults = null;
      SyncProgress.debugRate = null;
      syncStatus.value = null;
      SecondPlaceNudge.debugShow = false;
      debugHoldToasts = true;
      VaultManagerScreen.debugSlots = null;
      NewVaultScreen.debugBiometricStep = false;
      RestoreSourceScreen.debugDrive = false;
      DriveJoinScreen.debugAccount = null;
      NearbyPage.debugHosting = null;
      NearbyPage.debugEvents = null;
      NearbyPage.debugQr = false;
      NearbyPage.debugNothingYet = false;
      ChangeKeyScreen.debugWords = null;
      ChangeKeyScreen.debugStep = null;
      ScanCodePage.debugPreview = null;
      VaultHomeScreen.debugReveal = false;
      QuickLook.debugStillAudio = false;
      QuickLook.debugPdfPage = null;
      CoachTour.debugStart = 0;
      setup?.call();
      // Real shadows: tests otherwise draw every elevation as a solid black outline.
      debugDisableShadows = false;
      // A phone is the owner's iPhone: its back button, switches and title bar.
      if (size == _phone) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final rects = await _shot(t, '$name-${b.name}', home(), b: b, act: act, after: after, marks: marks, size: size);
        if (rects.isNotEmpty) entry['marks'] = rects;
        await t.pump(const Duration(seconds: 2)); // let an animation started by `act` end
      } finally {
        debugDisableShadows = true;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

void main() {
  setUpAll(() async {
    RustLib.initMock(api: _Fake());
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Cozy Safe', packageName: 'com.cozypi.cozysafe', version: '0.1.8', buildNumber: '1100', buildSignature: '');
    debugVoice = true;
    BiometricUnlock.debugKind = BiometricKind.face; // the owner's iPhone
    Links.debugCanOpen = true;
    Settings.debugIOS = true;
    debugOwnerConfirmed = true; // Face ID prompts pass in the renders (debug builds only)
    await _loadFonts();
  });

  setUp(() async {
    if (_thumbnails.isEmpty) await _thumbnailsReady();
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

  tearDownAll(() {
    if (!_enabled) return;
    File('test/preview/manifest.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_manifest));
  });

  const vault = VaultInfo(id: 'v', name: '', icon: 'home', color: 'green', hasPassword: true);
  Widget settings(VaultInfo v, {int? guideFrom}) => Readable(child: SettingsScreen(
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
        onTour: () {},
        guideFrom: guideFrom,
      ));
  Widget home() => const VaultHomeScreen(libraryDir: '', vault: vault);
  Widget lock() => const UnlockScreen(libraryDir: '', askBiometricNow: false);

  _screen('lock', 'Màn khoá', lock);
  // Cold start: the first frames hand over from the system launch screen (dial alone).
  for (final (ms, what) in [(0, 'khung đầu, y như màn khởi động của máy'), (220, 'mặt khoá thu nhỏ, mờ dần'), (420, 'màn khoá hiện ra')]) {
    _screen('launch-$ms', 'Mở app · $ms ms · $what', () => LaunchHandoff(child: lock()), after: 0,
        setup: () {
          LaunchHandoff.debugReset();
          LaunchHandoff.debugHold = true;
        },
        act: (t) async {
      LaunchHandoff.debugGo();
      await t.pump();
      if (ms > 0) await t.pump(Duration(milliseconds: ms));
      LaunchHandoff.debugHold = false;
    });
  }
  _screen('lock-fingerprint', 'Màn khoá · máy dùng vân tay', lock,
      setup: () => BiometricUnlock.debugKind = BiometricKind.fingerprint);
  _screen('lock-menu', 'Màn khoá · nút ⋯', lock, act: (t) => t.tap(find.byKey(const ValueKey('more-button'))));
  // A sync that went on as the vault locked (owner 2026-10-26): how far it is.
  _screen('lock-sync-drive', 'Màn khoá · đồng bộ Google Drive vẫn chạy (40%)', lock,
      setup: () => syncStatus.value = const SyncStatus(drive: true, kind: SyncStep.receiving, done: 12, total: 30, bytes: 40, bytesTotal: 100));
  _screen('lock-sync-nearby', 'Màn khoá · đồng bộ với máy bên cạnh vẫn chạy (75%)', lock,
      setup: () => syncStatus.value = const SyncStatus(drive: false, kind: SyncStep.sending, done: 3, total: 4));
  _screen('lock-sync-done', 'Màn khoá · đồng bộ xong sau khi khoá', lock,
      setup: () => syncStatus.value = const SyncStatus(drive: true, kind: SyncStep.done));
  // The unlock animation (playVaultSpin), frozen at four moments of its 1.15 s: the vault's
  // icon behind the dial, blurred at first, sharp when the dial has gone.
  for (final (ms, what) in [(250, 'mặt khoá hiện'), (520, 'đang xoay, màu két hắt quanh mép'), (950, 'cửa két mở vụt qua, biểu tượng hiện'), (1100, 'biểu tượng nét')]) {
    _screen('unlock-$ms', 'Mở khoá · $ms ms · $what', lock, after: 0,
        act: (t) async {
      playVaultSpin(t.element(find.byType(UnlockScreen)), opening: true, onCovered: () {},
          behind: const VaultBadge(icon: 'home', color: 'green', size: 120), glow: colorById('green').color);
      await t.pump();
      await t.pump(Duration(milliseconds: ms));
    });
  }
  // After the spin: the same icon, already sharp, holds, fades, then the content.
  for (final (ms, what) in [(100, 'biểu tượng nét, nối tiếp từ cửa két'), (500, 'biểu tượng mờ dần'), (1000, 'nội dung hiện ra')]) {
    _screen('reveal-$ms', 'Vừa mở · $ms ms · $what', home, section: 'library', after: 0,
        setup: () => VaultHomeScreen.debugReveal = true, act: (t) async {
      await t.pump(Duration(milliseconds: ms));
    });
  }
  _screen('library', 'Thư viện (mặc định: nút + ở giữa thanh)', home, section: 'library');
  _screen('lock-button', 'Thư viện · tắt “Giữ nút trang chủ để khoá” (có nút khoá)', home, section: 'library',
      setup: () => Prefs.write('hold-home-lock', '0'));
  _screen('add-library', 'Thư viện · nút bên trái · bấm +', home, section: 'library', setup: _leftCamera, act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  for (final (ms, what) in [(90, 'mục gần nhất vừa bật ra'), (200, 'các mục lần lượt nảy lên'), (320, 'gần xong, + đã xoay thành ×')]) {
    _screen('add-pop-$ms', 'Bấm + · $ms ms · $what', home, section: 'library', setup: _leftCamera, after: 0,
        act: (t) async {
      await t.tap(find.byKey(const ValueKey('vault-action')));
      await t.pump();
      await t.pump(Duration(milliseconds: ms));
    });
  }
  _screen('add-slide', 'Thư viện · nút bên trái · giữ + rồi vuốt tới “Máy ảnh”', home, section: 'library', setup: _leftCamera, act: (t) async {
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('vault-action'))));
    await g.moveBy(const Offset(0, -30));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100)); // let the ways finish popping out
    }
    await g.moveTo(t.getCenter(find.byKey(const ValueKey('add-card-photo'))));
    await t.pump(const Duration(milliseconds: 200));
  });
  _screen('empty', 'Két trống · thêm bằng ô lớn', home, section: 'library', setup: () {
    debugCamera = true;
    _itemsNow = const [];
  });
  _screen('one-type', 'Chỉ có ghi chú · thanh dưới gọn', home, section: 'note',
      setup: () => _itemsNow = _items.where((i) => i.kind == ItemKind.note || i.kind == ItemKind.tag).toList());
  _screen('note-editor', 'Sửa ghi chú', () => NoteScreen(item: _items.firstWhere((i) => i.kind == ItemKind.note)));
  _screen('note-new', 'Ghi chú mới', () => const NoteScreen());
  _screen('tag', 'Thư viện · trong nhóm "Du lịch"', home, section: 'library', act: (t) => _tapChip(t, 'Du lịch'));
  _screen('tag-empty', 'Trong nhóm "Hộ chiếu" · mục Ghi âm', home, section: 'audio', act: (t) => _tapChip(t, 'Hộ chiếu'));
  Widget camera({required bool video}) => CameraScreen(video: video, onOpenLast: (_) {});
  void still() {
    CameraView.debugPreview =
        _photos.isEmpty ? const ColoredBox(color: Colors.black) : Image.memory(_photos[3]!, fit: BoxFit.cover);
    CameraView.debugLast = (_items.firstWhere((i) => i.kind == ItemKind.photo), _photos[0] ?? _thumbnails[0]!);
  }
  _screen('camera', 'Chụp ảnh (mở từ Thư viện)', () => camera(video: false), setup: still);
  _screen('camera-video', 'Quay video', () => camera(video: true), setup: still);
  void drive({bool failed = false, bool moving = false, bool pending = false}) {
    Prefs.write('drive-account', 'ban.do@gmail.com');
    Prefs.write(AutoSync.pref, '1');
    AutoSync.failed.value = failed;
    AutoSync.moving.value = moving;
    AutoSync.pending.value = pending;
    AutoSync.lastOk.value = DateTime.now().subtract(const Duration(minutes: 5));
  }
  _screen('home', 'Trang chủ · chưa cài đồng bộ', home,
      section: 'home');
  _screen('home-synced', 'Trang chủ · đã đồng bộ', home,
      section: 'home', setup: drive);
  _screen('home-syncing', 'Trang chủ · đang gửi / nhận mục', home,
      section: 'home', setup: () => drive(moving: true));
  _screen('home-sync-pending', 'Trang chủ · vừa sửa, chưa gửi lên', home,
      section: 'home', setup: () => drive(pending: true));
  _screen('home-sync-failed', 'Trang chủ · đồng bộ lỗi', home,
      section: 'home', setup: () => drive(failed: true));
  // iPad and computer (owner 2026-10-27): three columns, the sync always in sight.
  const ipad = Size(1180, 820), ipadUp = Size(820, 1180), mac = Size(1440, 900), win = Size(1280, 800);
  _screen('wide-ipad-home', 'iPad ngang · Tổng quan: thanh bên (mục, nhóm, đồng bộ, Thêm), nội dung rộng', home,
      section: 'home', size: ipad, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('wide-ipad-library', 'iPad ngang · Thư viện: lưới nhiều cột theo bề ngang', home,
      section: 'library', size: ipad, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('wide-ipad-photo', 'iPad ngang · chạm một ảnh: mở ngay ở cột bên phải, không che danh sách', home,
      section: 'library', size: ipad, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3'],
      act: (t) async {
        await t.tap(find.byType(PrivateThumb).first);
        await t.pump();
      });
  _screen('wide-ipad-portrait', 'iPad dọc · hai cột: thanh bên + nội dung (mục mở ra như trên điện thoại)', home,
      section: 'note', size: ipadUp, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('wide-mac-note', 'MacBook · Ghi chú: chọn một ghi chú, xem ngay bên phải', home,
      section: 'note', size: mac, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3'],
      act: (t) async {
        await t.tap(find.text('Thuốc của mẹ').first);
        await t.pump();
      });
  _screen('wide-win-files', 'Cửa sổ Windows · Tệp', home,
      section: 'file', size: win, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('wide-ipad-add', 'iPad · bấm Thêm vào két ở thanh bên', home,
      section: 'library', size: ipad, setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3'],
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('wide-add')));
        await t.pump();
      });
  _screen('home-nudge', 'Trang chủ: két chỉ ở máy này', home, section: 'home',
      setup: () => SecondPlaceNudge.debugShow = true);
  _screen('shot-blocked', 'Vừa chụp màn hình · đang chặn', home, section: 'library', act: (t) async {
    PrivacyCover.onScreenshot?.call();
    await t.pumpAndSettle();
  });
  _screen('shot-saved', 'Vừa chụp màn hình · không chặn', home, section: 'library', setup: () => Prefs.write('block-screenshots', '0'),
      act: (t) async {
    PrivacyCover.onScreenshot?.call();
    await t.pumpAndSettle();
  });
  _screen('home-recording', 'Trang chủ · chạm một bản ghi âm', home, section: 'home',
      setup: () {
        QuickLook.debugStillAudio = true;
        // Recordings and notes only, so a recording is among the newest on home.
        _itemsNow = _items.where((i) => i.kind == ItemKind.audio || i.kind == ItemKind.note || i.kind == ItemKind.tag).toList();
      },
      act: (t) async {
        final row = find.text('Cuộc họp với luật sư', skipOffstage: false).first;
        await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
        await t.drag(find.byType(Scrollable).first, const Offset(0, -260));
        await t.pump();
        await t.tap(row);
        await t.pump(const Duration(milliseconds: 400));
      });
  Widget homeIn(String code) => Builder(
      builder: (context) => Localizations.override(context: context, locale: Locale(code), child: home()));
  _screen('tabs-fr', 'Thanh dưới · tiếng Pháp (chữ dài)', () => homeIn('fr'), section: 'note');
  _screen('tabs-fr-file', 'Thanh dưới · tiếng Pháp · đang ở Fichiers', () => homeIn('fr'), section: 'file');
  _screen('tabs-vi', 'Thanh dưới · tiếng Việt', home, section: 'note');
  _screen('home-scrolled', 'Trang chủ · kéo xuống', home, section: 'home', act: (t) async {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await t.pumpAndSettle();
  });
  _screen('add-library-center', 'Thư viện · bấm +: đủ mọi loại, 3 ô mỗi hàng', home, section: 'library', setup: () {
    debugCamera = true;
    Prefs.write('action-side', 'center');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  _screen('home-add-center', 'Trang chủ · nút ở giữa · bấm +', home, section: 'home', setup: () {
    debugCamera = true;
    Prefs.write('action-side', 'center');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  _screen('home-add', 'Trang chủ · nút bên trái (Cài đặt) · bấm +', home, section: 'home',
      setup: () {
    debugCamera = true;
    Prefs.write('action-side', 'left');
  },
      act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  _screen('notes', 'Ghi chú', home, section: 'note');
  _screen('sort-menu', 'Ghi chú · bấm ⇅', home, section: 'note', act: (t) async {
    await t.tap(find.byKey(const ValueKey('sort-button')));
    await t.pumpAndSettle();
  });
  _screen('notes-select', 'Ghi chú · bấm giữ một dòng', home, section: 'note',
      act: (t) async {
    await t.longPress(find.byType(SelectableRow).first);
    await t.pumpAndSettle();
  });
  Future<void> tapThumb(WidgetTester t, int n) async {
    await t.tap(find.byType(PrivateThumb).at(n));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  _screen('add-library-right', 'Thư viện · nút bên phải · bấm +', home, section: 'library', setup: () {
    debugCamera = true;
    Prefs.write('action-side', 'right');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  _screen('home-add-right', 'Trang chủ · nút bên phải · bấm +', home, section: 'home', setup: () {
    debugCamera = true;
    Prefs.write('action-side', 'right');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('vault-action')));
    await t.pumpAndSettle();
  });
  _screen('library-left', 'Thư viện · nút + bên trái (chọn trong Cài đặt)', home, section: 'library', setup: () {
    Prefs.write('action-side', 'left');
  });
  _screen('quick-photo-center', 'Xem trước · nút + ở giữa thanh', home, section: 'library', setup: () {
    Prefs.write('action-side', 'center');
  }, act: (t) => tapThumb(t, 2));
  _screen('quick-photo', 'Thư viện · chạm vào một ảnh', home, section: 'library',
      act: (t) => tapThumb(t, 2));
  _screen('quick-video', 'Thư viện · chạm vào một video', home, section: 'library',
      setup: () => QuickLook.debugVideo = _photos.isEmpty ? null : Image.memory(_photos[5]!, fit: BoxFit.cover),
      act: (t) => tapThumb(t, 5));
  _screen('quick-full', 'Ảnh · bấm ⛶', home, section: 'library', act: (t) async {
    await tapThumb(t, 2);
    await t.tap(find.byKey(const ValueKey('quick-full')));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
  });
  _screen('photo-swipe', 'Ảnh toàn màn hình · đang vuốt sang ảnh kế', home, section: 'library', act: (t) async {
    await tapThumb(t, 2);
    await t.tap(find.byKey(const ValueKey('quick-full')));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
    final g = await t.startGesture(t.getCenter(find.byType(PageView).last));
    await g.moveBy(const Offset(40, 0)); // a quick flick's first move
    await g.moveBy(const Offset(160, 0));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
  }, after: 0);
  _screen('photo-drag', 'Ảnh toàn màn hình · đang kéo xuống để đóng', home, section: 'library', act: (t) async {
    await tapThumb(t, 2);
    await t.tap(find.byKey(const ValueKey('quick-full')));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
    final g = await t.startGesture(t.getCenter(find.byType(PageView).last));
    await g.moveBy(const Offset(0, 30));
    await g.moveBy(const Offset(30, 150));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
  }, after: 0);
  _screen('audio', 'Ghi âm', home, section: 'audio');
  _screen('audio-select', 'Ghi âm · bấm giữ một bản ghi', home, section: 'audio',
      act: (t) async {
    await t.longPress(find.text('Cuộc họp với luật sư'));
    await t.pumpAndSettle();
  });
  _screen('audio-open', 'Ghi âm · chạm vào một bản ghi', home, section: 'audio',
      setup: () => QuickLook.debugStillAudio = true,
      act: (t) => t.tap(find.text('Cuộc họp với luật sư')));
  Future<void> openRow(WidgetTester t, String text) async {
    final row = find.text(text, skipOffstage: false).first;
    await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
    await t.tap(row);
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  _screen('quick-note', 'Ghi chú · chạm một ghi chú (đang bật “Ẩn nội dung ghi chú”)', home, section: 'note',
      act: (t) => openRow(t, 'Thuốc của mẹ'));
  _screen('note-format', 'Ghi chú có định dạng · chạm để xem trước', home, section: 'note',
      setup: () {
        Prefs.write('note-previews', '1');
        _itemsNow = [..._items, _formatted];
      },
      act: (t) => openRow(t, 'Chuẩn bị đi Đà Lạt'));
  _screen('note-link-card', 'Ghi chú · chạm một liên kết', home, section: 'note',
      setup: () {
        Prefs.write('note-previews', '1');
        _itemsNow = [..._items, _formatted];
      },
      act: (t) async {
        await openRow(t, 'Chuẩn bị đi Đà Lạt');
        _tapLink(t, 'https://vexere.com/vi-VN/ve-xe-sai-gon-da-lat');
        await t.pumpAndSettle();
      });
  _screen('note-link-idn', 'Ghi chú · liên kết tên miền quốc tế', home, section: 'note',
      setup: () {
        Prefs.write('note-previews', '1');
        _itemsNow = [..._items, _formatted];
      },
      act: (t) async {
        await openRow(t, 'Chuẩn bị đi Đà Lạt');
        _tapLink(t, 'https://bücher.de/geschenke');
        await t.pumpAndSettle();
      });
  _screen('note-format-bar', 'Sửa ghi chú · thanh định dạng trên bàn phím',
      () => _FakeKeyboard(child: NoteScreen(item: _formatted)),
      act: (t) async {
        // The keyboard is up: it covers the home indicator's room, as on the phone.
        t.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
        t.view.padding = const FakeViewPadding(top: 59 * 2);
        await t.pump();
        // The cursor on "Áo khoác ấm".
        final r = t.getRect(find.byType(TextField));
        await t.tapAt(r.topLeft + const Offset(150, 108));
        await t.pump();
      });
  _screen('quick-note-shown', 'Ghi chú · chạm một ghi chú (tắt “Ẩn nội dung ghi chú”)', home, section: 'note',
      setup: () => Prefs.write('note-previews', '1'),
      act: (t) => openRow(t, 'Thuốc của mẹ'));
  _screen('quick-pdf', 'Tệp · chạm một PDF', home, section: 'file',
      setup: () => QuickLook.debugPdfPage = const _FakePdfPage(),
      act: (t) => openRow(t, 'Hop-dong-thue-nha-2026.pdf'));
  _screen('quick-pdf-icon', 'Tệp · chạm một PDF lớn (chỉ biểu tượng)', home, section: 'file',
      act: (t) => openRow(t, 'So-do-nha-scan.pdf'));
  _screen('quick-file', 'Tệp · chạm một tệp .docx', home, section: 'file',
      act: (t) => openRow(t, 'Di-chuc-nhap.docx'));
  _screen('quick-image-file', 'Tệp · chạm một ảnh thêm từ Tệp', home, section: 'file',
      act: (t) => openRow(t, 'CCCD-mat-truoc.jpg'));
  _screen('quick-text', 'Tệp · chạm một tệp .md', () => FileViewScreen(item: _item('m1', ItemKind.file, 'gia-han-ho-chieu.md', 420), vaultId: 'v'),
      act: (t) async {
    QuickLook.show(t.element(find.byType(FileViewScreen)), _item('m1', ItemKind.file, 'gia-han-ho-chieu.md', 420), vaultId: 'v');
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
  });
  _screen('files', 'Tệp', home, section: 'file');
  _screen('files-grid', 'Tệp · dạng lưới', home, section: 'file', setup: () => Prefs.write('files-view', 'grid'));
  _screen('files-select', 'Tệp · bấm giữ một dòng', home, section: 'file',
      act: (t) async {
    await t.longPress(find.byType(SelectableRow).first);
    await t.pumpAndSettle();
  });
  _screen('info', 'Tệp · bấm giữ → Thông tin', home, section: 'file',
      act: (t) async {
    await t.longPress(find.byType(SelectableRow).first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-info')));
    await t.pumpAndSettle();
  });
  _screen('rename', 'Tệp · bấm giữ → Đổi tên', home, section: 'file',
      act: (t) async {
    await t.longPress(find.byType(SelectableRow).first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-rename')));
    await t.pumpAndSettle();
  });
  _screen('tag-files', 'Tệp · trong nhóm "Hộ chiếu"', home, section: 'file', act: (t) => _tapChip(t, 'Hộ chiếu'));
  _screen('tag-notes', 'Ghi chú · cùng nhóm "Hộ chiếu"', home, section: 'file', act: (t) async {
    await _tapChip(t, 'Hộ chiếu');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('tab-note')));
  });
  _screen('all-tags', 'Tất cả nhóm', home, section: 'audio', act: (t) => t.tap(find.byKey(const ValueKey('all-tags'))));
  _screen('select-mode', 'Thư viện · bấm Chọn', home, section: 'library', act: (t) async {
    await t.tap(find.byKey(const ValueKey('select-button')));
    await t.pump();
  });
  _screen('select', 'Đang chọn', home, section: 'library', act: (t) async {
    await t.tap(find.byKey(const ValueKey('select-button')));
    await t.pump();
    await t.tap(find.byType(PrivateThumb).at(2));
    await t.pump();
    await t.tap(find.byType(PrivateThumb).at(4));
  });
  _screen('photo-menu', 'Thư viện · bấm giữ một ảnh', home, section: 'library', act: (t) async {
    await t.longPress(find.byType(PrivateThumb).at(2));
    await t.pumpAndSettle();
  });
  _screen('home-menu', 'Trang chủ · bấm giữ một mục mới thêm', home, section: 'home', act: (t) async {
    final row = find.byType(OverviewRow).first;
    await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await t.pump();
    await t.longPress(row);
    await t.pumpAndSettle();
  });
  _screen('chip-menu', 'Bấm giữ chip nhóm', home, section: 'library', act: (t) async {
    await t.longPress(find.text('Du lịch').first);
    await t.pumpAndSettle();
  });
  _screen('tag-sheet', 'Chọn 2 ảnh → Nhóm', home, section: 'library',
      act: (t) async {
    await t.tap(find.byKey(const ValueKey('select-button')));
    await t.pump();
    await t.tap(find.byType(PrivateThumb).at(1));
    await t.pump();
    await t.tap(find.byType(PrivateThumb).at(2));
    await t.pump();
    await t.tap(find.text('Nhóm'));
  });
  _screen('message', 'Thông báo nổi', home, section: 'library', act: (t) async {
    showToast(t.element(find.byType(VaultHomeScreen)), 'Đã chuyển vào Đã xoá gần đây',
        icon: Icons.delete_outline_rounded, actionLabel: 'Hoàn tác', besideAction: true, onAction: () {});
  });
  Widget search() => SearchScreen(items: _items, thumbnail: (id) async => _photos.isEmpty ? _thumbnails[0]! : _photos.values.elementAt(id.hashCode % _photos.length));
  Future<void> typeSearch(WidgetTester t, String text) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await t.enterText(find.byType(TextField), text);
    await t.pump();
  }
  _screen('search-empty', 'Tìm kiếm · chưa gõ gì', search);
  _screen('search', 'Tìm kiếm · gõ “thuoc”', search,
      act: (t) => typeSearch(t, 'thuoc'));
  _screen('search-kind', 'Tìm kiếm · chạm ô Thư viện', search,
      act: (t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await t.tap(find.byKey(const ValueKey('search-kind-library')));
    await t.pump();
  });
  _screen('search-none', 'Tìm kiếm · không có kết quả', search,
      act: (t) => typeSearch(t, 'xyzw'));
  _screen('text-json', 'Tệp · mở wifi-config.json', () => FileViewScreen(item: _item('j1', ItemKind.file, 'wifi-config.json', 180), vaultId: 'v'));
  _screen('text-md', 'Tệp · mở gia-han-ho-chieu.md', () => FileViewScreen(item: _item('m1', ItemKind.file, 'gia-han-ho-chieu.md', 420), vaultId: 'v'));
  _screen('file-other', 'Tệp · mở hop-dong.docx', () => FileViewScreen(item: _item('d1', ItemKind.file, 'hop-dong.docx', 48000), vaultId: 'v'));
  _screen('text-txt', 'Tệp · mở ghi-chu-wifi.txt', () => FileViewScreen(item: _item('tx1', ItemKind.file, 'ghi-chu-wifi.txt', 240), vaultId: 'v'));
  _screen('settings', 'Cài đặt kiểu iPhone: các nhóm không tên, cách nhau bằng khoảng trống; thống kê dung lượng chỉ còn tên từng loại', () => settings(vault),
      setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('settings-sync-failed', 'Cài đặt · lần tự động đồng bộ gần nhất bị lỗi', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3'];
    Prefs.write('drive-account', 'ban.do@gmail.com');
    Prefs.write(AutoSync.pref, '1');
    AutoSync.failed.value = true;
  });
  _screen('storage', 'MỚI · bấm thẻ dung lượng: từng phần (ảnh, video, ghi chú, ghi âm, tệp, Đã xoá gần đây, Lịch sử) với số mục + dung lượng, lớn nhất trên cùng; bấm một dòng → tới đúng chỗ quản lý (mục đó / Thùng rác / cài đặt Lịch sử)', () => settings(vault),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('storage-card')));
        await t.pumpAndSettle();
      });
  _screen('sort-menu-library', 'Thư viện · bấm ⇅', home, section: 'library', act: (t) async {
    await t.tap(find.byKey(const ValueKey('sort-button')));
    await t.pumpAndSettle();
  });
  _screen('library-by-size', 'Thư viện · Lớn nhất trước: một lưới, không chia theo ngày', home, section: 'library',
      setup: () => Prefs.write('sort-library', 'size'));
  _screen('mac-settings', 'MacBook · Cài đặt: một cột giữa (trước: kéo căng hết bề ngang)', () => settings(vault), size: const Size(1440, 900),
      setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3']);
  _screen('mac-trash', 'MacBook · Đã xoá gần đây: một cột giữa, ảnh nhỏ lại', () => const Readable(child: TrashScreen()), size: const Size(1440, 900));
  _screen('mac-home', 'MacBook · Tổng quan: 4 ô loại trên một hàng, cao như trên điện thoại (trước: ô cao ~200px, trống)', home, section: 'home', size: const Size(1440, 900));
  _screen('mac-files-grid', 'MacBook · Tệp dạng lưới: nhiều cột vừa màn (trước: 3 ô to như tờ giấy)', home, section: 'file', size: const Size(1440, 900),
      setup: () => Prefs.write('files-view', 'grid'));

  // The whole page in one tall shot, to compare the order (owner 2026-10-27).
  _screen('settings-all', 'Cài đặt · cả trang (ảnh dài): quan trọng lên trên, cùng loại một nhóm', () => settings(vault),
      setup: () => SettingsScreen.debugSyncLog = ['${_now - 5 * 60000}|join|192.168.1.21|ok|12|3'],
      act: (t) async {
    t.view.physicalSize = const Size(430, 2560) * 2;
    await t.pumpAndSettle();
  });
  _screen('settings-backup', 'Cài đặt · Sao lưu và Bảo mật', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('kit-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 200));
    await t.pumpAndSettle();
  });
  // As pushPage: a readable column on a computer.
  Widget page(String title, Widget body) =>
      Readable(child: Builder(builder: (context) => Scaffold(appBar: pageBar(context, title), body: SafeArea(top: false, child: body))));
  final syncLog = [
    '${_now - 3600000}|nearby|iPhone 15 Pro Max|ok|12|3',
    '${_now - 86400000}|nearby|iPad|cancelled|0|0',
    '${_now - 2 * 86400000}|join|192.168.1.21|ok|0|5',
  ];
  _screen('sync', 'Đồng bộ: nhóm không tên — máy gần đây · Google Drive (email tài khoản, Gỡ tài khoản) · Các lần kết nối gần đây (một dòng, bấm mới mở)', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
    SyncScreen.debugAccount = 'ban.do@gmail.com';
    Prefs.write(AutoSync.pref, '1');
  });
  _screen('sync-drive-page', 'Đồng bộ · bấm Google Drive (đã có tài khoản): Đồng bộ ngay · email + Tự động đồng bộ + Chỉ khi có Wi‑Fi · Gỡ tài khoản', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
    SyncScreen.debugAccount = 'ban.do@gmail.com';
    Prefs.write(AutoSync.pref, '1');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-drive')));
    await t.pumpAndSettle();
  });
  _screen('sync-failed-dot', 'Đồng bộ · lần tự động đồng bộ gần nhất bị lỗi', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
    SyncScreen.debugAccount = 'ban.do@gmail.com';
    Prefs.write('drive-account', 'ban.do@gmail.com');
    Prefs.write(AutoSync.pref, '1');
    AutoSync.failed.value = true;
  });
  _screen('sync-drive-add', 'Đồng bộ · lần đầu thêm Google Drive: hộp cho phép kèm công tắc Tự động đồng bộ (bật sẵn)', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugDrive = true;
    SyncScreen.debugSession = (email: 'ban.do@gmail.com', token: '');
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-drive')));
    await t.pumpAndSettle();
  });
  _screen('sync-log', 'Đồng bộ · bấm Các lần kết nối gần đây: danh sách + một dòng giải thích (chỉ tên máy, không địa chỉ IP)', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-log')));
    await t.pumpAndSettle();
  });
  _screen('sync-drive-remove', 'Đồng bộ · Google Drive · bấm Gỡ tài khoản: hỏi lại, tệp trên Drive vẫn còn', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
    SyncScreen.debugAccount = 'ban.do@gmail.com';
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-drive')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sync-drive-remove')));
    await t.pumpAndSettle();
  });
  _screen('sync-allow', 'Đồng bộ · bấm Đồng bộ với máy gần đây → hỏi cho phép tìm và chờ trên Wi‑Fi', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugAddress = '192.168.1.37';
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-nearby')));
    await t.pumpAndSettle();
  });
  _screen('sync-scan', 'Máy kia: quét mã bằng camera (hoặc nhập mã)', () => page('Quét mã', ScanCodePage(onSynced: () {})),
      setup: () => ScanCodePage.debugPreview = const ColoredBox(color: Color(0xFF2A2F36), child: Center(child: QrView(text: _qrText, size: 170))));
  SyncEvent ev(SyncStep k, {int check = 0, int received = 0, int sent = 0, int copies = 0, int done = 0, int total = 0, int bytes = 0, int bytesTotal = 0, int moved = 0}) =>
      SyncEvent(kind: k, check: check, name: '', peers: const [], peerIds: const [], received: received, sent: sent, removed: 0, copies: copies, done: done, total: total, bytes: BigInt.from(bytes), bytesTotal: BigInt.from(bytesTotal), moved: moved, repaired: 0, unrepaired: 0, code: '');
  _screen('sync-drive-listing', 'Google Drive: đang đọc những gì có trên Drive', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.driveListing, done: 3000)), onSynced: () {})));
  _screen('sync-drive-folders', 'Google Drive: tạo thư mục (bản cập nhật thư mục, lần đầu)', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.driveFolders, done: 212, total: 517)), onSynced: () {})));
  _screen('sync-drive-moving', 'Google Drive: dời tệp cũ vào thư mục', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.driveMoving, done: 1400, total: 2986)), onSynced: () {})));
  _screen('sync-drive-done-moved', 'Google Drive: xong, đã sắp xếp lại tệp, không có gì mới', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.done, moved: 2986)), onSynced: () {})));
  // A first sync (owner 2026-10-27): it said "Looking at Google Drive" while it read
  // every item and while the first big file went up.
  _screen('sync-drive-preparing', 'Đồng bộ lần đầu: đang chuẩn bị từng mục để gửi (có đếm), thay vì “Đang xem Google Drive”',
      () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.preparing, done: 86, total: 340)), onSynced: () {})));
  _screen('sync-drive-start', 'Vừa bắt đầu gửi: chưa có byte nào, chưa có tốc độ — các dòng vẫn giữ chỗ (so với màn kế bên)',
      () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.sending, done: 0, total: 340, bytesTotal: 131 << 20)), onSynced: () {})));
  _screen('sync-drive-first-file', 'Tệp đầu tiên đang lên: đã là “Đang gửi lên Google Drive”, số byte chạy mỗi giây',
      () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.sending, done: 0, total: 340, bytes: 38 << 20, bytesTotal: 131 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (2.4 * (1 << 20), 6));
  _screen('sync-drive-repairing', 'Gửi lại tệp bị thiếu/hỏng trên Google Drive: có tên riêng và đếm, không còn là “Đang xem”',
      () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.repairing, done: 1, total: 3, bytes: 4 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (1.8 * (1 << 20), 2));
  _screen('sync-drive-tidying', 'Dọn bản cũ trên Google Drive (mỗi ngày một lần): tên riêng, không lẫn với “xoá mục đã xoá”',
      () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.tidying, done: 12, total: 40)), onSynced: () {})));
  _screen('sync-drive-progress', 'Google Drive: đang gửi lên', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.sending, done: 128, total: 340, bytes: 52 << 20, bytesTotal: 131 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (2.4 * (1 << 20), 6));
  _screen('sync-drive-receiving', 'Google Drive: đang tải về', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.receiving, done: 40, total: 212, bytes: 18 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (3.1 * (1 << 20), 7));
  _screen('sync-drive-removing', 'Google Drive: xoá các mục đã xoá', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.removing, done: 312, total: 700)), onSynced: () {})));
  _screen('sync-device-progress', 'Máy gần đây: đang nhận', () => page('Đồng bộ với máy gần đây', SyncProgress(events: Stream.value(ev(SyncStep.receiving, done: 64, total: 90, bytes: 210 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (9.8 * (1 << 20), 3));
  _screen('sync-interrupted', 'Bị gián đoạn (máy ngủ, mất mạng): bấm Tiếp tục', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.interrupted)), onSynced: () {}, retry: () => const Stream.empty())));
  const hosting = Hosting(qr: _qrText, findable: true, seconds: 274);
  Widget nearby() => page('Đồng bộ với máy gần đây', NearbyPage(address: '192.168.1.37', mirror: '', onSynced: () {}));
  SyncEvent named(SyncStep k, String name, int check) =>
      SyncEvent(kind: k, check: check, name: name, peers: const [], peerIds: const [], received: 0, sent: 0, removed: 0, copies: 0, done: 0, total: 0, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0, repaired: 0, unrepaired: 0, code: '');
  SyncEvent found(List<String> names) =>
      SyncEvent(kind: SyncStep.found, check: 0, name: '', peers: names, peerIds: [for (var i = 0; i < names.length; i++) 'a$i'], received: 0, sent: 0, removed: 0, copies: 0, done: 0, total: 0, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0, repaired: 0, unrepaired: 0, code: '');
  _screen('sync-nearby-waiting', 'Máy gần đây: cả hai máy mở màn hình này và chờ — tự tìm nhau, không cần nhập mã', nearby,
      setup: () => NearbyPage.debugHosting = hosting);
  _screen('sync-nearby-none', 'Máy gần đây: chờ một lúc chưa thấy máy nào — gợi ý cách sửa', nearby, setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugNothingYet = true;
  });
  _screen('sync-nearby-found-one', 'Máy gần đây: đã thấy máy kia, đang kết nối', nearby, setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugEvents = Stream.value(found(['']));
  });
  _screen('sync-nearby-confirm', 'Hai máy đã kết nối: tên máy + mã 472, tự đồng bộ sau 5 giây, chỉ còn nút Huỷ', nearby,
      setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugEvents = Stream.value(named(SyncStep.confirm, 'iPhone 15 Pro Max', 472));
  });
  _screen('sync-nearby-confirm-waiting', 'Hết 5 giây: máy này đã sẵn sàng, chờ máy kia', nearby, setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugEvents = Stream.value(named(SyncStep.confirm, 'iPhone 15 Pro Max', 472));
  }, act: (t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    await t.pump(const Duration(milliseconds: 300));
  });
  _screen('sync-nearby-pick', 'Thấy hai máy có két này: chọn máy muốn đồng bộ', nearby,
      setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugEvents = Stream.value(found(['iPad', 'Google Pixel 8']));
  });
  _screen('sync-peer-cancelled', 'Máy kia bấm Huỷ: máy này báo ngay', () => page('Đồng bộ', SyncProgress(events: Stream.value(named(SyncStep.peerCancelled, '', 0)), onSynced: () {})));
  _screen('sync-nearby-qr', 'Mạng chặn tìm nhau: bấm "Dùng mã QR" → hiện mã của máy này + nút Quét mã', nearby, setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugQr = true;
  }, act: (t) async {
    await t.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await t.pump();
  });
  _screen('sync-allow-restore', 'Máy cũ (đang chờ đồng bộ, không cần bật gì): iPhone 16 khôi phục — tên máy + mã, tự tiếp tục sau 5 giây, có nút Huỷ', nearby,
      setup: () {
    NearbyPage.debugHosting = hosting;
    NearbyPage.debugEvents = Stream.value(named(SyncStep.askRestore, 'iPhone 16', 318));
  });
  _screen('restore-nearby-looking', 'Máy mới (khôi phục): đang tìm máy cũ trên Wi‑Fi', () => page('Từ máy khác', SyncProgress(
        restoring: true,
        events: const Stream.empty(),
        onSynced: () {},
        waiting: Builder(builder: (context) => NearbyLooking(lead: AppLocalizations.of(context).restoreNearbyLead, restoring: true, onScan: () {})),
      )));
  _screen('sync-restore-connected', 'Máy mới (khôi phục): đã kết nối với máy cũ, cùng mã — không phải bấm gì', () => page('Khôi phục', SyncProgress(restoring: true, events: Stream.value(named(SyncStep.connected, 'iPhone 15 Pro Max', 318)), onSynced: () {})));
  _screen('sync-peer-wrong-password', 'Máy cũ: máy mới nhập sai mật khẩu — máy cũ dừng, chỉ mới gửi ổ khoá của két', () => page('Đồng bộ với máy gần đây', SyncProgress(events: Stream.value(ev(SyncStep.peerWrongPassword)), onSynced: () {})));
  _screen('restore-wrong-password', 'Máy mới: sai mật khẩu', () => page('Khôi phục', SyncProgress(restoring: true, events: Stream.value(ev(SyncStep.wrongPassword)), onSynced: () {})));
  _screen('sync-device-sending', 'Máy gần đây: đang gửi — ổ khoá trên đường truyền', () => page('Đồng bộ với máy gần đây', SyncProgress(events: Stream.value(ev(SyncStep.sending, done: 21, total: 90, bytes: 64 << 20, bytesTotal: 230 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (9.8 * (1 << 20), 3));
  _screen('sync-done', 'Xong', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.done, received: 12, sent: 3, copies: 1)), onSynced: () {})));
  _screen('sync-other-vault', 'Máy kia có két khác', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.otherVault)), onSynced: () {})));
  _screen('sync-unreachable', 'Không tới được máy kia', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.unreachable)), onSynced: () {})));
  _screen('sync-signin', 'Google Drive: phiên đăng nhập hết hạn', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.signIn)), onSynced: () {})));
  _screen('sync-failed', 'Không kết nối được', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.failed)), onSynced: () {})));
  SyncEvent failed(SyncStep k, String code) => SyncEvent(kind: k, check: 0, name: '', peers: const [], peerIds: const [], received: 0, sent: 0, removed: 0, copies: 0, done: 0, total: 0, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0, repaired: 0, unrepaired: 0, code: code);
  _screen('sync-drive-full', 'Google Drive đầy: nói rõ, kèm mã lỗi và Sao chép chi tiết', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(failed(SyncStep.driveFull, 'drive-full')), onSynced: () {})));
  _screen('sync-drive-repaired', 'Google Drive: đồng bộ xong, phát hiện 3 tệp trên Drive bị thiếu/hỏng (theo mã băm của chính Google) và đã gửi lại', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(SyncEvent(kind: SyncStep.done, check: 0, name: '', peers: const [], peerIds: const [], received: 2, sent: 1, removed: 0, copies: 0, done: 0, total: 0, bytes: BigInt.zero, bytesTotal: BigInt.zero, moved: 0, repaired: 3, unrepaired: 0, code: '')), onSynced: () {})));
  _screen('sync-drive-failed-code', 'Google Drive lỗi khác: mã lỗi để gửi kèm góp ý', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(failed(SyncStep.failed, 'drive-rate-limited')), onSynced: () {})));
  _screen('settings-keys', 'Cài đặt · nhóm khoá của két: thêm Kiểm tra 24 từ và mật khẩu, Giữ 24 từ trong iCloud Keychain (tắt mặc định)', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    KeyBackup.debugSupported = true;
  }, act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('key-backup-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 220));
    await t.pumpAndSettle();
  });
  _screen('key-backup-ask', 'Bật Giữ 24 từ trong iCloud Keychain: hỏi lại, nói rõ đánh đổi', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    KeyBackup.debugSupported = true;
  }, act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('key-backup-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byKey(const ValueKey('key-backup-row')), matching: find.byType(Switch)));
    await t.pumpAndSettle();
  });
  // Android: the same through Google Block Store (owner 2026-10-27).
  _screen('settings-keys-google', 'Android · Cài đặt: Giữ 24 từ trong tài khoản Google (Block Store, tắt mặc định)', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    KeyBackup.debugSupported = true;
    KeyBackup.debugGoogle = true;
  }, act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('key-backup-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 220));
    await t.pumpAndSettle();
  });
  _screen('key-backup-ask-google', 'Android · Bật Giữ 24 từ trong tài khoản Google: hỏi lại, nói rõ đánh đổi + cần khoá màn hình', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    KeyBackup.debugSupported = true;
    KeyBackup.debugGoogle = true;
  }, act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('key-backup-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byKey(const ValueKey('key-backup-row')), matching: find.byType(Switch)));
    await t.pumpAndSettle();
  });
  _screen('key-check', 'Kiểm tra 24 từ và mật khẩu: chỉ so khớp, không hiện, không lưu', () => page('Kiểm tra 24 từ và mật khẩu', const KeyCheckScreen(libraryDir: '', hasPassword: true)), setup: () => KeyCheckScreen.debugResults = (words: true, password: false));
  // Version history (owner 2026-10-27): every item, on this device, 30 days / 1 GB unless changed.
  final wifi = _item('n1', ItemKind.note, 'Wifi nhà bà ngoại', 120, tags: ['t7']);
  HistoryVersion ver(String rev, int ago, {String? name, bool here = true, bool same = false, bool gone = false, int size = 96}) =>
      HistoryVersion(rev: rev, replacedMs: _now - ago, item: _item('n1', ItemKind.note, name ?? 'Wifi nhà bà ngoại', size),
          thisDevice: here, hasContent: !gone, sameContent: same);
  void history() {
    HistoryScreen.debugVersions = [
      ver('a1', 3600000),
      ver('a2', _day * 2, here: false),
      ver('a3', _day * 6, name: 'Wifi nhà ngoại', same: true),
      ver('a4', _day * 19, size: 64),
      ver('a5', _day * 27, gone: true),
    ];
    HistoryScreen.debugContent = (rev) => Uint8List.fromList(utf8.encode(switch (rev) {
          'a1' => 'Tên mạng: Nha Ba Ngoai 5G\nMật khẩu: đổi ngày 20/10, ghi trong sổ đỏ\n\nModem để trên tủ lạnh.',
          _ => 'Tên mạng: Nha Ba Ngoai\nMật khẩu: ghi trong sổ đỏ',
        }));
    HistoryScreen.debugDays = 30;
  }
  _screen('item-menu-history', 'Ghi chú · bấm giữ: thêm "Lịch sử phiên bản" cho mọi mục', home, section: 'note',
      act: (t) async {
    await t.longPress(find.byType(SelectableRow).first);
    await t.pumpAndSettle();
  });
  _screen('history-list', 'Lịch sử phiên bản của một ghi chú: giờ thay đổi, máy nào sửa, cỡ; bản đã bị dọn để tiết kiệm chỗ thì mờ', () => page('Lịch sử phiên bản', HistoryScreen(item: wifi)), setup: history);
  _screen('history-version', 'Mở một bản cũ: xem nội dung, "Khôi phục bản này" (bản hiện tại được giữ lại, nên hoàn tác được)', () => page('Lịch sử phiên bản', HistoryScreen(item: wifi)),
      setup: history, act: (t) async {
    await t.tap(find.byKey(const ValueKey('history-a2')));
    await t.pumpAndSettle();
  });
  _screen('history-empty', 'Chưa có bản cũ nào', () => page('Lịch sử phiên bản', HistoryScreen(item: wifi)),
      setup: () {
    HistoryScreen.debugVersions = const [];
    HistoryScreen.debugDays = 30;
  });
  _screen('history-settings', 'Cài đặt → Lịch sử phiên bản: giữ bao lâu (Tắt · 7 · 30 · 90 ngày), tối đa bao nhiêu (500 MB · 1 GB · 5 GB · Không giới hạn), Xoá toàn bộ', () => page('Lịch sử phiên bản', const HistorySettingsScreen()),
      setup: () => HistorySettingsScreen.debugState = (30, BigInt.from(1 << 30), BigInt.from(186) * BigInt.from(1 << 20)));
  _screen('settings-history', 'Cài đặt: dòng Lịch sử phiên bản; thanh dung lượng có thêm phần Lịch sử (xám)', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    SettingsScreen.debugHistoryBytes = BigInt.from(186) * BigInt.from(1 << 20);
  });
  _screen('lock-sync', 'Két tự khoá giữa lúc đồng bộ Google Drive: màn khoá như thường, thêm dòng "Đang đồng bộ 40%", màn hình vẫn sáng, đồng bộ chạy tiếp', lock,
      setup: () => syncStatus.value = const SyncStatus(drive: true, kind: SyncStep.receiving, done: 40, total: 100));
  _screen('report-problem', 'Cài đặt → Báo lỗi: các lỗi gần đây (chỉ mã và giờ), Góp ý, Sao chép chi tiết', () => page('Báo lỗi', const ErrorReportScreen()),
      setup: () => ErrorReportScreen.debugEntries = [
            (DateTime.fromMillisecondsSinceEpoch(_now - 3600000), 'sync', 'drive-rate-limited'),
            (DateTime.fromMillisecondsSinceEpoch(_now - 3700000), 'sync', 'drive-server-error'),
            (DateTime.fromMillisecondsSinceEpoch(_now - 86400000), 'drive-sign-in', 'canceled'),
            (DateTime.fromMillisecondsSinceEpoch(_now - 2 * 86400000), 'vault', 'io-timed-out'),
          ]);
  _screen('settings-security', 'Cài đặt · Bảo mật (iPhone)', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.text('Chặn chụp màn hình'), 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
  });
  _screen('identity-card', 'Cài đặt · Đổi biểu tượng và màu', () => Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => showIdentityCard(context, icon: 0, color: 3));
        return settings(vault);
      }));
  _screen('settings-display', 'Cài đặt · Hiển thị', () => settings(vault),
      act: (t) async {
        await t.scrollUntilVisible(find.byKey(const ValueKey('hold-home-row')), 200, scrollable: find.byType(Scrollable).first);
        await t.drag(find.byType(Scrollable).first, const Offset(0, 500));
        await t.pump();
      });
  _screen('settings-appearance', 'Cài đặt · Giao diện', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.text('Giao diện'), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await t.pumpAndSettle();
    await t.tap(find.text('Giao diện'));
    await t.pumpAndSettle();
  });
  _screen('settings-language', 'Cài đặt · Ngôn ngữ', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('language-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('language-row')));
    await t.pumpAndSettle();
  });
  Future<void> toAbout(WidgetTester t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('about-version')), 300, scrollable: find.byType(Scrollable).first);
    await t.pump();
  }
  _screen('settings-about', 'Cài đặt · Thông tin', () => settings(vault), act: toAbout);
  // The quick tour (owner 2026-10-26): tips over the real vault page, after a vault is
  // made (it is empty then), again from Settings (a vault with things in it), and the
  // shorter one after a restore.
  Future<void> tourOpen(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  const madeTips = [
    ('add', 'các ô thêm (két còn trống)'),
    ('items', 'chạm mở · giữ ra menu · giữ rồi kéo để chọn nhiều'),
    ('settings', 'nút Cài đặt'),
    ('lock', 'nút khoá: rời app là két tự khoá'),
    ('copy', 'bản thứ hai + 24 từ và mật khẩu · Cài đồng bộ ngay / Để sau'),
  ];
  for (final (i, (name, caption)) in madeTips.indexed) {
    _screen('tip-made-${i + 1}-$name', 'Hướng dẫn nhanh sau khi tạo két · ${i + 1}/${madeTips.length}: $caption',
        () => const VaultHomeScreen(libraryDir: '', vault: vault, tour: TourKind.created),
        section: 'library',
        setup: () {
          CoachTour.debugStart = i;
          debugCamera = true; // a phone: Take photo and Record video are offered
          _itemsNow = const [];
        },
        act: tourOpen);
  }
  const fullTips = [
    ('add', 'nút +'),
    ('items', 'một mục: chạm mở · giữ ra menu · giữ rồi kéo'),
    ('tabs', 'các thẻ ở thanh dưới'),
    ('settings', 'nút Cài đặt'),
    ('lock', 'thẻ Tổng quan: giữ để khoá ngay'),
    ('copy', 'bản thứ hai + 24 từ và mật khẩu, không có nút: bấm Tiếp sang Cài đặt'),
  ];
  for (final (i, (name, caption)) in fullTips.indexed) {
    _screen('tip-guide-${i + 1}-$name', 'Hướng dẫn sử dụng (Cài đặt → Hướng dẫn sử dụng, két đã có đồ) · ${i + 1}/10: $caption',
        () => const VaultHomeScreen(libraryDir: '', vault: vault, tour: TourKind.guide),
        setup: () => CoachTour.debugStart = i,
        act: tourOpen);
  }
  _screen('tip-restored-1-add', 'Sau khi khôi phục: bản ngắn 4 gợi ý (thêm, mở, các thẻ, Cài đặt)',
      () => const VaultHomeScreen(libraryDir: '', vault: vault, tour: TourKind.restored),
      act: tourOpen);
  // User guide (owner 2026-10-26): near the top of Settings; it runs the vault tips, then
  // goes on in Settings, counting on.
  _screen('settings-top', 'Cài đặt · đầu trang: nhóm Trợ giúp (Hướng dẫn sử dụng, Góp ý) ngay dưới Đồng bộ',
      () => settings(vault),
      setup: () => SettingsScreen.debugSyncLog = const []);
  _screen('settings-security-group', 'Cài đặt · hai nhóm bảo mật: khoá của két (Face ID, PIN, mật khẩu, 24 từ) tách khỏi nhóm che màn hình (tự khoá, chặn chụp, làm mờ, ẩn chữ)',
      () => settings(vault),
      setup: () => SettingsScreen.debugSyncLog = const [],
      act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('lock-on-leave-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 260));
    await t.pumpAndSettle();
  });
  _screen('settings-lock-on-leave-off', 'Cài đặt · tắt “Khoá ngay khi rời ứng dụng” (máy hỏi Face ID/mật mã trước, như mọi cài đặt bảo mật)',
      () => settings(vault),
      setup: () => SettingsScreen.debugSyncLog = const [],
      act: (t) async {
    final row = find.byKey(const ValueKey('lock-on-leave-row'));
    await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 200));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await t.pumpAndSettle();
  });
  _screen('autolock-menu-away', 'Cài đặt · Tự khoá khi đã tắt “Khoá ngay khi rời ứng dụng”', () => settings(vault),
      setup: () {
    SettingsScreen.debugSyncLog = const [];
    Prefs.write('lock-on-leave', '0');
  }, act: (t) async {
    await t.scrollUntilVisible(find.text('Tự khoá khi không dùng'), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 300));
    await t.pumpAndSettle();
    await t.tap(find.text('Tự khoá khi không dùng'));
  });
  _screen('tip-lock-away', 'Gợi ý Tự khoá khi đã tắt “Khoá ngay khi rời ứng dụng”: chỉ vào Cài đặt',
      () => const VaultHomeScreen(libraryDir: '', vault: vault, tour: TourKind.guide),
      setup: () {
    CoachTour.debugStart = 4;
    Prefs.write('lock-on-leave', '0');
  }, act: tourOpen);
  const settingsTips = [
    ('sync', 'nhóm Đồng bộ'),
    ('security', 'nhóm Bảo mật'),
    ('backup', 'Sao lưu ra tệp'),
    ('guide', 'dòng Hướng dẫn sử dụng: xem lại bất cứ lúc nào'),
  ];
  for (final (i, (name, caption)) in settingsTips.indexed) {
    _screen('tip-guide-${i + 7}-$name', 'Hướng dẫn sử dụng trong Cài đặt · ${i + 7}/10: $caption',
        () => settings(vault, guideFrom: 6),
        setup: () {
          CoachTour.debugStart = i;
          SettingsScreen.debugSyncLog = const [];
        },
        act: tourOpen);
  }
  _screen('settings-debug-taps', 'Cài đặt · chạm 5 lần vào Phiên bản', () => settings(vault), act: (t) async {
    await toAbout(t);
    for (var i = 0; i < 5; i++) {
      await t.tap(find.byKey(const ValueKey('about-version')));
      await t.pump(const Duration(milliseconds: 120));
    }
  });
  _screen('settings-debug-on', 'Cài đặt · đã bật gỡ lỗi', () => settings(vault), setup: () => Prefs.write('debug-mode', '1'), act: toAbout);
  _screen('settings-debug-vault', 'Cài đặt · gỡ lỗi bật: Tạo két mới', () => settings(vault),
      setup: () => Prefs.write('debug-mode', '1'), act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('debug-new-vault')), 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
  });
  void debugSetup() {
    DebugScreen.debugNetworkBlocked = true;
    Prefs.write('debug-mode', '1');
    for (final (k, v) in [('run', 'start-open'), ('run', 'done-r2-s0-x0-4100ms'), ('look', 'same'), ('look', 'same'), ('run', 'start-change'), ('run', 'done-r0-s1-x0-2300ms')]) {
      SyncLog.add(k, v);
    }
  }
  _screen('debug', 'Trang gỡ lỗi', change: 'Làm lại theo kiểu Cài đặt: khối phiên bản trên cùng; Công cụ (Kiểm tra Google Drive MỚI, Sổ đồng bộ MỚI, Nhật ký, Két trên máy này) mở trang riêng; Máy này; Thử nghiệm; Tắt gỡ lỗi chữ đỏ ở cuối', () => const DebugScreen(), setup: debugSetup);
  _screen('debug-more', 'Trang gỡ lỗi · cuộn xuống', change: 'Phần dưới: thông tin máy, Bản tạm (nút Xoá ngay trên dòng), Thử nghiệm, Tắt gỡ lỗi', () => const DebugScreen(), setup: debugSetup, act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('debug-off')), 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
  });
  _screen('debug-sync-log', 'Gỡ lỗi · Sổ đồng bộ', change: 'MỚI: sổ đồng bộ trên trang riêng, mới nhất trên cùng; Sao chép / Xoá ở dưới', () => const DebugScreen(), setup: debugSetup, act: (t) async {
    await t.tap(find.byKey(const ValueKey('debug-sync-log')));
    await t.pumpAndSettle();
  });
  Widget driveCheckPage() => Builder(builder: (context) => groupedPage(context, Builder(builder: (context) =>
      Scaffold(appBar: AppBar(title: const Text('Kiểm tra Google Drive')), body: const DriveCheckScreen()))));
  _screen('drive-check', 'Gỡ lỗi · Kiểm tra Google Drive (chưa chạy)', change: 'MỚI: giải thích ngắn + nút Kiểm tra', driveCheckPage, setup: () {
    Prefs.write('drive-account', 'ban.do@gmail.com');
    DriveCheckScreen.debugResult = null;
  });
  _screen('drive-check-junk', 'Gỡ lỗi · Kiểm tra Google Drive: có tệp rác', change: 'MỚI: số liệu theo loại; Tệp rác đỏ kèm dung lượng; nút Dọn tệp rác (hỏi lại trước khi xoá)', driveCheckPage, setup: () {
    Prefs.write('drive-account', 'ban.do@gmail.com');
    DriveCheckScreen.debugResult = const DriveCounts(items: 98, folders: 172, current: 290, currentBytes: 1240000000, old: 214, oldBytes: 96000000,
        journal: 141, junk: 37, junkBytes: 81000000, unknown: 0, summary: '');
  });
  _screen('drive-check-clean', 'Gỡ lỗi · Kiểm tra Google Drive: không có rác', change: 'MỚI: Tệp rác: Không có (dấu ✓ xanh)', driveCheckPage, setup: () {
    Prefs.write('drive-account', 'ban.do@gmail.com');
    DriveCheckScreen.debugResult = const DriveCounts(items: 98, folders: 172, current: 290, currentBytes: 1240000000, old: 214, oldBytes: 96000000,
        journal: 141, junk: 0, junkBytes: 0, unknown: 0, summary: '');
  });
  _screen('autolock-menu', 'Cài đặt · Tự khoá', () => settings(vault), act: (t) async {
    await t.tap(find.text('Tự khoá khi không dùng'));
  });
  Widget sheetOver(Widget sheet) => Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => showModalBottomSheet<bool>(context: context, builder: (_) => sheet));
        return home();
      });
  _screen('originals-photos', 'Vừa cất 5 ảnh vào két', () => sheetOver(const DeleteOriginalsSheet(count: 5, photos: true)),
      section: 'library');
  _screen('originals-files', 'Vừa cất 2 tệp vào két', () => sheetOver(const DeleteOriginalsSheet(count: 2, photos: false)),
      section: 'file');
  _screen('blur', 'Thư viện · làm mờ ảnh thu nhỏ (mặc định)', home, section: 'library');
  _screen('security-info', 'Cách két được bảo vệ · đầu trang', () => const SecurityInfoScreen());
  _screen('security-info-2', 'Cách két được bảo vệ · giữa trang', () => const SecurityInfoScreen(), act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('sec-4')), 300, scrollable: find.byType(Scrollable).first);
    await t.pump();
  });
  _screen('security-info-3', 'Cách két được bảo vệ · cuối trang', () => const SecurityInfoScreen(), act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('sec-tech')), 300, scrollable: find.byType(Scrollable).first);
    await t.scrollUntilVisible(find.textContaining('kiểm toán'), 300, scrollable: find.byType(Scrollable).first);
  });
  Future<void> showInTrash(WidgetTester t, String text) =>
      t.scrollUntilVisible(find.text(text), 200, scrollable: find.byType(Scrollable).first);
  Future<void> settleTrash(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  _screen('trash', 'Đã xoá gần đây', () => const Readable(child: TrashScreen()));
  _screen('trash-select', 'Đã xoá · bấm Chọn rồi chạm 2 mục', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('trash-select')));
        await t.pump();
        await t.tap(find.byType(PrivateThumb).first);
        await t.pump();
        await t.tap(find.text('Mật khẩu wifi cũ'));
        await t.pump();
      });
  _screen('trash-drag', 'Đã xoá · bấm giữ 1 ảnh rồi quẹt sang mục khác', () => const Readable(child: TrashScreen()),
      act: (t) async {
        final from = t.getCenter(find.byType(PrivateThumb).first);
        final g = await t.startGesture(from);
        await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await g.moveBy(const Offset(40, 0));
        await t.pump();
        await g.moveTo(t.getCenter(find.byType(PrivateThumb).last));
        await t.pump();
        await g.up();
      });
  _screen('trash-preview', 'Đã xoá · chạm 1 ảnh', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.tap(find.byType(PrivateThumb).first);
        await settleTrash(t);
      });
  _screen('trash-preview-video', 'Đã xoá · chạm 1 video (có ảnh nhỏ)', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('trash-video-mark')));
        await settleTrash(t);
      });
  _screen('trash-preview-file', 'Đã xoá · chạm tệp bị xoá ở máy khác', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await showInTrash(t, 'Hop-dong-thue-nha-cu.pdf');
        await t.pump();
        await t.tap(find.text('Hop-dong-thue-nha-cu.pdf'));
        await settleTrash(t);
      });
  _screen('trash-menu', 'Đã xoá · bấm giữ 1 ảnh', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.longPress(find.byType(PrivateThumb).first);
        await t.pumpAndSettle();
      });
  _screen('trash-info', 'Đã xoá · bấm giữ → Thông tin', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await showInTrash(t, 'Hop-dong-thue-nha-cu.pdf');
        await t.pump();
        await t.longPress(find.text('Hop-dong-thue-nha-cu.pdf'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('menu-info')));
        await t.pumpAndSettle();
      });
  _screen('trash-purge-confirm', 'Đã xoá · chọn 2 mục → Xoá vĩnh viễn', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('trash-select')));
        await t.pump();
        await t.tap(find.byType(PrivateThumb).first);
        await t.tap(find.text('Mật khẩu wifi cũ'));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('trash-purge')));
        await t.pumpAndSettle();
      });
  // Owner 2026-10-27: two parts, and Restore asks first with a clearer icon.
  _screen('trash-held-part', 'Đã xoá · phần thứ hai: “Đã xoá hẳn trên máy khác”, chỉ còn trên máy này, không đồng bộ nữa',
      () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.scrollUntilVisible(find.byKey(const ValueKey('trash-part-held')), 200, scrollable: find.byType(Scrollable).first);
        await t.drag(find.byType(Scrollable).first, const Offset(0, -120));
        await t.pumpAndSettle();
      });
  _screen('trash-restore-confirm', 'Đã xoá · bấm giữ 1 ảnh → Khôi phục: hỏi trước', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.longPress(find.byType(PrivateThumb).first);
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('menu-restore')));
        await t.pumpAndSettle();
      });
  _screen('trash-empty', 'Đã xoá gần đây · trống', () => const Readable(child: TrashScreen()), setup: () => _noTrash = true);
  _screen('delete-confirm-one', 'Thư viện · bấm giữ 1 ảnh → Xoá', home, section: 'library', act: (t) async {
    await t.longPress(find.byType(PrivateThumb).at(2));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('menu-delete')));
    await t.pumpAndSettle();
  });
  _screen('delete-confirm-many', 'Thư viện · chọn 3 ảnh → Xoá', home, section: 'library', act: (t) async {
    await t.tap(find.byKey(const ValueKey('select-button')));
    await t.pump();
    for (final i in [1, 2, 4]) {
      await t.tap(find.byType(PrivateThumb).at(i));
      await t.pump();
    }
    await t.tap(find.byKey(const ValueKey('select-delete')));
    await t.pumpAndSettle();
  });
  _screen('delete-confirm-note', 'Sửa ghi chú · bấm Xoá', () => NoteScreen(item: _items.firstWhere((i) => i.kind == ItemKind.note)),
      act: (t) async {
    await t.tap(find.byKey(const ValueKey('note-delete')));
    await t.pumpAndSettle();
  });
  _screen('delete-confirm-tag', 'Bấm giữ chip nhóm → Xoá nhóm', home, section: 'library', act: (t) async {
    await t.longPress(find.text('Du lịch').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Xoá nhóm'));
    await t.pumpAndSettle();
  });
  _screen('drag-select', 'Thư viện · bấm giữ 1 ảnh rồi quẹt qua 6 ảnh', home, section: 'library', act: (t) async {
    final g = await t.startGesture(t.getCenter(find.byType(PrivateThumb).at(1)));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(30, 0));
    await t.pump();
    await g.moveTo(t.getCenter(find.byType(PrivateThumb).at(4)));
    await t.pump();
    await g.moveTo(t.getCenter(find.byType(PrivateThumb).at(6)));
    await t.pump();
    await g.up();
  });
  const words = 'bounce announce episode wreck engine define poet hand figure slide beef confirm frown notice actor mom surround nurse feature ski gadget volume cousin cancel';
  _screen('kit-password', 'Khoá khôi phục: sau Face ID còn phải nhập mật khẩu két', () => const KitPasswordScreen(libraryDir: ''));
  _screen('kit', 'Khoá khôi phục: 24 từ che sẵn, có nút Đổi khoá khôi phục', () => EmergencyKitScreen(keyText: words, confirm: false, onChange: () {}));
  _screen('kit-legacy', 'Khoá khôi phục kiểu cũ (CS1-…): nút "Đổi sang 24 từ"', () => EmergencyKitScreen(keyText: 'CS1-7QK2-M9XD-4TRB-PW3H-8ZNA-6CJE-1VFS', confirm: false, onChange: () {}));
  Widget change(int step) => ChangeKeyScreen(libraryDir: '', password: '', onBackup: () async {});
  for (final (i, name, what) in [
    (0, 'intro', 'giải thích: dữ liệu giữ nguyên, PIN/Face ID dùng tiếp, bản sao lưu cũ cần khoá cũ'),
    (1, 'words', '24 từ mới'),
    (2, 'check', 'gõ lại 4 từ'),
    (3, 'done', 'xong, nhắc sao lưu lại'),
  ]) {
    _screen('change-key-$name', 'Đổi khoá khôi phục · $what', () => change(i), setup: () {
      ChangeKeyScreen.debugWords = words;
      ChangeKeyScreen.debugStep = i;
    });
  }
  _screen('kit-shown', 'Khoá khôi phục: sau khi bấm Xem', () => const EmergencyKitScreen(keyText: words, confirm: false),
      act: (t) => t.tap(find.byKey(const ValueKey('secret-show'))));
  _screen('kit-confirm', 'Khoá khôi phục lần đầu: gõ một từ để xác nhận', () => const EmergencyKitScreen(keyText: words, confirm: true));
  _screen('backup-password', 'Mật khẩu sao lưu: ô nhập che sẵn', () => const BackupPasswordScreen(libraryDir: '', change: false),
      act: (t) async {
    await t.enterText(find.byType(TextField).first, 'orange kettle whispers at dawn');
  });
  _screen('password-common', 'Mật khẩu: bị từ chối vì quá phổ biến (kể cả thêm số)', () => const BackupPasswordScreen(libraryDir: '', change: false),
      act: (t) async {
    await t.enterText(find.byType(TextField).first, 'Sunshine2024!');
    await t.pump();
  });
  _screen('password-guessable', 'Mật khẩu: bị từ chối vì quá dễ đoán', () => const BackupPasswordScreen(libraryDir: '', change: false),
      act: (t) async {
    await t.enterText(find.byType(TextField).first, 'lamp river');
    await t.pump();
  });
  _screen('change-password', 'Đổi mật khẩu', () => const BackupPasswordScreen(libraryDir: '', change: true));
  void useWords() => NewVaultScreen.debugWords = words;
  Future<void> tapKey(WidgetTester t, String key) async {
    await t.ensureVisible(find.byKey(ValueKey(key)));
    await t.pump();
    await t.tap(find.byKey(ValueKey(key)));
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> fillCheck(WidgetTester t) async {
    final w = words.split(' ');
    for (final (i, n) in [2, 8, 14, 21].indexed) {
      await t.enterText(find.byKey(ValueKey('check-word-$i')), w[n]);
    }
    await t.pump();
  }

  _screen('delete-countdown', 'Xoá két · 10 giây đếm ngược', () => const SizedBox.expand(key: ValueKey('host')),
      act: (t) async {
    confirmCountdown(t.element(find.byKey(const ValueKey('host'))), title: 'Xoá vĩnh viễn két này?');
    await t.pump();
    await t.pump(const Duration(milliseconds: 3200));
  });
  _screen('vault-manager', 'Debug · Két trên máy này', () => const VaultManagerScreen(libraryDir: ''),
      setup: () => VaultManagerScreen.debugSlots = [
            VaultSlot(id: 'e0a966aed6bec8151ebb59139e5aa773', sizeBytes: BigInt.from(1843 << 20), hasPassword: true, hasPin: true, hasBiometric: true, isOpen: true),
            VaultSlot(id: '3fa9c1d2e4b5a6978877665544332211', sizeBytes: BigInt.from(37 << 20), hasPassword: true, hasPin: true, hasBiometric: false, isOpen: false),
            VaultSlot(id: '9b3ad0e1f2c4475a8e61d39b2f0c18d3', sizeBytes: BigInt.from(212 << 10), hasPassword: false, hasPin: true, hasBiometric: false, isOpen: false),
          ]);
  _screen('welcome', 'Màn đầu tiên: Tạo két mới · Khôi phục két', () => const WelcomeScreen(libraryDir: ''));
  _screen('restore-keys', 'Khôi phục · 1. Dán 24 từ và mật khẩu', () => const RestoreKeysScreen(libraryDir: ''));
  _screen('restore-source', 'Khôi phục · 2. Két đang ở đâu?', () => const RestoreSourceScreen(libraryDir: '', words: 'fake', password: 'fake'),
      setup: () => RestoreSourceScreen.debugDrive = true);
  _screen('restore-none', 'Khôi phục · không còn nơi nào giữ két', () => const RestoreSourceScreen(libraryDir: '', words: 'fake', password: 'fake'),
      act: (t) async {
    await t.tap(find.byKey(const ValueKey('restore-none')));
    await t.pumpAndSettle();
  });
  _screen('restore-drive', 'Khôi phục · Google Drive (24 từ đã nhập ở bước 1)', () => const DriveJoinScreen(libraryDir: '', words: 'fake', password: 'fake'),
      setup: () => DriveJoinScreen.debugAccount = 'me@example.com');
  _screen('new-vault-biometric', 'Tạo két · 5. Face ID: Bật hoặc Để sau', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: () {
    useWords();
    NewVaultScreen.debugBiometricStep = true;
  });
  _screen('new-vault', 'Tạo két · 1. Ghi lại 24 từ (vào thẳng, không màn giới thiệu)', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords);
  _screen('join-drive', 'Mở két từ Google Drive · trước khi đăng nhập', () => const DriveJoinScreen(libraryDir: ''));
  _screen('join-drive-signed', 'Mở két từ Google Drive · đã đăng nhập: nhập 24 từ và mật khẩu', () => const DriveJoinScreen(libraryDir: ''),
      setup: () => DriveJoinScreen.debugAccount = 'ban@gmail.com');
  _screen('new-vault-words-shown', 'Tạo két · 24 từ sau khi chạm Xem', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords, act: (t) async {
    await tapKey(t, 'secret-show');
  });
  _screen('new-vault-check', 'Tạo két · 2. Gõ lại 4 từ', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords, act: (t) async {
    await tapKey(t, 'words-done');
    await fillCheck(t);
  });
  _screen('new-vault-password', 'Tạo két · 3. Mật khẩu: nhớ thật kỹ', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords, act: (t) async {
    await tapKey(t, 'words-done');
    await fillCheck(t);
    await tapKey(t, 'check-done');
    await t.enterText(find.byKey(const ValueKey('new-password')).first, 'sunflower');
    await t.pump();
  });
  _screen('new-vault-pin', 'Tạo két · 4. Mã PIN = mở nhanh trên máy này', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords, act: (t) async {
    await tapKey(t, 'words-done');
    await fillCheck(t);
    await tapKey(t, 'check-done');
    await t.enterText(find.byKey(const ValueKey('new-password')).first, 'orange kettle whispers at dawn');
    await t.enterText(find.byKey(const ValueKey('new-password-again')).first, 'orange kettle whispers at dawn');
    await t.pump();
    await tapKey(t, 'password-next');
  });
  _screen('new-vault-second', 'Két thứ hai: dùng chung 24 từ, bỏ qua bước ghi từ', () => const NewVaultScreen(libraryDir: '', first: false),
      setup: () => NewVaultScreen.debugWords = words);

  // Every action button at the bottom, within the thumb's reach (2026-10-25).
  _screen('bottom-note', 'Sửa ghi chú · bàn phím đóng: Xong · Gửi · Xoá ở dưới',
      () => NoteScreen(item: _items.firstWhere((i) => i.kind == ItemKind.note)));
  _screen('bottom-note-typing', 'Sửa ghi chú · bàn phím mở: định dạng + ẩn bàn phím',
      () => _FakeKeyboard(child: NoteScreen(item: _formatted)),
      act: (t) async {
        t.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
        t.view.padding = const FakeViewPadding(top: 59 * 2);
        await t.pump();
        final r = t.getRect(find.byType(TextField));
        await t.tapAt(r.topLeft + const Offset(150, 108));
        await t.pump();
      });
  _screen('bottom-file-image', 'Tệp · mở CCCD-mat-truoc.jpg', () => FileViewScreen(item: _items.firstWhere((i) => i.name == 'CCCD-mat-truoc.jpg'), vaultId: 'v'));
  _screen('bottom-file-other', 'Tệp · mở hop-dong.docx', () => FileViewScreen(item: _item('d1', ItemKind.file, 'hop-dong.docx', 48000), vaultId: 'v'));
  _screen('bottom-trash', 'Đã xoá gần đây · Chọn ở thanh dưới', () => const Readable(child: TrashScreen()));
  _screen('bottom-trash-select', 'Đã xoá · bấm Chọn', () => const Readable(child: TrashScreen()),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('trash-select')));
        await t.pump();
        await t.tap(find.byKey(ValueKey('trash-${'x1'.padRight(32, '_')}')));
        await t.pump();
      });
  _screen('bottom-select', 'Thư viện · đang chọn: Xong và Chọn tất cả ở thanh dưới', home, section: 'library', act: (t) async {
    await t.tap(find.byKey(const ValueKey('select-button')));
    await t.pump();
  });
  _screen('bottom-set-pin', 'Đặt mã PIN cho máy này · Tiếp + Để sau ở dưới',
      () => const SetPinScreen(skippable: true, forThisPhone: true));
  _screen('bottom-icons', 'Tạo két · ⋯ biểu tượng: nút Đóng ở dưới, bỏ ×', () => Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => showAllIcons(context, 0));
        return const Scaffold();
      }));
  _screen('bottom-search', 'Tìm kiếm · ô tìm ở dưới, trên bàn phím',
      () => _FakeKeyboard(child: SearchScreen(items: _items, thumbnail: (_) async => _thumbnails[0]!)),
      act: (t) async {
        t.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
        t.view.padding = const FakeViewPadding(top: 59 * 2);
        await t.pump();
        await t.enterText(find.byKey(const ValueKey('search-field')), 'thuoc');
        await t.pump();
      });
  _screen('bottom-lock-password', 'Màn khoá · dùng mật khẩu: Mở khoá ở dưới', lock, act: (t) async {
    await t.tap(find.byKey(const ValueKey('more-button')));
    await t.pumpAndSettle();
    await t.tap(find.text('Dùng mật khẩu'));
    await t.pump();
  });
  _screen('bottom-backup-password', 'Mật khẩu sao lưu · Lưu ở dưới, bàn phím mở',
      () => const _FakeKeyboard(child: BackupPasswordScreen(libraryDir: '', change: false)),
      act: (t) async {
        t.view.viewInsets = const FakeViewPadding(bottom: 336 * 2);
        t.view.padding = const FakeViewPadding(top: 59 * 2);
        await t.pump();
      });
  _screen('bottom-kit-password', 'Khoá khôi phục · nhập mật khẩu: nút ở dưới', () => const KitPasswordScreen(libraryDir: ''));
  _screen('bottom-delete-vault', 'Xoá két · nút đỏ ở dưới',
      () => const DeleteVaultScreen(libraryDir: '', vault: vault, sizeText: '214 MB · 86 mục'));
  _screen('bottom-new-vault-password', 'Tạo két · 3. Mật khẩu: Tiếp ở hàng dưới', () => const NewVaultScreen(libraryDir: '', first: true),
      setup: useWords, act: (t) async {
    await tapKey(t, 'words-done');
    await fillCheck(t);
    await tapKey(t, 'check-done');
  });
}

void _leftCamera() {
  debugCamera = true;
  Prefs.write('action-side', 'left');
}

/// A PDF's first page for the renders (tests have no PDF engine): a white sheet with a
/// heading and lines of text.
/// Taps the link whose text is [text] in the rich text on screen.
void _tapLink(WidgetTester t, String text) {
  for (final rich in t.widgetList<RichText>(find.byType(RichText))) {
    TapGestureRecognizer? hit;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text && span.recognizer is TapGestureRecognizer) {
        hit = span.recognizer as TapGestureRecognizer;
        return false;
      }
      return true;
    });
    if (hit != null) return hit!.onTap!();
  }
  throw StateError('no link "$text"');
}

/// A keyboard's place at the bottom, for the editor shots (a grey board with keys).
class _FakeKeyboard extends StatelessWidget {
  const _FakeKeyboard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.viewInsetsOf(context).bottom;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final key = dark ? const Color(0xFF6B6B6B) : Colors.white;
    return Stack(
      children: [
        child,
        if (h > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: h,
            child: ColoredBox(
              color: dark ? const Color(0xFF2B2B2B) : const Color(0xFFD1D3D9),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 40),
                child: Column(
                  children: [
                    for (final n in [10, 9, 9, 5])
                      Expanded(
                        child: Row(
                          children: [
                            for (var i = 0; i < n; i++)
                              Expanded(
                                flex: n == 5 && i == 2 ? 5 : 1,
                                child: Container(
                                  margin: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(color: key, borderRadius: BorderRadius.circular(6)),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FakePdfPage extends StatelessWidget {
  const _FakePdfPage();

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1 / 1.414,
        child: ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(34, 40, 34, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(
                  child: Text('HỢP ĐỒNG THUÊ NHÀ',
                      style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: .5)),
                ),
                const SizedBox(height: 6),
                const Center(child: Text('Số: 18/2026/HĐTN', style: TextStyle(color: Colors.black54, fontSize: 11))),
                const SizedBox(height: 22),
                for (final w in const [1.0, .96, .9, .98, .7, 0.0, 1.0, .93, .97, .88, .6, 0.0, 1.0, .95, .91, .99, .8, .5])
                  w == 0
                      ? const SizedBox(height: 14)
                      : FractionallySizedBox(
                          widthFactor: w,
                          child: Container(height: 5, margin: const EdgeInsets.symmetric(vertical: 4), color: const Color(0x22000000)),
                        ),
              ],
            ),
          ),
        ),
      );
}
