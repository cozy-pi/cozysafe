// The bar shows the three kinds the vault holds most of, most on the left, and the quick
// buttons above + add those three, the most in the middle (owner 2026-11-03).

import 'package:cozysafe/l10n/app_localizations_en.dart';
import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugVoice = true);
  tearDown(() => debugVoice = false);

  const all = [VaultSection.home, VaultSection.library, VaultSection.file, VaultSection.note, VaultSection.audio];
  int Function(VaultSection) counts(Map<VaultSection, int> m) => (s) => m[s] ?? 0;

  test('the bar: overview, then the three most held, most first', () {
    final count = counts({VaultSection.note: 9, VaultSection.audio: 5, VaultSection.library: 2, VaultSection.file: 1});
    expect(barSections(all, count), [VaultSection.home, VaultSection.note, VaultSection.audio, VaultSection.library]);
  });

  test('a tie keeps the fixed order; kinds the vault does not hold get no tab', () {
    final count = counts({VaultSection.file: 3, VaultSection.note: 3});
    expect(barSections(const [VaultSection.home, VaultSection.file, VaultSection.note], count),
        [VaultSection.home, VaultSection.file, VaultSection.note]);
  });

  test('quick buttons: second, most, third', () {
    final count = counts({VaultSection.note: 9, VaultSection.audio: 5, VaultSection.library: 2});
    final ways = quickWays(AppLocalizationsEn(), count, camera: true).map((w) => w.$1);
    expect(ways, [AddWhat.voice, AddWhat.note, AddWhat.photo]);
  });

  test('quick buttons are three even in an empty vault', () {
    final ways = quickWays(AppLocalizationsEn(), (_) => 0, camera: false).map((w) => w.$1);
    expect(ways, [AddWhat.file, AddWhat.photos, AddWhat.note]);
  });
}
