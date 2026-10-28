import 'package:cozysafe/capture_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('names say when, and are safe as file names', () {
    final at = DateTime(2026, 10, 20, 9, 5, 7);
    expect(captureName(at, '.jpg'), '20-10-2026 09.05.07.jpg');
    expect(captureName(at, '.m4a'), '20-10-2026 09.05.07.m4a');
    for (final n in [captureName(at, '.jpg'), captureName(at, '.mov')]) {
      expect(n.contains('/') || n.contains(':') || n.contains(r'\'), isFalse);
    }
  });

  test('made-up picker names are replaced, real ones kept', () {
    for (final n in [
      'image_picker_3F2A9C1B-1D2E-4F5A-8B9C-0D1E2F3A4B5C.jpg',
      'scaled_1000012345.jpg',
      '3F2A9C1B-1D2E-4F5A-8B9C-0D1E2F3A4B5C.jpeg',
      '1000012345.jpg',
      '.jpg',
    ]) {
      expect(isMadeUpName(n), isTrue, reason: n);
    }
    for (final n in ['IMG_4810.HEIC', 'PXL_20231001_101010.jpg', 'Sinh nhật bé Na.MOV', 'Hop-dong.pdf']) {
      expect(isMadeUpName(n), isFalse, reason: n);
    }
  });
}
