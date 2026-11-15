// An imported photo or video gets the date it was made, not the day of the import
// (lib/media_date.dart): the date inside the file, else the file's own time when it is
// older than the import, else now.

import 'dart:io';
import 'dart:typed_data';

import 'package:cozysafe/media_date.dart';
import 'package:flutter_test/flutter_test.dart';

/// A TIFF block as cameras write it: DateTime in the first directory, DateTimeOriginal
/// (and the time zone, when given) in the Exif directory.
Uint8List _tiff({String? changed, String? taken, String? zone, Endian e = Endian.little}) {
  final b = BytesBuilder();
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, e)).buffer.asUint8List());
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, e)).buffer.asUint8List());
  void text(String s) => b.add([...s.codeUnits, 0]);
  void entry(int tag, int type, int count, int value) {
    u16(tag);
    u16(type);
    u32(count);
    u32(value);
  }

  b.add(e == Endian.little ? [0x49, 0x49] : [0x4D, 0x4D]);
  u16(42);
  u32(8);
  // First directory at 8: two entries, then the next-directory offset.
  const firstEnd = 8 + 2 + 2 * 12 + 4; // 38
  const changedAt = firstEnd; // 20 bytes
  const exifAt = changedAt + 20; // 58
  const exifEnd = exifAt + 2 + 2 * 12 + 4; // 88
  const takenAt = exifEnd; // 20 bytes
  const zoneAt = takenAt + 20; // 7 bytes
  u16(2);
  entry(0x0132, 2, changed == null ? 0 : 20, changedAt);
  entry(0x8769, 4, 1, exifAt);
  u32(0);
  text((changed ?? '').padRight(19));
  u16(2);
  entry(0x9003, 2, taken == null ? 0 : 20, takenAt);
  entry(0x9011, 2, zone == null ? 0 : 7, zoneAt);
  u32(0);
  text((taken ?? '').padRight(19));
  text((zone ?? '').padRight(6));
  return b.toBytes();
}

Uint8List _jpeg(Uint8List tiff) => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE1, (tiff.length + 8) >> 8, (tiff.length + 8) & 0xFF,
      ...'Exif'.codeUnits, 0, 0,
      ...tiff,
      0xFF, 0xD9,
    ]);

Uint8List _box(String type, List<int> content) {
  final size = content.length + 8;
  return Uint8List.fromList([size >> 24, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF, ...type.codeUnits, ...content]);
}

/// A movie header whose creation time is [seconds] since 1904.
Uint8List _mvhd(int seconds, {int version = 0}) => _box('mvhd', [
      version, 0, 0, 0,
      if (version == 1) ...[0, 0, 0, 0],
      seconds >> 24, (seconds >> 16) & 0xFF, (seconds >> 8) & 0xFF, seconds & 0xFF,
      ...List.filled(20, 0),
    ]);

const _epoch1904 = 2082844800;

