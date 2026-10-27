// Wrong-PIN waits (owner 2026-10-26): moving the phone's date cannot shorten them, and
// the PIN goes after 10 wrong tries in a row.

import 'package:cozysafe/secret_key_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Duration mono;
  late DateTime wall;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    mono = Duration.zero;
    wall = DateTime(2026, 10, 27, 9);
    TryWait.monotonic = () => mono;
    TryWait.wall = () => wall;
  });

  Future<Duration?> left() async => (await PinStore.waitUntil())?.difference(wall);

  Future<void> fail(int times) async {
    for (var i = 0; i < times; i++) {
      await PinStore.addFail();
    }
  }

  test('the fifth wrong PIN waits a minute, which passes with time', () async {
    await fail(5);
    expect(await left(), const Duration(minutes: 1));
    mono += const Duration(seconds: 40);
    wall = wall.add(const Duration(seconds: 40));
    expect(await left(), const Duration(seconds: 20));
    mono += const Duration(seconds: 25);
    wall = wall.add(const Duration(seconds: 25));
    expect(await left(), isNull);
  });

  test('moving the date forward does not shorten the wait', () async {
    await fail(6); // 5 minutes
    wall = wall.add(const Duration(days: 1));
    mono += const Duration(seconds: 10);
    expect(await left(), const Duration(minutes: 5) - const Duration(seconds: 10));
  });

  test('moving the date back does not lengthen it either', () async {
    await fail(5);
    wall = wall.subtract(const Duration(hours: 3));
    mono += const Duration(seconds: 30);
    expect(await left(), Duration.zero + const Duration(seconds: 60));
    // Only once both clocks moved on does time count.
    wall = wall.add(const Duration(seconds: 30));
    mono += const Duration(seconds: 30);
    expect(await left(), const Duration(seconds: 30));
  });

  test('a right PIN clears the wait; the wipe count is ten', () async {
    await fail(7);
    expect(await left(), isNotNull);
    await PinStore.resetFails();
    expect(await left(), isNull);
    expect(PinStore.wipeAt, 10);
  });

  test('wiping removes the PIN files and starts the count again', () async {
    await fail(10);
    String? forgot;
    await PinStore.wipe('/lib', ({required String dir}) async => forgot = dir);
    expect(forgot, '/lib');
    expect(await PinStore.fails(), 0);
    expect(await left(), isNull);
  });
}
