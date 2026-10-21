import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';
import 'prefs.dart';

/// The app's languages, each named in itself (the order of the picker). [code] is the
/// arb file's locale; [tag] is what iOS (lproj name) and Android (locales_config.xml)
/// call it.
const languages = <({String code, String tag, String name})>[
  (code: 'en', tag: 'en', name: 'English'),
  (code: 'es', tag: 'es', name: 'Español'),
  (code: 'pt', tag: 'pt-BR', name: 'Português (Brasil)'),
  (code: 'fr', tag: 'fr', name: 'Français'),
  (code: 'de', tag: 'de', name: 'Deutsch'),
  (code: 'it', tag: 'it', name: 'Italiano'),
  (code: 'tr', tag: 'tr', name: 'Türkçe'),
  (code: 'ru', tag: 'ru', name: 'Русский'),
  (code: 'id', tag: 'id', name: 'Bahasa Indonesia'),
  (code: 'th', tag: 'th', name: 'ไทย'),
  (code: 'ja', tag: 'ja', name: '日本語'),
  (code: 'ko', tag: 'ko', name: '한국어'),
  (code: 'zh', tag: 'zh-Hans', name: '简体中文'),
  (code: 'zh_Hant', tag: 'zh-Hant', name: '繁體中文'),
  (code: 'vi', tag: 'vi', name: 'Tiếng Việt'),
];

Locale localeOf(String code) =>
    code == 'zh_Hant' ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant') : Locale(code);

/// Traditional Chinese from a device that says only "zh-TW" / "zh-HK" / "zh-MO" (no
/// script); otherwise Flutter's usual match, English when nothing fits.
Locale resolveLocale(Locale? device, Iterable<Locale> supported) {
  if (device == null) return const Locale('en');
  if (device.languageCode == 'zh') {
    final hant = device.scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(device.countryCode);
    return hant ? localeOf('zh_Hant') : const Locale('zh');
  }
  for (final s in supported) {
    if (s.languageCode == device.languageCode) return s;
  }
  return const Locale('en');
}

/// The language chosen in the app, or null to follow the device.
///
/// On iPhone and Android 13+ the choice lives in the system's own per-app language
/// (Settings → Cozy Safe → Language), so the two always agree: picking here writes it
/// there, and picking there is what the app reads at start. Elsewhere (computers, older
/// Android) it is a pref.
abstract final class AppLanguage {
  static const _channel = MethodChannel('cozysafe/language');
  static const pref = 'language';

  /// What MaterialApp shows; null follows the device locales Flutter reports.
  static final current = ValueNotifier<Locale?>(null);

  /// The picked code, or null for "same as device".
  static String? chosen;

  static bool get _system => Device.iOS || Device.android;

  static Future<void> load() async {
    if (_system) {
      try {
        final tag = await _channel.invokeMethod<String>('get');
        if (tag != null) {
          chosen = _codeOf(tag);
          return; // the system already gives Flutter this language
        }
      } catch (_) {}
      if (Device.iOS) return;
      // Android before 13 has no per-app language: fall through to the pref.
    }
    final saved = Prefs.read(pref);
    if (saved != null && languages.any((x) => x.code == saved)) {
      chosen = saved;
      current.value = localeOf(saved);
    }
  }

  /// Pick a language, or null for the device's.
  static Future<void> choose(String? code) async {
    chosen = code;
    final tag = code == null ? '' : languages.firstWhere((x) => x.code == code).tag;
    if (_system) {
      try {
        // iOS answers with its first language after the change (it only takes over
        // at the next start, so this session switches by hand); Android 13+ applies it
        // at once and answers true; older Android answers null and keeps the pref.
        final now = await _channel.invokeMethod<Object>('set', {'tag': tag});
        if (Device.android && now == true) {
          current.value = null;
          return;
        }
        if (Device.iOS) {
          current.value = code != null ? localeOf(code) : (now is String ? _localeOfTag(now) : null);
          return;
        }
      } catch (_) {}
    }
    Prefs.write(pref, code ?? '');
    current.value = code == null ? null : localeOf(code);
  }

  static String? _codeOf(String tag) {
    final l = _localeOfTag(tag);
    if (!languages.any((x) => x.code.split('_').first == l.languageCode)) return null;
    final r = resolveLocale(l, languages.map((x) => localeOf(x.code)));
    final code = r.scriptCode == 'Hant' ? 'zh_Hant' : r.languageCode;
    return languages.any((x) => x.code == code) ? code : null;
  }

  static Locale _localeOfTag(String tag) {
    final p = tag.replaceAll('_', '-').split('-');
    String? script, country;
    for (final s in p.skip(1)) {
      if (s.length == 4) script = s;
      if (s.length == 2) country = s.toUpperCase();
    }
    return Locale.fromSubtags(languageCode: p.first, scriptCode: script, countryCode: country);
  }

  @visibleForTesting
  static String? codeOfTag(String tag) => _codeOf(tag);
}
