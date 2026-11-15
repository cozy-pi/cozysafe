import 'dart:io';
import 'dart:typed_data';

/// When a picked photo or video was made, so an import does not put years of photos under
/// "Today". Read here in Dart from the file itself (no plugin, no network):
///
/// 1. the date inside the file: EXIF "date taken" of a JPEG, HEIC or PNG, or the creation
///    time in an MP4 / MOV header;
/// 2. else the file's last-modified time, when it is clearly older than this import (a
///    picker's fresh copy carries the moment of the copy, which says nothing);
/// 3. else now.
///
/// Cheap for big imports: one read of the file's head for a picture, a few small reads
/// for a video, whatever the size.

/// Nothing earlier counts as a real date (a zeroed clock, a wrong epoch).
final int _earliestMs = DateTime.utc(1980).millisecondsSinceEpoch;

/// A camera clock may be a little ahead, or in another time zone.
const int _aheadMs = 24 * 60 * 60 * 1000;

/// A picker's copy is made around the start of the import; anything modified up to a
/// minute before it is taken for such a copy.
const int _copySlackMs = 60 * 1000;

/// The date an imported photo or video gets: [takenMs] from inside the file when it is
/// believable, else [modifiedMs] when it is older than the import ([startedMs]), else
/// [nowMs].
int chooseCreatedMs({int? takenMs, int? modifiedMs, required int startedMs, required int nowMs}) {
  if (takenMs != null && takenMs >= _earliestMs && takenMs <= nowMs + _aheadMs) return takenMs;
  if (modifiedMs != null && modifiedMs >= _earliestMs && modifiedMs < startedMs - _copySlackMs) return modifiedMs;
  return nowMs;
}

/// How much of a picture is read to find its EXIF block: it sits near the start.
const int _headBytes = 256 * 1024;

/// The date inside the file at [path], or null (none, unreadable, not a known format).
Future<int?> embeddedDateMs(String path, {required bool video}) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    if (video) return await _mp4DateMs(f);
    final length = await f.length();
    return exifDateMs(await f.read(length < _headBytes ? length : _headBytes));
  } catch (_) {
    return null;
  } finally {
    try {
      await f?.close();
    } catch (_) {}
  }
}

