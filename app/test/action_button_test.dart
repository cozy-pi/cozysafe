// + must not fire for a finger passing over it (owner 2026-10-24: with + on the left,
// swiping back from the edge kept opening it).

import 'package:cozysafe/widgets/vault_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a swipe or a brush over + is not a tap; a tap is', (t) async {
    var taps = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(child: ActionButton(icon: Icons.add, tooltip: 'Add', onTap: () => taps++)),
      ),
    ));
    final plus = find.byKey(const ValueKey('vault-action'));
    // Sideways across the button, as a back swipe passes over it.
    await t.dragFrom(t.getCenter(plus), const Offset(40, 0));
    await t.pumpAndSettle();
    expect(taps, 0);
    // A short brush that moved a little.
    final g = await t.startGesture(t.getCenter(plus));
    await g.moveBy(const Offset(4, 0), timeStamp: const Duration(milliseconds: 10));
    await g.up(timeStamp: const Duration(milliseconds: 20));
    await t.pumpAndSettle();
    expect(taps, 0);
    // A real tap: the finger stays put.
    final tap = await t.startGesture(t.getCenter(plus));
    await tap.up(timeStamp: const Duration(milliseconds: 90));
    await t.pumpAndSettle();
    expect(taps, 1);
    // Resting a while and moving a hair is still a tap.
    final slow = await t.startGesture(t.getCenter(plus));
    await slow.moveBy(const Offset(4, 0), timeStamp: const Duration(milliseconds: 60));
    await slow.up(timeStamp: const Duration(milliseconds: 120));
    await t.pumpAndSettle();
    expect(taps, 2);
  });
}
