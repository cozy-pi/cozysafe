import 'package:cozysafe/screens/file_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text files are recognised by extension, case-insensitively', () {
    expect(textKindOf('notes.MD'), TextKind.markdown);
    expect(textKindOf('wifi.json'), TextKind.json);
    expect(textKindOf('server.log'), TextKind.prose);
    expect(textKindOf('id_ed25519.pub'), TextKind.code);
    expect(textKindOf('.gitignore'), TextKind.code);
    expect(textKindOf('README'), TextKind.prose);
    expect(textLabelOf('README'), 'TXT');
  });

  test('binary look-alikes are not read as text', () {
    for (final name in ['photo.jpg', 'report.pdf', 'letter.docx', 'notes.rtf', 'settings.plist', 'archive.zip', 'noext']) {
      expect(textKindOf(name), isNull, reason: name);
    }
  });
}
