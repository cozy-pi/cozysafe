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

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/screens/camera.dart';
import 'package:cozysafe/screens/backup_password.dart';
import 'package:cozysafe/screens/emergency_kit.dart';
import 'package:cozysafe/screens/new_vault.dart';
import 'package:cozysafe/screens/note.dart';
import 'package:cozysafe/screens/search.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/trash.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/widgets/brand.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:cozysafe/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('PREVIEW');
final _now = DateTime.now().millisecondsSinceEpoch;

ItemInfo _item(String id, String kind, String name, int sizeBytes,
        {int ago = 0, int? deleted, int? duration, List<String> tags = const []}) =>
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
  _item('n2', ItemKind.note, 'Tài khoản ngân hàng', 640, ago: _day),
  _item('n3', ItemKind.note, 'Thuốc của mẹ', 420, ago: _day * 3, tags: ['t5']),
  _item('n4', ItemKind.note, 'Hộ chiếu và visa', 260, ago: _day * 9, tags: ['t1', 't2', 't3']),
  _item('n5', ItemKind.note, 'Mật khẩu router và camera an ninh', 300, ago: _day * 15, tags: ['t7', 't6']),
  _item('n6', ItemKind.note, 'Danh sách quà Tết', 90, ago: _day * 30, tags: ['t4']),
  _item('n7', ItemKind.note, 'Mã két sắt', 40, ago: _day * 60, tags: ['t7', 't6']),
  _item('n8', ItemKind.note, 'Thông tin bảo hiểm xe', 520, ago: _day * 75),
  _item('g1', ItemKind.file, 'Ho-chieu-scan.pdf', 2300000, ago: _day * 220, tags: ['t1', 't2']),
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

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    if (n.contains('MinPasswordScore')) return 3;
    if (n.contains('PasswordScore')) return 4;
    if (n.contains('HasVaults')) return true;
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
      final id = (call.namedArguments[#id] as String).replaceAll('_', '');
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
      debugCamera = false;
      CameraView.debugPreview = null;
      CameraView.debugLast = null;
      _itemsNow = null;
      VaultHomeScreen.debugReveal = false;
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
  _screen('lock-menu', 'Màn khoá · nút ⋯', lock, act: (t) => t.tap(find.byKey(const ValueKey('more-button'))));
  // The unlock animation (playVaultSpin), frozen at three moments of its 1.15 s.
  for (final (ms, what) in [(250, 'mặt khoá hiện'), (520, 'đang xoay'), (950, 'phóng to và tan')]) {
    _screen('unlock-$ms', 'Mở khoá · $ms ms · $what', lock, after: 0, act: (t) async {
      playVaultSpin(t.element(find.byType(UnlockScreen)), opening: true, onCovered: () {});
      await t.pump();
      await t.pump(Duration(milliseconds: ms));
    });
  }
  // After the unlock spin: the vault's icon in the middle, then it fades (docs/ui.md).
  for (final (ms, what) in [(900, 'nền trơn, biểu tượng két'), (1350, 'biểu tượng mờ dần'), (1800, 'dữ liệu hiện ra')]) {
    _screen('reveal-$ms', 'Vừa mở · $ms ms · $what', home, section: 'library', after: 0,
        setup: () => VaultHomeScreen.debugReveal = true, act: (t) async {
      await t.pump(Duration(milliseconds: ms - 800));
    });
  }
  _screen('library', 'Thư viện', home, section: 'library');
  _screen('add-library', 'Thư viện · bấm +', home, section: 'library', setup: () => debugCamera = true,
      change: 'MỚI: bấm + mọc cột thêm xếp dọc; 3 cách thêm ảnh/video (tô đậm) nằm sát nút nhất',
      marks: [() => find.byKey(const ValueKey('add-column'))], act: (t) => t.tap(find.byKey(const ValueKey('vault-action'))));
  _screen('add-slide', 'Thư viện · giữ + rồi vuốt lên “Chụp ảnh”', home, section: 'library', setup: () => debugCamera = true,
      change: 'MỘT TAY: đặt ngón lên +, vuốt lên tới mục cần (mục to lên, máy rung nhẹ), nhấc tay là chọn',
      marks: [() => find.byKey(const ValueKey('add-photo'))], act: (t) async {
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('vault-action'))));
    await g.moveBy(const Offset(0, -30));
    await t.pump(const Duration(milliseconds: 250));
    await g.moveTo(t.getCenter(find.byKey(const ValueKey('add-photo'))));
    await t.pump(const Duration(milliseconds: 200));
  });
  _screen('add-notes', 'Ghi chú · bấm +', home, section: 'note', setup: () => debugCamera = true,
      change: 'Cùng cột đó; ở Ghi chú thì “Ghi chú mới” nằm sát nút', marks: [() => find.byKey(const ValueKey('add-column'))], act: (t) => t.tap(find.byKey(const ValueKey('vault-action'))));
  _screen('add-files', 'Tệp · bấm +', home, section: 'file', setup: () => debugCamera = true,
      change: 'Ở Tệp thì “Thêm tệp” nằm sát nút', marks: [() => find.byKey(const ValueKey('add-column'))], act: (t) => t.tap(find.byKey(const ValueKey('vault-action'))));
  _screen('empty', 'Két trống · thêm bằng ô lớn', home, section: 'library', setup: () {
    debugCamera = true;
    _itemsNow = const [];
  });
  _screen('one-type', 'Chỉ có ghi chú · không thanh chọn mục', home, section: 'note',
      setup: () => _itemsNow = _items.where((i) => i.kind == ItemKind.note || i.kind == ItemKind.tag).toList());
  _screen('one-type-add', 'Chỉ có ghi chú · bấm +', home, section: 'note',
      change: 'Két chỉ có ghi chú vẫn thêm được mọi loại từ cột này',
      setup: () {
        debugCamera = true;
        _itemsNow = _items.where((i) => i.kind == ItemKind.note || i.kind == ItemKind.tag).toList();
      }, act: (t) => t.tap(find.byKey(const ValueKey('vault-action'))));
  _screen('note-editor', 'Sửa ghi chú', () => NoteScreen(item: _items.firstWhere((i) => i.kind == ItemKind.note)));
  _screen('note-new', 'Ghi chú mới', () => const NoteScreen());
  _screen('tag', 'Thư viện · trong nhóm "Du lịch"', home, section: 'library', act: (t) => _tapChip(t, 'Du lịch'));
  Widget camera({required bool video}) => CameraScreen(video: video, onOpenLast: (_) {});
  void still() {
    CameraView.debugPreview =
        _photos.isEmpty ? const ColoredBox(color: Colors.black) : Image.memory(_photos[3]!, fit: BoxFit.cover);
    CameraView.debugLast = (_items.firstWhere((i) => i.kind == ItemKind.photo), _photos[0] ?? _thumbnails[0]!);
  }
  _screen('camera', 'Chụp ảnh (mở từ Thư viện)', () => camera(video: false), setup: still);
  _screen('camera-video', 'Quay video', () => camera(video: true), setup: still);
  _screen('notes', 'Ghi chú', home, section: 'note',
      change: 'Nút chính là + như mọi mục (trước là cây bút)', marks: [() => find.byKey(const ValueKey('vault-action'))]);
  _screen('audio', 'Ghi âm', home, section: 'audio');
  _screen('audio-open', 'Ghi âm · chạm vào một bản ghi', home, section: 'audio',
      change: 'Chạm bản ghi là mở rộng tại chỗ: Gửi · Đổi tên · Xoá ngay dưới nó (trước bật bảng từ dưới lên)',
      marks: [() => find.byKey(const ValueKey('audio-send')), () => find.byKey(const ValueKey('audio-rename')), () => find.byKey(const ValueKey('audio-delete'))],
      act: (t) => t.tap(find.text('Cuộc họp với luật sư')));
  _screen('files', 'Tệp', home, section: 'file');
  _screen('tag-files', 'Tệp · trong nhóm "Hộ chiếu"', home, section: 'file', act: (t) => _tapChip(t, 'Hộ chiếu'));
  _screen('tag-notes', 'Ghi chú · cùng nhóm "Hộ chiếu"', home, section: 'file', act: (t) async {
    await _tapChip(t, 'Hộ chiếu');
    await t.pump();
    await t.tap(find.text('Ghi chú'));
  });
  _screen('all-tags', 'Tất cả nhóm', home, section: 'audio', act: (t) => t.tap(find.byKey(const ValueKey('all-tags'))));
  _screen('select', 'Đang chọn', home, section: 'library', act: (t) async {
    await t.longPress(find.byType(Image).at(2));
    await t.pump();
    await t.tap(find.byType(Image).at(4));
  });
  _screen('tag-sheet', 'Chọn 2 ảnh → Nhóm', home, section: 'library', act: (t) async {
    await t.longPress(find.byType(Image).at(1));
    await t.pump();
    await t.tap(find.byType(Image).at(2));
    await t.pump();
    await t.tap(find.text('Nhóm'));
  });
  _screen('message', 'Thông báo nổi', home, section: 'library', act: (t) async {
    showToast(t.element(find.byType(VaultHomeScreen)), 'Đã chuyển vào Đã xoá gần đây',
        icon: Icons.delete_outline_rounded, actionLabel: 'Hoàn tác', besideAction: true, onAction: () {});
  });
  _screen('search', 'Tìm kiếm', () => SearchScreen(items: _items, thumbnail: (id) async => _thumbnails[0]!), act: (t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await t.enterText(find.byType(TextField), 'thuoc');
  });
  _screen('settings', 'Cài đặt', () => settings(vault));
  _screen('settings-display', 'Cài đặt · Hiển thị', () => settings(vault),
      act: (t) async {
    await t.scrollUntilVisible(find.text('Hiện nội dung ghi chú'), 200, scrollable: find.byType(Scrollable).first);
    await t.pump();
  });
  _screen('trash', 'Đã xoá gần đây', () => const TrashScreen(),
      change: 'Thanh kính dưới đáy giống thanh chọn ở Thư viện; chưa chọn gì thì áp cho tất cả',
      marks: [() => find.byKey(const ValueKey('restore')), () => find.byKey(const ValueKey('delete-all'))]);
  _screen('trash-select', 'Đã xoá · chạm chọn 1 ảnh', () => const TrashScreen(),
      change: 'Chạm là chọn (dấu tick), thanh dưới thành Khôi phục · Xoá hẳn cho mục đã chọn',
      marks: [() => find.byIcon(Icons.check_circle), () => find.byKey(const ValueKey('restore')), () => find.byKey(const ValueKey('delete-all'))],
      act: (t) => t.tap(find.byType(Image).first));
  _screen('kit', 'Bộ khẩn cấp: khoá bí mật che sẵn', () => const EmergencyKitScreen(
      keyText: 'CS1-7KQ2-M9XA-4TWB-PL3D-8VNC-2HRE-6YJF', confirm: false));
  _screen('kit-shown', 'Bộ khẩn cấp: sau khi bấm Xem', () => const EmergencyKitScreen(
      keyText: 'CS1-7KQ2-M9XA-4TWB-PL3D-8VNC-2HRE-6YJF', confirm: false),
      act: (t) => t.tap(find.byKey(const ValueKey('secret-show'))));
  _screen('backup-password', 'Mật khẩu sao lưu: ô nhập che sẵn', () => const BackupPasswordScreen(libraryDir: '', change: false),
      act: (t) async {
    await t.enterText(find.byType(TextField).first, 'orange kettle whispers at dawn');
  });
  _screen('new-vault', 'Tạo két · bước 1', () => const NewVaultScreen(libraryDir: '', first: false));
  _screen('new-vault-2', 'Tạo két · bước 2', () => const NewVaultScreen(libraryDir: '', first: false), act: (t) async {
    await t.tap(find.byType(GestureDetector).at(3));
    await t.pump(const Duration(milliseconds: 400));
  });
}
