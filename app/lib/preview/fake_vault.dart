// A pretend vault for trying the interface in a browser (lib/preview_main.dart):
// realistic sample content, no encryption, nothing saved. Not used by the app itself.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show PlatformInt64;

import '../platform.dart';
import '../src/rust/api/vault.dart';
import '../src/rust/frb_generated.dart';

const previewPin = '1234';
const _day = 86400000;

class FakeVault implements RustLibApi {
  FakeVault(this.photos) {
    final now = DateTime.now().millisecondsSinceEpoch;
    ItemInfo it(String id, String kind, String name, int size,
            {int ago = 0, int? duration, String? folder, String? color, String? space, String mime = ''}) =>
        ItemInfo(
          id: id,
          kind: kind,
          name: name,
          mime: mime.isNotEmpty
              ? mime
              : kind == 'photo'
                  ? 'image/jpeg'
                  : kind == 'video'
                      ? 'video/quicktime'
                      : name.endsWith('.pdf')
                          ? 'application/pdf'
                          : 'application/octet-stream',
          createdMs: i64(now - ago),
          size: BigInt.from(size),
          deletedMs: null,
          durationMs: duration == null ? null : i64(duration),
          folder: folder,
          color: color,
          space: space,
        );
    _items.addAll([
      for (var i = 0; i < 5; i++) it('p$i', 'photo', 'IMG_${4810 + i}.HEIC', 2400000, ago: i * 600000),
      it('v1', 'video', 'Sinh nhật bé Na.MOV', 38400000, ago: 3600000, duration: 42000),
      for (var i = 5; i < 9; i++) it('p$i', 'photo', 'IMG_${4790 + i}.HEIC', 2100000, ago: _day + i * 300000),
      it('v2', 'video', 'Đi biển Quy Nhơn.MOV', 126000000, ago: _day * 2, duration: 197000),
      for (var i = 9; i < 16; i++)
        it('p$i', 'photo', 'IMG_${4700 + i}.HEIC', 1900000, ago: _day * (20 + i), folder: i < 13 ? 'b3' : null),
      it('b1', 'folder', 'Giấy tờ', 0, color: 'amber', space: 'library'),
      it('b2', 'folder', 'Gia đình', 0, color: 'blue', space: 'library'),
      it('b3', 'folder', 'Du lịch', 0, color: 'leaf', space: 'library'),
      it('c1', 'folder', 'Mật khẩu', 0, color: 'amber', space: 'note'),
      it('c2', 'folder', 'Sức khoẻ', 0, color: 'red', space: 'note'),
      it('e1', 'folder', 'Cuộc họp', 0, color: 'violet', space: 'audio'),
      it('a1', 'audio', 'Cuộc họp với luật sư.m4a', 6100000, ago: 7200000, duration: 768000, mime: 'audio/mp4'),
      it('a2', 'audio', 'Bác sĩ dặn về thuốc của mẹ.m4a', 1500000, ago: _day, duration: 185000, mime: 'audio/mp4'),
      it('a3', 'audio', 'Thoả thuận đặt cọc nhà.m4a', 11600000, ago: _day * 8, duration: 1450000, mime: 'audio/mp4'),
      it('n1', 'note', 'Wifi nhà bà ngoại', 120),
      it('n2', 'note', 'Tài khoản ngân hàng', 640, ago: _day),
      it('n3', 'note', 'Thuốc của mẹ', 420, ago: _day * 3),
      it('n4', 'note', 'Hộ chiếu và visa', 260, ago: _day * 9, folder: 'd1'),
      it('n5', 'note', 'Mật khẩu router và camera an ninh', 300, ago: _day * 15, folder: 'c1'),
      it('n6', 'note', 'Danh sách quà Tết', 90, ago: _day * 30),
      it('d1', 'folder', 'Giấy tờ tùy thân', 0, color: 'amber'),
      it('d2', 'folder', 'Nhà cửa', 0, color: 'blue'),
      it('d3', 'folder', 'Sức khoẻ', 0, color: 'red'),
      it('d4', 'folder', 'Công việc', 0, color: 'violet'),
      it('d6', 'folder', 'Hộ chiếu', 0, color: 'teal', folder: 'd1'),
      it('g1', 'file', 'Ho-chieu-scan.pdf', 2300000, ago: _day * 220, folder: 'd1'),
      it('g2', 'file', 'Giay-khai-sinh-Na.pdf', 640000, ago: _day * 290, folder: 'd1'),
      it('g3', 'file', 'So-do-nha-scan.pdf', 4870000, ago: _day * 2, folder: 'd2'),
      it('f1', 'file', 'Hop-dong-thue-nha-2026.pdf', 1240000),
      it('f3', 'file', 'Chi tieu gia dinh 2026.xlsx', 86000, ago: _day * 4),
      it('f4', 'file', 'Ket qua xet nghiem mau thang 9 - Benh vien Bach Mai.pdf', 732000, ago: _day * 11, folder: 'd3'),
      it('f5', 'file', 'Di-chuc-nhap.docx', 42000, ago: _day * 20),
      it('f7', 'file', 'Ho-so-xin-viec.zip', 15600000, ago: _day * 50, folder: 'd4'),
    ]);
  }

