// A sync waiting or running keeps the vault from locking itself for lack of touches
// (owner 2026-10-26: a nearby sync was cut by the idle lock).

import 'package:cozysafe/sync/awake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('busy while anyone holds it, free once all let go', () async {
    expect(Awake.busy, isFalse);
    await Awake.set(true, who: 'nearby');
    await Awake.set(true);
    expect(Awake.busy, isTrue);
    await Awake.set(false);
    expect(Awake.busy, isTrue, reason: 'the waiting page still holds it');
    await Awake.set(false, who: 'nearby');
    expect(Awake.busy, isFalse);
    // Letting go twice is harmless.
    await Awake.set(false);
    expect(Awake.busy, isFalse);
  });
}
