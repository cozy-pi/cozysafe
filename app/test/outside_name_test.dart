import 'package:cozysafe/screens/file_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a copy going out keeps its extension, or gets one from its kind', () {
    expect(outsideName('Clip.MOV', 'video/quicktime'), 'Clip.MOV');
    expect(outsideName('Photo 12', 'image/jpeg'), 'Photo 12.jpg');
    expect(outsideName('a/b:c', 'application/pdf'), 'a-b-c.pdf');
    expect(outsideName('  ', 'video/mp4'), 'file.mp4');
    expect(outsideName('notes.', 'application/x-unknown'), 'notes.');
  });
}