void main() {
  final now = DateTime(2026, 11, 15, 10).millisecondsSinceEpoch;
  final started = now - 5000;
  final summer2019 = DateTime(2019, 7, 4, 18, 30, 5).millisecondsSinceEpoch;

  group('which date an imported item gets', () {
    test('the date inside the file comes first', () {
      expect(chooseCreatedMs(takenMs: summer2019, modifiedMs: now - 1000, startedMs: started, nowMs: now), summer2019);
    });

    test('no date inside: the file time, when it is older than the import', () {
      final lastYear = DateTime(2025, 3, 1).millisecondsSinceEpoch;
      expect(chooseCreatedMs(modifiedMs: lastYear, startedMs: started, nowMs: now), lastYear);
    });

    test('a copy the picker just made says nothing: now', () {
      // Written during this import, or within the minute before it.
      expect(chooseCreatedMs(modifiedMs: now - 1000, startedMs: started, nowMs: now), now);
      expect(chooseCreatedMs(modifiedMs: started - 30 * 1000, startedMs: started, nowMs: now), now);
      expect(chooseCreatedMs(startedMs: started, nowMs: now), now);
    });

    test('dates that cannot be right are passed over', () {
      final lastYear = DateTime(2025, 3, 1).millisecondsSinceEpoch;
      // A zeroed clock (1970, 1904) and a date years ahead.
      expect(chooseCreatedMs(takenMs: 0, modifiedMs: lastYear, startedMs: started, nowMs: now), lastYear);
      expect(chooseCreatedMs(takenMs: -2082844800000, startedMs: started, nowMs: now), now);
      expect(chooseCreatedMs(takenMs: DateTime(2031).millisecondsSinceEpoch, startedMs: started, nowMs: now), now);
      expect(chooseCreatedMs(modifiedMs: 0, startedMs: started, nowMs: now), now);
      // A camera a few hours ahead (another time zone) is believed.
      final ahead = now + 5 * 60 * 60 * 1000;
      expect(chooseCreatedMs(takenMs: ahead, startedMs: started, nowMs: now), ahead);
    });
  });

  group('the date inside a picture', () {
    test('an EXIF date is the device\'s local time unless the camera noted its zone', () {
      expect(parseExifDate('2019:07:04 18:30:05'), summer2019);
      expect(parseExifDate('2019:07:04 18:30:05', offset: '+07:00'), DateTime.utc(2019, 7, 4, 11, 30, 5).millisecondsSinceEpoch);
      expect(parseExifDate('2019:07:04 18:30:05', offset: '-05:30'), DateTime.utc(2019, 7, 5, 0, 0, 5).millisecondsSinceEpoch);
      expect(parseExifDate('0000:00:00 00:00:00'), isNull);
      expect(parseExifDate('                   '), isNull);
      expect(parseExifDate('yesterday'), isNull);
    });

    test('JPEG: date taken wins over the date last changed', () {
      final jpeg = _jpeg(_tiff(changed: '2024:01:02 03:04:05', taken: '2019:07:04 18:30:05'));
      expect(exifDateMs(jpeg), summer2019);
    });

    test('big-endian, with the camera\'s time zone', () {
      final jpeg = _jpeg(_tiff(taken: '2019:07:04 18:30:05', zone: '+07:00', e: Endian.big));
      expect(exifDateMs(jpeg), DateTime.utc(2019, 7, 4, 11, 30, 5).millisecondsSinceEpoch);
    });

    test('only the date last changed: that one', () {
      expect(exifDateMs(_jpeg(_tiff(changed: '2024:01:02 03:04:05'))), DateTime(2024, 1, 2, 3, 4, 5).millisecondsSinceEpoch);
    });

    test('HEIC keeps the same block somewhere after its header; PNG in an eXIf chunk', () {
      final tiff = _tiff(taken: '2019:07:04 18:30:05');
      final heic = Uint8List.fromList([...List.filled(3000, 7), 0, 0, 0, 6, ...'Exif'.codeUnits, 0, 0, ...tiff, ...List.filled(500, 9)]);
      expect(exifDateMs(heic), summer2019);
      final png = Uint8List.fromList([0x89, ...'PNG'.codeUnits, 13, 10, 26, 10, 0, 0, 0, tiff.length, ...'eXIf'.codeUnits, ...tiff]);
      expect(exifDateMs(png), summer2019);
    });

    test('no EXIF, or a broken one: no date, and no crash', () {
      expect(exifDateMs(Uint8List.fromList(List.filled(4000, 0x45))), isNull);
      expect(exifDateMs(Uint8List(0)), isNull);
      final cut = _jpeg(_tiff(taken: '2019:07:04 18:30:05'));
      expect(exifDateMs(Uint8List.sublistView(cut, 0, 40)), isNull);
      // A directory offset pointing far outside the block.
      final wild = _jpeg(_tiff(taken: '2019:07:04 18:30:05'));
      wild[12 + 4] = 0xFF;
      wild[12 + 5] = 0xFF;
      expect(exifDateMs(wild), isNull);
    });
  });

  group('the date inside a video', () {
    final utc = DateTime.utc(2019, 7, 4, 11, 30, 5);
    final seconds = utc.millisecondsSinceEpoch ~/ 1000 + _epoch1904;

    test('the movie header\'s creation time, counted from 1904', () {
      expect(mvhdDateMs(_mvhd(seconds)), utc.millisecondsSinceEpoch);
      expect(mvhdDateMs(_mvhd(seconds, version: 1)), utc.millisecondsSinceEpoch);
      // Other boxes before it are stepped over; a zero time is no date.
      expect(mvhdDateMs(Uint8List.fromList([..._box('free', List.filled(12, 0)), ..._mvhd(seconds)])), utc.millisecondsSinceEpoch);
      expect(mvhdDateMs(_mvhd(0)), isNull);
      expect(mvhdDateMs(Uint8List.fromList(List.filled(7, 1))), isNull);
    });

    test('read from a file whose header sits after the video data, as phones write it', () async {
      final dir = Directory.systemTemp.createTempSync('media-date');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = File('${dir.path}/clip.mov')
        ..writeAsBytesSync([
          ..._box('ftyp', 'qt  '.codeUnits),
          ..._box('mdat', List.filled(300000, 3)),
          ..._box('moov', _mvhd(seconds)),
        ]);
      expect(await embeddedDateMs(video.path, video: true), utc.millisecondsSinceEpoch);

      final photo = File('${dir.path}/photo.jpg')..writeAsBytesSync(_jpeg(_tiff(taken: '2019:07:04 18:30:05')));
      expect(await embeddedDateMs(photo.path, video: false), summer2019);

      // Not a video at all, and a file that is not there: no date.
      final text = File('${dir.path}/notes.mp4')..writeAsStringSync('hello, this is not a video');
      expect(await embeddedDateMs(text.path, video: true), isNull);
      expect(await embeddedDateMs('${dir.path}/missing.jpg', video: false), isNull);
      expect(await modifiedDateMs('${dir.path}/missing.jpg'), isNull);
      expect(await modifiedDateMs(photo.path), isNotNull);
    });
  });
}
