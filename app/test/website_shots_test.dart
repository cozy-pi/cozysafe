// Renders the real screens on several devices for safe.cozypi.com, in English and
// Vietnamese, light and dark. Rust is a fake holding sample items; photos come from
// test/preview_assets (free photos, not in git). Off by default:
//   flutter test test/website_shots_test.dart --update-goldens --dart-define=SHOTS=true
// Output: test/website/<device>-<screen>-<lang>-<light|dark>.png (not committed);
// website/shots.sh turns them into the site's WebP files.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PictureRecorder, ImageByteFormat;

import 'package:cozysafe/biometric.dart';
import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/screens/settings.dart';
import 'package:cozysafe/screens/unlock.dart';
import 'package:cozysafe/screens/vault_home.dart';
import 'package:cozysafe/src/rust/api/vault.dart';
import 'package:cozysafe/src/rust/frb_generated.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _enabled = bool.fromEnvironment('SHOTS');
final _now = DateTime.now().millisecondsSinceEpoch;
const _day = 86400000;

/// Window size in points and the system bars' safe areas (top, bottom).
const _devices = {
  'iphone': (Size(390, 844), 47.0, 34.0),
  'android': (Size(412, 915), 32.0, 24.0),
  'ipad': (Size(820, 1180), 24.0, 20.0),
  'mac': (Size(1200, 760), 0.0, 0.0),
};

ItemInfo _item(String id, String kind, String name, int sizeBytes,
        {int ago = 0, int? duration, List<String> tags = const []}) =>
    ItemInfo(
      id: id.padRight(32, '_'),
      kind: kind,
      name: name,
      mime: kind == ItemKind.photo ? 'image/jpeg' : (name.endsWith('.pdf') ? 'application/pdf' : 'text/plain'),
      createdMs: _now - ago,
      sizeBytes: BigInt.from(sizeBytes),
      durationMs: duration,
      tagIds: [for (final t in tags) t.padRight(32, '_')],
      isFavorite: false,
      modifiedMs: _now - ago,
    );