  final List<Uint8List> photos;
  final List<ItemInfo> _items = [];
  var _vault = const VaultInfo(id: 'preview', name: '', icon: 'home', color: 'green', hasPassword: false);
  bool _open = false;
  int _next = 100;

  final Map<String, String> _text = {
    'n1': 'Wifi nhà bà ngoại\nTên mạng: TP-Link_5G_BaNgoai\nMật khẩu: hoaMai2024@',
    'n2': 'Tài khoản ngân hàng\nVietcombank 0011 0023 4567 — Nguyễn Văn A, chi nhánh Hoàn Kiếm.\nTechcombank 1903 2211 4455 66 — tài khoản phụ, chỉ nhận lương.',
    'n3': 'Thuốc của mẹ\nSáng: Amlodipine 5mg sau ăn.\nTối: Metformin 500mg sau ăn.\nTái khám ngày 3/11.',
    'n4': 'Hộ chiếu và visa\nHộ chiếu C1234567, hết hạn 12/3/2031.\nVisa Nhật Bản nhiều lần, hết hạn 5/2027.',
    'n5': 'Mật khẩu router và camera an ninh\nRouter: admin / Zx9!kq2Lm\nCamera cổng: app EZVIZ, mã thiết bị F7K2Q9',
    'n6': 'Danh sách quà Tết\nÔng bà nội: chè Thái, bánh. Bố mẹ vợ: rượu vang, hoa quả.',
  };

  ItemInfo _copy(ItemInfo i, {String? name, String? folder, bool clearFolder = false, String? color, PlatformInt64? deleted, bool restore = false}) =>
      ItemInfo(
        id: i.id,
        kind: i.kind,
        name: name ?? i.name,
        mime: i.mime,
        createdMs: i.createdMs,
        size: i.size,
        deletedMs: restore ? null : (deleted ?? i.deletedMs),
        durationMs: i.durationMs,
        folder: clearFolder ? null : (folder ?? i.folder),
        color: color ?? i.color,
        space: i.space,
      );

  void _replace(String id, ItemInfo Function(ItemInfo) f) {
    final at = _items.indexWhere((x) => x.id == id);
    if (at >= 0) _items[at] = f(_items[at]);
  }

  List<ItemInfo> _live() => [
        for (final i in _items)
          if (i.deletedMs == null) i
      ]..sort((a, b) => b.createdMs.toInt().compareTo(a.createdMs.toInt()));

