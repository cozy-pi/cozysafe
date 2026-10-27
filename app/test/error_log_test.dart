// The error log (owner 2026-10-26): codes and times only, kept few, safe to copy.

import 'dart:io';

import 'package:cozysafe/error_log.dart';
import 'package:cozysafe/prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => Prefs.dir = Directory.systemTemp.createTempSync('errlog').path);

  test('a line is a time, a place and a code, nothing else slips in', () {
    ErrorLog.add('drive sign in', 'Canceled: /Users/someone/x|y');
    final [(_, place, code)] = ErrorLog.entries();
    expect(place, 'drive-sign-in');
    expect(code, 'canceled-users-someone-x-y');
  });

  test('only the last ones are kept, newest first', () {
    for (var i = 0; i < ErrorLog.keep + 20; i++) {
      ErrorLog.add('sync', 'e$i');
    }
    final all = ErrorLog.entries();
    expect(all.length, ErrorLog.keep);
    expect(all.first.$3, 'e${ErrorLog.keep + 19}');
  });

  test('the report names the app and lists the codes', () {
    ErrorLog.add('sync', 'drive-rate-limited');
    final text = ErrorLog.report(version: '0.1.76 (1290)');
    expect(text, startsWith('Cozy Safe 0.1.76 (1290)'));
    expect(text, contains('sync drive-rate-limited'));
  });
}