/// What people keep in a vault, named in each language: (en, vi).
List<ItemInfo> _items(String lang) {
  String n((String, String) p) => lang == 'vi' ? p.$2 : p.$1;
  return [
    _item('t1', ItemKind.tag, n(('ID documents', 'Giấy tờ tùy thân')), 0),
    _item('t2', ItemKind.tag, n(('Passport', 'Hộ chiếu')), 0),
    _item('t3', ItemKind.tag, n(('Travel', 'Du lịch')), 0),
    _item('t4', ItemKind.tag, n(('Family', 'Gia đình')), 0),
    _item('t5', ItemKind.tag, n(('Health', 'Sức khoẻ')), 0),
    _item('t6', ItemKind.tag, n(('Home', 'Nhà cửa')), 0),
    _item('t7', ItemKind.tag, n(('Passwords', 'Mật khẩu')), 0),
    _item('t8', ItemKind.tag, n(('Work', 'Công việc')), 0),
    for (var i = 0; i < 5; i++)
      _item('p$i', ItemKind.photo, 'IMG_${4810 + i}.HEIC', 2400000 + i * 90000, ago: i * 600000,
          tags: i == 2 ? ['t1', 't2'] : (i < 2 ? ['t4'] : [])),
    _item('v1', ItemKind.video, n(('Birthday party.MOV', 'Sinh nhật bé Na.MOV')), 38400000, ago: 3600000, duration: 42000, tags: ['t4']),
    for (var i = 5; i < 9; i++) _item('p$i', ItemKind.photo, 'IMG_${4790 + i}.HEIC', 2100000, ago: _day + i * 300000),
    _item('v2', ItemKind.video, n(('Beach trip.MOV', 'Đi biển Quy Nhơn.MOV')), 126000000, ago: _day * 2, duration: 197000, tags: ['t3', 't4']),
    for (var i = 9; i < 16; i++)
      _item('p$i', ItemKind.photo, 'IMG_${4700 + i}.HEIC', 1900000, ago: _day * (20 + i), tags: i < 13 ? ['t3'] : []),
    _item('a1', ItemKind.audio, n(('Meeting with the lawyer.m4a', 'Cuộc họp với luật sư.m4a')), 6100000, ago: 7200000, duration: 768000, tags: ['t8']),
    _item('a2', ItemKind.audio, n(('Doctor on Mum\'s medicine.m4a', 'Bác sĩ dặn về thuốc của mẹ.m4a')), 1500000, ago: _day, duration: 185000, tags: ['t5']),
    _item('a3', ItemKind.audio, n(('House deposit agreement.m4a', 'Thoả thuận đặt cọc nhà.m4a')), 11600000, ago: _day * 8, duration: 1450000, tags: ['t6']),
    _item('a4', ItemKind.audio, n(('Ideas for the garden.m4a', 'Ý tưởng làm vườn.m4a')), 900000, ago: _day * 19, duration: 96000),
    _item('n1', ItemKind.note, n(('Wi-Fi at Grandma\'s', 'Wifi nhà bà ngoại')), 120, tags: ['t7']),
    _item('n2', ItemKind.note, n(('Bank accounts', 'Tài khoản ngân hàng')), 640, ago: _day),
    _item('n3', ItemKind.note, n(('Mum\'s medicine', 'Thuốc của mẹ')), 420, ago: _day * 3, tags: ['t5']),
    _item('n4', ItemKind.note, n(('Passport and visa', 'Hộ chiếu và visa')), 260, ago: _day * 9, tags: ['t1', 't2', 't3']),
    _item('n5', ItemKind.note, n(('Router and security camera', 'Mật khẩu router và camera an ninh')), 300, ago: _day * 15, tags: ['t7', 't6']),
    _item('n6', ItemKind.note, n(('Holiday gift list', 'Danh sách quà Tết')), 90, ago: _day * 30, tags: ['t4']),
    _item('n7', ItemKind.note, n(('Safe combination', 'Mã két sắt')), 40, ago: _day * 60, tags: ['t7', 't6']),
    _item('n8', ItemKind.note, n(('Car insurance', 'Thông tin bảo hiểm xe')), 520, ago: _day * 75),
    _item('n9', ItemKind.note, n(('Recovery codes', 'Mã khôi phục tài khoản')), 210, ago: _day * 90, tags: ['t7']),
    _item('g1', ItemKind.file, n(('Passport-scan.pdf', 'Ho-chieu-scan.pdf')), 2300000, ago: _day * 220, tags: ['t1', 't2']),
    _item('g2', ItemKind.file, n(('Birth-certificate.pdf', 'Giay-khai-sinh-Na.pdf')), 640000, ago: _day * 290, tags: ['t1', 't4']),
    _item('g3', ItemKind.file, n(('Driving-licence.pdf', 'Bang-lai-xe.pdf')), 1100000, ago: _day * 72, tags: ['t1']),
    _item('f1', ItemKind.file, n(('Lease-2026.pdf', 'Hop-dong-thue-nha-2026.pdf')), 1240000, tags: ['t6']),
    _item('f2', ItemKind.file, n(('House-deed-scan.pdf', 'So-do-nha-scan.pdf')), 4870000, ago: _day * 2, tags: ['t6']),
    _item('f3', ItemKind.file, n(('Family budget 2026.xlsx', 'Chi tieu gia dinh 2026.xlsx')), 86000, ago: _day * 4, tags: ['t4']),
    _item('f4', ItemKind.file, n(('Blood test results - September.pdf', 'Ket qua xet nghiem mau thang 9.pdf')), 732000, ago: _day * 11, tags: ['t5']),
    _item('f5', ItemKind.file, n(('Will-draft.docx', 'Di-chuc-nhap.docx')), 42000, ago: _day * 20),
    _item('f6', ItemKind.file, n(('ID-card-front.jpg', 'CCCD-mat-truoc.jpg')), 1840000, ago: _day * 33, tags: ['t1']),
    _item('f7', ItemKind.file, n(('Job-application.zip', 'Ho-so-xin-viec.zip')), 15600000, ago: _day * 50, tags: ['t8']),
  ];
}

String _lang = 'en';
final Map<int, Uint8List> _photos = {};
final _thumbnails = <int, Uint8List>{};

