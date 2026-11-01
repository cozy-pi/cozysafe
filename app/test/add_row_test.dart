// The quick buttons above + span the screen in one row: a tap beside them closes it, as a
// tap anywhere outside (owner 2026-10-31: the gaps did nothing), and a button still picks.

import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a tap beside the quick buttons closes; a button picks', (t) async {
    var closed = 0;
    final picked = <AddWhat>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AddRow(
          open: true,
          ways: const [
            (AddWhat.video, Icons.videocam_rounded, 'Video'),
            (AddWhat.photo, Icons.photo_camera_rounded, 'Photo'),
            (AddWhat.voice, Icons.mic_none_rounded, 'Voice'),
          ],
          bottom: 100,
          hovered: null,
          onPick: picked.add,
          onClose: () => closed++,
          onGone: () {},
        ),
      ),
    ));
    // Past the scroll hint's wait (a narrow screen shows the row slides).
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    final row = t.getRect(find.byKey(const ValueKey('add-row-gap')));
    // Near the left edge, level with the buttons, away from all of them.
    await t.tapAt(Offset(row.left + 6, row.center.dy));
    await t.pump();
    expect(closed, 1);
    await t.tap(find.byIcon(Icons.photo_camera_rounded));
    await t.pump();
    expect(picked, [AddWhat.photo]);
    expect(closed, 1);
  });
}
