import 'dart:io';

import 'package:cozysafe/prefs.dart';
import 'package:cozysafe/sync/sync_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => Prefs.dir = Directory.systemTemp.createTempSync('sync-log').path);

  test('the same step again only counts; codes stay plain words', () {
    SyncLog.add('look', 'same');
    SyncLog.add('look', 'same');
    SyncLog.add('look', 'same');
    SyncLog.add('run', 'done-r2-s0-x0-4100ms');
    SyncLog.add('run', 'Failed: a@b.com/x');
    final lines = SyncLog.lines();
    expect(lines, hasLength(3));
    expect(lines[0], endsWith('run failed-a-b-com-x'));
    expect(lines[1], endsWith('run done-r2-s0-x0-4100ms'));
    expect(lines[2], endsWith('look same ×3'));
  });

  test('keeps only the last lines', () {
    for (var i = 0; i < SyncLog.keep + 20; i++) {
      SyncLog.add('run', 'n$i');
    }
    expect(SyncLog.lines(), hasLength(SyncLog.keep));
    expect(SyncLog.lines().first, endsWith('n${SyncLog.keep + 19}'));
  });
}
