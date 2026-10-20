import 'package:cozysafe/capture_name.dart';
import 'package:cozysafe/item_kind.dart';
import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('names say what and when, and are safe as file names', (t) async {
    late AppLocalizations vi, en;
    await t.pumpWidget(Localizations(
      locale: const Locale('vi'),
      delegates: AppLocalizations.localizationsDelegates,
      child: Builder(builder: (c) {
        vi = AppLocalizations.of(c);
        return const SizedBox();
      }),
    ));
    await t.pumpWidget(Localizations(
      locale: const Locale('en'),
      delegates: AppLocalizations.localizationsDelegates,
      child: Builder(builder: (c) {
        en = AppLocalizations.of(c);
        return const SizedBox();
      }),
    ));
    final at = DateTime(2026, 10, 20, 9, 5, 7);
    expect(captureName(vi, ItemKind.photo, at, '.jpg'), 'Ảnh 20-10-2026 09.05.07.jpg');
    expect(captureName(vi, ItemKind.video, at, '.mp4'), 'Video 20-10-2026 09.05.07.mp4');
    expect(captureName(en, ItemKind.audio, at, '.m4a'), 'Recording 20-10-2026 09.05.07.m4a');
    for (final n in [captureName(vi, ItemKind.photo, at, '.jpg'), captureName(en, ItemKind.video, at, '.mov')]) {
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