class _Fake implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation call) {
    final n = call.memberName.toString();
    final items = _items(_lang);
    final media = items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
    if (n.contains('MinPasswordScore')) return 3;
    if (n.contains('PasswordScore')) return 4;
    if (n.contains('HasVaults')) return true;
    if (n.contains('ListItems')) return Future<List<ItemInfo>>.value(items);
    if (n.contains('ListTrash')) return Future<List<ItemInfo>>.value(const []);
    if (n.contains('PurgeExpired')) return Future<int>.value(0);
    if (n.contains('ItemContent')) {
      final id = call.namedArguments[#id] as String;
      final m = media.indexWhere((x) => x.id == id);
      if (m >= 0) return Future<Uint8List>.value(_photos[m % _photos.length] ?? _thumbnails[0]);
      return Future<Uint8List>.value(Uint8List.fromList(utf8.encode('')));
    }
    if (n.contains('ItemThumbnail')) {
      final id = call.namedArguments[#id] as String;
      final m = media.indexWhere((x) => x.id == id);
      if (m < 0) return Future<Uint8List>.value(Uint8List(0));
      return Future<Uint8List>.value(_photos[m % _photos.length] ?? _thumbnails[0]);
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
}

void main() {
  setUpAll(() async {
    RustLib.initMock(api: _Fake());
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: 'Cozy Safe', packageName: 'com.cozypi.cozysafe', version: '0.1.14', buildNumber: '1200', buildSignature: '');
    debugOwnerConfirmed = true;
    await _loadFonts();
    const colors = [Color(0xFF7FA79A), Color(0xFFD9A07A)];
    for (var i = 0; i < colors.length; i++) {
      final rec = PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = colors[i]);
      final img = await rec.endRecording().toImage(32, 32);
      _thumbnails[i] = (await img.toByteData(format: ImageByteFormat.png))!.buffer.asUint8List();
    }
    final dir = Directory('test/preview_assets');
    if (dir.existsSync()) {
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final (i, f) in files.indexed) {
        _photos[i] = f.readAsBytesSync();
      }
    }
  });

  const vault = VaultInfo(id: 'v', name: '', icon: 'home', color: 'green', hasPassword: true);
  Widget home() => const VaultHomeScreen(libraryDir: '', vault: vault);
  Widget lock() => const UnlockScreen(libraryDir: '', askBiometricNow: false);
  Widget settings() => SettingsScreen(
        libraryDir: '',
        vault: () => vault,
        canBiometric: true,
        biometricOn: () => true,
        onToggleBiometric: () async {},
        onPassword: () async {},
        onShowKit: () async {},
        onBackup: () async {},
        lastBackup: () => _lang == 'vi' ? 'Lần cuối: hôm qua' : 'Last backup: yesterday',
        onChangeIdentity: () async {},
        onOpenTrash: () async {},
        onNewVault: () async {},
      );

  final screens = <String, (Widget Function(), String?, Future<void> Function(WidgetTester)?)>{
    'lock': (lock, null, null),
    'library': (home, 'library', null),
    'notes': (home, 'note', null),
    'voice': (home, 'audio', null),
    'files': (home, 'file', null),
    'group': (home, 'library', (t) async {
      final row = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.right).first;
      final label = _lang == 'vi' ? 'Du lịch' : 'Travel';
      await t.scrollUntilVisible(find.text(label), 120, scrollable: row);
      await t.pump();
      await t.tap(find.text(label).first);
    }),
    'settings': (settings, null, null),
  };

  for (final MapEntry(key: device, value: (size, top, bottom)) in _devices.entries) {
    for (final MapEntry(key: name, value: (screen, section, act)) in screens.entries) {
      for (final lang in ['en', 'vi']) {
        for (final b in [Brightness.light, Brightness.dark]) {
          testWidgets('$device $name $lang ${b.name}', skip: !_enabled, (t) async {
            _lang = lang;
            Prefs.dir = Directory.systemTemp.createTempSync('prefs').path;
            if (section != null) Prefs.write('vault-section', section);
            Prefs.write('add-column-hint', '3');
            VaultHomeScreen.debugReveal = false;
            debugVoice = device != 'mac'; // voice memos: phones and tablets only
            BiometricUnlock.debugKind = device == 'android' ? BiometricKind.fingerprint : BiometricKind.face;
            debugDisableShadows = false;
            try {
              t.view.physicalSize = size * 2;
              t.view.devicePixelRatio = 2;
              t.view.padding = FakeViewPadding(top: top * 2, bottom: bottom * 2);
              t.view.viewPadding = FakeViewPadding(top: top * 2, bottom: bottom * 2);
              addTearDown(t.view.reset);
              await t.pumpWidget(MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: Locale(lang),
                theme: buildTheme(b),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: screen(),
              ));
              for (var i = 0; i < 8; i++) {
                await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
                await t.pump(const Duration(milliseconds: 100));
              }
              if (act != null) {
                await act(t);
                for (var i = 0; i < 6; i++) {
                  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
                  await t.pump(const Duration(milliseconds: 100));
                }
              }
              await expectLater(find.byType(MaterialApp), matchesGoldenFile('website/$device-$name-$lang-${b.name}.png'));
              await t.pump(const Duration(seconds: 2));
            } finally {
              debugDisableShadows = true;
            }
          });
        }
      }
    }
  }
}
