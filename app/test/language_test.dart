import 'dart:convert';
import 'dart:io';

import 'package:cozysafe/l10n/app_localizations.dart';
import 'package:cozysafe/language.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final supported = AppLocalizations.supportedLocales;

  test('every language in the picker has an arb file, and every arb file is in the picker', () {
    final files = Directory('lib/l10n')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.startsWith('app_') && n.endsWith('.arb'))
        .map((n) => n.substring(4, n.length - 4))
        .toSet();
    expect(files, languages.map((x) => x.code).toSet());
  });

  test('every arb file has exactly the English keys and the same placeholders', () {
    Map<String, dynamic> read(String code) => jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync());
    final en = read('en');
    final keys = en.keys.where((k) => !k.startsWith('@')).toSet();
    // A placeholder, not a plural branch (`=0{…}`, `other{…}`).
    final ph = RegExp(r'(?<!\w)\{(\w+)[,}]');
    for (final x in languages) {
      final t = read(x.code);
      expect(t.keys.where((k) => !k.startsWith('@')).toSet(), keys, reason: x.code);
      for (final k in keys) {
        expect((t[k] as String).trim(), isNotEmpty, reason: '${x.code} $k');
        expect(ph.allMatches(t[k]).map((m) => m[1]).toSet(), ph.allMatches(en[k]).map((m) => m[1]).toSet(),
            reason: '${x.code} $k');
      }
    }
  });

  test('the same list on iOS and Android', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final android = File('android/app/src/main/res/xml/locales_config.xml').readAsStringSync();
    for (final x in languages) {
      expect(plist, contains('<string>${x.tag}</string>'), reason: x.tag);
      expect(android, contains('android:name="${x.tag}"'), reason: x.tag);
    }
  });

  test('device languages resolve to ours', () {
    Locale r(Locale l) => resolveLocale(l, supported);
    expect(r(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW')), localeOf('zh_Hant'));
    expect(r(const Locale('zh', 'HK')), localeOf('zh_Hant'));
    expect(r(const Locale('zh', 'CN')), const Locale('zh'));
    expect(r(const Locale('pt', 'PT')), const Locale('pt'));
    expect(r(const Locale('vi', 'VN')), const Locale('vi'));
    expect(r(const Locale('pl')), const Locale('en'));
  });

  test('system tags map back to our codes', () {
    expect(AppLanguage.codeOfTag('zh-Hant'), 'zh_Hant');
    expect(AppLanguage.codeOfTag('zh-Hans'), 'zh');
    expect(AppLanguage.codeOfTag('pt-BR'), 'pt');
    expect(AppLanguage.codeOfTag('vi'), 'vi');
    expect(AppLanguage.codeOfTag('pl'), isNull);
  });
}
