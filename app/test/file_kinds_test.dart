// Each common kind of file has its own icon and colour (owner 2026-10-31).

import 'package:cozysafe/file_kinds.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the extension decides, case aside; the MIME type when there is none', () {
    expect(fileKindOf('Ho-chieu.PDF', ''), FileKind.pdf);
    expect(fileKindOf('IMG_4810.HEIC', 'image/heic'), FileKind.image);
    expect(fileKindOf('Sinh nhật.MOV', ''), FileKind.video);
    expect(fileKindOf('hop-dong.docx', ''), FileKind.document);
    expect(fileKindOf('bang-luong.xlsx', ''), FileKind.sheet);
    expect(fileKindOf('du-an.pptx', ''), FileKind.slides);
    expect(fileKindOf('anh.zip', ''), FileKind.archive);
    expect(fileKindOf('id_rsa.pub', ''), FileKind.key);
    expect(fileKindOf('wifi-config.json', ''), FileKind.code);
    expect(fileKindOf('ghi-chu.txt', ''), FileKind.text);
    expect(fileKindOf('scan', 'application/pdf'), FileKind.pdf);
    expect(fileKindOf('voice', 'audio/mp4'), FileKind.audio);
    expect(fileKindOf('blob.xyz', 'application/octet-stream'), FileKind.other);
  });

  test('every kind has its own colour', () {
    final colours = {for (final k in FileKind.values) k.color.toARGB32()};
    expect(colours.length, FileKind.values.length);
  });
}