/// The file's last-modified time, or null.
Future<int?> modifiedDateMs(String path) async {
  try {
    return (await File(path).lastModified()).millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}

/// "Date taken" from the EXIF block in the first bytes of a picture: DateTimeOriginal,
/// else DateTimeDigitized, else DateTime; with the time zone the camera noted, else the
/// device's. JPEG and HEIC mark the block "Exif\0\0", PNG has it in an "eXIf" chunk.
int? exifDateMs(Uint8List head) {
  try {
    for (var i = 0; i + 12 < head.length; i++) {
      final c = head[i];
      int tiff;
      if (c == 0x45 && _is(head, i, const [0x45, 0x78, 0x69, 0x66, 0, 0])) {
        tiff = i + 6; // "Exif\0\0"
      } else if (c == 0x65 && _is(head, i, const [0x65, 0x58, 0x49, 0x66])) {
        tiff = i + 4; // "eXIf"
      } else {
        continue;
      }
      final ms = _tiffDateMs(Uint8List.sublistView(head, tiff));
      if (ms != null) return ms;
    }
  } catch (_) {}
  return null;
}

bool _is(Uint8List b, int at, List<int> what) {
  if (at + what.length > b.length) return false;
  for (var i = 0; i < what.length; i++) {
    if (b[at + i] != what[i]) return false;
  }
  return true;
}

const _tagExifIfd = 0x8769;
const _tagDateTime = 0x0132;
const _tagOriginal = 0x9003;
const _tagDigitized = 0x9004;
const _tagOffsetOriginal = 0x9011;

int? _tiffDateMs(Uint8List t) {
  if (t.length < 8) return null;
  final Endian e;
  if (t[0] == 0x49 && t[1] == 0x49) {
    e = Endian.little;
  } else if (t[0] == 0x4D && t[1] == 0x4D) {
    e = Endian.big;
  } else {
    return null;
  }
  final d = ByteData.sublistView(t);
  if (d.getUint16(2, e) != 42) return null;

  /// The entries of the directory at [at]: tag to (count, where its value is).
  Map<int, (int, int)> entries(int at) {
    final found = <int, (int, int)>{};
    if (at <= 0 || at + 2 > t.length) return found;
    final n = d.getUint16(at, e);
    for (var i = 0; i < n; i++) {
      final p = at + 2 + i * 12;
      if (p + 12 > t.length) break;
      final count = d.getUint32(p + 4, e);
      // ASCII of up to 4 bytes sits in the entry itself; longer values are pointed to.
      found[d.getUint16(p, e)] = (count, count <= 4 ? p + 8 : d.getUint32(p + 8, e));
    }
    return found;
  }

  String? text(Map<int, (int, int)> dir, int tag) {
    final v = dir[tag];
    if (v == null) return null;
    final (count, at) = v;
    if (count <= 0 || count > 64 || at + count > t.length) return null;
    return String.fromCharCodes(t.sublist(at, at + count)).split('\u0000').first.trim();
  }

  final first = entries(d.getUint32(4, e));
  final exifAt = first[_tagExifIfd];
  final exif = exifAt == null ? const <int, (int, int)>{} : entries(d.getUint32(exifAt.$2, e));
  final when = text(exif, _tagOriginal) ?? text(exif, _tagDigitized) ?? text(first, _tagDateTime);
  if (when == null) return null;
  return parseExifDate(when, offset: text(exif, _tagOffsetOriginal));
}

/// "2019:07:04 18:30:05" (and "+07:00" when the camera noted its zone) as milliseconds
/// since the Unix epoch; null for anything else, the all-zero date included.
int? parseExifDate(String when, {String? offset}) {
  final m = RegExp(r'^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(when);
  if (m == null) return null;
  final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (p[0] == 0 || p[1] < 1 || p[1] > 12 || p[2] < 1 || p[2] > 31 || p[3] > 23 || p[4] > 59 || p[5] > 60) return null;
  final z = offset == null ? null : RegExp(r'^([+\-])(\d{2}):(\d{2})$').firstMatch(offset);
  if (z == null) return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]).millisecondsSinceEpoch;
  final minutes = (int.parse(z.group(2)!) * 60 + int.parse(z.group(3)!)) * (z.group(1) == '-' ? -1 : 1);
  return DateTime.utc(p[0], p[1], p[2], p[3], p[4], p[5]).millisecondsSinceEpoch - minutes * 60 * 1000;
}

/// Seconds from 1904 (the MP4 epoch) to 1970.
const int _mp4EpochSeconds = 2082844800;

/// The creation time in the movie header (`moov` → `mvhd`) of an MP4 or MOV. The boxes
/// are walked by their sizes, so a 4 GB video costs a handful of small reads wherever
/// its header sits.
Future<int?> _mp4DateMs(RandomAccessFile f) async {
  final length = await f.length();
  var at = 0;
  for (var boxes = 0; boxes < 64 && at + 8 <= length; boxes++) {
    await f.setPosition(at);
    final head = await f.read(16);
    if (head.length < 8) return null;
    final d = ByteData.sublistView(head);
    var size = d.getUint32(0);
    var payload = at + 8;
    if (size == 1) {
      if (head.length < 16) return null;
      size = d.getUint64(8);
      payload = at + 16;
    } else if (size == 0) {
      size = length - at;
    }
    if (size < 8) return null;
    if (_is(head, 4, const [0x6D, 0x6F, 0x6F, 0x76])) {
      // "moov": its header box comes first; 64 KB is far more than enough to reach it.
      await f.setPosition(payload);
      final want = at + size - payload;
      return mvhdDateMs(await f.read(want < 64 * 1024 ? want : 64 * 1024));
    }
    at += size;
  }
  return null;
}

/// The creation time of the `mvhd` box among the first boxes of a `moov` box's content.
int? mvhdDateMs(Uint8List moov) {
  try {
    final d = ByteData.sublistView(moov);
    var at = 0;
    while (at + 8 <= moov.length) {
      final size = d.getUint32(at);
      if (_is(moov, at + 4, const [0x6D, 0x76, 0x68, 0x64])) {
        final version = moov[at + 8];
        final seconds = version == 1 ? d.getUint64(at + 12) : d.getUint32(at + 12);
        if (seconds == 0) return null;
        return (seconds - _mp4EpochSeconds) * 1000;
      }
      if (size < 8) return null;
      at += size;
    }
  } catch (_) {}
  return null;
}
