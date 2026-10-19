// The dock's mode strip must be easy to hit: a swipe anywhere on the dock (also on the
// row of buttons) changes the mode while the finger is still down, and a tap in the
// gap between two labels still picks one.

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/theme.dart';
import 'package:cozysafe/widgets/add_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const modes = [AddMode.note, AddMode.library, AddMode.camera, AddMode.file];

  Future<List<AddMode>> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(430, 932) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final seen = <AddMode>[];
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: AddDock(
          modes: modes,
          leading: const SizedBox(width: 46),
          trailing: const SizedBox(width: 46),
          onAction: (_) {},
          onModeChanged: seen.add,
        ),
      ),
    ));
    await t.pump();
    return seen;
  }

  testWidgets('a swipe on the button row switches mode before the finger lifts', (t) async {
    final seen = await pump(t);
    // Start on the big button, well below the labels.
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('add-dock-action'))));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(-20, 0));
      await t.pump();
    }
    expect(seen, isNotEmpty, reason: 'mode changed while still dragging');
    expect(seen.first, AddMode.camera);
    await g.up();
  });

  testWidgets('a tap just beside a label picks it', (t) async {
    final seen = await pump(t);
    final label = t.getRect(find.text('CAMERA'));
    // 6 px left of the word: in the gap, which belongs to it.
    await t.tapAt(Offset(label.left - 6, label.center.dy));
    await t.pump();
    expect(seen, [AddMode.camera]);
  });
}
