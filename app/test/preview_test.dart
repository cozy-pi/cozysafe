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

import 'package:cozysafe/links.dart';
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
import 'package:cozysafe/screens/file_view.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/search.dart';
import 'package:cozysafe/screens/security_info.dart';
import 'package:cozysafe/screens/settings.dart';
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
import 'package:cozysafe/sync/drive_join.dart';
import 'package:cozysafe/sync/find_page.dart';
import 'package:cozysafe/sync/host_page.dart';
import 'package:cozysafe/sync/join_page.dart';
import 'package:cozysafe/sync/progress.dart';
import 'package:cozysafe/sync/qr_view.dart';
import 'package:cozysafe/sync/sync_screen.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/privacy.dart';
import 'package:cozysafe/screens/overview.dart';
import 'package:cozysafe/screens/recorder.dart';
import 'package:cozysafe/widgets/brand.dart';
import 'package:cozysafe/widgets/identity.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:cozysafe/widgets/toast.dart';
import 'package:cozysafe/widgets/countdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('PREVIEW');
final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, int sizeBytes,
        {int ago = 0, int? deleted, int? duration, List<String> tags = const [], bool fav = false}) =>
    ItemInfo(
      id: id.padRight(32, '_'),
      kind: kind,
      name: name,
      mime: kind == ItemKind.photo ? 'image/jpeg' : (name.endsWith('.pdf') ? 'application/pdf' : 'text/plain'),
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

const _noteText = {
  'j1': '{"router":{"ssid":"TP-Link_5G_BaNgoai","password":"hoaMai2024@","channel":36},"camera":{"app":"EZVIZ","device":"F7K2Q9","admin":true}}',
  'm1': '# Gia hạn hộ chiếu\n\nMang theo **bản gốc** và nộp ở *Phòng Quản lý xuất nhập cảnh*.\n\n## Giấy tờ\n\n- Hộ chiếu cũ\n- Căn cước công dân\n- 2 ảnh 4x6 nền trắng\n- Tờ khai `TK01` điền sẵn\n\n## Lệ phí\n\n1. Nộp 200.000 đ tại quầy\n2. Giữ biên lai để nhận hộ chiếu\n\n> Hẹn lấy sau 8 ngày làm việc.\n\n```\nSĐT tổng đài: 1900 1234\nMã hồ sơ: HC-2026-55821\n```',
  'tx1': 'Wifi nhà ngoại đổi mật khẩu ngày 12/10.\n\nMạng 5G: TP-Link_5G_BaNgoai\nMật khẩu mới: hoaMai2024@\n\nNếu camera cổng mất kết nối thì rút điện 10 giây rồi cắm lại, đợi đèn xanh.',
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
final _thumbnails = <int, Uint8List>{};

/// A real pairing code (192.168.1.37:51234) and its QR, from the Rust encoder.
const _qrTyped = '60N00J-BJ120X-DWG3A2';
const _qrText = 'cozysafe:p2p:1:60N00JBJ120XDWG3A2';
const _qrBits = '1111111000011001111010111111110000010000000000110001000001101110101000101010110010111011011101011100000111000101110110111010100101110000101011101100000101010111110100010000011111111010101010101010111111100000000110111010001000000000101111100111001101110011111001110110001011001100010101010110001010010010000110011011000001001011100001010100110110110110111110010000011011010111100101100100011110001001110001100000110001011100100100011000000110101001100001000001100110101011010100111000110100101101100000011100001010010100111000111011010001101001101100010110100110100110011111011001101001100111100100011111101100000000010000111101010001101111111110001111111000101010100100000101011110000111000110001011101011101011100011111011010111010111011000000010101011101110101010001111000011110101000001000100100100110000001011111110110110010000011001100';

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('MinPasswordScore')) return 3;
    if (n.contains('MinPasswordLength')) return 8;
    if (n.contains('MinPinLength')) return 6;
    if (n.contains('PasswordScore')) return (call.namedArguments[#password] as String).length < 12 ? 1 : 4;
    if (n.contains('HasVaults')) return true;
    if (n.contains('QrMatrix')) return QrMatrix(size: 29, dark: [for (final c in _qrBits.split('')) c == '1']);
    if (n.contains('P2PCodeAddress')) return '192.168.1.37';
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(_itemsNow ?? _items);
    if (n.contains('ListTrash')) {
      return Future<List<ItemInfo>>.value([
        _item('t1', 'photo', 'a.jpg', 900000, deleted: _now - 86400000),
        _item('t2', 'photo', 'b.jpg', 900000, deleted: _now - 18 * 86400000),
        _item('t3', 'file', 'Bao-gia-sua-nha.pdf', 300000, deleted: _now - 27 * 86400000),
      ]);
    }
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('ItemContent')) {
      final full = call.namedArguments[#id] as String;
      final media = _items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
      final m = media.indexWhere((x) => x.id == full);
      if (m >= 0) return Future<Uint8List>.value(_photos[m % _photos.length] ?? _thumbnails[0]);
      final id = full.replaceAll('_', '');
      return Future<Uint8List>.value(Uint8List.fromList(utf8.encode(_noteText[id] ?? '')));
    }
    if (n.contains('ItemThumbnail')) {
      final id = call.namedArguments[#id] as String;
      final bare = id.replaceAll('_', '');
      if (bare == 't1' || bare == 't2') return Future<Uint8List>.value(_photos[bare == 't1' ? 5 : 7] ?? _thumbnails[1]);
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
  final roboto = FontLoader('Roboto');
  for (final f in dir.listSync().whereType<File>()) {
    final n = f.uri.pathSegments.last;
    if (n.startsWith('Roboto-') && n.endsWith('.ttf')) roboto.addFont(bytes(f));
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

Future<List<List<double>>> _shot(WidgetTester t, String file, Widget home, {Brightness b = Brightness.light,
    Future<void> Function(WidgetTester)? act, int after = 6, List<Finder Function()> marks = const []}) async {
  t.view.physicalSize = const Size(430, 932) * 2; // iPhone 15 Pro Max, the owner's phone
  t.view.devicePixelRatio = 2;
  // The phone's safe areas (status bar with the Dynamic Island, home indicator), so
  // content sits where it does on the device; the mockup page draws the frame on top.
  t.view.padding = const FakeViewPadding(top: 59 * 2, bottom: 34 * 2);
  t.view.viewPadding = const FakeViewPadding(top: 59 * 2, bottom: 34 * 2);
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
void _screen(String name, String caption, Widget Function() home,
    {String? section, Future<void> Function(WidgetTester)? act, int after = 6, void Function()? setup,
    String? change, List<Finder Function()> marks = const []}) {
  final entry = <String, Object>{'name': name, 'caption': caption, 'change': ?change};
  _manifest.add(entry);
  for (final b in [Brightness.dark, Brightness.light]) {
    testWidgets('$name ${b.name}', skip: !_enabled, (t) async {
      Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
      if (section != null) Prefs.write('vault-section', section);
      Prefs.write('add-column-hint', '3'); // the drag hint has been seen; no mid-nudge shots
      debugCamera = false;
      CameraView.debugPreview = null;
      CameraView.debugLast = null;
      QuickLook.debugVideo = null;
      NewVaultScreen.debugWords = null;
      DebugScreen.debugNetworkBlocked = null;
      _itemsNow = null;
      SyncScreen.debugLog = null;
      SyncScreen.debugAddress = null;
      SyncScreen.debugDrive = false;
      SyncProgress.debugRate = null;
      SecondPlaceNudge.debugShow = false;
      debugHoldToasts = true;
      VaultManagerScreen.debugSlots = null;
      NewVaultScreen.debugBiometricStep = false;
      RestoreSourceScreen.debugDrive = false;
      DriveJoinScreen.debugAccount = null;
      HostSyncPage.debugHosting = null;
      HostSyncPage.debugEvents = null;
      FindDevicePage.debugFound = null;
      ChangeKeyScreen.debugWords = null;
      ChangeKeyScreen.debugStep = null;
      ScanCodePage.debugPreview = null;
      VaultHomeScreen.debugReveal = false;
      debugRecordingStill = false;
      setup?.call();
      // Real shadows: tests otherwise draw every elevation as a solid black outline.
      debugDisableShadows = false;
      try {
        final rects = await _shot(t, '$name-${b.name}', home(), b: b, act: act, after: after, marks: marks);
        if (rects.isNotEmpty) entry['marks'] = rects;
        await t.pump(const Duration(seconds: 2)); // let an animation started by `act` end
      } finally {
        debugDisableShadows = true;
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
    await g.moveTo(t.getCenter(find.byKey(const ValueKey('add-photo')).first));
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
  _screen('home', 'Trang chủ (Tổng quan)', home, section: 'home');
  _screen('home-nudge', 'Trang chủ: két chỉ ở máy này', home, section: 'home',
      setup: () => SecondPlaceNudge.debugShow = true);
  _screen('shot-blocked', 'Vừa chụp màn hình · đang chặn', home, section: 'library', act: (t) async {
    PrivacyCover.onScreenshot?.call();
    await t.pumpAndSettle();
  }, change: 'Thông báo chụp màn hình cũng hiện ở trên');
  _screen('shot-saved', 'Vừa chụp màn hình · không chặn', home, section: 'library', setup: () => Prefs.write('block-screenshots', '0'),
      act: (t) async {
    PrivacyCover.onScreenshot?.call();
    await t.pumpAndSettle();
  });
  _screen('home-recording', 'Trang chủ · chạm một bản ghi âm', home, section: 'home',
      setup: () {
        debugRecordingStill = true;
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
  }, change: 'Đủ 6 nút trên một hàng, không còn nút bị giấu bên phải');
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
    await t.tap(find.byType(Image).at(n));
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
  _screen('audio', 'Ghi âm', home, section: 'audio');
  _screen('audio-select', 'Ghi âm · bấm giữ một bản ghi', home, section: 'audio',
      act: (t) async {
    await t.longPress(find.text('Cuộc họp với luật sư'));
    await t.pumpAndSettle();
  });
  _screen('audio-open', 'Ghi âm · chạm vào một bản ghi', home, section: 'audio',
      act: (t) => t.tap(find.text('Cuộc họp với luật sư')));
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
    await t.tap(find.byType(Image).at(2));
    await t.pump();
    await t.tap(find.byType(Image).at(4));
  });
  _screen('photo-menu', 'Thư viện · bấm giữ một ảnh', home, section: 'library', act: (t) async {
    await t.longPress(find.byType(Image).at(2));
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
    await t.tap(find.byType(Image).at(1));
    await t.pump();
    await t.tap(find.byType(Image).at(2));
    await t.pump();
    await t.tap(find.text('Nhóm'));
  });
  _screen('message', 'Thông báo nổi', home, section: 'library', act: (t) async {
    showToast(t.element(find.byType(VaultHomeScreen)), 'Đã chuyển vào Đã xoá gần đây',
        icon: Icons.delete_outline_rounded, actionLabel: 'Hoàn tác', besideAction: true, onAction: () {});
  }, change: 'MỚI: thông báo hiện ở TRÊN CÙNG, trượt xuống, vuốt lên để tắt (trước nằm dưới, đè lên thanh menu)');
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
  _screen('settings', 'Cài đặt', () => settings(vault));
  _screen('settings-backup', 'Cài đặt · Sao lưu và Bảo mật', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.byKey(const ValueKey('kit-row')), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 200));
    await t.pumpAndSettle();
  });
  Widget page(String title, Widget body) => Scaffold(appBar: AppBar(title: Text(title)), body: SafeArea(top: false, child: body));
  final syncLog = [
    '${_now - 3600000}|join|192.168.1.21|ok|12|3',
    '${_now - 86400000}|host|-|ok|0|5',
    '${_now - 2 * 86400000}|host|-|expired|0|0',
  ];
  _screen('sync', 'Đồng bộ: hiện mã / quét mã / nhập mã, và các lần kết nối gần đây', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugDrive = true;
  });
  _screen('sync-allow', 'Đồng bộ · bấm Hiện mã → hỏi cho phép, ghi rõ địa chỉ', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugAddress = '192.168.1.37';
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-show')));
    await t.pumpAndSettle();
  });
  _screen('sync-host', 'Máy này hiện mã 6 số (QR khi cần), mã dùng được 5 phút, một lần', () => page('Hiện mã', HostSyncPage(address: '192.168.1.37', mirror: '', onSynced: () {})),
      setup: () => HostSyncPage.debugHosting = Hosting(typed: _qrTyped, qr: _qrText, digits: '482913', findable: true, seconds: 107));
  _screen('sync-scan', 'Máy kia: quét mã bằng camera (hoặc nhập mã)', () => page('Quét mã', ScanCodePage(onSynced: () {})),
      setup: () => ScanCodePage.debugPreview = const ColoredBox(color: Color(0xFF2A2F36), child: Center(child: QrView(text: _qrText, size: 170))));
  _screen('sync-host-qr', 'Máy này hiện mã: đã bấm Hiện mã QR', () => page('Hiện mã', HostSyncPage(address: '192.168.1.37', mirror: '', onSynced: () {})),
      setup: () => HostSyncPage.debugHosting = Hosting(typed: _qrTyped, qr: _qrText, digits: '482913', findable: true, seconds: 241),
      act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-show-qr')));
    await t.pump(const Duration(milliseconds: 300));
  });
  _screen('sync-find-allow', 'Máy kia · bấm Nhập mã → hỏi cho phép tìm trên Wi‑Fi', () => page('Đồng bộ', SyncScreen(libraryDir: '', onSynced: () {})),
      setup: () {
    SyncScreen.debugLog = syncLog;
    SyncScreen.debugAddress = '192.168.1.52';
  }, act: (t) async {
    await t.tap(find.byKey(const ValueKey('sync-enter')));
    await t.pumpAndSettle();
  });
  _screen('sync-find', 'Máy kia: đã thấy máy của bạn, nhập 6 số', () => page('Nhập mã', FindDevicePage(address: '192.168.1.52', onFound: (a, b) async {}, onScanned: (a, b) async {})),
      setup: () => FindDevicePage.debugFound = 1);
  _screen('sync-find-typing', 'Máy kia: đang nhập mã', () => page('Nhập mã', FindDevicePage(address: '192.168.1.52', onFound: (a, b) async {}, onScanned: (a, b) async {})),
      setup: () => FindDevicePage.debugFound = 1,
      act: (t) async {
    await t.enterText(find.byKey(const ValueKey('sync-digits-field')), '4829');
    await t.pump();
  });
  _screen('sync-find-none', 'Máy kia: chưa thấy máy nào', () => page('Nhập mã', FindDevicePage(address: '192.168.1.52', onFound: (a, b) async {}, onScanned: (a, b) async {})),
      setup: () => FindDevicePage.debugFound = 0);
  SyncEvent ev(SyncStep k, {int check = 0, int received = 0, int sent = 0, int copies = 0, int done = 0, int total = 0, int bytes = 0, int bytesTotal = 0}) =>
      SyncEvent(kind: k, check: check, received: received, sent: sent, removed: 0, copies: copies, done: done, total: total, bytes: BigInt.from(bytes), bytesTotal: BigInt.from(bytesTotal));
  _screen('sync-drive-progress', 'Google Drive: đang gửi lên', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.sending, done: 128, total: 340, bytes: 52 << 20, bytesTotal: 131 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (2.4 * (1 << 20), 6));
  _screen('sync-drive-receiving', 'Google Drive: đang tải về', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.receiving, done: 40, total: 212, bytes: 18 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (3.1 * (1 << 20), 7));
  _screen('sync-drive-removing', 'Google Drive: xoá các mục đã xoá', () => page('Đồng bộ với Google Drive', SyncProgress(place: SyncPlace.drive, events: Stream.value(ev(SyncStep.removing, done: 312, total: 700)), onSynced: () {})));
  _screen('sync-device-progress', 'Máy gần đây: đang nhận', () => page('Đồng bộ với máy gần đây', SyncProgress(events: Stream.value(ev(SyncStep.receiving, done: 64, total: 90, bytes: 210 << 20)), onSynced: () {})),
      setup: () => SyncProgress.debugRate = (9.8 * (1 << 20), 3));
  _screen('sync-interrupted', 'Bị gián đoạn (máy ngủ, mất mạng): bấm Tiếp tục', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.interrupted)), onSynced: () {}, retry: () => const Stream.empty())));
  _screen('sync-connected', 'Đã kết nối: hai máy hiện cùng một số để đối chiếu', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.connected, check: 4821)), onSynced: () {})));
  _screen('sync-done', 'Xong', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.done, received: 12, sent: 3, copies: 1)), onSynced: () {})));
  _screen('sync-knock', 'Máy hiện mã: máy kia vừa chạm tới, đang chứng minh cùng két', () => page('Hiện mã', HostSyncPage(address: '192.168.1.37', mirror: '', onSynced: () {})),
      setup: () {
    HostSyncPage.debugHosting = Hosting(typed: _qrTyped, qr: _qrText, digits: '482913', findable: true, seconds: 74);
    HostSyncPage.debugEvents = Stream.value(ev(SyncStep.knock));
  });
  _screen('sync-other-vault', 'Máy kia có két khác', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.otherVault)), onSynced: () {})));
  _screen('sync-unreachable', 'Không tới được máy kia', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.unreachable)), onSynced: () {})));
  _screen('sync-rejected', 'Máy hiện mã: một máy két khác vừa thử vào', () => page('Hiện mã', HostSyncPage(address: '192.168.1.37', mirror: '', onSynced: () {})),
      setup: () {
    HostSyncPage.debugHosting = Hosting(typed: _qrTyped, qr: _qrText, digits: '482913', findable: true, seconds: 74);
    HostSyncPage.debugEvents = Stream.value(ev(SyncStep.rejected));
  });
  _screen('sync-signin', 'Google Drive: phiên đăng nhập hết hạn', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.signIn)), onSynced: () {})));
  _screen('sync-failed', 'Không kết nối được', () => page('Đồng bộ', SyncProgress(events: Stream.value(ev(SyncStep.failed)), onSynced: () {})));
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
  _screen('debug', 'Trang gỡ lỗi', () => const DebugScreen(), setup: () => DebugScreen.debugNetworkBlocked = true);
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
  _screen('trash', 'Đã xoá gần đây', () => const TrashScreen());
  _screen('trash-select', 'Đã xoá · bấm Chọn rồi chạm 1 ảnh', () => const TrashScreen(),
      act: (t) async {
        await t.tap(find.byKey(const ValueKey('trash-select')));
        await t.pump();
        await t.tap(find.byType(Image).first);
        await t.pump();
      });
  _screen('trash-preview', 'Đã xoá · chạm 1 ảnh', () => const TrashScreen(),
      act: (t) async {
        await t.tap(find.byType(Image).first);
        for (var i = 0; i < 6; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await t.pump(const Duration(milliseconds: 100));
        }
      });
  _screen('trash-menu', 'Đã xoá · bấm giữ 1 ảnh', () => const TrashScreen(),
      act: (t) async {
        await t.longPress(find.byType(Image).first);
        await t.pumpAndSettle();
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
  }, change: 'MỚI: đếm ngược 10 giây, chỉ nút Huỷ dừng được');
  _screen('vault-manager', 'Debug · Két trên máy này', () => const VaultManagerScreen(libraryDir: ''),
      setup: () => VaultManagerScreen.debugSlots = [
            VaultSlot(id: 'e0a966aed6bec8151ebb59139e5aa773', sizeBytes: BigInt.from(1843 << 20), hasPassword: true, hasPin: true, hasBiometric: true, isOpen: true),
            VaultSlot(id: '3fa9c1d2e4b5a6978877665544332211', sizeBytes: BigInt.from(37 << 20), hasPassword: true, hasPin: true, hasBiometric: false, isOpen: false),
            VaultSlot(id: '9b3ad0e1f2c4475a8e61d39b2f0c18d3', sizeBytes: BigInt.from(212 << 10), hasPassword: false, hasPin: true, hasBiometric: false, isOpen: false),
          ],
      change: 'Nút xoá màu đỏ; sau khi gõ XOÁ còn 10 giây đếm ngược để Huỷ');
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
}

void _leftCamera() {
  debugCamera = true;
  Prefs.write('action-side', 'left');
}