  Future<T> _f<T>(T v) => Future<T>.value(v);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final call = invocation;
    final m = call.memberName.toString().split('"')[1].replaceFirst('crateApiVault', '');
    T a<T>(String n) => call.namedArguments[Symbol(n)] as T;
    switch (m) {
      case 'HasVaults':
        return true;
      case 'PinLengths':
        return Uint32List.fromList([previewPin.length]);
      case 'PinLength':
        return previewPin.length;
      case 'AnyPassword':
      case 'HasBiometricUnlock':
      case 'BiometricEnabled':
        return false;
      case 'PinEnabled':
        return true;
      case 'MinPasswordScore':
        return 3;
      case 'PasswordScore':
        return (a<String>('password').length ~/ 6).clamp(0, 4);
      case 'SuggestPassphrase':
        return 'mây-tháng-mười-rơi-phố-cổ';
      case 'SetSecretKey':
        return true;
      case 'UnlockWithPin':
        _open = a<String>('pin') == previewPin;
        return _f<VaultInfo?>(_open ? _vault : null);
      case 'Unlock':
      case 'UnlockWithBiometric':
        return _f<VaultInfo?>(null);
      case 'Lock':
        _open = false;
        return null;
      case 'ListItems':
        return _f(_live());
      case 'ListTrash':
        return _f([
          for (final i in _items)
            if (i.deletedMs != null) i
        ]);
      case 'PurgeExpired':
        return _f(0);
      case 'ItemThumbnail':
        final id = a<String>('id');
        final media = _items.where((x) => x.kind == 'photo' || x.kind == 'video').toList();
        final at = media.indexWhere((x) => x.id == id);
        return _f(at < 0 || photos.isEmpty ? Uint8List(0) : photos[at % photos.length]);
      case 'ItemContent':
        final id = a<String>('id');
        final item = _items.where((x) => x.id == id).firstOrNull;
        if (item?.kind == 'photo') return _f(photos.isEmpty ? Uint8List(0) : photos[_items.indexOf(item!) % photos.length]);
        return _f(Uint8List.fromList(utf8.encode(_text[id] ?? '')));
      case 'AddNote':
        final id = 'n${_next++}';
        final text = a<String>('text');
        _text[id] = text;
        final item = ItemInfo(
          id: id, kind: 'note', name: a<String>('title'), mime: 'text/plain',
          createdMs: a<PlatformInt64>('createdMs'), size: BigInt.from(text.length),
          deletedMs: null, durationMs: null, folder: null, color: null,
        );
        _items.add(item);
        return _f(item);
      case 'UpdateNote':
        final id = a<String>('id');
        _text[id] = a<String>('text');
        _replace(id, (i) => _copy(i, name: a<String>('title')));
        return _f(_items.firstWhere((x) => x.id == id));
      case 'TrashItem':
        _replace(a<String>('id'), (i) => _copy(i, deleted: a<PlatformInt64>('nowMs')));
        return _f<void>(null);
      case 'RestoreItem':
        _replace(a<String>('id'), (i) => _copy(i, restore: true));
        return _f<void>(null);
      case 'DeleteItem':
        _items.removeWhere((x) => x.id == a<String>('id'));
        return _f<void>(null);
      case 'CreateFolder':
        final f = ItemInfo(
          id: 'd${_next++}', kind: 'folder', name: a<String>('name'), mime: '',
          createdMs: a<PlatformInt64>('createdMs'), size: BigInt.zero, deletedMs: null, durationMs: null,
          folder: a<String?>('parent'), color: a<String>('color'), space: a<String>('space'),
        );
        _items.add(f);
        return _f(f);
      case 'UpdateFolder':
        _replace(a<String>('id'), (i) => _copy(i, name: a<String>('name'), color: a<String>('color')));
        return _f(_items.firstWhere((x) => x.id == a<String>('id')));
      case 'MoveItems':
        final to = a<String?>('folder');
        for (final id in a<List<String>>('ids')) {
          _replace(id, (i) => _copy(i, folder: to, clearFolder: to == null));
        }
        return _f<void>(null);
      case 'DeleteFolder':
        final id = a<String>('id');
        final up = _items.firstWhere((x) => x.id == id).folder;
        for (final i in [..._items]) {
          if (i.folder == id) _replace(i.id, (x) => _copy(x, folder: up, clearFolder: up == null));
        }
        _items.removeWhere((x) => x.id == id);
        return _f<void>(null);
      case 'SetIdentity':
        _vault = VaultInfo(id: _vault.id, name: '', icon: a<String>('icon'), color: a<String>('color'), hasPassword: _vault.hasPassword);
        return _f(_vault);
      case 'SecretKeyText':
        return 'CS1-PREV-IEW0-0000-0000-0000-0000-0000';
      case 'SecretKeyFits':
        return true;
      case 'NewSecretKey':
        return Uint8List(16);
      case 'CreateVaultWithPin':
        _vault = VaultInfo(id: 'preview2', name: '', icon: a<String>('icon'), color: a<String>('color'), hasPassword: false);
        return _f(_vault);
      case 'EnablePin':
      case 'SetItemDuration':
        return _f<void>(null);
      default:
        return Future<Never>.error(VaultError.storage);
    }
  }
}
