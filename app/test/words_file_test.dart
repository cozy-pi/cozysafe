import 'package:cozysafe/widgets/secret.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the saved file gives back the 24 words, without its title and note', () {
    final words = [for (var i = 1; i <= 24; i++) 'word$i'];
    final file = 'Recovery Key\n\n${[for (final (i, w) in words.indexed) '${i + 1}. $w'].join('\n')}\n\nKeep it safe.\n';
    expect(wordsFromText(file), words.join(' '));
  });

  test('plain text without numbers is taken whole', () {
    expect(wordsFromText('  alpha beta gamma \n'), 'alpha beta gamma');
  });
}
