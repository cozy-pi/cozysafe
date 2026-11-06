import 'dart:convert';
import 'dart:math';

import 'package:cozysafe/entries/entry.dart';
import 'package:cozysafe/entries/password_gen.dart';
import 'package:cozysafe/entries/totp.dart';
import 'package:cozysafe/item_kind.dart';
import 'package:flutter_test/flutter_test.dart';

String b32(String ascii) {
  const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = '';
  for (final c in ascii.codeUnits) {
    bits += c.toRadixString(2).padLeft(8, '0');
  }
  while (bits.length % 5 != 0) {
    bits += '0';
  }
  return [for (var i = 0; i < bits.length; i += 5) a[int.parse(bits.substring(i, i + 5), radix: 2)]].join();
}

void main() {
  test('RFC 6238 test vectors, all three hashes', () {
    final seeds = {
      'SHA1': '12345678901234567890',
      'SHA256': '12345678901234567890123456789012',
      'SHA512': '1234567890123456789012345678901234567890123456789012345678901234',
    };
    final expected = {
      59: {'SHA1': '94287082', 'SHA256': '46119246', 'SHA512': '90693936'},
      1111111109: {'SHA1': '07081804', 'SHA256': '68084774', 'SHA512': '25091201'},
      1234567890: {'SHA1': '89005924', 'SHA256': '91819424', 'SHA512': '93441116'},
      20000000000: {'SHA1': '65353130', 'SHA256': '77737706', 'SHA512': '47863826'},
    };
    expected.forEach((t, codes) {
      codes.forEach((algo, code) {
        final totp = Totp(secret: b32(seeds[algo]!), algo: algo, digits: 8);
        expect(totp.code(DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true)), code, reason: '$algo $t');
      });
    });
    final t = Totp(secret: b32(seeds['SHA1']!));
    expect(t.secondsLeft(DateTime.fromMillisecondsSinceEpoch(59 * 1000)), 1);
  });

  test('otpauth links and pasted secrets', () {
    final t = Totp.parse('otpauth://totp/GitHub:kien%40example.com?secret=jbsw y3dp ehpk3pxp&issuer=GitHub&digits=8&period=60&algorithm=sha256')!;
    expect([t.secret, t.issuer, t.account, t.digits, t.period, t.algo],
        ['JBSWY3DPEHPK3PXP', 'GitHub', 'kien@example.com', 8, 60, 'SHA256']);
    expect(Totp.parse('jbsw-y3dp-ehpk-3pxp')!.secret, 'JBSWY3DPEHPK3PXP');
    for (final bad in ['', 'short', 'JBSWY3DPEHPK3PX1', 'otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP',
      'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=12', 'https://example.com']) {
      expect(Totp.parse(bad), isNull, reason: bad);
    }
  });

  test('generated passwords mix every kind and repeat nothing', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final p = generatePassword(random: Random(i));
      expect(p.length, 20);
      expect(RegExp(r'[a-z]').hasMatch(p) && RegExp(r'[A-Z]').hasMatch(p) && RegExp(r'[0-9]').hasMatch(p), isTrue);
      expect(RegExp(r'[Il0O1]').hasMatch(p), isFalse);
      seen.add(p);
    }
    expect(seen.length, 200);
  });

  test('an entry keeps fields it does not know, and drops empty ones', () {
    final e = Entry.decode(ItemKind.login, '{"v":1,"username":"kien","password":"p","later":{"x":[1,2]}}');
    e.password = 'new';
    e.urls = ['  https://github.com ', ''];
    e.notes = '  ';
    e.totp = Totp.parse('JBSWY3DPEHPK3PXP');
    final back = jsonDecode(e.encode()) as Map<String, Object?>;
    expect(back['later'], {'x': [1, 2]});
    expect(back['password'], 'new');
    expect(back['urls'], ['https://github.com']);
    expect(back.containsKey('notes'), isFalse);
    expect((back['otp'] as Map)['secret'], 'JBSWY3DPEHPK3PXP');
    expect(Entry(ItemKind.otp).encode(), '{"v":1}');
  });

  test('a one-time code item takes the issuer and account from the link', () {
    final e = Entry(ItemKind.otp)..totp = Totp.parse('otpauth://totp/Google:me?secret=JBSWY3DPEHPK3PXP');
    expect([e.issuer, e.account, e.totp!.secret], ['Google', 'me', 'JBSWY3DPEHPK3PXP']);
  });

  test('recovery codes: one per line, a code may hold a space', () {
    expect(Entry.splitCodes('1234 5678\n8765 4321\r\n, abcd-efgh'), ['1234 5678', '8765 4321', 'abcd-efgh']);
    final e = Entry(ItemKind.codes)..codes = [(code: 'a', used: true), (code: 'b', used: false)];
    expect(e.codes.map((c) => (c.code, c.used)), [('a', true), ('b', false)]);
  });
}
